param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$outPath = Join-Path $workspace 'last-change-integrity.json'

$checks = @(
  [pscustomobject]@{ path='super-memory-brain/SKILL.md'; must=@('Temporary session binding protocol','Fast Session Resume rule','Project Graph Continuity rule','Multi-agent memory isolation rule','Evidence freshness gate','Long-context safe learning rule','Step/structure anti-drift rule','Avoidable Issue Elimination Rule','Accepted constraints preflight rule','Hot-refresh rule') },
  [pscustomobject]@{ path='scripts/learn-memory.ps1'; must=@('TextFile','writeParams','write-memory.ps1','last-learn-memory.json') },
  [pscustomobject]@{ path='scripts/evidence-freshness.ps1'; must=@('last-evidence-freshness.json','older_than','version_mismatch','stale logs/snapshots') },
  [pscustomobject]@{ path='scripts/project-continuity.ps1'; must=@('project-graph.json','structure-baseline.json','step-ledger.json','mustPreserve','mustNotViolate','openSteps') },
  [pscustomobject]@{ path='manifest.json'; must=@('evidence-freshness.ps1','project-continuity.ps1','learn-memory.ps1') },
  [pscustomobject]@{ path='tests/memory-eval-tests.json'; must=@('static-project-graph-continuity','static-fast-session-resume') }
)

$results = @($checks | ForEach-Object {
  $rel = $_.path
  $full = Join-Path $Root ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
  $exists = Test-Path -LiteralPath $full
  $missing = @()
  if ($exists) {
    $raw = Get-Content -LiteralPath $full -Raw -Encoding UTF8
    foreach ($needle in @($_.must)) {
      if ($raw.IndexOf([string]$needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { $missing += [string]$needle }
    }
  } else {
    $missing = @($_.must)
  }
  [pscustomobject]@{ path=$rel; exists=$exists; ok=($exists -and @($missing).Count -eq 0); missing=@($missing) }
})

$result = [pscustomobject]@{
  ok = (@($results | Where-Object { -not $_.ok }).Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  packageRoot = $Root
  results = @($results)
  guard = 'Critical rule edits must preserve existing rules and verify new rules; no accidental deletion or second-pass restoration should be needed.'
  nextAction = if (@($results | Where-Object { -not $_.ok }).Count -eq 0) { 'Change integrity passed.' } else { 'Restore missing rules before continuing.' }
}
Write-JsonUtf8NoBom $outPath $result 10
if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { if ($result.ok) { Write-Host "CHANGE_INTEGRITY_OK path=$outPath" } else { Write-Host "CHANGE_INTEGRITY_FAILED path=$outPath"; exit 1 } }
