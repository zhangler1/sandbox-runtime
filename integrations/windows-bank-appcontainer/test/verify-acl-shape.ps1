param([string]$Exe = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\bank-sandbox.exe'))
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'test-runs'))
$case = Join-Path $root ([guid]::NewGuid().ToString('N'))
$workspace = Join-Path $case 'workspace'
$prepared = $false
$originalAcl = $null

function Call-Exe([string[]]$Arguments) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & $Exe @Arguments 2>&1 | Out-String; return @{ Code = $LASTEXITCODE; Output = $output } }
    finally { $ErrorActionPreference = $saved }
}

try {
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null
    $originalAcl = Get-Acl -LiteralPath $workspace
    $result = Call-Exe @('prepare','--workspace',$workspace)
    if ($result.Code -ne 0) { throw "setup failed: $($result.Output)" }
    $prepared = $true
    $status = (Call-Exe @('status','--workspace',$workspace,'--json')).Output | ConvertFrom-Json
    $identity = [Security.Principal.SecurityIdentifier]::new($status.packageSid)
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    $propagate = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $exact = [Security.AccessControl.FileSystemAccessRule]::new($identity,
        [Security.AccessControl.FileSystemRights]::Modify, $inherit, $propagate, $allow)
    $broad = [Security.AccessControl.FileSystemAccessRule]::new($identity,
        [Security.AccessControl.FileSystemRights]::FullControl, $inherit, $propagate, $allow)
    $acl = Get-Acl -LiteralPath $workspace
    $acl.RemoveAccessRuleSpecific($exact)
    $acl.AddAccessRule($broad)
    Set-Acl -LiteralPath $workspace -AclObject $acl

    $result = Call-Exe @('status','--workspace',$workspace,'--json')
    $status = $result.Output | ConvertFrom-Json
    if ($result.Code -ne 125 -or $status.ready -or $status.workspaceState -ne 'unsafe') {
        throw "FAIL: broad own-package ACE must be unsafe: $($result.Output)"
    }
    Write-Output 'PASS: broad own-package ACE is rejected as unsafe'
    $result = Call-Exe @('run','--workspace',$workspace,'--shell','cmd','--command','whoami')
    if ($result.Code -ne 125 -or $result.Output -match 'srt-sandbox') {
        throw "FAIL: command ran with broad package ACE: $($result.Output)"
    }
    Write-Output 'PASS: run fails closed for broad own-package ACE'

    $acl = Get-Acl -LiteralPath $workspace
    $acl.RemoveAccessRuleSpecific($broad)
    $acl.AddAccessRule($exact)
    Set-Acl -LiteralPath $workspace -AclObject $acl
    $file = Join-Path $workspace 'probe.txt'
    Set-Content -LiteralPath $file -Value 'fixture'
    $otherWorkspace = Join-Path $case 'other-workspace'
    New-Item -ItemType Directory -Path $otherWorkspace | Out-Null
    $other = (Call-Exe @('plan','--workspace',$otherWorkspace,'--json')).Output | ConvertFrom-Json
    $otherSid = [Security.Principal.SecurityIdentifier]::new($other.packageSid)
    $fileGrant = [Security.AccessControl.FileSystemAccessRule]::new($otherSid,
        [Security.AccessControl.FileSystemRights]::Modify, $allow)
    $originalFileAcl = Get-Acl -LiteralPath $file
    $fileAcl = Get-Acl -LiteralPath $file
    $fileAcl.AddAccessRule($fileGrant)
    Set-Acl -LiteralPath $file -AclObject $fileAcl
    $result = Call-Exe @('status','--workspace',$workspace,'--json')
    $status = $result.Output | ConvertFrom-Json
    if ($result.Code -ne 125 -or $status.ready -or $status.workspaceState -ne 'unsafe') {
        throw "FAIL: file-level other-package write ACE must be unsafe: $($result.Output)"
    }
    Write-Output 'PASS: file-level other-package write ACE is rejected'

    Set-Acl -LiteralPath $file -AclObject $originalFileAcl
    $deny = [Security.AccessControl.FileSystemAccessRule]::new($identity,
        [Security.AccessControl.FileSystemRights]::ReadData,
        [Security.AccessControl.AccessControlType]::Deny)
    $acl = Get-Acl -LiteralPath $workspace
    $acl.AddAccessRule($deny)
    Set-Acl -LiteralPath $workspace -AclObject $acl
    $result = Call-Exe @('status','--workspace',$workspace,'--json')
    $status = $result.Output | ConvertFrom-Json
    if ($result.Code -ne 125 -or $status.ready -or $status.workspaceState -ne 'unsafe') {
        throw "FAIL: own-package deny ACE must be unsafe: $($result.Output)"
    }
    Write-Output 'PASS: own-package deny ACE is rejected'

    $acl = Get-Acl -LiteralPath $workspace
    $acl.RemoveAccessRuleSpecific($deny)
    Set-Acl -LiteralPath $workspace -AclObject $acl
    $allPackages = [Security.Principal.SecurityIdentifier]::new('S-1-15-2-1')
    $sharedRead = [Security.AccessControl.FileSystemAccessRule]::new($allPackages,
        [Security.AccessControl.FileSystemRights]::Read, $allow)
    $fileAcl = Get-Acl -LiteralPath $file
    $fileAcl.AddAccessRule($sharedRead)
    Set-Acl -LiteralPath $file -AclObject $fileAcl
    $result = Call-Exe @('status','--workspace',$workspace,'--json')
    $status = $result.Output | ConvertFrom-Json
    if ($result.Code -ne 125 -or $status.ready -or $status.workspaceState -ne 'unsafe') {
        throw "FAIL: file shared with all AppContainers must be unsafe: $($result.Output)"
    }
    Write-Output 'PASS: file shared with all AppContainers is rejected'

    $fileAcl = Get-Acl -LiteralPath $file
    $fileAcl.RemoveAccessRuleSpecific($sharedRead)
    $capability = [Security.Principal.SecurityIdentifier]::new('S-1-15-3-1')
    $capabilityRead = [Security.AccessControl.FileSystemAccessRule]::new($capability,
        [Security.AccessControl.FileSystemRights]::Read, $allow)
    $fileAcl.AddAccessRule($capabilityRead)
    Set-Acl -LiteralPath $file -AclObject $fileAcl
    $result = Call-Exe @('status','--workspace',$workspace,'--json')
    $status = $result.Output | ConvertFrom-Json
    if ($result.Code -ne 125 -or $status.ready -or $status.workspaceState -ne 'unsafe') {
        throw "FAIL: file shared by capability SID must be unsafe: $($result.Output)"
    }
    Write-Output 'PASS: capability SID file read grant is rejected'
}
finally {
    if ($prepared) {
        if ($originalAcl -and (Test-Path -LiteralPath $workspace)) {
            Set-Acl -LiteralPath $workspace -AclObject $originalAcl
        }
        $result = Call-Exe @('remove','--workspace',$workspace)
        if ($result.Code -ne 0) { throw "cleanup failed: $($result.Output)" }
    }
    if (-not ([IO.Path]::GetFullPath($case).StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) { throw 'Unsafe cleanup path' }
    if (Test-Path -LiteralPath $case) { Remove-Item -LiteralPath $case -Recurse -Force }
}
