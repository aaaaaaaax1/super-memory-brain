param(
  [string]$Summary = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$path = Join-Path $workspace 'last-retrospective.json'

function Read-WorkspaceJson([string]$Name) {
  $candidate = Join-Path $workspace $Name
  if (-not (Test-Path $candidate)) { return $null }
  try { return Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

$lastTask = Read-WorkspaceJson 'last-task-verification.json'
$lastCi = Read-WorkspaceJson 'last-ci.json'
$lastVerify = Read-WorkspaceJson 'last-verify-package.json'
if ([string]::IsNullOrWhiteSpace($Summary) -and $lastTask) { $Summary = [string]$lastTask.summary }

$lessons = @()
if ($lastCi -and $lastCi.ok -eq $true) { $lessons += 'Full CI evidence is the strongest completion signal.' }
if ($lastVerify -and $lastVerify.ok -eq $true) { $lessons += 'Package verification should remain the baseline before release or handoff.' }
if ($lastTask -and @($lastTask.evidence).Count -gt 0) { $lessons += 'Task verification evidence is sufficient for continuation handoff.' }

$lessonCandidates = @()
foreach ($lesson in @($lessons)) {
  $lessonCandidates += [pscustomobject]@{
    target = 'experience'
    summary = $lesson
    evidence = @('last-task-verification.json','last-ci.json','last-verify-package.json')
    confidence = 0.72
    promotionHint = 'reflection-promotion.ps1 -Mode Preview can classify and promote this only after evidence/privacy/duplicate checks.'
  }
}
if (-not [string]::IsNullOrWhiteSpace($Summary)) {
  $lessonCandidates += [pscustomobject]@{
    target = 'memory'
    summary = $Summary
    evidence = @('last-retrospective.json')
    confidence = 0.65
    promotionHint = 'Keep as a candidate unless it is reusable, verified, and non-private.'
  }
}

$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  summary = $Summary
  didWell = @('Kept machine-readable status current','Verified before completion','Preserved privacy and memory-root state')
  improveNext = @('Prefer trigger simulation before changing dispatch priority','Keep release readiness separate from release execution','Record only concise lessons to avoid memory noise')
  lessons = @($lessons)
  lessonCandidates = @($lessonCandidates)
  selfLearning = [pscustomobject]@{
    defaultPromotionMode = 'Preview'
    promotionScript = 'reflection-promotion.ps1'
    noDurableWriteWithoutApply = $true
  }
  evidence = @('last-task-verification.json','last-ci.json','last-verify-package.json')
}
Write-JsonUtf8NoBom $path $result 8

if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "TASK_RETROSPECTIVE_OK path=$path summary=$Summary" }
exit 0
