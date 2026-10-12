# Generates THROWAWAY local development secrets into .env.local at the repo root (Windows).
# Never use these values in production. Requires: node (>=20) on PATH.
param([switch]$Force)
$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Out = Join-Path $Root '.env.local'
if ((Test-Path $Out) -and -not $Force) { Write-Error ".env.local already exists. Re-run with -Force to overwrite."; exit 1 }
# Same generator as the bash script: the Node block lives in gen-dev-secrets.sh between the JS markers.
$sh = Get-Content (Join-Path $PSScriptRoot 'gen-dev-secrets.sh') -Raw
$js = ($sh -split "<<'JS'\r?\n")[1] -split "\r?\nJS" | Select-Object -First 1
$tmp = New-TemporaryFile
Set-Content -Path $tmp -Value $js -Encoding UTF8
node $tmp (Join-Path $Root '.env.example') $Out
Remove-Item $tmp
