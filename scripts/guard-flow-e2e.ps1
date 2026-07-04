param([switch]$Json)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$outPath = Join-Path $workspace 'last-guard-flow-e2e.json'
if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }

$checks = New-Object System.Collections.ArrayList
$taskId = 'guard-flow-e2e-task'
function Add-Check([string]$Name,[bool]$Ok,[string]$Evidence){ [void]$checks.Add([pscustomobject]@{ name=$Name; ok=$Ok; evidence=$Evidence }) }
function Run-Json([string]$ScriptName,[string[]]$ScriptArgs){
  $scriptPath = Join-Path $PSScriptRoot $ScriptName
  $quotedArgs = @($ScriptArgs | ForEach-Object { if ($_ -like '-*') { $_ } else { "'" + (($_ -replace "'", "''")) + "'" } })
  $command = "& '$scriptPath' $($quotedArgs -join ' ') -Json"
  $output = Invoke-Expression $command 2>$null
  $text = ($output -join "`n")
  $jsonStart = $text.IndexOf('{')
  if ($jsonStart -lt 0) { throw "No JSON from $ScriptName" }
  return ($text.Substring($jsonStart) | ConvertFrom-Json)
}

try {
  $goal = Run-Json 'goal-route-lock.ps1' @('-Action','Create','-TaskId',$taskId,'-AcceptedGoal','Improve guard loop e2e','-AcceptedRoute','causal plan -> route checkpoint -> integration replay -> completion guard','-NonGoals','unrelated cleanup','-MustNotDriftTo','unrelated cleanup','-ApprovalEvidence','guard-flow-e2e')
  Add-Check 'goal-route-lock-create' ($goal.ok -eq $true -and $goal.active -eq $true) "routeHash=$($goal.routeHash) taskId=$($goal.taskId)"
} catch { Add-Check 'goal-route-lock-create' $false $_.Exception.Message }
try {
  $route = Run-Json 'route-checkpoint.ps1' @('-Phase','BeforeAct','-TaskId',$taskId,'-ObservedAction','causal plan then integration replay for Improve guard loop e2e')
  Add-Check 'route-checkpoint-clean' ($route.ok -eq $true) "status=$($route.status)"
} catch { Add-Check 'route-checkpoint-clean' $false $_.Exception.Message }
try {
  $plan = Run-Json 'causal-change-plan.ps1' @('-Action','Create','-TaskId',$taskId,'-ObservedProblem','guards need closed-loop evidence','-RootCause','expected-vs-actual and behavior replay were not first-class','-KnownFacts','0.5.72 has base guards','-ProposedChange','run e2e guard flow','-ExpectedOptimization','completion guard sees causal review and behavior replay evidence','-VerificationMethod','guard-flow-e2e checks')
  Add-Check 'causal-change-plan-create' ($plan.ok -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$plan.planId)) "planId=$($plan.planId) taskId=$($plan.taskId)"
} catch { Add-Check 'causal-change-plan-create' $false $_.Exception.Message }
try {
  $review = Run-Json 'causal-change-review.ps1' @('-TaskId',$taskId,'-ActualResult','expected optimization evidenced by guard-flow-e2e checks','-Evidence','guard-flow-e2e','-Decision','keep')
  Add-Check 'causal-change-review-clean' ($review.ok -eq $true) "reviewId=$($review.reviewId)"
} catch { Add-Check 'causal-change-review-clean' $false $_.Exception.Message }
try {
  $snapshot = Run-Json 'verified-module-snapshot.ps1' @('-Action','Create','-Module','guard-flow-demo','-VerifiedBehavior','echo contract','-Entrypoint','demo','-Inputs','input-a','-Outputs','output-a','-Dependencies','none','-StateAssumptions','none','-VerificationCommand','guard-flow-e2e','-Evidence','module smoke OK')
  Add-Check 'verified-module-snapshot-create' ($snapshot.ok -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$snapshot.snapshotHash)) "snapshotHash=$($snapshot.snapshotHash)"
} catch { Add-Check 'verified-module-snapshot-create' $false $_.Exception.Message }
try {
  $parity = Run-Json 'integration-parity-check.ps1' @('-TaskId',$taskId,'-Module','guard-flow-demo','-CurrentEntrypoint','demo','-CurrentDependencies','none','-CurrentStateAssumptions','none','-IntegrationCommand','guard-flow-e2e','-UserAcceptanceEvidence','actual output: guard-flow-e2e stdout matched output-a','-ModuleSmokeOk','-IntegrationSmokeOk','-UserAcceptanceOk')
  Add-Check 'integration-parity-clean' ($parity.ok -eq $true) "drifts=$(@($parity.drifts).Count)"
} catch { Add-Check 'integration-parity-clean' $false $_.Exception.Message }
try {
  $replay = Run-Json 'integration-contract-replay.ps1' @('-TaskId',$taskId,'-Module','guard-flow-demo','-Input','input-a','-ExpectedOutput','output-a','-IntegratedCommand','Write-Output output-a')
  Add-Check 'integration-contract-replay-clean' ($replay.ok -eq $true) "replayId=$($replay.replayId)"
} catch { Add-Check 'integration-contract-replay-clean' $false $_.Exception.Message }
try {
  $routeDone = Run-Json 'route-checkpoint.ps1' @('-Phase','BeforeCompletion','-TaskId',$taskId,'-ObservedAction','completed accepted goal Improve guard loop e2e with causal review and integration replay')
  Add-Check 'route-checkpoint-before-completion' ($routeDone.ok -eq $true) "status=$($routeDone.status)"
} catch { Add-Check 'route-checkpoint-before-completion' $false $_.Exception.Message }

$failed = @($checks | Where-Object { $_.ok -ne $true })
$result = [pscustomobject]@{ ok=($failed.Count -eq 0); checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.guard-flow-e2e.v1'; version=(Get-SuperBrainManifest $Root).version; failed=$failed.Count; checks=@($checks); guard='E2E guard flow proves route lock, causal plan/review, verified snapshot, integration parity, behavior replay, and completion route checkpoint can work together.'; path=$outPath }
Write-JsonUtf8NoBom $outPath $result 12
if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "GUARD_FLOW_E2E ok=$($result.ok) failed=$($result.failed) path=$outPath"}
if(-not $result.ok){exit 1}; exit 0
