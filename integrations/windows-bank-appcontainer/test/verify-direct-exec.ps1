param(
    [string]$Exe = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\bank-sandbox.exe'),
    [string]$NetworkHost,
    [int]$NetworkPort = 0
)

$ErrorActionPreference = 'Stop'
$testRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'test-runs'))
$case = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
$work = Join-Path $case 'workspace'
$outside = Join-Path $case 'outside'
$secret = Join-Path $outside 'ordinary-readable.txt'
$marker = 'DIRECT-SECRET-' + [guid]::NewGuid().ToString('N')
$prepared = $false
$powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Assert-True([bool]$Condition, [string]$Description) {
    if (-not $Condition) { throw "FAIL: $Description" }
    Write-Output "PASS: $Description"
}

function Call-Exe([string[]]$Arguments) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Exe @Arguments 2>&1 | Out-String
        return @{ Code = $LASTEXITCODE; Output = $output }
    }
    finally { $ErrorActionPreference = $saved }
}

function Call-ExeRaw([string]$ArgumentText) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Exe
    $start.Arguments = $ArgumentText
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'raw direct EXE call timed out' }
        return @{ Code = $process.ExitCode; Output = ($stdout.Result + $stderr.Result) }
    }
    finally { $process.Dispose() }
}

function Call-DirectPowerShell([string]$Script, [string[]]$ExtraOptions = @()) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $arguments = @('run', '--workspace', $work, '--exec', $powershellExe,
        '--arg', '-NoProfile', '--arg', '-NonInteractive', '--arg', '-EncodedCommand', '--arg', $encoded)
    return Call-Exe ($arguments + $ExtraOptions)
}

