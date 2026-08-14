$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$trialScript = Join-Path $root 'scripts\typed-memory-trial.ps1'
. (Join-Path $root 'scripts\common.ps1')

function Write-TrialTestJson([string]$Path,[object]$Value) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 14),[Text.UTF8Encoding]::new($false))
}

function Get-TrialTestSha256([string]$Value) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) | ForEach-Object { $_.ToString('x2') })).ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function Invoke-TrialTest([string]$StateRoot,[hashtable]$Arguments,[string]$ScriptPath = $trialScript) {
  $oldState = $env:SUPER_BRAIN_STATE_ROOT
  $oldWorkspace = $env:SUPER_BRAIN_WORKSPACE_KEY
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $env:SUPER_BRAIN_WORKSPACE_KEY = [string]$Arguments.WorkspaceKey
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ScriptPath)
    foreach ($key in $Arguments.Keys) {
      if ($key -eq 'WorkspaceKey') { continue }
      $value = $Arguments[$key]
      if (($value -is [switch] -and $value.IsPresent) -or ($value -is [bool] -and $value)) { $args += ('-' + $key); continue }
      if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) { $args += ('-' + $key); $args += [string]$value }
    }
    $raw = @(& powershell.exe @args 2>$null)
    $exitCode = $LASTEXITCODE
    $value = (($raw -join "`n") | ConvertFrom-Json)
    return [pscustomobject]@{ exitCode=$exitCode; value=$value }
  } finally {
    if ($null -eq $oldState) { Remove-Item Env:SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldState }
    if ($null -eq $oldWorkspace) { Remove-Item Env:SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspace }
  }
}

