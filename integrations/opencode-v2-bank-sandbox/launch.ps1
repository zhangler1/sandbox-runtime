param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$SandboxExe,
    [Parameter(Mandatory=$true)][string]$OpenCodeExe,
    [Parameter(Mandatory=$true)][string]$Model,
    [Parameter(Mandatory=$true)][string]$Message,
    [Parameter(Mandatory=$true)][string]$OutputLog,
    [string]$SourceConfig = (Join-Path $env:USERPROFILE '.bocomcode\work\config\bocomcode.json'),
    [string]$ControlParent = (Join-Path ([IO.Path]::GetTempPath()) 'bank-opencode-adapter'),
    [switch]$CheckOnly,
    [ValidateRange(5,120)][int]$StartupTimeoutSeconds = 60,
    [ValidateRange(10,1800)][int]$ClientTimeoutSeconds = 600
)
$ErrorActionPreference = 'Stop'
$pluginId = 'opencode-v2-bank-appcontainer'
$moduleDirectory = [IO.Path]::GetFullPath($PSScriptRoot)

function Local-Path([string]$Value, [string]$Label) {
    if ($Value -notmatch '^[A-Za-z]:[\\/]' -or $Value.StartsWith('\\')) { throw "$Label must be an absolute local path" }
    return [IO.Path]::GetFullPath($Value).TrimEnd('\')
}
function Assert-OutsideWorkspace([string]$Value, [string]$Label) {
    if ($Value.Equals($Workspace,[StringComparison]::OrdinalIgnoreCase) -or $Value.StartsWith($Workspace+'\',[StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must be outside the writable workspace"
    }
}
function Quote-NativeArgument([string]$Value) {
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $result = New-Object Text.StringBuilder
    [void]$result.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') { [void]$result.Append('\',($slashes*2+1)).Append('"'); $slashes=0; continue }
        [void]$result.Append('\',$slashes).Append($character); $slashes=0
    }
    [void]$result.Append('\',($slashes*2)).Append('"')
    return $result.ToString()
}
function Start-Native([string[]]$Arguments) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $OpenCodeExe
    $start.Arguments = ($Arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' '
    $start.WorkingDirectory = $controlDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    foreach ($name in @('OPENCODE_CONFIG','OPENCODE_CONFIG_CONTENT','OPENCODE_CLI_CONFIG_CONTENT')) { $start.EnvironmentVariables.Remove($name) }
    foreach ($entry in $childEnvironment.GetEnumerator()) { $start.EnvironmentVariables[$entry.Key] = $entry.Value }
    return [Diagnostics.Process]::Start($start)
}
function Stop-PrivateProcess([Diagnostics.Process]$Process) {
    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) {
            $savedPreference=$ErrorActionPreference
            try { $ErrorActionPreference='Continue'; & "$env:WINDIR\System32\taskkill.exe" /PID $Process.Id /T /F *> $null }
            finally { $ErrorActionPreference=$savedPreference }
            if (-not $Process.WaitForExit(5000)) { throw "Private process $($Process.Id) did not terminate" }
        }
    }
    finally { $Process.Dispose() }
}
function Api-Get([string]$Path) {
    return Invoke-RestMethod -Uri ($serverUrl+$Path) -Headers $headers -TimeoutSec 3 -ErrorAction Stop
}
function Safe-Diagnostic([string]$Text) {
    $value = $Text.Replace("`r",' ').Replace("`n",' ')
    foreach ($secret in $diagnosticSecrets) { if ($secret) { $value=$value.Replace($secret,'[REDACTED]') } }
    if ($value.Length -gt 800) { $value=$value.Substring(0,800) }
    return $value
}
function Provider-Strings($Value) {
    if ($Value -is [string]) { if($Value.Length -ge 6){return $Value}; return }
    if ($null -eq $Value -or $Value -is [ValueType]) { return }
    if ($Value -is [System.Collections.IDictionary]) { foreach($item in $Value.Values){Provider-Strings $item}; return }
    if ($Value -is [System.Collections.IEnumerable]) { foreach($item in $Value){Provider-Strings $item}; return }
    foreach($property in $Value.PSObject.Properties){Provider-Strings $property.Value}
}
function Assert-PluginActive {
    $response = Api-Get ('/api/plugin?location%5Bdirectory%5D='+$locationQuery)
    $matches = @($response.data | Where-Object { $_.id -eq $pluginId })
    if ($matches.Count -ne 1) { throw "Sandbox plugin is missing (matching entries: $($matches.Count)); model execution is blocked" }
    if ($matches[0].state.status -ne 'active') {
        throw ("Sandbox plugin state="+$matches[0].state.status+'; '+(Safe-Diagnostic ([string]$matches[0].state.error)))
    }
}
function Assert-SandboxAccessDenied([string]$Operation,[string]$Label) {
    $command = "try { $Operation; exit 0 } catch { `$e=`$_.Exception; while (`$e.InnerException) { `$e=`$e.InnerException }; if (`$e -is [UnauthorizedAccessException]) { [Console]::Write('BANK-WRITE-PROBE-DENIED'); exit 1 }; throw }"
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $SandboxExe
    $start.Arguments = (@('run','--workspace',$Workspace,'--shell','powershell','--timeout-ms','10000','--command',$command) | ForEach-Object { Quote-NativeArgument $_ }) -join ' '
    $start.WorkingDirectory = $controlDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $probe = [Diagnostics.Process]::Start($start)
    try {
        $probeOutput = $probe.StandardOutput.ReadToEndAsync()
        $probeError = $probe.StandardError.ReadToEndAsync()
        if (-not $probe.WaitForExit(30000)) { throw 'Trusted-directory sandbox write probe timed out' }
        if ($probe.ExitCode -ne 1 -or $probeOutput.Result -notmatch 'BANK-WRITE-PROBE-DENIED') {
            throw "Sandbox can modify a trusted resource or probe failed: $Label"
        }
    }
    finally { Stop-PrivateProcess $probe }
}
function Assert-SandboxCannotWrite([string]$Directory) {
    $sentinel = Join-Path $Directory ('bank-sandbox-write-probe-'+[guid]::NewGuid().ToString('N')+'.tmp')
    $quoted = "'"+$sentinel.Replace("'","''")+"'"
    try {
        Assert-SandboxAccessDenied "[IO.File]::WriteAllText($quoted,'synthetic-probe')" $Directory
        if (Test-Path -LiteralPath $sentinel) { throw "Sandbox wrote a trusted-directory sentinel: $Directory" }
    } finally { if (Test-Path -LiteralPath $sentinel) { Remove-Item -LiteralPath $sentinel -Force } }
}
function Assert-SandboxCannotOpenForWrite([string]$File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "Trusted file missing: $File" }
    $quoted="'"+$File.Replace("'","''")+"'"
    Assert-SandboxAccessDenied "`$s=[IO.File]::Open($quoted,[IO.FileMode]::Open,[IO.FileAccess]::Write,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)); `$s.Dispose()" $File
}

