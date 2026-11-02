$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw ".NET Framework x64 compiler missing: $compiler" }
$destination = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$sources = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -Filter '*.cs' | Select-Object -ExpandProperty FullName)
& $compiler /nologo /target:exe /platform:x64 /optimize+ /warnaserror+ ("/out:" + (Join-Path $destination 'bank-sandbox.exe')) @sources
if ($LASTEXITCODE -ne 0) { throw "Compiler failed: $LASTEXITCODE" }
Get-FileHash -LiteralPath (Join-Path $destination 'bank-sandbox.exe') -Algorithm SHA256
