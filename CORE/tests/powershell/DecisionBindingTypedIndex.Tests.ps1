$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$bindingScript = Join-Path $root 'scripts\decision-binding.ps1'

function Invoke-TypedDecisionBinding([string]$StateRoot,[hashtable]$Parameters) {
  $Parameters.StateRoot = $StateRoot
  $Parameters.NoExit = $true
  $Parameters.Json = $true
  $exitCode = 0
  try {
    $raw = @(& $bindingScript @Parameters 2>&1)
  } catch {
    $raw = @($_)
    $exitCode = 1
  }
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  if ([string]::IsNullOrWhiteSpace($text)) { throw 'DECISION_TYPED_INDEX_EMPTY_OUTPUT' }
  return [pscustomobject]@{ exitCode=$exitCode; value=($text | ConvertFrom-Json); text=$text }
}

function New-TypedDecisionIdentity([string]$Suffix) {
  return [pscustomobject]@{
    taskId = 'task-typed-index-' + $Suffix
    taskInstanceId = 'ti-0123456789abcdef0123456789abcdef'
    workspaceKey = 'ws-typed-index-' + $Suffix
    ownerSessionKey = 'sid-typed-index-' + $Suffix
    planFingerprint = ('p' * 64)
  }
}

function Add-IrrelevantTypedIndexEntries([string]$IndexPath,[int]$Count) {
  $index = Get-Content -LiteralPath $IndexPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $records = New-Object System.Collections.ArrayList
  foreach ($entry in @($index.records)) { [void]$records.Add($entry) }
  for ($i = 1; $i -le $Count; $i++) {
    [void]$records.Add([pscustomobject]@{
      decisionId = 'irrelevant-' + $i; revision = 1; lifecycle = 'active'; authority = 'user_confirmed'; enforcement = 'completion_gate'
      workspaceKey = 'ws-other-' + $i; taskId = ''; taskInstanceId = ''; worklineId = ''; stageKinds = @('build'); intentFingerprint = ''
      scopeFingerprint = 'scope-' + $i; recordFingerprint = 'record-' + $i; fileHash = ('f' * 64); path = 'missing-' + $i + '.json'
    })
  }
  $index.records = [object[]]$records.ToArray()
  [IO.File]::WriteAllText($IndexPath,($index | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}

function Register-TypedDecision([string]$StateRoot,[object]$Identity) {
  $registered = Invoke-TypedDecisionBinding $StateRoot @{
    Action='Register'; DecisionId='release-archive'; WorkspaceKey=$Identity.workspaceKey; StageKinds=@('release')
    Enforcement='completion_gate'; Authority='user_confirmed'; Lifecycle='active'; ContentHash=('a' * 64); CompletionCriteriaDigest=('b' * 64)
  }
  $registered.exitCode | Should Be 0
  return $registered.value
}

function Resolve-TypedDecision([string]$StateRoot,[object]$Identity,[int]$Revision=1) {
  return Invoke-TypedDecisionBinding $StateRoot @{
    Action='Resolve'; TaskId=$Identity.taskId; TaskInstanceId=$Identity.taskInstanceId; WorkspaceKey=$Identity.workspaceKey
    WorklineId='release-main'; StageKind='release'; IntentFingerprint='release-intent'; ContractRevision=$Revision
    PlanFingerprint=$Identity.planFingerprint; OwnerSessionKey=$Identity.ownerSessionKey
  }
}

Describe 'Decision typed lookup index' {
  It 'uses the scope index and safely falls back to the canonical index when the derived lookup is stale' {
    $stateRoot = Join-Path $TestDrive 'typed-fallback'
    $identity = New-TypedDecisionIdentity 'fallback'
    Register-TypedDecision $stateRoot $identity | Out-Null
    $indexPath = Join-Path $stateRoot 'workspace\db\index.json'
    $lookup = @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'workspace\db\typed-index') -Filter '*.json' -File)
    $manifest = @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'workspace\db\typed-manifests') -Filter '*.json' -File)
    $lookup.Count | Should Be 1
    $manifest.Count | Should Be 1

    Add-IrrelevantTypedIndexEntries $indexPath 256
    $typed = Resolve-TypedDecision $stateRoot $identity
    $typed.exitCode | Should Be 0
    $typed.value.status | Should Be 'bound'

    $staleLookup = Get-Content -LiteralPath $lookup[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $staleLookup.generation = [int]$staleLookup.generation + 1
    [IO.File]::WriteAllText($lookup[0].FullName,($staleLookup | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    $fallback = Resolve-TypedDecision $stateRoot $identity
    $fallback.exitCode | Should Be 0
    $fallback.value.status | Should Be 'bound'
  }

  It 'keeps 10000-record exact decision resolution within the 250 ms p95 budget' {
    $stateRoot = Join-Path $TestDrive 'typed-performance'
    $identity = New-TypedDecisionIdentity 'performance'
    Register-TypedDecision $stateRoot $identity | Out-Null
    Add-IrrelevantTypedIndexEntries (Join-Path $stateRoot 'workspace\db\index.json') 9999

    $samples = New-Object System.Collections.Generic.List[int]
    for ($i = 1; $i -le 25; $i++) {
      $watch = [Diagnostics.Stopwatch]::StartNew()
      $resolved = Resolve-TypedDecision $stateRoot $identity
      $watch.Stop()
      $resolved.exitCode | Should Be 0
      $resolved.value.status | Should Be 'bound'
      $samples.Add([int]$watch.ElapsedMilliseconds)
    }
    $sorted = @($samples | Sort-Object)
    $p95 = [int]$sorted[[Math]::Max(0,[Math]::Ceiling($sorted.Count * 0.95) - 1)]
    $p95 | Should BeLessThan 251
  }
}
