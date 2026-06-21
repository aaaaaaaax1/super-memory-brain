param(
  [string[]]$Keywords = @('默认记忆写入策略','G1审记','ORC调度','NexSandglass 协作规则','super-memory-brain')
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$MemoryScripts = Join-Path $MemoryRoot 'scripts'
$env:NEXSANDBASE_HOME = $MemoryRoot
$env:PYTHONPATH = $MemoryScripts

Write-Host 'NexSandglass compact candidate report'
Write-Host "Memory root: $MemoryRoot"
Write-Host 'This script does not delete memory. It searches likely duplicate rule clusters.'

foreach ($kw in $Keywords) {
  Write-Host "`n--- Keyword: $kw ---"
  python -c "from sandglass_vault import search; print(search('$kw'))"
}

Write-Host "`nReview the results. If duplicates exist, write one short accepted replacement note and mark old conflicting rules stale."
