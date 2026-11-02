param(
    [string]$Exe = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\bank-sandbox.exe')
)

$ErrorActionPreference = 'Stop'
$testRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'test-runs'))
$case = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
$workspace = Join-Path $case 'workspace'
$outside = Join-Path $case 'outside'
$secret = Join-Path $outside 'ordinary-readable.txt'
$marker = 'BANK-SANDBOX-SECRET-' + [guid]::NewGuid().ToString('N')
$prepared = $false
$secondPrepared = $false
$secondWorkspace = Join-Path $case 'second-workspace'

function Assert-True([bool]$Condition, [string]$Description) {
    if (-not $Condition) { throw "FAIL: $Description" }
    Write-Output "PASS: $Description"
}

function Invoke-Runner([string[]]$Arguments) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Exe @Arguments 2>&1 | Out-String
        return @{ Output = $output; Code = $LASTEXITCODE }
    }
    finally { $ErrorActionPreference = $saved }
}

try {
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null
    New-Item -ItemType Directory -Path $outside -Force | Out-Null
    Set-Content -LiteralPath $secret -Value $marker -NoNewline
    Assert-True ((Get-Content -LiteralPath $secret -Raw) -eq $marker) 'host can read outside control'
    Assert-True (Test-Path -LiteralPath $Exe -PathType Leaf) 'CLI binary exists'

    $beforeUsers = @(Get-LocalUser | Select-Object -ExpandProperty Name | Sort-Object)
    $result = Invoke-Runner @('prepare', '--workspace', $workspace)
    Assert-True ($result.Code -eq 0) "prepare succeeded: $($result.Output)"
    $prepared = $true
    $result = Invoke-Runner @('status', '--workspace', $workspace)
    Assert-True ($result.Code -eq 0 -and $result.Output -match 'ready=true') 'status reports ready'

    foreach ($shell in @('cmd', 'powershell')) {
        $result = Invoke-Runner @('run', '--workspace', $workspace, '--shell', $shell, '--command', 'whoami')
        Assert-True ($result.Code -eq 0 -and $result.Output -match [regex]::Escape($env:USERNAME)) "$shell executes whoami (code=$($result.Code)): $($result.Output)"

        $created = Join-Path $workspace "$shell-created.txt"
        $writeCommand = if ($shell -eq 'cmd') { 'echo sandbox-ok>"' + $created + '"' }
            else { "Set-Content -LiteralPath '$created' -Value 'sandbox-ok' -ErrorAction Stop" }
        $result = Invoke-Runner @('run', '--workspace', $workspace, '--shell', $shell, '--command', $writeCommand)
        Assert-True ($result.Code -eq 0 -and (Test-Path -LiteralPath $created) -and
            ((Get-Content -LiteralPath $created -Raw).Trim() -eq 'sandbox-ok')) "$shell writes workspace"

        $readCommand = if ($shell -eq 'cmd') { 'echo READ-ATTEMPT & type "' + $secret + '"' }
            else { "'READ-ATTEMPT'; Get-Content -LiteralPath '$secret' -ErrorAction Stop" }
        $result = Invoke-Runner @('run', '--workspace', $workspace, '--shell', $shell, '--command', $readCommand)
        Assert-True ($result.Code -eq 1 -and $result.Output -match 'READ-ATTEMPT' -and $result.Output -notmatch [regex]::Escape($marker)) "$shell attempts read but cannot read outside marker"

        $target = Join-Path $outside "$shell-created.txt"
        $outsideCommand = if ($shell -eq 'cmd') { 'echo WRITE-ATTEMPT & echo breach>"' + $target + '"' }
            else { "'WRITE-ATTEMPT'; Set-Content -LiteralPath '$target' -Value 'breach' -ErrorAction Stop" }
        $result = Invoke-Runner @('run', '--workspace', $workspace, '--shell', $shell, '--command', $outsideCommand)
        Assert-True ($result.Code -eq 1 -and $result.Output -match 'WRITE-ATTEMPT' -and -not (Test-Path -LiteralPath $target)) "$shell attempts write but cannot write outside"
    }

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        $control = [Net.Sockets.TcpClient]::new()
        try { $control.Connect('127.0.0.1', $port); Assert-True $control.Connected 'host loopback control connects' }
        finally { $control.Dispose() }
        $networkCommand = "'NETWORK-ATTEMPT'; `$c=New-Object Net.Sockets.TcpClient; try { `$a=`$c.BeginConnect('127.0.0.1',$port,`$null,`$null); if (`$a.AsyncWaitHandle.WaitOne(2000)) { `$c.EndConnect(`$a); 'NETWORK-CONNECTED' } else { 'NETWORK-DENIED-TIMEOUT' } } catch { 'NETWORK-DENIED' } finally { `$c.Dispose() }"
        $result = Invoke-Runner @('run', '--workspace', $workspace, '--shell', 'powershell', '--command', $networkCommand, '--timeout-ms', '10000')
        Assert-True ($result.Code -eq 0 -and $result.Output -match 'NETWORK-ATTEMPT' -and $result.Output -match 'NETWORK-DENIED' -and $result.Output -notmatch 'NETWORK-CONNECTED') 'sandbox loopback is denied after a real attempt'
    }
    finally { $listener.Stop() }

    $result = Invoke-Runner @('run', '--workspace', $workspace, '--shell', 'powershell', '--command', "'DOTNET-READ-ATTEMPT'; [IO.File]::ReadAllText('$secret')")
    Assert-True ($result.Code -eq 1 -and $result.Output -match 'DOTNET-READ-ATTEMPT' -and $result.Output -notmatch [regex]::Escape($marker)) '.NET file read also denies the outside file'

    New-Item -ItemType Directory -Path $secondWorkspace | Out-Null
    Set-Content -LiteralPath (Join-Path $secondWorkspace 'private.txt') -Value $marker
    $result = Invoke-Runner @('prepare', '--workspace', $secondWorkspace)
    Assert-True ($result.Code -eq 0) 'second workspace prepares independently'
    $secondPrepared = $true
    $secondSecret = Join-Path $secondWorkspace 'private.txt'
    $result = Invoke-Runner @('run', '--workspace', $workspace, '--shell', 'powershell', '--command', "'SECOND-READ-ATTEMPT'; [IO.File]::ReadAllText('$secondSecret')")
    Assert-True ($result.Code -eq 1 -and $result.Output -match 'SECOND-READ-ATTEMPT' -and $result.Output -notmatch [regex]::Escape($marker)) 'first workspace cannot read the second workspace'

    $hostNested = & $env:ComSpec /d /c ('type "' + $secret + '"') | Out-String
    Assert-True ($hostNested -match [regex]::Escape($marker)) 'host nested CMD can read outside control'
    $nested = "& `$env:ComSpec /d /c 'echo NESTED-ATTEMPT & type `"$secret`"'"
    $result = Invoke-Runner @('run', '--workspace', $workspace, '--shell', 'powershell', '--command', $nested)
    Assert-True ($result.Code -eq 1 -and $result.Output -match 'NESTED-ATTEMPT' -and $result.Output -notmatch [regex]::Escape($marker)) 'nested CMD attempts read but cannot read outside marker'

    $env:BANK_SANDBOX_HOST_SECRET_TEST = $marker
    try {
        $result = Invoke-Runner @('run', '--workspace', $workspace, '--shell', 'powershell', '--command', "[Environment]::GetEnvironmentVariable('BANK_SANDBOX_HOST_SECRET_TEST')")
        Assert-True ($result.Code -eq 0 -and $result.Output -notmatch [regex]::Escape($marker)) 'host environment secret is not inherited'
    }
    finally { Remove-Item Env:BANK_SANDBOX_HOST_SECRET_TEST }

    $started = Join-Path $workspace 'timeout-started.txt'
    $result = Invoke-Runner @('run', '--workspace', $workspace, '--shell', 'powershell', '--command', "Set-Content -LiteralPath '$started' -Value started; Start-Sleep -Seconds 10", '--timeout-ms', '2000')
    Assert-True ($result.Code -eq 124 -and (Test-Path -LiteralPath $started)) 'timeout terminates a command that actually started'

    $lateFile = Join-Path $workspace 'background-survived.txt'
    $childScript = "Start-Sleep -Seconds 3; [IO.File]::WriteAllText('$lateFile','survived')"
    $encodedChild = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
    $spawnChild = "`$s=New-Object Diagnostics.ProcessStartInfo; `$s.FileName=Join-Path `$env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; `$s.Arguments='-NoProfile -NonInteractive -EncodedCommand $encodedChild'; `$s.UseShellExecute=`$false; `$p=[Diagnostics.Process]::Start(`$s); 'CHILD-STARTED-'+`$p.Id"
    $result = Invoke-Runner @('run', '--workspace', $workspace, '--shell', 'powershell', '--command', $spawnChild)
    Assert-True ($result.Code -eq 0 -and $result.Output -match 'CHILD-STARTED-\d+') 'background descendant really started'
    Start-Sleep -Seconds 4
    Assert-True (-not (Test-Path -LiteralPath $lateFile)) 'Job cleanup terminates background descendants'

    $result = Invoke-Runner @('run', '--workspace', $workspace, '--shell', 'git-bash', '--command', 'whoami')
    Assert-True ($result.Code -ne 0 -and $result.Output -match 'unsupported') 'Git Bash request fails closed'

    $linkedWork = Join-Path $case 'hardlink-workspace'
    New-Item -ItemType Directory -Path $linkedWork | Out-Null
    New-Item -ItemType HardLink -Path (Join-Path $linkedWork 'alias.txt') -Target $secret | Out-Null
    $outsideAcl = (Get-Acl -LiteralPath $secret).Sddl
    $result = Invoke-Runner @('prepare', '--workspace', $linkedWork)
    Assert-True ($result.Code -eq 125 -and $result.Output -match 'hard-linked' -and (Get-Acl -LiteralPath $secret).Sddl -eq $outsideAcl) 'prepare rejects hard links without broadening outside ACL'

    $shared = Join-Path $outside 'app-package-readable.txt'
    Set-Content -LiteralPath $shared -Value 'EXPLICITLY-SHARED'
    $sharedAcl = Get-Acl -LiteralPath $shared
    $packageGroup = [Security.Principal.SecurityIdentifier]::new('S-1-15-2-1')
    $sharedAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($packageGroup, [Security.AccessControl.FileSystemRights]::Read, [Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $shared -AclObject $sharedAcl
    $result = Invoke-Runner @('run', '--workspace', $workspace, '--shell', 'powershell', '--command', "[IO.File]::ReadAllText('$shared')")
    Assert-True ($result.Code -eq 0 -and $result.Output -match 'EXPLICITLY-SHARED') 'documented boundary: files explicitly shared with all AppContainers remain readable'

    $result = Invoke-Runner @('run', '--workspace', $workspace, '--shell', 'powershell', '--command', '[Console]::Write($env:TEMP)')
    Assert-True ($result.Code -eq 0) 'profile temp path is available'
    $profileTemp = $result.Output.Trim()
    $profileBase = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Packages')) + '\'
    Assert-True ($profileTemp.StartsWith($profileBase, [StringComparison]::OrdinalIgnoreCase) -and
        $profileTemp -match '\\bankagentsandbox_v1_[a-f0-9]{32}\\AC\\Temp$' -and
        (Test-Path -LiteralPath $profileTemp -PathType Container)) 'regression Temp target stays inside the synthetic AppContainer profile'
    $savedTempName = 'Temp.saved-' + [guid]::NewGuid().ToString('N')
    $savedTemp = Join-Path (Split-Path -Parent $profileTemp) $savedTempName
    Rename-Item -LiteralPath $profileTemp -NewName $savedTempName
    New-Item -ItemType Junction -Path $profileTemp -Target $outside | Out-Null
    try {
        $result = Invoke-Runner @('run', '--workspace', $workspace, '--shell', 'cmd', '--command', 'echo should-not-run')
        Assert-True ($result.Code -eq 125 -and $result.Output -match 'reparse point' -and $result.Output -notmatch 'should-not-run') 'host rejects a poisoned profile Temp before launching'
    }
    finally {
        if ((Test-Path -LiteralPath $profileTemp) -and ((Get-Item -LiteralPath $profileTemp -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            [IO.Directory]::Delete($profileTemp)
        }
        Rename-Item -LiteralPath $savedTemp -NewName 'Temp'
    }

    $junctionWork = Join-Path $case 'junction-workspace'
    $junction = Join-Path $junctionWork 'outside-link'
    New-Item -ItemType Directory -Path $junctionWork | Out-Null
    $result = Invoke-Runner @('prepare', '--workspace', $junctionWork)
    Assert-True ($result.Code -eq 0) 'junction cleanup regression workspace prepares'
    New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
    try {
        $result = Invoke-Runner @('prepare', '--workspace', $junctionWork)
        Assert-True ($result.Code -eq 125 -and $result.Output -match 'reparse point' -and (Get-Acl -LiteralPath $secret).Sddl -eq $outsideAcl) 'prepare rejects junctions without broadening outside ACL'
        $result = Invoke-Runner @('remove', '--workspace', $junctionWork)
        Assert-True ($result.Code -eq 125 -and $result.Output -match 'reparse point') 'remove refuses ACL propagation through junctions'
        $result = Invoke-Runner @('status', '--workspace', $junctionWork)
        Assert-True ($result.Code -ne 0 -and $result.Output -match 'ready=false') 'unsafe workspace cleanup still revokes readiness'
        Assert-True ($result.Output -match 'profile=true') 'unsafe cleanup preflight preserves the profile for retry'
    }
    finally {
        [IO.Directory]::Delete($junction)
        $result = Invoke-Runner @('remove', '--workspace', $junctionWork)
        if ($result.Code -ne 0) { throw "junction cleanup failed: $($result.Output)" }
    }

    $afterUsers = @(Get-LocalUser | Select-Object -ExpandProperty Name | Sort-Object)
    Assert-True (($beforeUsers -join '|') -eq ($afterUsers -join '|')) 'no local SAM user created'
}
finally {
    if ($secondPrepared) {
        $result = Invoke-Runner @('remove', '--workspace', $secondWorkspace)
        if ($result.Code -ne 0) { throw "second workspace remove failed; files preserved: $($result.Output)" }
    }
    if ($prepared) {
        $result = Invoke-Runner @('remove', '--workspace', $workspace)
        if ($result.Code -ne 0) { throw "remove failed; test files preserved: $($result.Output)" }
        $result = Invoke-Runner @('status', '--workspace', $workspace)
        Assert-True ($result.Code -ne 0 -and $result.Output -match 'ready=false') 'remove revokes workspace readiness'
    }
    $resolved = [IO.Path]::GetFullPath($case)
    if (-not $resolved.StartsWith($testRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe cleanup target: $resolved"
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