function New-TrialFixtureScripts([string]$StateRoot) {
  $fixtureRoot = Join-Path $StateRoot 'fixture-root'
  $scripts = Join-Path $fixtureRoot 'scripts'
  New-Item -ItemType Directory -Force -Path $scripts | Out-Null
  Copy-Item -LiteralPath (Join-Path $root 'manifest.json') -Destination (Join-Path $fixtureRoot 'manifest.json') -Force
  foreach ($name in @('common.ps1','typed-memory-trial.ps1')) {
    Copy-Item -LiteralPath (Join-Path $root ('scripts\' + $name)) -Destination (Join-Path $scripts $name) -Force
  }
  $guard = @'
param([string]$TaskId = '',[int]$MaxEvidenceAgeMinutes = 60,[switch]$Json)
$negative = $TaskId -like '*-fail'
$result = [pscustomobject]@{ok=(-not $negative);completionAuthorized=(-not $negative);checkedAt=(Get-Date).ToString('o');taskId=$TaskId;failed=if($negative){1}else{0};checks=@()}
if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host 'COMPLETION_GUARD ok=True' }
if ($negative) { exit 1 }
exit 0
'@
  [IO.File]::WriteAllText((Join-Path $scripts 'completion-guard.ps1'),$guard,[Text.UTF8Encoding]::new($false))
  return [pscustomobject]@{ root=$fixtureRoot; trialScript=(Join-Path $scripts 'typed-memory-trial.ps1') }
}

Describe 'Task-scoped typed-memory trial' {
  It 'captures only typed refs/effects, uses taskInstanceId hash naming, and is idempotent' {
    $state = Join-Path $TestDrive 'typed-trial-start'
    $workspace = Join-Path $state 'workspace'
    $taskId = 'task-typed-trial-start'
    $taskInstanceId = 'ti-0123456789abcdef0123456789abcdef'
    $workspaceKey = 'ws-aaaaaaaaaaaaaaaaaaaaaaaa'
    $sessionKey = 'sid-bbbbbbbbbbbbbbbbbbbbbbbb'
    $cognitivePath = Join-Path $workspace 'last-cognitive-enforce.json'
    Write-TrialTestJson $cognitivePath ([pscustomobject]@{
      schema='super-brain.cognitive-enforce.v1'; taskId=$taskId
      memoryInfluence=[pscustomobject]@{
        ok=$true; status='ready'
        scope=[pscustomobject]@{taskId=$taskId;taskInstanceId=$taskInstanceId;workspaceKey=$workspaceKey;ownerSessionKey=$sessionKey}
        behaviorGuidance=@([pscustomobject]@{cardId='pref-trial';cardRevision=2;effect='shape_behavior'})
        reusableAdvice=@([pscustomobject]@{cardId='exp-trial';cardRevision=1;effect='reuse_as_advice'})
        procedureSteps=@(); references=@(); learningCandidates=@()
      }
    })

    $first = Invoke-TrialTest $state @{Action='Start';TaskId=$taskId;TaskInstanceId=$taskInstanceId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey;CognitiveEvidencePath=$cognitivePath;Json=$true;NoExit=$true}
    $first.exitCode | Should Be 0
    $first.value.status | Should Be 'captured'
    @($first.value.memoryRefs).Count | Should Be 2
    @($first.value.effects).Count | Should Be 2
    $first.value.rawPromptStored | Should Be $false
    $first.value.memoryBodyStored | Should Be $false
    $first.value.cachePending | Should Be $false
    $first.value.nativeMemorySnapshot.ok | Should Be $true
    (Split-Path -Leaf $first.value.path) | Should Be ((Get-TrialTestSha256 $taskInstanceId) + '.json')
    $snapshot = Get-Content -LiteralPath $first.value.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $snapshot.schema | Should Be 'super-brain.typed-memory-trial-snapshot.v1'
    (@($snapshot.memoryRefs[0].PSObject.Properties.Name) -contains 'title') | Should Be $false
    $snapshot.privacy.rawTranscriptStored | Should Be $false
    Test-Path -LiteralPath (Join-Path $workspace 'native-memory-influence-snapshot.json') | Should Be $true
    Test-Path -LiteralPath (Join-Path $workspace 'native-memory-influence-snapshot.dirty.json') | Should Be $false

    $second = Invoke-TrialTest $state @{Action='Start';TaskId=$taskId;TaskInstanceId=$taskInstanceId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey;CognitiveEvidencePath=$cognitivePath;Json=$true;NoExit=$true}
    $second.value.status | Should Be 'reused'
    $second.value.sha256 | Should Be $first.value.sha256
  }

  It 'rejects a changed typed-memory snapshot instead of overwriting it' {
    $state = Join-Path $TestDrive 'typed-trial-conflict'
    $workspace = Join-Path $state 'workspace'
    $taskId = 'task-typed-trial-conflict'
    $taskInstanceId = 'ti-fedcba9876543210fedcba9876543210'
    $workspaceKey = 'ws-cccccccccccccccccccccccc'
    $sessionKey = 'sid-dddddddddddddddddddddddd'
    $cognitivePath = Join-Path $workspace 'last-cognitive-enforce.json'
    $base = [pscustomobject]@{schema='super-brain.cognitive-enforce.v1';taskId=$taskId;memoryInfluence=[pscustomobject]@{ok=$true;status='ready';scope=[pscustomobject]@{taskId=$taskId;taskInstanceId=$taskInstanceId;workspaceKey=$workspaceKey;ownerSessionKey=$sessionKey};behaviorGuidance=@([pscustomobject]@{cardId='pref-conflict';cardRevision=1;effect='shape_behavior'});reusableAdvice=@();procedureSteps=@();references=@();learningCandidates=@()}}
    Write-TrialTestJson $cognitivePath $base
    $null = Invoke-TrialTest $state @{Action='Start';TaskId=$taskId;TaskInstanceId=$taskInstanceId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey;CognitiveEvidencePath=$cognitivePath;Json=$true;NoExit=$true}
    $base.memoryInfluence.references = @([pscustomobject]@{cardId='note-conflict';cardRevision=1;effect='reference_only'})
    Write-TrialTestJson $cognitivePath $base
    $changed = Invoke-TrialTest $state @{Action='Start';TaskId=$taskId;TaskInstanceId=$taskInstanceId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey;CognitiveEvidencePath=$cognitivePath;Json=$true;NoExit=$true}
    $changed.value.status | Should Be 'conflict'
    $changed.value.code | Should Be 'TYPED_MEMORY_TRIAL_SNAPSHOT_CONFLICT'
  }

  It 'returns inconclusive without authoritative completion evidence and never creates a receipt' {
    $state = Join-Path $TestDrive 'typed-trial-resolve'
    $workspace = Join-Path $state 'workspace'
    $taskId = 'task-typed-trial-resolve'
    $taskInstanceId = 'ti-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $workspaceKey = 'ws-eeeeeeeeeeeeeeeeeeeeeeee'
    $sessionKey = 'sid-ffffffffffffffffffffffff'
    $cognitivePath = Join-Path $workspace 'last-cognitive-enforce.json'
    Write-TrialTestJson $cognitivePath ([pscustomobject]@{schema='super-brain.cognitive-enforce.v1';taskId=$taskId;memoryInfluence=[pscustomobject]@{ok=$true;status='ready';scope=[pscustomobject]@{taskId=$taskId;taskInstanceId=$taskInstanceId;workspaceKey=$workspaceKey;ownerSessionKey=$sessionKey};behaviorGuidance=@([pscustomobject]@{cardId='pref-resolve';cardRevision=1;effect='shape_behavior'});reusableAdvice=@();procedureSteps=@();references=@();learningCandidates=@()}})
    $start = Invoke-TrialTest $state @{Action='Start';TaskId=$taskId;TaskInstanceId=$taskInstanceId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey;CognitiveEvidencePath=$cognitivePath;Json=$true;NoExit=$true}
    $resolved = Invoke-TrialTest $state @{Action='Resolve';TaskId=$taskId;TaskInstanceId=$taskInstanceId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey;Json=$true;NoExit=$true}
    $resolved.value.verdict | Should Be 'inconclusive'
    $resolved.value.code | Should Be 'TYPED_MEMORY_TRIAL_TASK_VERIFICATION_MISSING'
    Test-Path -LiteralPath (Join-Path $workspace 'runtime-state\typed-memory-trial-receipts') | Should Be $false
  }

  It 'derives passed and explicit failed only from current task-scoped completion evidence' {
    $state = Join-Path $TestDrive 'typed-trial-verdicts'
    $workspace = Join-Path $state 'workspace'
    $workspaceKey = 'ws-565656565656565656565656'
    $sessionKey = 'sid-787878787878787878787878'
    $fixture = New-TrialFixtureScripts $state
    foreach ($case in @(
      [pscustomobject]@{ suffix='pass'; instance='ti-22222222222222222222222222222222'; accepted=$true; outcome=$true; verdict='passed' },
      [pscustomobject]@{ suffix='fail'; instance='ti-33333333333333333333333333333333'; accepted=$false; outcome=$false; verdict='failed' }
    )) {
      $taskId = 'task-typed-trial-' + $case.suffix
      $cognitivePath = Join-Path $workspace 'last-cognitive-enforce.json'
      $binding = New-SuperBrainEvidenceBinding -TaskId $taskId -WorkspaceKey $workspaceKey -OwnerSessionKey $sessionKey -Root $fixture.root
      Write-TrialTestJson $cognitivePath ([pscustomobject]@{schema='super-brain.cognitive-enforce.v1';taskId=$taskId;memoryInfluence=[pscustomobject]@{ok=$true;status='ready';scope=[pscustomobject]@{taskId=$taskId;taskInstanceId=$case.instance;workspaceKey=$workspaceKey;ownerSessionKey=$sessionKey};behaviorGuidance=@([pscustomobject]@{cardId=('pref-' + $case.suffix);cardRevision=1;effect='shape_behavior'});reusableAdvice=@();procedureSteps=@();references=@();learningCandidates=@()}})
      $verificationPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'runtime-state\task-verifications') $taskId '.json'
      $outcomePath = Join-Path (Join-Path $workspace 'runtime-state\verified-task-outcomes') ($taskId + '.json')
      Write-TrialTestJson $verificationPath ([pscustomobject]@{ok=$case.accepted;checkedAt=(Get-Date).ToString('o');taskId=$taskId;workspaceKey=$workspaceKey;taskScopedGuardOk=$case.accepted;evidenceBinding=$binding;userAcceptanceVerification=[pscustomobject]@{ok=$case.accepted;realUserPathVerification=$case.accepted};integrationParity=[pscustomobject]@{ok=$case.accepted;unresolvedIntegrationDrift=(-not $case.accepted)};causalReview=[pscustomobject]@{decision=if($case.accepted){'keep'}else{'revise'}}})
      Write-TrialTestJson $outcomePath ([pscustomobject]@{schema='super-brain.verified-task-outcome.v1';taskId=$taskId;workspaceKey=$workspaceKey;recordedAt=(Get-Date).ToString('o');classification=[pscustomobject]@{verifiedRealWorldTask=$case.outcome};evidenceBinding=$binding;privacy=[pscustomobject]@{rawPromptStored=$false;rawSummaryStored=$false}})
      $start = Invoke-TrialTest $state @{Action='Start';TaskId=$taskId;TaskInstanceId=$case.instance;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey;CognitiveEvidencePath=$cognitivePath;Json=$true;NoExit=$true} $fixture.trialScript
      $start.value.status | Should Be 'captured'
      $start.value.cachePending | Should Be $true
      $start.value.nativeMemorySnapshot.dirty | Should Be $true
      Test-Path -LiteralPath (Join-Path $workspace 'native-memory-influence-snapshot.dirty.json') | Should Be $true
      $resolved = Invoke-TrialTest $state @{Action='Resolve';TaskId=$taskId;TaskInstanceId=$case.instance;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey;Json=$true;NoExit=$true} $fixture.trialScript
      $resolved.value.verdict | Should Be $case.verdict
      $resolved.value.status | Should Be 'evaluated'
      $resolved.value.cachePending | Should Be $true
      $receipt = Get-Content -LiteralPath $resolved.value.path -Raw -Encoding UTF8 | ConvertFrom-Json
      $receipt.verdict | Should Be $case.verdict
      $receipt.trialState | Should Be 'closed'
      @($receipt.memoryRefs).Count | Should Be 1
    }
  }

  It 'fails closed when a task-instance snapshot is altered after capture' {
    $state = Join-Path $TestDrive 'typed-trial-tamper'
    $workspace = Join-Path $state 'workspace'
    $taskId = 'task-typed-trial-tamper'
    $taskInstanceId = 'ti-11111111111111111111111111111111'
    $workspaceKey = 'ws-121212121212121212121212'
    $sessionKey = 'sid-343434343434343434343434'
    $cognitivePath = Join-Path $workspace 'last-cognitive-enforce.json'
    Write-TrialTestJson $cognitivePath ([pscustomobject]@{schema='super-brain.cognitive-enforce.v1';taskId=$taskId;memoryInfluence=[pscustomobject]@{ok=$true;status='ready';scope=[pscustomobject]@{taskId=$taskId;taskInstanceId=$taskInstanceId;workspaceKey=$workspaceKey;ownerSessionKey=$sessionKey};behaviorGuidance=@([pscustomobject]@{cardId='pref-tamper';cardRevision=1;effect='shape_behavior'});reusableAdvice=@();procedureSteps=@();references=@();learningCandidates=@()}})
    $start = Invoke-TrialTest $state @{Action='Start';TaskId=$taskId;TaskInstanceId=$taskInstanceId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey;CognitiveEvidencePath=$cognitivePath;Json=$true;NoExit=$true}
    $snapshot = Get-Content -LiteralPath $start.value.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $snapshot.memoryRefs[0].cardId = 'tampered-card'
    Write-TrialTestJson $start.value.path $snapshot
    $resolved = Invoke-TrialTest $state @{Action='Resolve';TaskId=$taskId;TaskInstanceId=$taskInstanceId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey;Json=$true;NoExit=$true}
    $resolved.value.verdict | Should Be 'inconclusive'
    $resolved.value.code | Should Be 'TYPED_MEMORY_TRIAL_SNAPSHOT_HASH_MISMATCH'
  }

  It 'keeps the P7 path out of the helper and wires both automatic call sites' {
    $helperText = Get-Content -LiteralPath $trialScript -Raw -Encoding UTF8
    $helperText.Contains('prompt-hook-telemetry') | Should Be $false
    $helperText.Contains('dispatcher') | Should Be $false
    $cognitiveText = Get-Content -LiteralPath (Join-Path $root 'scripts\cognitive-enforce.ps1') -Raw -Encoding UTF8
    $verificationText = Get-Content -LiteralPath (Join-Path $root 'scripts\task-verification.ps1') -Raw -Encoding UTF8
    $cognitiveText.Contains("-Action Start") | Should Be $true
    $cognitiveText.Contains("$Phase -in @('BeforeMutation','BeforeCompletion')") | Should Be $true
    $verificationText.Contains("-Action Resolve") | Should Be $true
    $verificationText.Contains('typedMemoryTrial') | Should Be $true
  }
}
