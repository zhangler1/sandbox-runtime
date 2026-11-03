param(
  [Parameter(Mandatory=$true)][string]$Destination,
  [Parameter(Mandatory=$true)][string]$SandboxExe
)
$ErrorActionPreference='Stop'
$target=[IO.Path]::GetFullPath($Destination)
if(Test-Path -LiteralPath $target){throw 'Destination already exists'}
if(-not(Test-Path -LiteralPath $SandboxExe -PathType Leaf)){throw 'Sandbox EXE missing'}
New-Item -ItemType Directory -Path $target | Out-Null
foreach($name in @('index.js','package.json','launch.ps1','README.md','验证记录.md')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $target}
Copy-Item -LiteralPath $SandboxExe -Destination (Join-Path $target 'bank-sandbox.exe')
Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'windows-bank-appcontainer\README.md') -Destination (Join-Path $target '沙箱核心说明.md')
New-Item -ItemType Directory -Path (Join-Path $target 'test') | Out-Null
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'test') -File | Where-Object { $_.Extension -in @('.ps1','.mjs') } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $target 'test') }
$repository=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Copy-Item -LiteralPath (Join-Path $repository 'LICENSE') -Destination $target
Get-ChildItem -LiteralPath $target -Recurse -File | Get-FileHash -Algorithm SHA256 | Select-Object @{Name='File';Expression={$_.Path.Substring($target.Length+1)}},Hash | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target 'SHA256.json') -Encoding UTF8
Compress-Archive -Path (Join-Path $target '*') -DestinationPath ($target+'.zip')
Get-Item -LiteralPath ($target+'.zip') | Select-Object FullName,Length
