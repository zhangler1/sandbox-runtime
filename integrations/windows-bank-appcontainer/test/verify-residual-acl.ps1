param([string]$Exe = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\bank-sandbox.exe'))
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'test-runs'))
$case = Join-Path $root ([guid]::NewGuid().ToString('N'))
$workspace = Join-Path $case 'workspace'
$child = Join-Path $workspace 'child'
$prepared = $false

function Call-Exe([string[]]$Arguments) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & $Exe @Arguments 2>&1 | Out-String; return @{ Code = $LASTEXITCODE; Output = $output } }
    finally { $ErrorActionPreference = $saved }
}

try {
    New-Item -ItemType Directory -Path $child -Force | Out-Null
    $result = Call-Exe @('prepare','--workspace',$workspace)
    if ($result.Code -ne 0) { throw "setup failed: $($result.Output)" }
    $prepared = $true
    & "$env:WINDIR\System32\icacls.exe" $child '/inheritance:d' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'fixture ACL conversion failed' }
    $result = Call-Exe @('remove','--workspace',$workspace)
    $status = (Call-Exe @('status','--workspace',$workspace,'--json')).Output | ConvertFrom-Json
    if ($result.Code -ne 125 -or $status.profileFolder -ne 'present') {
        throw "FAIL: remove must preserve profile when child retains an explicit Package SID ACE: $($result.Output)"
    }
    Write-Output 'PASS: remove refuses converted explicit child ACL and preserves profile'
    & "$env:WINDIR\System32\icacls.exe" $child '/reset' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'fixture ACL reset failed' }
    $result = Call-Exe @('remove','--workspace',$workspace)
    if ($result.Code -ne 0) { throw "FAIL: remove after restoring inheritance: $($result.Output)" }
    $prepared = $false
    Write-Output 'PASS: remove succeeds after restoring child inheritance'
}
finally {
    if ($prepared) {
        & "$env:WINDIR\System32\icacls.exe" $child '/reset' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'fixture ACL cleanup failed' }
        $result = Call-Exe @('remove','--workspace',$workspace)
        if ($result.Code -ne 0) { throw "cleanup failed; fixture preserved: $($result.Output)" }
    }
    if (-not ([IO.Path]::GetFullPath($case).StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) { throw 'Unsafe cleanup path' }
    if (Test-Path -LiteralPath $case) { Remove-Item -LiteralPath $case -Recurse -Force }
}
