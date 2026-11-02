param([string]$Exe = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\bank-sandbox.exe'))

$ErrorActionPreference = 'Stop'
$testRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'test-runs'))
$case = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
$work = Join-Path $case 'workspace'
$outside = Join-Path $case 'outside'
$secret = Join-Path $outside 'ordinary-readable.txt'
$prepared = $false

function Call-Exe([string[]]$Arguments) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & $Exe @Arguments 2>&1 | Out-String; return @{ Code = $LASTEXITCODE; Output = $output } }
    finally { $ErrorActionPreference = $saved }
}

try {
    New-Item -ItemType Directory -Path $work, $outside -Force | Out-Null
    Set-Content -LiteralPath $secret -Value 'outside' -NoNewline
    $result = Call-Exe @('prepare', '--workspace', $work)
    if ($result.Code -ne 0) { throw "prepare failed: $($result.Output)" }
    $prepared = $true

    $link = Join-Path $work 'outside-hardlink.txt'
    New-Item -ItemType HardLink -Path $link -Target $secret | Out-Null
    try {
        $result = Call-Exe @('run', '--workspace', $work, '--shell', 'cmd', '--command', 'echo SHOULD-NOT-START')
        if ($result.Code -ne 125 -or $result.Output -notmatch 'hard-linked' -or $result.Output -match 'SHOULD-NOT-START') {
            throw "FAIL: post-prepare hard link did not block launch: code=$($result.Code); output=$($result.Output)"
        }
        Write-Output 'PASS: post-prepare hard link blocks launch'
    }
    finally { Remove-Item -LiteralPath $link -Force }

    $junction = Join-Path $work 'outside-junction'
    New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
    try {
        $result = Call-Exe @('run', '--workspace', $work, '--shell', 'cmd', '--command', 'echo SHOULD-NOT-START')
        if ($result.Code -ne 125 -or $result.Output -notmatch 'reparse point' -or $result.Output -match 'SHOULD-NOT-START') {
            throw "FAIL: post-prepare junction did not block launch: code=$($result.Code); output=$($result.Output)"
        }
        Write-Output 'PASS: post-prepare junction blocks launch'
    }
    finally { [IO.Directory]::Delete($junction) }

    $result = Call-Exe @('run', '--workspace', $work, '--shell', 'powershell', '--command', '[Console]::Write($env:TEMP)')
    if ($result.Code -ne 0) { throw "profile lookup failed: $($result.Output)" }
    $temp = $result.Output.Trim()
    $profile = Split-Path -Parent (Split-Path -Parent $temp)
    $packages = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Packages'))
    if (-not $profile.StartsWith($packages + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unexpected profile path; fixture not created: $profile"
    }
    $profileJunction = Join-Path $profile ('fixture-junction-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Junction -Path $profileJunction -Target $outside | Out-Null
    try {
        $result = Call-Exe @('run', '--workspace', $work, '--shell', 'cmd', '--command', 'echo SHOULD-NOT-START')
        if ($result.Code -ne 125 -or $result.Output -notmatch 'reparse point' -or $result.Output -match 'SHOULD-NOT-START') {
            throw "FAIL: post-prepare profile junction did not block launch: code=$($result.Code); output=$($result.Output)"
        }
        Write-Output 'PASS: post-prepare profile junction blocks launch'
    }
    finally { [IO.Directory]::Delete($profileJunction) }
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
