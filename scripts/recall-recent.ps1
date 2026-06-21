param(
  [int]$Count = 5,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$MemoryScripts = Join-Path $MemoryRoot 'scripts'
$env:NEXSANDBASE_HOME = $MemoryRoot
$env:PYTHONPATH = $MemoryScripts
$code = "import json; from sandglass_vault import recent; print(json.dumps(recent($Count), ensure_ascii=False))"
$result = python -c $code
if ($Json) {
  $result
} else {
  $items = $result | ConvertFrom-Json
  foreach ($item in $items) {
    Write-Host ($item | ConvertTo-Json -Compress -Depth 5)
  }
}
