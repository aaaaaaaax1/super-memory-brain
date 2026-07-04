param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$statusPath = Join-Path $workspace 'last-recovery-e2e.json'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }

function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
function Invoke-JsonTool([string]$Name, [scriptblock]$Call) {
  $output = @()
  try {
    $output = @(& $Call 6>$null 2>&1)
    $raw = (@($output | ForEach-Object { [string]$_ }) -join "`n") -replace '\x1b\[[0-9;?]*[A-Za-z]', '' -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''
    $start = $raw.IndexOf('{')
    $end = $raw.LastIndexOf('}')
    if ($start -lt 0 -or $end -lt $start) { return [pscustomobject]@{ ok=$false; parsed=$false; name=$Name; error='no_json'; value=$null; raw=@($output) } }
    $json = $raw.Substring($start, $end - $start + 1) | ConvertFrom-Json
    return [pscustomobject]@{ ok=$true; parsed=$true; name=$Name; error=''; value=$json; raw=@($output) }
  } catch {
    return [pscustomobject]@{ ok=$false; parsed=$false; name=$Name; error=$_.Exception.Message; value=$null; raw=@($output) }
  }
}
function New-Case([string]$Name, [bool]$Ok, [string]$Reason, [object]$Observed) {
  return [pscustomobject]@{ name=$Name; ok=$Ok; reason=$Reason; observed=$Observed }
}

$planPrompt = (U @(0x5148,0x51FA,0x65B9,0x6848)) + ',' + (U @(0x4E0D,0x8981,0x6267,0x884C))
$statusPrompt = U @(0x4EFB,0x52A1,0x72B6,0x6001)
$continuePrompt = U @(0x7EE7,0x7EED)
$taskListPrompt = U @(0x6709,0x54EA,0x4E9B,0x4EFB,0x52A1)
$ocrNoisePrompt = 'OCR 1920x1080 button text continue G1 log fragment no user instruction'

$cases = @()
$planGate = Invoke-JsonTool 'intent-gate plan_only' { & (Join-Path $PSScriptRoot 'intent-gate.ps1') $planPrompt -Json }
$cases += New-Case 'plan_only_cannot_mutate' ($planGate.parsed -and $planGate.value.intent -eq 'plan_only' -and $planGate.value.canMutate -eq $false -and $planGate.value.shouldExecute -eq $false) 'plan-only prompt must not mutate or execute' $planGate.value

$statusGate = Invoke-JsonTool 'intent-gate status_only' { & (Join-Path $PSScriptRoot 'intent-gate.ps1') $statusPrompt -Json }
$cases += New-Case 'status_only_cannot_mutate' ($statusGate.parsed -and $statusGate.value.intent -eq 'status_only' -and $statusGate.value.canMutate -eq $false -and $statusGate.value.shouldExecute -eq $false) 'status prompt must be read-only' $statusGate.value

$executeGate = Invoke-JsonTool 'intent-gate execute' { & (Join-Path $PSScriptRoot 'intent-gate.ps1') $continuePrompt -Json }
$restore = Invoke-JsonTool 'session-restore continue' { & (Join-Path $PSScriptRoot 'session-restore.ps1') -Query $continuePrompt -Json }
$cases += New-Case 'continue_restore_light_packet' ($executeGate.parsed -and $executeGate.value.intent -eq 'execute' -and $restore.parsed -and $restore.value.recallTriggered -eq $false -and $null -ne $restore.value.statusCard) 'continue must be authorized and restore a light packet without deep recall' ([pscustomobject]@{ gate=$executeGate.value; restore=$restore.value })

$taskIndex = Invoke-JsonTool 'task-index' { & (Join-Path $PSScriptRoot 'task-index.ps1') -Json }
$cases += New-Case 'task_list_has_buckets' ($taskIndex.parsed -and $null -ne $taskIndex.value.counts -and $null -ne $taskIndex.value.current -and $null -ne $taskIndex.value.completed -and $null -ne $taskIndex.value.candidates) 'task-index must expose current/completed/candidate buckets' $taskIndex.value

$taskListGate = Invoke-JsonTool 'intent-gate task_list' { & (Join-Path $PSScriptRoot 'intent-gate.ps1') $taskListPrompt -Json }
$cases += New-Case 'task_list_is_status_only' ($taskListGate.parsed -and $taskListGate.value.intent -eq 'status_only' -and $taskListGate.value.canMutate -eq $false) 'task list prompt must be status-only' $taskListGate.value

$noiseGate = Invoke-JsonTool 'intent-gate ocr_noise' { & (Join-Path $PSScriptRoot 'intent-gate.ps1') $ocrNoisePrompt -Json }
$cases += New-Case 'ocr_noise_does_not_execute' ($noiseGate.parsed -and $noiseGate.value.intent -ne 'execute' -and $noiseGate.value.canMutate -eq $false) 'OCR/log/code noise must not trigger execution by itself' $noiseGate.value

$failed = @($cases | Where-Object { $_.ok -ne $true })
$result = [pscustomobject]@{
  ok = ($failed.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = [string]$manifest.version
  total = @($cases).Count
  failed = $failed.Count
  cases = @($cases)
  nextAction = if ($failed.Count -eq 0) { 'Recovery E2E passed.' } else { 'Fix failed recovery E2E cases.' }
  statusPath = $statusPath
}
Write-JsonUtf8NoBom $statusPath $result 12
if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "RECOVERY_E2E ok=$($result.ok) total=$($result.total) failed=$($result.failed) status=$statusPath" }
if (-not $result.ok) { exit 1 }
exit 0
