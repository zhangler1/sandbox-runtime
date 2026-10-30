$ErrorActionPreference = 'Stop'
$config = Join-Path $env:USERPROFILE '.bocomcode\work\config\bocomcode.json'
if (-not (Test-Path -LiteralPath $config -PathType Leaf)) { throw "Work config not found: $config" }
$cfg = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
$pluginPath = $PSScriptRoot.Replace('\','/')
if ($cfg.PSObject.Properties.Name -contains 'plugins') {
  $cfg.plugins = @($cfg.plugins | Where-Object { $_ -and $_.package -ne $pluginPath -and $_ -ne $pluginPath })
  [System.IO.File]::WriteAllText($config,($cfg | ConvertTo-Json -Depth 30),[System.Text.UTF8Encoding]::new($false))
}
Write-Output 'Removed Windows sandbox plugin from the work config.'
