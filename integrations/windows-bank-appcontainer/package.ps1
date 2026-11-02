param([Parameter(Mandatory = $true)][string]$Destination)
$ErrorActionPreference = 'Stop'
$target = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $target) { throw "Destination already exists: $target" }
& (Join-Path $PSScriptRoot 'build.ps1') | Out-Null
New-Item -ItemType Directory -Path $target | Out-Null
foreach ($name in @('src', 'dist')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $target -Recurse }
Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.md' | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $target }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'build.ps1') -Destination $target
New-Item -ItemType Directory -Path (Join-Path $target 'test') | Out-Null
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'test') -Filter 'verify*.ps1' -File |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $target 'test') }
$repository = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Copy-Item -LiteralPath (Join-Path $repository 'LICENSE') -Destination $target
Get-FileHash -LiteralPath (Join-Path $target 'dist\bank-sandbox.exe') -Algorithm SHA256 |
    Select-Object Algorithm,Hash | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target 'SHA256.json') -Encoding UTF8
Compress-Archive -Path (Join-Path $target '*') -DestinationPath ($target + '.zip')
Get-Item -LiteralPath ($target + '.zip') | Select-Object FullName,Length