$Workspace = Local-Path $Workspace 'Workspace'
$SandboxExe = Local-Path $SandboxExe 'SandboxExe'
$OpenCodeExe = Local-Path $OpenCodeExe 'OpenCodeExe'
$SourceConfig = Local-Path $SourceConfig 'SourceConfig'
$OutputLog = Local-Path $OutputLog 'OutputLog'
if ((Test-Path -LiteralPath $OutputLog) -or (Test-Path -LiteralPath ($OutputLog+'.stderr.log'))) { throw 'OutputLog must be a new file' }
for ($logParent=[IO.Path]::GetDirectoryName($OutputLog); $logParent; $logParent=[IO.Path]::GetDirectoryName($logParent)) {
    if ((Test-Path -LiteralPath $logParent) -and ((Get-Item -LiteralPath $logParent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'OutputLog path must not contain a reparse point' }
}
$ControlParent = Local-Path $ControlParent 'ControlParent'
if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) { throw 'Workspace must already exist' }
foreach ($path in @($SandboxExe,$OpenCodeExe,$SourceConfig)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required file missing: $path" } }
if ([IO.Path]::GetExtension($OpenCodeExe) -ne '.exe' -or [IO.Path]::GetExtension($SandboxExe) -ne '.exe') { throw 'OpenCodeExe and SandboxExe must be native .exe paths' }
foreach ($path in @($SandboxExe,$OpenCodeExe,$SourceConfig,$OutputLog,$moduleDirectory)) { Assert-OutsideWorkspace $path 'Trusted resource / output' }
Assert-OutsideWorkspace $ControlParent 'ControlParent'
for ($ancestor=$ControlParent; $ancestor; $ancestor=[IO.Path]::GetDirectoryName($ancestor)) {
    if (Test-Path -LiteralPath (Join-Path $ancestor '.git')) { throw 'ControlParent must not have a Git repository ancestor' }
    if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'ControlParent must not contain a reparse point' }
}
if ([string]::IsNullOrWhiteSpace($Message) -or [string]::IsNullOrWhiteSpace($Model)) { throw 'Model and Message must be nonempty' }

$privateParent = $ControlParent
$privateRoot = Join-Path $privateParent ([guid]::NewGuid().ToString('N'))
$privateConfig = Join-Path $privateRoot 'config'
$controlDirectory = Join-Path $privateRoot 'control'
$server = $null
$client = $null
try {
    New-Item -ItemType Directory -Path $privateRoot -Force | Out-Null
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & "$env:WINDIR\System32\icacls.exe" $privateRoot /inheritance:r /grant:r ('*'+$userSid+':(OI)(CI)F') 'SYSTEM:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot restrict temporary configuration ACL' }
    New-Item -ItemType Directory -Path $privateConfig,$controlDirectory -Force | Out-Null
    $source = Get-Content -LiteralPath $SourceConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $source.providers) { throw 'SourceConfig must contain the configured providers object (JSON format)' }
    $configuration = [ordered]@{
        model = $Model
        providers = $source.providers
        plugins = @(@{package=$moduleDirectory;options=@{workspace=$Workspace;sandboxExe=$SandboxExe;controlDirectory=$controlDirectory}})
    }
    $configuration | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath (Join-Path $privateConfig 'bocomcode.json') -Encoding UTF8
    & $SandboxExe prepare --workspace $Workspace | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Sandbox preparation failed; model execution is blocked' }
    foreach ($trustedDirectory in @($controlDirectory,$privateConfig,$moduleDirectory)) { Assert-SandboxCannotWrite $trustedDirectory }
    foreach ($trustedFile in @((Join-Path $moduleDirectory 'index.js'),(Join-Path $moduleDirectory 'package.json'),$PSCommandPath,$SandboxExe,$OpenCodeExe,$SourceConfig,(Join-Path $privateConfig 'bocomcode.json'))) { Assert-SandboxCannotOpenForWrite $trustedFile }
    $passwordBytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($passwordBytes) } finally { $rng.Dispose() }
    $password = [Convert]::ToBase64String($passwordBytes)
    $diagnosticSecrets = @($password) + @(Provider-Strings $source.providers)
    $childEnvironment = @{
        USERPROFILE=$privateRoot; HOME=$privateRoot; OPENCODE_CONFIG_DIR=$privateConfig
        XDG_DATA_HOME=(Join-Path $privateRoot 'data'); XDG_CACHE_HOME=(Join-Path $privateRoot 'cache'); XDG_STATE_HOME=(Join-Path $privateRoot 'state')
        OPENCODE_CONFIG_PROJECT_DISABLE='1'; OPENCODE_DISABLE_PROJECT_CONFIG='1'
        OPENCODE_DISABLE_CLAUDE_CODE='1'; OPENCODE_DISABLE_CLAUDE_CODE_SKILLS='1'
        BANK_SANDBOX_LAUNCHER='1'; OPENCODE_PASSWORD=$password; OPENCODE_SERVER_PASSWORD=$password
        SHELL=(Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')
    }
    $portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $portProbe.Start()
    $port = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port
    $portProbe.Stop()
    $serverUrl = 'http://127.0.0.1:'+$port
    $headers = @{Authorization=('Basic '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('opencode:'+$password)))}
    $locationQuery = [Uri]::EscapeDataString($controlDirectory)
    $server = Start-Native @('--channel=work','serve','--hostname','127.0.0.1','--port',([string]$port))
    $serverOut = $server.StandardOutput.ReadToEndAsync()
    $serverError = $server.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    $ready = $false
    $lastSafeError = 'API not yet reachable'
    do {
        if ($server.HasExited) { throw "Private OpenCode server exited ($($server.ExitCode)); model execution is blocked" }
        try {
            $info = Api-Get '/api/info'
            if ($info.pid -ne $server.Id) { throw "Unexpected server PID: expected=$($server.Id), received=$($info.pid)" }
            Assert-PluginActive
            $ready = $true
        } catch {
            $lastSafeError=Safe-Diagnostic $_.Exception.Message
            if ([DateTime]::UtcNow -ge $deadline) { throw ('Sandbox plugin did not become active; model execution is blocked. Last check: '+$lastSafeError) }
        }
        if (-not $ready) { Start-Sleep -Milliseconds 250 }
    } while (-not $ready)
    if ($CheckOnly) { Write-Output 'SandboxPluginActive=true; model client was not started'; return }
    New-Item -ItemType Directory -Path (Split-Path -Parent $OutputLog) -Force | Out-Null
    $client = Start-Native @('--channel=work','run','--server',$serverUrl,'--model',$Model,'--auto','--format','json',$Message)
    $stdout = $client.StandardOutput.ReadToEndAsync()
    $stderr = $client.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds($ClientTimeoutSeconds)
    while (-not $client.WaitForExit(500)) {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'OpenCode client timed out' }
        if ($server.HasExited) { throw 'Private OpenCode server stopped during the run' }
        Assert-PluginActive
    }
    [IO.File]::WriteAllText($OutputLog,$stdout.Result,(New-Object Text.UTF8Encoding($false)))
    if ($stderr.Result) { [IO.File]::WriteAllText($OutputLog+'.stderr.log',$stderr.Result,(New-Object Text.UTF8Encoding($false))) }
    Assert-PluginActive
    if ($client.ExitCode -ne 0) { throw "OpenCode client exited $($client.ExitCode); inspect OutputLog" }
    Write-Output "OutputLog=$OutputLog"
}
finally {
    $cleanupErrors = New-Object 'Collections.Generic.List[string]'
    try { Stop-PrivateProcess $client } catch { $cleanupErrors.Add('client cleanup failed') }
    try { Stop-PrivateProcess $server } catch { $cleanupErrors.Add('server cleanup failed or did not terminate') }
    try {
        if (Test-Path -LiteralPath $privateRoot) {
            $resolved = [IO.Path]::GetFullPath($privateRoot)
            $prefix = [IO.Path]::GetFullPath($privateParent).TrimEnd('\')+'\'
            if (-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^[a-f0-9]{32}$' -or ((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe temporary configuration cleanup path' }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    } catch { $cleanupErrors.Add('sensitive temporary directory cleanup failed: '+$privateRoot) }
    if ($cleanupErrors.Count -gt 0) { throw ($cleanupErrors -join '; ') }
}
