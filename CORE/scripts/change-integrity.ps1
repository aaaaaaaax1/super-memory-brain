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
  # The host skill is intentionally a compact router. Long continuity and
  # governance rules belong in their cold owners, not in every prompt.
  [pscustomobject]@{ id='short-router-cold-pointers'; path='super-memory-brain/SKILL.md'; must=@('lightweight host adapter','references/runtime-control-plane.md','references/status-recovery.md','Moving behavior from this adapter into the runtime','automatic-wake tests are additive') },
  [pscustomobject]@{ id='continuity-and-session-isolation'; path='references/status-recovery.md'; must=@('Resume Receipt','P0 Continuity Priority Invariant','Canonical Active Checklist Additive Continuity','Workspace Isolation') },
  [pscustomobject]@{ id='runtime-preflight-and-non-regression'; path='references/runtime-control-plane.md'; must=@('Automatic Wake Path','Action Dependency Preflight','Non-Regression Contract','TaskStateStore CompleteTask') },
  [pscustomobject]@{ id='memory-writeback-and-evidence'; path='references/memory-governance.md'; must=@('Canonical Workflow Preference Recall','Memory Consolidation And Verified Writeback','stale record to override live evidence') },
  [pscustomobject]@{ id='learning-lifecycle'; path='references/automatic-evolution-policy.md'; must=@('Ponytail Gate','Canonical Lifecycle','never auto-adopts a rule, skill, test, reference, runtime behavior') },
  [pscustomobject]@{ id='accepted-constraints-preflight'; path='scripts/accepted-constraints-preflight.ps1'; must=@('last-accepted-constraints-preflight.json','Do not violate accepted constraint','Apply these accepted constraints before editing') },
  [pscustomobject]@{ id='hot-refresh'; path='scripts/hot-refresh-skills.ps1'; must=@('HOT_REFRESH_SKILL_OK','last-hot-refresh.json','SkipGlobalStartup') },
  [pscustomobject]@{ id='learning-write-entry'; path='scripts/learn-memory.ps1'; must=@('TextFile','writeParams','write-memory.ps1','last-learn-memory.json') },
  [pscustomobject]@{ id='evidence-freshness'; path='scripts/evidence-freshness.ps1'; must=@('last-evidence-freshness.json','older_than','version_mismatch','stale logs/snapshots') },
  [pscustomobject]@{ id='retired-project-graph-writer'; path='scripts/project-continuity.ps1'; must=@('PROJECT_CONTINUITY_LEGACY_WRITER_RETIRED','retired_read_only','execution-contract.ps1 + TaskStateStore','retired direct legacy writer') },
  [pscustomobject]@{ id='manifest-capabilities'; path='manifest.json'; must=@('evidence-freshness.ps1','project-continuity.ps1','learn-memory.ps1') },
  [pscustomobject]@{ id='memory-regression-cases'; path='tests/memory-eval-tests.json'; must=@('static-project-graph-continuity','static-fast-session-resume') }
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
  [pscustomobject]@{ id=[string]$_.id; path=$rel; exists=$exists; ok=($exists -and @($missing).Count -eq 0); missing=@($missing) }
})

$result = [pscustomobject]@{
  ok = (@($results | Where-Object { -not $_.ok }).Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  packageRoot = $Root
  results = @($results)
  guard = 'Critical behavior must retain a compact hot pointer plus its canonical cold owner or executable guard; do not re-inline cold rules merely to satisfy an obsolete validator.'
  nextAction = if (@($results | Where-Object { -not $_.ok }).Count -eq 0) { 'Change integrity passed.' } else { 'Restore the missing canonical guard or its required hot pointer before continuing.' }
}
Write-JsonUtf8NoBom $outPath $result 10
if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { if ($result.ok) { Write-Host "CHANGE_INTEGRITY_OK path=$outPath" } else { Write-Host "CHANGE_INTEGRITY_FAILED path=$outPath"; exit 1 } }
