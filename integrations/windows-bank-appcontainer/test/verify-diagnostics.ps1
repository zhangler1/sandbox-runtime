param([string]$Exe = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\bank-sandbox.exe'))
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'test-runs'))
$case = Join-Path $root ([guid]::NewGuid().ToString('N'))
$workspace = Join-Path $case 'workspace'
$savedWorkspace = Join-Path $case 'workspace-saved'
$prepared = $false

function Call-Exe([string[]]$Arguments) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & $Exe @Arguments 2>&1 | Out-String; return @{ Code = $LASTEXITCODE; Output = $output } }
    finally { $ErrorActionPreference = $saved }
}

try {
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null
    $initialAcl = (Get-Acl -LiteralPath $workspace).Sddl
    $result = Call-Exe @('plan','--workspace',$workspace,'--json')
    if ($result.Code -ne 0) { throw "FAIL: read-only plan unavailable: $($result.Output)" }
    $plan = $result.Output | ConvertFrom-Json
    if (-not $plan.safe -or -not $plan.wouldCreateProfile -or -not $plan.wouldAddGrant -or
        $plan.workspace -ne $workspace -or (Get-Acl -LiteralPath $workspace).Sddl -ne $initialAcl) {
        throw "FAIL: plan must report and preserve untouched workspace: $($result.Output)"
    }
    Write-Output 'PASS: JSON plan is read-only and reports intended changes'
    $result = Call-Exe @('status','--workspace',$workspace,'--json')
    $status = $result.Output | ConvertFrom-Json
    if ($result.Code -ne 125 -or $status.ready -or $status.profileFolder -ne 'absent' -or $status.workspaceState -ne 'present') {
        throw "FAIL: unprepared JSON status: $($result.Output)"
    }
    Write-Output 'PASS: JSON status reports unprepared workspace'

    $result = Call-Exe @('prepare','--workspace',$workspace)
    if ($result.Code -ne 0) { throw "setup failed: $($result.Output)" }
    $prepared = $true
    $result = Call-Exe @('status','--workspace',$workspace,'--json')
    $status = $result.Output | ConvertFrom-Json
    if ($result.Code -ne 0 -or -not $status.ready -or $status.profileFolder -ne 'present' -or -not $status.rootGrant) {
        throw "FAIL: prepared JSON status: $($result.Output)"
    }
    Write-Output 'PASS: JSON status reports prepared workspace'

    $identity = [Security.Principal.SecurityIdentifier]::new($status.packageSid)
    $grant = [Security.AccessControl.FileSystemAccessRule]::new($identity,
        [Security.AccessControl.FileSystemRights]::Modify,
        [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow)
    $acl = Get-Acl -LiteralPath $workspace
    $acl.RemoveAccessRuleSpecific($grant)
    Set-Acl -LiteralPath $workspace -AclObject $acl
    $result = Call-Exe @('status','--workspace',$workspace,'--json')
    $partial = $result.Output | ConvertFrom-Json
    if ($result.Code -ne 125 -or $partial.ready -or $partial.profileFolder -ne 'present' -or $partial.rootGrant) {
        throw "FAIL: profile-only state must be diagnosed: $($result.Output)"
    }
    Write-Output 'PASS: profile-only interrupted state is visible'
    $result = Call-Exe @('prepare','--workspace',$workspace)
    if ($result.Code -ne 0) { throw "FAIL: repeated prepare repairs profile-only state: $($result.Output)" }
    Write-Output 'PASS: repeated prepare repairs profile-only state'

    Rename-Item -LiteralPath $workspace -NewName 'workspace-saved'
    try {
        $result = Call-Exe @('status','--workspace',$workspace,'--json')
        $status = $result.Output | ConvertFrom-Json
        if ($result.Code -ne 125 -or $status.ready -or $status.workspaceState -ne 'missing' -or $status.profileFolder -ne 'present') {
            throw "FAIL: moved workspace must report orphan profile: $($result.Output)"
        }
        Write-Output 'PASS: missing workspace reports durable profile without hiding it'
    }
    finally { Rename-Item -LiteralPath $savedWorkspace -NewName 'workspace' }

    $result = Call-Exe @('run','--workspace',$workspace,'--shell','powershell','--command','[Console]::Write($env:TEMP)')
    if ($result.Code -ne 0) { throw "Temp lookup failed: $($result.Output)" }
    $temp = $result.Output.Trim()
    $savedTempName = 'Temp.saved-' + [guid]::NewGuid().ToString('N')
    $savedTemp = Join-Path (Split-Path -Parent $temp) $savedTempName
    Rename-Item -LiteralPath $temp -NewName $savedTempName
    New-Item -ItemType Junction -Path $temp -Target $case | Out-Null
    try {
        $result = Call-Exe @('status','--workspace',$workspace,'--json')
        $status = $result.Output | ConvertFrom-Json
        if ($result.Code -ne 125 -or $status.ready -or $status.profileTemp -ne 'unsafe') {
            throw "FAIL: poisoned Temp must be diagnosed before run: $($result.Output)"
        }
        Write-Output 'PASS: JSON status identifies poisoned profile Temp'
    }
    finally {
        if ((Test-Path -LiteralPath $temp) -and ((Get-Item -LiteralPath $temp -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { [IO.Directory]::Delete($temp) }
        Rename-Item -LiteralPath $savedTemp -NewName 'Temp'
    }
}
finally {
    if ($prepared) {
        if (Test-Path -LiteralPath $savedWorkspace) { Rename-Item -LiteralPath $savedWorkspace -NewName 'workspace' }
        $result = Call-Exe @('remove','--workspace',$workspace)
        if ($result.Code -ne 0) { throw "cleanup failed: $($result.Output)" }
    }
    if (-not ([IO.Path]::GetFullPath($case).StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) { throw 'Unsafe cleanup path' }
    if (Test-Path -LiteralPath $case) { Remove-Item -LiteralPath $case -Recurse -Force }
}
