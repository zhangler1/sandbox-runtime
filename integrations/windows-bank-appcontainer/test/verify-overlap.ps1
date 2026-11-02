param([string]$Exe = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\bank-sandbox.exe'))
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'test-runs'))
$case = Join-Path $root ([guid]::NewGuid().ToString('N'))
$parent = Join-Path $case 'parent'
$child = Join-Path $parent 'child'
$parentPrepared = $false
$childPrepared = $false

function Call-Exe([string[]]$Arguments) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Exe @Arguments 2>&1 | Out-String
        return @{ Code = $LASTEXITCODE; Output = $output }
    }
    finally { $ErrorActionPreference = $saved }
}

try {
    New-Item -ItemType Directory -Path $child -Force | Out-Null
    $result = Call-Exe @('prepare','--workspace',$child)
    if ($result.Code -ne 0) { throw "child setup failed: $($result.Output)" }
    $childPrepared = $true
    $before = (Get-Acl -LiteralPath $parent).Sddl
    $result = Call-Exe @('prepare','--workspace',$parent)
    if ($result.Code -eq 0) { $parentPrepared = $true }
    if ($result.Code -ne 125 -or $result.Output -notmatch 'overlap|overlapping' -or (Get-Acl -LiteralPath $parent).Sddl -ne $before) {
        throw "FAIL: parent setup must reject an existing child workspace without changing its ACL: $($result.Output)"
    }
    Write-Output 'PASS: parent setup rejects an already prepared child workspace'
    $result = Call-Exe @('remove','--workspace',$child)
    if ($result.Code -ne 0) { throw "child cleanup failed: $($result.Output)" }
    $childPrepared = $false

    $result = Call-Exe @('prepare','--workspace',$parent)
    if ($result.Code -ne 0) { throw "parent setup failed: $($result.Output)" }
    $parentPrepared = $true
    $before = (Get-Acl -LiteralPath $child).Sddl
    $result = Call-Exe @('prepare','--workspace',$child)
    if ($result.Code -eq 0) { $childPrepared = $true }
    if ($result.Code -ne 125 -or $result.Output -notmatch 'overlap|overlapping' -or (Get-Acl -LiteralPath $child).Sddl -ne $before) {
        throw "FAIL: child setup must reject an existing parent workspace without changing its ACL: $($result.Output)"
    }
    Write-Output 'PASS: child setup rejects an already prepared parent workspace'
    $result = Call-Exe @('status','--workspace',$parent)
    if ($result.Code -ne 0 -or $result.Output -notmatch 'ready=true') { throw "FAIL: parent remains runnable: $($result.Output)" }
    Write-Output 'PASS: existing parent remains ready'
}
finally {
    if ($childPrepared) { $result = Call-Exe @('remove','--workspace',$child); if ($result.Code -ne 0) { throw "child remove failed: $($result.Output)" } }
    if ($parentPrepared) { $result = Call-Exe @('remove','--workspace',$parent); if ($result.Code -ne 0) { throw "parent remove failed: $($result.Output)" } }
    if (-not ([IO.Path]::GetFullPath($case).StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) { throw 'Unsafe cleanup path' }
    if (Test-Path -LiteralPath $case) { Remove-Item -LiteralPath $case -Recurse -Force }
}