try {
    New-Item -ItemType Directory -Path $work, $outside -Force | Out-Null
    Set-Content -LiteralPath $secret -Value $marker -NoNewline
    Assert-True ((Get-Content -LiteralPath $secret -Raw) -eq $marker) 'host can read outside control'
    Assert-True (Test-Path -LiteralPath $Exe -PathType Leaf) 'CLI binary exists'

    $result = Call-Exe @('prepare', '--workspace', $work)
    Assert-True ($result.Code -eq 0) "prepare succeeds: $($result.Output)"
    $prepared = $true

    $cmdExe = Join-Path $env:WINDIR 'System32\cmd.exe'
    $result = Call-Exe @('run', '--workspace', $work, '--exec', $cmdExe,
        '--arg', '/d', '--arg', '/c', '--arg', 'echo DIRECT ARG WITH SPACES')
    Assert-True ($result.Code -eq 0 -and $result.Output -match 'DIRECT ARG WITH SPACES') "direct system EXE preserves spaced argument: $($result.Output)"

    $probeSource = Join-Path $work 'argv-probe.cs'
    $probeExe = Join-Path $work 'argv-probe.exe'
    Set-Content -LiteralPath $probeSource -Encoding Ascii -Value @'
using System;
class Probe { static int Main(string[] args) { foreach (string arg in args) Console.WriteLine("ARG=" + arg); return 0; } }
'@
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:exe /platform:x64 ("/out:" + $probeExe) $probeSource
    Assert-True ($LASTEXITCODE -eq 0) 'synthetic argument probe compiles'
    $quotedArg = 'spaced "quoted" value\'
    # PowerShell 5.1 rewrites embedded quotes in native argv. Pass a raw Win32 command line
    # so this test isolates the CLI's own argument quoting.
    $raw = 'run --workspace "' + $work + '" --exec "' + $probeExe + '" --arg "spaced \"quoted\" value\\"'
    $result = Call-ExeRaw $raw
    Assert-True ($result.Code -eq 0 -and $result.Output.Trim() -eq ('ARG=' + $quotedArg)) "direct EXE preserves embedded quotes and trailing slash: $($result.Output)"

    $whoamiExe = Join-Path $env:WINDIR 'System32\whoami.exe'
    $result = Call-Exe @('run', '--workspace', $work, '--exec', $whoamiExe)
    Assert-True ($result.Code -eq 0 -and $result.Output -match [regex]::Escape($env:USERNAME)) 'direct whoami executes in verified AppContainer child'

    $result = Call-Exe @('run', '--workspace', $work, '--exec', 'whoami.exe')
    Assert-True ($result.Code -eq 125 -and $result.Output -match 'absolute local') 'relative executable fails closed'

    $command = "[Console]::Write('DIRECT-READ-ATTEMPT'); [IO.File]::ReadAllText('$secret')"
    $result = Call-DirectPowerShell $command
    Assert-True ($result.Code -ne 0 -and $result.Output -match 'DIRECT-READ-ATTEMPT' -and
        $result.Output -notmatch [regex]::Escape($marker)) 'direct EXE starts but cannot read outside file'

    $target = Join-Path $outside 'direct-created.txt'
    $command = "[Console]::Write('DIRECT-WRITE-ATTEMPT'); [IO.File]::WriteAllText('$target', 'breach')"
    $result = Call-DirectPowerShell $command
    Assert-True ($result.Code -ne 0 -and $result.Output -match 'DIRECT-WRITE-ATTEMPT' -and
        -not (Test-Path -LiteralPath $target)) 'direct EXE starts but cannot write outside file'

    $lateFile = Join-Path $work 'descendant-survived.txt'
    $lateScript = "Start-Sleep -Seconds 3; [IO.File]::WriteAllText('$lateFile','survived')"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($lateScript))
    $spawn = "`$s=New-Object Diagnostics.ProcessStartInfo; `$s.FileName=Join-Path `$env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; `$s.Arguments='-NoProfile -NonInteractive -EncodedCommand $encoded'; `$s.UseShellExecute=`$false; `$p=[Diagnostics.Process]::Start(`$s); [Console]::Write('DIRECT-CHILD-'+`$p.Id)"
    $result = Call-DirectPowerShell $spawn
    Assert-True ($result.Code -eq 0 -and $result.Output -match 'DIRECT-CHILD-\d+') "direct EXE starts descendant: $($result.Output)"
    Start-Sleep -Seconds 4
    Assert-True (-not (Test-Path -LiteralPath $lateFile)) 'direct EXE Job terminates background descendant'

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        $loopbackPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        $control = [Net.Sockets.TcpClient]::new()
        try { $control.Connect('127.0.0.1', $loopbackPort); Assert-True $control.Connected 'host loopback control connects' }
        finally { $control.Dispose() }
        $command = "[Console]::Write('DIRECT-NETWORK-ATTEMPT'); `$c=New-Object Net.Sockets.TcpClient; try { `$a=`$c.BeginConnect('127.0.0.1',$loopbackPort,`$null,`$null); if (`$a.AsyncWaitHandle.WaitOne(3000)) { `$c.EndConnect(`$a); [Console]::Write('DIRECT-NETWORK-CONNECTED') } else { [Console]::Write('DIRECT-NETWORK-DENIED-TIMEOUT') } } catch { [Console]::Write('DIRECT-NETWORK-DENIED') } finally { `$c.Dispose() }"
        $result = Call-DirectPowerShell $command @('--timeout-ms', '10000')
        Assert-True ($result.Code -eq 0 -and $result.Output -match 'DIRECT-NETWORK-ATTEMPT' -and
            $result.Output -match 'DIRECT-NETWORK-DENIED' -and $result.Output -notmatch 'DIRECT-NETWORK-CONNECTED') 'direct EXE loopback denied after reachable host control'
    }
    finally { $listener.Stop() }

    if ($NetworkHost -or $NetworkPort) {
        if (-not $NetworkHost -or $NetworkPort -lt 1 -or $NetworkPort -gt 65535) {
            throw 'Supply both -NetworkHost and a valid -NetworkPort'
        }
        $control = [Net.Sockets.TcpClient]::new()
        try {
            $async = $control.BeginConnect($NetworkHost, $NetworkPort, $null, $null)
            Assert-True ($async.AsyncWaitHandle.WaitOne(3000) -and $control.Connected) "host can reach $($NetworkHost):$NetworkPort"
            $control.EndConnect($async)
        }
        finally { $control.Dispose() }
        $command = "[Console]::Write('DIRECT-NETWORK-ATTEMPT'); `$c=New-Object Net.Sockets.TcpClient; try { `$a=`$c.BeginConnect('$NetworkHost',$NetworkPort,`$null,`$null); if (`$a.AsyncWaitHandle.WaitOne(3000)) { `$c.EndConnect(`$a); [Console]::Write('DIRECT-NETWORK-CONNECTED') } else { [Console]::Write('DIRECT-NETWORK-DENIED-TIMEOUT') } } catch { [Console]::Write('DIRECT-NETWORK-DENIED') } finally { `$c.Dispose() }"
        $result = Call-DirectPowerShell $command @('--timeout-ms', '10000')
        Assert-True ($result.Code -eq 0 -and $result.Output -match 'DIRECT-NETWORK-ATTEMPT' -and
            $result.Output -match 'DIRECT-NETWORK-DENIED' -and $result.Output -notmatch 'DIRECT-NETWORK-CONNECTED') 'direct EXE network denied after reachable host control'
    }
}
finally {
    if ($prepared) {
        $result = Call-Exe @('remove', '--workspace', $work)
        if ($result.Code -ne 0) { throw "remove failed; fixture preserved: $($result.Output)" }
    }
    $resolved = [IO.Path]::GetFullPath($case)
    if (-not $resolved.StartsWith($testRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe cleanup target: $resolved"
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
