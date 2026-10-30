param(
  [Parameter(Mandatory=$true)][string]$Workspace,
  [string]$SandboxExe = (Join-Path $PSScriptRoot 'windows-sandbox-cli.exe'),
  [string[]]$DenyRead = @()
)
$ErrorActionPreference = 'Stop'
$config = Join-Path $env:USERPROFILE '.bocomcode\work\config\bocomcode.json'
if (-not (Test-Path -LiteralPath $config -PathType Leaf)) { throw "Work config not found: $config" }
if (-not (Test-Path -LiteralPath $SandboxExe -PathType Leaf)) { throw "Sandbox EXE not found: $SandboxExe" }
if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) { throw "Workspace not found: $Workspace" }
$root = [System.IO.Path]::GetFullPath($Workspace).TrimEnd('\')
if ($root -notmatch '^[A-Za-z]:\\' -or $root -match '^[A-Za-z]:\\$') { throw 'Workspace must be a local directory below a drive root' }
$profile = [System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\') + '\'
if (($root + '\').StartsWith($profile,[System.StringComparison]::OrdinalIgnoreCase)) { throw 'Workspace must be outside the user profile' }
$rootPrefix = $root + '\'
function Assert-OutsideWorkspace([string]$candidate, [string]$label) {
  $full = [System.IO.Path]::GetFullPath($candidate).TrimEnd('\')
  if ($full.Equals($root,[System.StringComparison]::OrdinalIgnoreCase) -or
      $full.StartsWith($rootPrefix,[System.StringComparison]::OrdinalIgnoreCase)) {
    throw "$label must be outside the writable workspace"
  }
  $current = $full
  while ($current) {
    $item = Get-Item -LiteralPath $current -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "$label must not contain a junction or symlink: $current"
    }
    $parent = [System.IO.Path]::GetDirectoryName($current)
    if (-not $parent -or $parent -eq $current) { break }
    $current = $parent
  }
}
Assert-OutsideWorkspace $PSScriptRoot 'Plugin package'
Assert-OutsideWorkspace $SandboxExe 'Sandbox EXE'
$validatedDenyRead = @($DenyRead | ForEach-Object {
  $path = [System.IO.Path]::GetFullPath($_).TrimEnd('\')
  if ($path -notmatch '^[A-Za-z]:\\' -or $path -match '^[A-Za-z]:\\$') { throw "DenyRead must be a local path below a drive root: $_" }
  $path.Replace('\','/')
})
$cfg = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
$plugin = [pscustomobject]@{
  package = ($PSScriptRoot.Replace('\','/'))
  options = [pscustomobject]@{ sandboxExe = ([System.IO.Path]::GetFullPath($SandboxExe).Replace('\','/')); workspace = $root.Replace('\','/'); denyRead = $validatedDenyRead }
}
$existing = @($cfg.plugins | Where-Object { $_ -and $_.package -ne $plugin.package -and $_ -ne $plugin.package })
if ($cfg.PSObject.Properties.Name -contains 'plugins') { $cfg.plugins = @($existing + $plugin) }
else { $cfg | Add-Member -NotePropertyName plugins -NotePropertyValue @($plugin) }
[System.IO.File]::WriteAllText($config,($cfg | ConvertTo-Json -Depth 30),[System.Text.UTF8Encoding]::new($false))
Write-Output "Installed Windows sandbox plugin for workspace: $root"
Write-Output 'Open a new V2 work session in that workspace to use it.'
