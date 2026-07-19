param(
  [string]$Lesson = '',
  [string]$Scope = '',
  [string[]]$Evidence = @(),
  [string[]]$AppliesWhen = @(),
  [string[]]$DoesNotApplyWhen = @(),
  [string[]]$CounterExamples = @(),
  [string[]]$ValidationConditions = @(),
  [double]$Confidence = 0.0,
  [string]$WorkspaceRoot = '',
  [switch]$NoWrite,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace' } else { [IO.Path]::GetFullPath($WorkspaceRoot) }
$outPath = Join-Path $workspace 'last-lesson-scope-gate.json'

function Limit-Text([string]$Value,[int]$Max=700){ if([string]::IsNullOrWhiteSpace($Value)){return ''}; $v=$Value.Trim() -replace '\s+',' '; if($v.Length -gt $Max){return $v.Substring(0,$Max)+'...'}; return $v }
function Add-Gap($List,[string]$Code,[string]$EvidenceText,[string]$Severity='medium'){ [void]$List.Add([pscustomobject]@{ code=$Code; severity=$Severity; evidence=Limit-Text $EvidenceText 500 }) }

$gaps = New-Object System.Collections.ArrayList
if ([string]::IsNullOrWhiteSpace($Lesson)) { Add-Gap $gaps 'missing_lesson' 'Lesson text is required before any durable learning.' 'high' }
if ([string]::IsNullOrWhiteSpace($Scope)) { Add-Gap $gaps 'missing_scope' 'Lesson must name its scope to avoid broad overfitting.' 'high' }
if (@($Evidence).Count -eq 0) { Add-Gap $gaps 'missing_evidence' 'Lesson must cite evidence; one unsupported incident must not become a rule.' 'high' }
if (@($AppliesWhen).Count -eq 0) { Add-Gap $gaps 'missing_applies_when' 'Lesson must say when it applies.' 'medium' }
if (@($DoesNotApplyWhen).Count -eq 0) { Add-Gap $gaps 'missing_does_not_apply_when' 'Lesson must say when it does not apply.' 'high' }
if (@($CounterExamples).Count -eq 0) { Add-Gap $gaps 'missing_counterexamples' 'Lesson should include counterexamples or falsifiers.' 'medium' }
if (@($ValidationConditions).Count -eq 0) { Add-Gap $gaps 'missing_validation_conditions' 'Lesson must say how future tasks can validate or falsify the rule before reuse.' 'high' }
if ($Confidence -lt 0.6) { Add-Gap $gaps 'low_confidence' "Confidence $Confidence is below durable learning threshold 0.6." 'medium' }

$result = [pscustomobject]@{
  ok = ($gaps.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = 'super-brain.lesson-scope-gate.v1'
  version = (Get-SuperBrainManifest $Root).version
  lesson = Limit-Text $Lesson 900
  scope = Limit-Text $Scope 400
  evidence = @($Evidence | ForEach-Object { Limit-Text $_ 360 })
  appliesWhen = @($AppliesWhen | ForEach-Object { Limit-Text $_ 360 })
  doesNotApplyWhen = @($DoesNotApplyWhen | ForEach-Object { Limit-Text $_ 360 })
  counterExamples = @($CounterExamples | ForEach-Object { Limit-Text $_ 360 })
  validationConditions = @($ValidationConditions | ForEach-Object { Limit-Text $_ 360 })
  confidence = $Confidence
  gaps = @($gaps)
  guard = 'Anti-overfitting gate: no durable lesson from one vague incident without scope, evidence, counterexamples/falsifiers, confidence, validation conditions, and does-not-apply conditions.'
  nextAction = if($gaps.Count -gt 0){'Keep as reflection candidate only; fill scope/evidence/falsifier fields before promotion.'}else{'Lesson is scoped enough to be considered by reflection-promotion / learn-memory gates.'}
  path = $outPath
}
if (-not $NoWrite) { Write-JsonUtf8NoBom $outPath $result 12 }
if($Json){$result|ConvertTo-Json -Depth 12}else{Write-Host "LESSON_SCOPE_GATE ok=$($result.ok) gaps=$(@($gaps).Count) path=$outPath"}
if(-not $result.ok){exit 1}; exit 0
