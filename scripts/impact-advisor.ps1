param(
  [string[]]$ChangedFiles = @(),
  [switch]$Json,
  [switch]$RefreshCodegraph
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }

$manifest = Get-SuperBrainManifest $Root
$now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$outPath = Join-Path $workspace 'last-impact-advisor.json'
$codegraphPath = Join-Path $workspace 'last-codegraph-index.json'
$projectContinuityPath = Join-Path $workspace 'last-project-continuity.json'
$structureBaselinePath = Join-Path $workspace 'structure-baseline.json'
$stepLedgerPath = Join-Path $workspace 'step-ledger.json'

function Read-JsonOrNull([string]$Path) { if (-not (Test-Path -LiteralPath $Path)) { return $null }; try { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } }
function Normalize-ChangedFile([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
  $p = ($Path -replace '\\','/').Trim().TrimStart('/')
  $idx = $p.LastIndexOf('/scripts/')
  if ($idx -ge 0) { return 'scripts/' + $p.Substring($idx + 9) }
  if ($p -match '^[A-Za-z0-9_.-]+\.ps1$') { return 'scripts/' + $p }
  return $p
}
function Add-Unique([object[]]$Items) { @($Items | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique) }
function Add-Check([string[]]$Checks, [string]$Check) { if ($Checks -notcontains $Check) { $Checks += $Check }; return $Checks }

if ($RefreshCodegraph -or -not (Test-Path -LiteralPath $codegraphPath)) {
  & (Join-Path $PSScriptRoot 'codegraph-index.ps1') -Json | Out-Null
}
$codegraph = Read-JsonOrNull $codegraphPath
$continuity = Read-JsonOrNull $projectContinuityPath
$baseline = Read-JsonOrNull $structureBaselinePath
$ledger = Read-JsonOrNull $stepLedgerPath

$normalizedChanged = Add-Unique @($ChangedFiles | ForEach-Object { Normalize-ChangedFile $_ })
$normalizedScripts = Add-Unique @($normalizedChanged | Where-Object { $_ -like 'scripts/*.ps1' } | ForEach-Object { $_.Substring(8) })

$directCallers = @(); $directCallees = @(); $affectedScripts = @(); $workspaceReads = @(); $workspaceWrites = @(); $affectedWorkspaceFiles = @(); $dynamicUnknown = @(); $whyRisky = @(); $recommendedChecks = @(); $scriptRisks = @()
$scriptMap = @{}
foreach ($s in @($codegraph.scripts)) { $scriptMap[[string]$s.path] = $s }

foreach ($script in @($normalizedScripts)) {
  $nodeId = "script:$script"
  $info = if ($scriptMap.ContainsKey($script)) { $scriptMap[$script] } else { $null }
  if ($info) {
    $directCallees += @($info.calls | ForEach-Object { [pscustomobject]@{ from=$script; to=[string]$_ } })
    $workspaceReads += @($info.workspaceReads | ForEach-Object { [pscustomobject]@{ script=$script; workspaceFile=[string]$_ } })
    $workspaceWrites += @($info.workspaceWrites | ForEach-Object { [pscustomobject]@{ script=$script; workspaceFile=[string]$_ } })
    $affectedWorkspaceFiles += @($info.workspaceReads + $info.workspaceWrites + $info.workspaceReferences)
    $dynamicUnknown += @($info.dynamicCallsUnknown | ForEach-Object { [pscustomobject]@{ script=$script; call=[string]$_ } })
    $scriptRisks += [pscustomobject]@{ script=$script; tier=$info.tier; hasMutation=[bool]$info.hasMutation; manualOnly=[bool]$info.manualOnly; dangerousSwitches=@($info.dangerousSwitches) }
  }
  foreach ($edge in @($codegraph.edges | Where-Object { $_.to -eq $nodeId -and $_.relation -like 'script_call*' })) {
    $caller = ([string]$edge.from) -replace '^script:',''
    $directCallers += [pscustomobject]@{ from=$caller; to=$script; relation=$edge.relation }
    $affectedScripts += $caller
  }
  foreach ($edge in @($codegraph.edges | Where-Object { $_.from -eq $nodeId -and $_.relation -like 'script_call*' -and $_.to -like 'script:*' })) {
    $callee = ([string]$edge.to) -replace '^script:',''
    if ($callee -ne 'unknown') { $affectedScripts += $callee }
  }
}

foreach ($wf in Add-Unique $affectedWorkspaceFiles) {
  foreach ($edge in @($codegraph.edges | Where-Object { $_.to -eq "workspace:$wf" -and $_.relation -in @('workspace_read','workspace_write','workspace_reference') })) {
    $affectedScripts += (([string]$edge.from) -replace '^script:','')
  }
}
$affectedScripts = Add-Unique @($affectedScripts + $normalizedScripts)
$affectedWorkspaceFiles = Add-Unique $affectedWorkspaceFiles

$critical = @('scripts/project-continuity.ps1','scripts/codegraph-index.ps1','scripts/impact-advisor.ps1','scripts/verify-package.ps1','scripts/ci.ps1','memory-policy.json','manifest.json','CURRENT_BASELINE.md')
foreach ($f in @($normalizedChanged)) { if ($critical -contains $f) { $whyRisky += "critical_file_changed:$f" } }
foreach ($r in @($scriptRisks)) { if (($r.tier -in @('T2','T3')) -and $r.hasMutation) { $whyRisky += "mutating_high_tier_script:$($r.script):$($r.tier)" } elseif ($r.tier -eq 'T1') { $whyRisky += "t1_script_changed:$($r.script)" } }
if (@($directCallers).Count -gt 0) { $whyRisky += "direct_callers:$(@($directCallers).Count)" }
if (@($directCallees).Count -gt 0) { $whyRisky += "direct_callees:$(@($directCallees).Count)" }
if (@($affectedWorkspaceFiles).Count -gt 0) { $whyRisky += "workspace_dataflow:$(@($affectedWorkspaceFiles).Count)" }
if (@($dynamicUnknown).Count -gt 0) { $whyRisky += "dynamic_unknown_calls:$(@($dynamicUnknown).Count)" }
$openSteps = @($ledger.openSteps)
if (@($openSteps).Count -gt 0) { $whyRisky += "open_steps:$(@($openSteps).Count)" }
$candidateFindings = if ($continuity -and $continuity.findingCounts) { [int]$continuity.findingCounts.candidate } else { 0 }
if ($candidateFindings -gt 0) { $whyRisky += "candidate_findings:$candidateFindings" }

$riskLevel = 'low'
if (@($whyRisky | Where-Object { $_ -like 'critical_file_changed:*' -or $_ -like 'mutating_high_tier_script:*' -or $_ -like 'open_steps:*' -or $_ -like 'candidate_findings:*' }).Count -gt 0) { $riskLevel = 'high' }
elseif (@($whyRisky).Count -gt 0) { $riskLevel = 'medium' }

$recommendedChecks = Add-Check $recommendedChecks 'scripts/codegraph-index.ps1 -Json'
$recommendedChecks = Add-Check $recommendedChecks 'scripts/project-continuity.ps1 -Action Status -Json'
if ($riskLevel -in @('medium','high')) { $recommendedChecks = Add-Check $recommendedChecks 'scripts/verify-package.ps1' }
if (@($normalizedChanged | Where-Object { $_ -match 'recall|memory|session|intent|trigger|super-memory-brain/SKILL.md|memory-policy.json' }).Count -gt 0) { $recommendedChecks = Add-Check $recommendedChecks 'scripts/memory-eval.ps1 -Json'; $recommendedChecks = Add-Check $recommendedChecks 'scripts/trigger-simulation.ps1 -Json' }
if (@($normalizedChanged | Where-Object { $_ -in @('manifest.json','CURRENT_BASELINE.md') -or $_ -like 'scripts/project-continuity.ps1' -or $_ -like 'scripts/codegraph-index.ps1' -or $_ -like 'scripts/impact-advisor.ps1' -or $_ -like 'scripts/verify-package.ps1' -or $_ -like 'scripts/ci.ps1' }).Count -gt 0) { $recommendedChecks = Add-Check $recommendedChecks 'scripts/accepted-constraints-preflight.ps1 -Json'; $recommendedChecks = Add-Check $recommendedChecks 'scripts/test-pester.ps1'; $recommendedChecks = Add-Check $recommendedChecks 'scripts/ci.ps1' }
if ($riskLevel -eq 'high') { $recommendedChecks = Add-Check $recommendedChecks 'scripts/ci.ps1' }

$structureConstraints = if ($baseline) { @($baseline.mustPreserve | Select-Object -First 12) } else { @() }
$ok = ($null -ne $codegraph)
$nextAction = if (@($ChangedFiles).Count -eq 0) { 'Pass -ChangedFiles or run with -RefreshCodegraph before relying on impact results.' } elseif ($riskLevel -eq 'high') { 'Treat as high impact: review affected scripts/workspace files and run recommended checks before completion.' } elseif ($riskLevel -eq 'medium') { 'Run recommended targeted checks and review direct callers/callees.' } else { 'Low impact: run lightweight checks and report any skipped verification.' }

$result = [pscustomobject]@{
  schema='super-brain.impact-advisor.v1'; ok=$ok; checkedAt=$now; version=[string]$manifest.version; packageRoot=$Root
  changedFiles=@($normalizedChanged); normalizedChangedScripts=@($normalizedScripts)
  directCallers=@($directCallers); directCallees=@($directCallees); workspaceReads=@($workspaceReads); workspaceWrites=@($workspaceWrites); affectedWorkspaceFiles=@($affectedWorkspaceFiles); affectedScripts=@($affectedScripts)
  riskLevel=$riskLevel; whyRisky=Add-Unique $whyRisky; recommendedChecks=@($recommendedChecks); structureConstraints=@($structureConstraints); openSteps=@($openSteps); candidateFindings=$candidateFindings; dynamicUnknownCalls=@($dynamicUnknown)
  nextAction=$nextAction
}
Write-JsonUtf8NoBom $outPath $result 12
if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "IMPACT_ADVISOR_OK risk=$riskLevel changed=$(@($normalizedChanged).Count) affected=$(@($affectedScripts).Count) checks=$(@($recommendedChecks).Count) status=$outPath" }
exit 0
