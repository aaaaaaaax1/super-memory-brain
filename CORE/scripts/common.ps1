$SuperBrainRoot = Split-Path -Parent $PSScriptRoot

function Get-FullPath([string]$Path) {
  return [System.IO.Path]::GetFullPath($Path)
}

function Get-SuperBrainUtcNow {
  return [DateTimeOffset]::UtcNow
}

function Get-SuperBrainUtcTimestamp {
  return (Get-SuperBrainUtcNow).ToString('o')
}

function Get-SuperBrainLocalNow {
  return [DateTimeOffset]::Now
}

function Get-SuperBrainStableHash([string]$Value,[int]$Length = 16) {
  if ([string]::IsNullOrWhiteSpace($Value)) { throw 'SUPER_BRAIN_HASH_VALUE_REQUIRED' }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hex = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$Value)) | ForEach-Object { $_.ToString('x2') })
    return $hex.Substring(0,[Math]::Min($Length,$hex.Length))
  } finally {
    $sha.Dispose()
  }
}

function Get-SuperBrainFileSha256([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  # Do not depend on Microsoft.PowerShell.Utility autoloading.  The parallel
  # Pester worker and a few embedded Windows PowerShell hosts can start with a
  # reduced module surface where Get-FileHash is unavailable even though the
  # file itself is readable.  A direct .NET stream keeps hashing portable,
  # deterministic, and fully disposed on every path.
  $stream = $null
  $sha = $null
  try {
    $stream = [System.IO.File]::Open(
      [System.IO.Path]::GetFullPath($Path),
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read,
      [System.IO.FileShare]::ReadWrite
    )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })
  } catch {
    return ''
  } finally {
    if ($null -ne $sha) { $sha.Dispose() }
    if ($null -ne $stream) { $stream.Dispose() }
  }
}

# Some embedded Windows PowerShell workers intentionally start without the
# Microsoft.PowerShell.Utility module.  Keep legacy callers compatible while
# routing every production hash through the same direct .NET implementation.
# The shim is defined only when the native cmdlet is genuinely unavailable, so
# normal hosts retain their standard Get-FileHash behavior and object shape.
if (-not (Get-Command Get-FileHash -ErrorAction SilentlyContinue)) {
  function Get-FileHash {
    [CmdletBinding()]
    param(
      [Parameter(Mandatory=$true,Position=0)]
      [Alias('Path')]
      [string]$LiteralPath,
      [ValidateSet('SHA256')]
      [string]$Algorithm = 'SHA256'
    )
    $resolved = [IO.Path]::GetFullPath($LiteralPath)
    $hash = Get-SuperBrainFileSha256 $resolved
    if ([string]::IsNullOrWhiteSpace($hash)) { throw "SUPER_BRAIN_FILE_HASH_FAILED: $resolved" }
    [pscustomobject]@{
      Algorithm = $Algorithm
      Hash = $hash.ToUpperInvariant()
      Path = $resolved
    }
  }
}

function Get-SuperBrainMcpRuntimeIdentity([string]$Root = $SuperBrainRoot) {
  # Keep one identity compiler.  The resident MCP is a Python import graph;
  # PowerShell must not maintain a second hand-written file list that can drift.
  $normalizedRoot = Get-NormalizedSuperBrainRoot $Root
  $compiler = Join-Path $normalizedRoot 'runtime\mcp_runtime_identity.py'
  if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'SUPER_BRAIN_MCP_RUNTIME_IDENTITY_COMPILER_MISSING' }
  $raw = @(& python -X utf8 $compiler --package-root $normalizedRoot 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "SUPER_BRAIN_MCP_RUNTIME_IDENTITY_COMPILE_FAILED: $($raw -join ' ')" }
  $identity = (($raw | ForEach-Object { [string]$_ }) -join '').Trim().ToLowerInvariant()
  if ($identity -notmatch '^[a-f0-9]{64}$') { throw 'SUPER_BRAIN_MCP_RUNTIME_IDENTITY_INVALID' }
  return $identity
}

function Get-SuperBrainTestSourceTreeBindingCache([string]$Root) {
  # Test-only performance seam. Production ignores this cache unless an
  # isolated Pester process explicitly opts in with a temp-root cache.
  if ([string]$env:SUPER_BRAIN_TEST_SOURCE_TREE_BINDING_MODE -ne '1') { return $null }
  $cachePath = [string]$env:SUPER_BRAIN_TEST_SOURCE_TREE_BINDING_CACHE
  $token = [string]$env:SUPER_BRAIN_TEST_SOURCE_TREE_BINDING_TOKEN
  if ([string]::IsNullOrWhiteSpace($cachePath) -or $token -notmatch '^[a-f0-9]{32}$') { return $null }
  try {
    $fullRoot = [IO.Path]::GetFullPath($Root)
    $fullCache = [IO.Path]::GetFullPath($cachePath)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $fullCache.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $fullCache -PathType Leaf)) { return $null }
    $cache = Get-Content -LiteralPath $fullCache -Raw -Encoding UTF8 | ConvertFrom-Json
    $binding = $cache.binding
    if (
      -not $cache -or [string]$cache.schema -ne 'super-brain.test-source-tree-binding-cache.v1' -or
      -not ([string]$cache.packageRoot).Equals($fullRoot,[StringComparison]::OrdinalIgnoreCase) -or
      [string]$cache.token -ne $token -or -not $binding -or
      [string]$binding.schema -ne 'super-brain.source-tree-binding.v1' -or
      [string]$binding.treeAlgorithm -notin @('git-worktree-v1','portable-content-tree-v1') -or
      [string]$binding.gitTreeHash -notmatch '^[a-f0-9]{64}$' -or
      (-not [string]::IsNullOrWhiteSpace([string]$binding.gitHeadTreeHash) -and [string]$binding.gitHeadTreeHash -notmatch '^[a-f0-9]{40,64}$')
    ) { return $null }
    return [pscustomobject]@{
      schema = [string]$binding.schema
      treeAlgorithm = [string]$binding.treeAlgorithm
      gitTreeHash = [string]$binding.gitTreeHash
      gitHeadTreeHash = [string]$binding.gitHeadTreeHash
      fileCount = [int]$binding.fileCount
    }
  } catch { return $null }
}

function Get-SuperBrainSourceTreeBinding([string]$Root = $SuperBrainRoot) {
  $fullRoot = [IO.Path]::GetFullPath($Root)
  $testCachedBinding = Get-SuperBrainTestSourceTreeBindingCache $fullRoot
  if ($testCachedBinding) { return $testCachedBinding }
  $entries = New-Object Collections.Generic.List[string]
  $treeAlgorithm = 'portable-content-tree-v1'
  $gitHeadTreeHash = ''
  $git = Get-Command git -ErrorAction SilentlyContinue
  $gitReady = $false
  $fileCount = 0

  if ($git) {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $gitHeadTreeHash = ((@(& $git.Source -C $fullRoot rev-parse 'HEAD^{tree}' 2>$null) | Select-Object -First 1) -join '').Trim().ToLowerInvariant()
      if ($LASTEXITCODE -eq 0 -and $gitHeadTreeHash -match '^[0-9a-f]{40,64}$') {
        $gitReady = $true
        $treeAlgorithm = 'git-worktree-v1'
        $diffText = (@(& $git.Source -C $fullRoot diff --no-ext-diff --binary HEAD -- . 2>$null) -join "`n")
        if ($LASTEXITCODE -ne 0) { throw 'SUPER_BRAIN_GIT_DIFF_FAILED' }
        [void]$entries.Add(('diff=' + (Get-SuperBrainStableHash ('diff-v1' + "`n" + $diffText) 64)))
        $untracked = @(& $git.Source -C $fullRoot -c core.quotepath=false ls-files --others --exclude-standard -- . 2>$null)
        if ($LASTEXITCODE -ne 0) { throw 'SUPER_BRAIN_GIT_UNTRACKED_LIST_FAILED' }
        foreach ($rawPath in @($untracked | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)) {
          $relative = $rawPath.Replace('/',[IO.Path]::DirectorySeparatorChar).TrimStart('\','/')
          $candidate = [IO.Path]::GetFullPath((Join-Path $fullRoot $relative))
          $prefix = $fullRoot.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
          if (-not $candidate.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { continue }
          $fileHash = Get-SuperBrainFileSha256 $candidate
          if ([string]::IsNullOrWhiteSpace($fileHash)) { $fileHash = 'missing' }
          [void]$entries.Add(('untracked:' + $relative.Replace('\','/') + "`t" + $fileHash))
        }
        $fileCount = @(& $git.Source -C $fullRoot ls-files --cached -- . 2>$null).Count + @($untracked).Count
      }
    } catch {
      $entries.Clear()
      $gitReady = $false
      $treeAlgorithm = 'portable-content-tree-v1'
      $gitHeadTreeHash = ''
    } finally {
      $ErrorActionPreference = $previousErrorActionPreference
    }
  }

  if (-not $gitReady) {
    # Portable installs have no .git directory. Limit the fallback to shareable source roots.
    $sourceRoots = @('extensions','modules','references','runtime','scripts','super-memory-brain','tests','vendor','docs')
    foreach ($sourceRoot in $sourceRoots) {
      $candidateRoot = Join-Path $fullRoot $sourceRoot
      if (-not (Test-Path -LiteralPath $candidateRoot -PathType Container)) { continue }
      foreach ($file in @(Get-ChildItem -LiteralPath $candidateRoot -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($fullRoot.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
        $fileHash = Get-SuperBrainFileSha256 $file.FullName
        if (-not [string]::IsNullOrWhiteSpace($fileHash)) { [void]$entries.Add(($relative + "`t" + $fileHash)) }
      }
    }
    foreach ($name in @('manifest.json','capabilities.json','route-map.json','memory-policy.json','intelligence-policy.json','maintenance-policy.json','objective-benchmark-policy.json','install.bat')) {
      $candidate = Join-Path $fullRoot $name
      $fileHash = Get-SuperBrainFileSha256 $candidate
      if (-not [string]::IsNullOrWhiteSpace($fileHash)) { [void]$entries.Add(($name + "`t" + $fileHash)) }
    }
    $fileCount = $entries.Count
  }

  if ($entries.Count -eq 0) { throw 'SUPER_BRAIN_SOURCE_TREE_EMPTY' }
  $treeMaterial = @('schema=super-brain.source-tree-binding.v1',('algorithm=' + $treeAlgorithm),('head=' + $gitHeadTreeHash)) + @($entries | Sort-Object -Unique)
  return [pscustomobject]@{
    schema = 'super-brain.source-tree-binding.v1'
    treeAlgorithm = $treeAlgorithm
    gitTreeHash = Get-SuperBrainStableHash ($treeMaterial -join "`n") 64
    gitHeadTreeHash = $gitHeadTreeHash
    fileCount = $fileCount
  }
}

function New-SuperBrainEvidenceBinding(
  [string]$TaskId,
  [string]$WorkspaceKey,
  [string]$OwnerSessionKey,
  [string]$ArtifactHash = '',
  [string]$ArtifactKind = 'task_verification',
  [string]$Root = $SuperBrainRoot
) {
  $tree = Get-SuperBrainSourceTreeBinding $Root
  return [pscustomobject]@{
    schema = 'super-brain.completion-evidence-binding.v1'
    packageVersion = [string](Get-SuperBrainManifest $Root).version
    gitTreeHash = [string]$tree.gitTreeHash
    treeAlgorithm = [string]$tree.treeAlgorithm
    gitHeadTreeHash = [string]$tree.gitHeadTreeHash
    taskId = [string]$TaskId
    workspaceKey = Get-SuperBrainWorkspaceKey $WorkspaceKey
    ownerSessionKey = [string]$OwnerSessionKey
    artifactHash = [string]$ArtifactHash
    artifactKind = [string]$ArtifactKind
  }
}

function Test-SuperBrainEvidenceBinding(
  [object]$Binding,
  [string]$TaskId,
  [string]$WorkspaceKey,
  [string]$OwnerSessionKey,
  [string]$ArtifactPath = '',
  [switch]$RequireArtifactHash,
  [string]$Root = $SuperBrainRoot
) {
  if (-not $Binding -or [string]$Binding.schema -ne 'super-brain.completion-evidence-binding.v1') { return [pscustomobject]@{ ok=$false; reason='historical_evidence_binding_missing' } }
  foreach ($name in @('packageVersion','gitTreeHash','treeAlgorithm','taskId','workspaceKey','ownerSessionKey','artifactKind')) {
    if (-not $Binding.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$Binding.$name)) { return [pscustomobject]@{ ok=$false; reason=('evidence_binding_missing_' + $name) } }
  }
  if ([string]$Binding.packageVersion -ne [string](Get-SuperBrainManifest $Root).version) { return [pscustomobject]@{ ok=$false; reason='evidence_package_version_mismatch' } }
  if ([string]$Binding.taskId -ne [string]$TaskId) { return [pscustomobject]@{ ok=$false; reason='evidence_task_mismatch' } }
  if (-not (Test-SuperBrainWorkspaceKey ([string]$Binding.workspaceKey) (Get-SuperBrainWorkspaceKey $WorkspaceKey))) { return [pscustomobject]@{ ok=$false; reason='evidence_workspace_mismatch' } }
  if ([string]$Binding.ownerSessionKey -ne [string]$OwnerSessionKey) { return [pscustomobject]@{ ok=$false; reason='evidence_owner_session_mismatch' } }
  $currentTree = Get-SuperBrainSourceTreeBinding $Root
  if ([string]$Binding.treeAlgorithm -ne [string]$currentTree.treeAlgorithm -or [string]$Binding.gitTreeHash -ne [string]$currentTree.gitTreeHash -or [string]$Binding.gitHeadTreeHash -ne [string]$currentTree.gitHeadTreeHash) { return [pscustomobject]@{ ok=$false; reason='evidence_git_tree_mismatch'; currentTree=$currentTree } }
  if ($RequireArtifactHash) {
    if (-not $Binding.PSObject.Properties['artifactHash'] -or [string]::IsNullOrWhiteSpace([string]$Binding.artifactHash)) { return [pscustomobject]@{ ok=$false; reason='evidence_artifact_hash_missing'; currentTree=$currentTree } }
    $actualArtifactHash = Get-SuperBrainFileSha256 $ArtifactPath
    if ([string]::IsNullOrWhiteSpace($actualArtifactHash) -or [string]$Binding.artifactHash -ne $actualArtifactHash) { return [pscustomobject]@{ ok=$false; reason='evidence_artifact_hash_mismatch'; currentTree=$currentTree } }
  }
  return [pscustomobject]@{ ok=$true; reason='evidence_binding_current'; currentTree=$currentTree }
}

function Get-SuperBrainCausalReviewFingerprint([object]$Review) {
  if (-not $Review) { return '' }
  $binding = if ($Review.PSObject.Properties['reviewBinding']) { $Review.reviewBinding } else { $null }
  $tree = if ($binding -and $binding.PSObject.Properties['sourceTreeBinding']) { $binding.sourceTreeBinding } else { $null }
  $decision = if ($Review.PSObject.Properties['expectedVsActual'] -and $Review.expectedVsActual) { [string]$Review.expectedVsActual.decision } else { '' }
  $payload = [ordered]@{
    schema = [string]$Review.schema
    version = [string]$Review.version
    taskId = [string]$Review.taskId
    reviewId = [string]$Review.reviewId
    planPath = [string]$Review.planPath
    planId = [string]$Review.planId
    planTaskId = [string]$Review.planTaskId
    planVersion = [string]$Review.planVersion
    observedProblem = [string]$Review.observedProblem
    expectedOptimization = [string]$Review.expectedOptimization
    verificationMethod = [string]$Review.verificationMethod
    actualResult = [string]$Review.actualResult
    evidence = @($Review.evidence | ForEach-Object { [string]$_ })
    decision = $decision
    reviewBinding = [ordered]@{
      schema = if ($binding) { [string]$binding.schema } else { '' }
      status = if ($binding) { [string]$binding.status } else { '' }
      reason = if ($binding) { [string]$binding.reason } else { '' }
      taskStateRevision = if ($binding -and $binding.PSObject.Properties['taskStateRevision']) { [int]$binding.taskStateRevision } else { 0 }
      workspaceKey = if ($binding) { [string]$binding.workspaceKey } else { '' }
      ownerSessionKey = if ($binding) { [string]$binding.ownerSessionKey } else { '' }
      contractRevision = if ($binding -and $binding.PSObject.Properties['contractRevision']) { [int]$binding.contractRevision } else { 0 }
      planFingerprint = if ($binding) { [string]$binding.planFingerprint } else { '' }
      planPath = if ($binding) { [string]$binding.planPath } else { '' }
      planSha256 = if ($binding) { [string]$binding.planSha256 } else { '' }
      sourceTreeBinding = [ordered]@{
        schema = if ($tree) { [string]$tree.schema } else { '' }
        treeAlgorithm = if ($tree) { [string]$tree.treeAlgorithm } else { '' }
        gitTreeHash = if ($tree) { [string]$tree.gitTreeHash } else { '' }
        gitHeadTreeHash = if ($tree) { [string]$tree.gitHeadTreeHash } else { '' }
        fileCount = if ($tree -and $tree.PSObject.Properties['fileCount']) { [int]$tree.fileCount } else { 0 }
      }
      producer = if ($binding) { [string]$binding.producer } else { '' }
    }
  }
  return Get-SuperBrainStableHash ($payload | ConvertTo-Json -Depth 10 -Compress) 64
}

function Test-SuperBrainCausalReviewBinding(
  [object]$Review,
  [string]$ReviewPath,
  [string]$TaskId,
  [object]$Contract,
  [object]$EvidenceBinding,
  [object]$TaskStateProjection,
  [string]$Root = $SuperBrainRoot
) {
  function Fail-CausalReviewBinding([string]$Code,[string]$Reason) {
    return [pscustomobject]@{ ok=$false; code=$Code; reason=$Reason; reviewArtifactHash=''; reviewFingerprint='' }
  }
  if (-not $Review) { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_MISSING' 'causal_review_missing' }
  if ([string]$Review.schema -ne 'super-brain.causal-change-review.v2') { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_HISTORICAL' 'causal_review_binding_missing' }
  if ($Review.ok -ne $true) { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_INVALID' 'causal_review_not_ok' }
  if (-not $Review.PSObject.Properties['reviewBinding'] -or -not $Review.reviewBinding) { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_BINDING_MISSING' 'review_binding_missing' }
  $binding = $Review.reviewBinding
  if ([string]$binding.schema -ne 'super-brain.causal-review-binding.v1' -or [string]$binding.status -ne 'bound') { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_BINDING_UNBOUND' ('review_binding_' + [string]$binding.status) }
  if ([string]$Review.taskId -ne $TaskId -or [string]$binding.taskId -ne $TaskId) { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_TASK_MISMATCH' 'review_task_mismatch' }
  if ([string]$binding.packageVersion -ne [string](Get-SuperBrainManifest $Root).version) { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_PACKAGE_MISMATCH' 'review_package_version_mismatch' }
  if (-not $Contract -or [string]$Contract.taskId -ne $TaskId -or [string]$Contract.status -ne 'active') { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_CONTRACT_MISSING' 'current_contract_missing_or_inactive' }
  if (-not $EvidenceBinding) { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_EVIDENCE_BINDING_MISSING' 'current_evidence_binding_missing' }
  if (-not $TaskStateProjection -or [string]$TaskStateProjection.taskId -ne $TaskId) { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_TASK_STATE_MISSING' 'current_task_state_projection_missing' }
  if ([int]$binding.taskStateRevision -ne [int]$TaskStateProjection.revision) { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_TASK_STATE_REVISION_MISMATCH' 'task_state_revision_changed_after_review' }
  if (-not $TaskStateProjection.lifecycle -or [string]$TaskStateProjection.lifecycle.status -ne 'active') { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_TASK_STATE_INACTIVE' 'task_state_not_active' }
  if (-not (Test-SuperBrainWorkspaceKey ([string]$binding.workspaceKey) ([string]$Contract.workspaceKey)) -or -not (Test-SuperBrainWorkspaceKey ([string]$binding.workspaceKey) ([string]$TaskStateProjection.lifecycle.workspaceKey)) -or -not (Test-SuperBrainWorkspaceKey ([string]$binding.workspaceKey) ([string]$EvidenceBinding.workspaceKey))) { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_WORKSPACE_MISMATCH' 'review_workspace_mismatch' }
  if ([string]$binding.ownerSessionKey -ne [string]$Contract.ownerSessionKey -or [string]$binding.ownerSessionKey -ne [string]$TaskStateProjection.lifecycle.ownerSessionKey -or [string]$binding.ownerSessionKey -ne [string]$EvidenceBinding.ownerSessionKey) { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_OWNER_SESSION_MISMATCH' 'review_owner_session_mismatch' }
  if ([int]$binding.contractRevision -ne [int]$Contract.revision -or [int]$binding.contractRevision -ne [int]$TaskStateProjection.lifecycle.contractRevision) { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_CONTRACT_REVISION_MISMATCH' 'contract_revision_changed_after_review' }
  if ([string]$binding.planFingerprint -ne [string]$Contract.planReceipt.planFingerprint -or [string]$binding.planFingerprint -ne [string]$TaskStateProjection.lifecycle.planFingerprint) { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_PLAN_FINGERPRINT_MISMATCH' 'plan_fingerprint_changed_after_review' }
  $tree = if ($binding.PSObject.Properties['sourceTreeBinding']) { $binding.sourceTreeBinding } else { $null }
  if (-not $tree -or [string]$tree.schema -ne 'super-brain.source-tree-binding.v1' -or [string]$tree.treeAlgorithm -ne [string]$EvidenceBinding.treeAlgorithm -or [string]$tree.gitTreeHash -ne [string]$EvidenceBinding.gitTreeHash -or [string]$tree.gitHeadTreeHash -ne [string]$EvidenceBinding.gitHeadTreeHash) { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_SOURCE_TREE_MISMATCH' 'source_tree_changed_after_review' }
  $planPath = [string]$binding.planPath
  if ([string]::IsNullOrWhiteSpace($planPath) -or -not (Test-Path -LiteralPath $planPath -PathType Leaf)) { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_PLAN_MISSING' 'reviewed_plan_missing' }
  if (-not (Test-SuperBrainSamePath $planPath ([string]$Review.planPath)) -or [string](Get-SuperBrainFileSha256 $planPath) -ne [string]$binding.planSha256) { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_PLAN_HASH_MISMATCH' 'reviewed_plan_changed_after_review' }
  $fingerprint = Get-SuperBrainCausalReviewFingerprint $Review
  if ([string]::IsNullOrWhiteSpace($fingerprint) -or [string]$binding.reviewFingerprint -ne $fingerprint) { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_FINGERPRINT_MISMATCH' 'causal_review_payload_changed' }
  $effectiveReviewPath = if (-not [string]::IsNullOrWhiteSpace($ReviewPath)) { $ReviewPath } else { [string]$Review.path }
  if ([string]::IsNullOrWhiteSpace($effectiveReviewPath) -or -not (Test-Path -LiteralPath $effectiveReviewPath -PathType Leaf)) { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_ARTIFACT_MISSING' 'causal_review_artifact_missing' }
  if (-not [string]::IsNullOrWhiteSpace([string]$Review.path) -and -not (Test-SuperBrainSamePath $effectiveReviewPath ([string]$Review.path))) { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_ARTIFACT_PATH_MISMATCH' 'causal_review_artifact_path_mismatch' }
  $artifactHash = Get-SuperBrainFileSha256 $effectiveReviewPath
  if ([string]::IsNullOrWhiteSpace($artifactHash)) { return Fail-CausalReviewBinding 'CAUSAL_REVIEW_ARTIFACT_HASH_FAILED' 'causal_review_artifact_hash_failed' }
  return [pscustomobject]@{ ok=$true; code='CAUSAL_REVIEW_BINDING_CURRENT'; reason='causal_review_bound_to_current_source_plan_and_contract'; reviewArtifactHash=$artifactHash; reviewFingerprint=$fingerprint }
}

function Limit-SuperBrainCanonicalText([string]$Value,[int]$Max=480) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $clean = ([string]$Value).Trim() -replace '\s+',' '
  if ($clean.Length -gt $Max) { return $clean.Substring(0,$Max) + '...' }
  return $clean
}

function Limit-SuperBrainCanonicalList([object[]]$Items,[int]$MaxItems=12,[int]$MaxChars=220) {
  return @($Items | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { Limit-SuperBrainCanonicalText ([string]$_) $MaxChars } | Select-Object -Unique -First $MaxItems)
}

function Test-SuperBrainCanonicalArrayValue([object]$Value) {
  return ($null -ne $Value -and $Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [System.Collections.IDictionary])
}

function Get-SuperBrainCanonicalPlanFingerprint([object]$Plan) {
  if (-not $Plan) { return '' }
  $items = @($Plan.items | Sort-Object { [int]$_.ordinal } | ForEach-Object {
    [ordered]@{
      itemId = Limit-SuperBrainCanonicalText ([string]$_.itemId) 80
      ordinal = [int]$_.ordinal
      label = Limit-SuperBrainCanonicalText ([string]$_.label) 180
      status = Limit-SuperBrainCanonicalText ([string]$_.status) 24
      evidenceRefs = @(Limit-SuperBrainCanonicalList @($_.evidenceRefs) 6 160)
    }
  })
  $history = @($Plan.supersessionHistory | Select-Object -Last 4 | ForEach-Object {
    [ordered]@{
      planId = Limit-SuperBrainCanonicalText ([string]$_.planId) 80
      generation = if ($_.PSObject.Properties['generation']) { [int]$_.generation } else { 0 }
      currentFingerprint = Limit-SuperBrainCanonicalText ([string]$_.currentFingerprint) 32
      itemCount = if ($_.PSObject.Properties['itemCount']) { [int]$_.itemCount } else { 0 }
      supersededAt = Limit-SuperBrainCanonicalText ([string]$_.supersededAt) 48
      transitionId = Limit-SuperBrainCanonicalText ([string]$_.transitionId) 120
    }
  })
  $payload = [ordered]@{
    schemaVersion = 1
    planId = Limit-SuperBrainCanonicalText ([string]$Plan.planId) 80
    generation = [int]$Plan.generation
    rootFocusId = Limit-SuperBrainCanonicalText ([string]$Plan.rootFocusId) 120
    originFingerprint = Limit-SuperBrainCanonicalText ([string]$Plan.originFingerprint) 32
    orderConfidence = Limit-SuperBrainCanonicalText ([string]$Plan.orderConfidence) 32
    approvalSource = Limit-SuperBrainCanonicalText ([string]$Plan.approvalSource) 48
    approvalInstructionFingerprint = Limit-SuperBrainCanonicalText ([string]$Plan.approvalInstructionFingerprint) 32
    items = @($items)
    supersessionHistory = @($history)
  }
  if ($Plan.PSObject.Properties['intentBinding'] -and $Plan.intentBinding) {
    $payload.intentBinding = [ordered]@{
      intentRevision = [int]$Plan.intentBinding.intentRevision
      intentContractFingerprint = Limit-SuperBrainCanonicalText ([string]$Plan.intentBinding.intentContractFingerprint) 64
    }
  }
  return Get-SuperBrainStableHash ($payload | ConvertTo-Json -Depth 10 -Compress) 16
}

function Test-SuperBrainCanonicalPlan([object]$Plan,[switch]$AllowMissingFingerprint,[int]$MaxItems=24,[int]$MaxBytes=16384) {
  if (-not $Plan) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_PLAN_REQUIRED'; plan=$null } }
  if (-not $Plan.PSObject.Properties['schemaVersion'] -or [int]$Plan.schemaVersion -ne 1) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_SCHEMA_INVALID'; plan=$null } }
  $planId = Limit-SuperBrainCanonicalText ([string]$Plan.planId) 80
  $rootFocusId = Limit-SuperBrainCanonicalText ([string]$Plan.rootFocusId) 120
  if ([string]::IsNullOrWhiteSpace($planId) -or [string]::IsNullOrWhiteSpace($rootFocusId) -or [int]$Plan.generation -lt 1) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_IDENTITY_INVALID'; plan=$null } }
  if (-not $Plan.PSObject.Properties['items'] -or -not (Test-SuperBrainCanonicalArrayValue $Plan.items)) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_ITEMS_ARRAY_REQUIRED'; plan=$null } }
  $rawItems = @($Plan.items)
  if ($rawItems.Count -eq 0) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_ITEMS_REQUIRED'; plan=$null } }
  if ($rawItems.Count -gt $MaxItems) { return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_CANONICAL_ITEM_LIMIT_EXCEEDED'; count=$rawItems.Count; maxItems=$MaxItems; plan=$null } }
  $items=@();$seenIds=@{};$expectedOrdinal=1
  foreach($rawItem in @($rawItems|Sort-Object{[int]$_.ordinal})){
    if(-not$rawItem-or-not$rawItem.PSObject.Properties['itemId']-or-not$rawItem.PSObject.Properties['ordinal']-or-not$rawItem.PSObject.Properties['label']-or-not$rawItem.PSObject.Properties['status']){return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_CANONICAL_ITEM_INVALID';plan=$null}}
    $itemId=Limit-SuperBrainCanonicalText ([string]$rawItem.itemId) 80;$label=Limit-SuperBrainCanonicalText ([string]$rawItem.label) 180;$status=Limit-SuperBrainCanonicalText ([string]$rawItem.status) 24;$ordinal=[int]$rawItem.ordinal
    if([string]::IsNullOrWhiteSpace($itemId)-or[string]::IsNullOrWhiteSpace((($label.Trim()-replace '\s+',' ').ToLowerInvariant()))-or$status-notin@('pending','in_progress','completed','cancelled')-or$ordinal-ne$expectedOrdinal-or$seenIds.ContainsKey($itemId)){return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_CANONICAL_ITEM_INVALID';plan=$null}}
    $seenIds[$itemId]=$true
    $items += [pscustomobject]@{itemId=$itemId;ordinal=$ordinal;label=$label;status=$status;evidenceRefs=@(Limit-SuperBrainCanonicalList $(if($rawItem.PSObject.Properties['evidenceRefs']){@($rawItem.evidenceRefs)}else{@()}) 6 160);updatedAt=if($rawItem.PSObject.Properties['updatedAt']){Limit-SuperBrainCanonicalText ([string]$rawItem.updatedAt) 48}else{''}}
    $expectedOrdinal++
  }
  $history=@()
  if($Plan.PSObject.Properties['supersessionHistory']){
    if(-not(Test-SuperBrainCanonicalArrayValue $Plan.supersessionHistory)){return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_CANONICAL_HISTORY_ARRAY_REQUIRED';plan=$null}}
    foreach($entry in @($Plan.supersessionHistory|Select-Object -Last 4)){
      if(-not$entry-or[string]::IsNullOrWhiteSpace([string]$entry.planId)){return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_CANONICAL_HISTORY_INVALID';plan=$null}}
      $history += [pscustomobject]@{planId=Limit-SuperBrainCanonicalText ([string]$entry.planId) 80;generation=if($entry.PSObject.Properties['generation']){[int]$entry.generation}else{0};currentFingerprint=Limit-SuperBrainCanonicalText ([string]$entry.currentFingerprint) 32;itemCount=if($entry.PSObject.Properties['itemCount']){[int]$entry.itemCount}else{0};supersededAt=Limit-SuperBrainCanonicalText ([string]$entry.supersededAt) 48;transitionId=Limit-SuperBrainCanonicalText ([string]$entry.transitionId) 120}
    }
  }
  $normalized=[pscustomobject]@{schemaVersion=1;planId=$planId;generation=[int]$Plan.generation;rootFocusId=$rootFocusId;originFingerprint=Limit-SuperBrainCanonicalText ([string]$Plan.originFingerprint) 32;currentFingerprint=Limit-SuperBrainCanonicalText ([string]$Plan.currentFingerprint) 32;orderConfidence=if([string]$Plan.orderConfidence-in@('verified','legacy_derived')){[string]$Plan.orderConfidence}else{'legacy_derived'};approvalSource=Limit-SuperBrainCanonicalText ([string]$Plan.approvalSource) 48;approvalInstructionFingerprint=Limit-SuperBrainCanonicalText ([string]$Plan.approvalInstructionFingerprint) 32;items=@($items);supersessionHistory=@($history);createdAt=Limit-SuperBrainCanonicalText ([string]$Plan.createdAt) 48;updatedAt=Limit-SuperBrainCanonicalText ([string]$Plan.updatedAt) 48}
  if($Plan.PSObject.Properties['intentBinding']-and$Plan.intentBinding){
    $intentRevision=[int]$Plan.intentBinding.intentRevision;$intentFingerprint=Limit-SuperBrainCanonicalText ([string]$Plan.intentBinding.intentContractFingerprint) 64
    if($intentRevision-lt1-or$intentFingerprint-notmatch'^[a-f0-9]{64}$'){return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_CANONICAL_INTENT_BINDING_INVALID';plan=$null}}
    $normalized|Add-Member -NotePropertyName intentBinding -NotePropertyValue ([pscustomobject]@{intentRevision=$intentRevision;intentContractFingerprint=$intentFingerprint}) -Force
  }
  if($normalized.orderConfidence-eq'verified'-and$normalized.approvalSource-eq'user_confirmation'-and[string]::IsNullOrWhiteSpace([string]$normalized.approvalInstructionFingerprint)){return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_CANONICAL_APPROVAL_RECEIPT_REQUIRED';plan=$null}}
  $expectedFingerprint=Get-SuperBrainCanonicalPlanFingerprint $normalized
  if(-not$AllowMissingFingerprint-and([string]::IsNullOrWhiteSpace([string]$normalized.currentFingerprint)-or[string]$normalized.currentFingerprint-ne$expectedFingerprint)){return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_CANONICAL_FINGERPRINT_MISMATCH';expectedFingerprint=$expectedFingerprint;actualFingerprint=[string]$normalized.currentFingerprint;plan=$null}}
  $normalized.currentFingerprint=$expectedFingerprint
  $byteCount=[Text.Encoding]::UTF8.GetByteCount(($normalized|ConvertTo-Json -Depth 12 -Compress))
  if($byteCount-gt$MaxBytes){return [pscustomobject]@{ok=$false;code='EXECUTION_CONTRACT_CANONICAL_PLAN_SIZE_EXCEEDED';byteCount=$byteCount;maxBytes=$MaxBytes;plan=$null}}
  return [pscustomobject]@{ok=$true;code='EXECUTION_CONTRACT_CANONICAL_PLAN_OK';plan=$normalized;byteCount=$byteCount}
}

function Get-SuperBrainLocalSessionKey([string]$SessionId = '') {
  $candidate = $SessionId
  # Local scope is explicit. Legacy desktop thread metadata is never a
  # fallback because it can bind a stale Host conversation to this process.
  if ([string]::IsNullOrWhiteSpace($candidate) -and -not [string]::IsNullOrWhiteSpace($env:SUPER_BRAIN_LOCAL_SESSION_ID)) { $candidate = [string]$env:SUPER_BRAIN_LOCAL_SESSION_ID }
  if ([string]::IsNullOrWhiteSpace($candidate)) { return '' }
  $candidate = $candidate.Trim()
  if ($candidate -match '^sid-[0-9a-f]{16,64}$') { return $candidate.ToLowerInvariant() }
  return 'sid-' + (Get-SuperBrainStableHash $candidate 24)
}

function Get-SuperBrainCanonicalTaskToken([string]$TaskId) {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'TASK_STATE_TASK_ID_REQUIRED' }
  $safe = (([string]$TaskId -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'task' }
  if ($safe.Length -gt 96) { $safe = $safe.Substring(0,96).TrimEnd('-') }
  return $safe + '--' + (Get-SuperBrainStableHash ([string]$TaskId) 16)
}

function Get-SuperBrainCanonicalTaskFileName([string]$TaskId,[string]$Suffix = '.json') {
  if ([string]::IsNullOrWhiteSpace($Suffix)) { throw 'TASK_STATE_SUFFIX_REQUIRED' }
  return (Get-SuperBrainCanonicalTaskToken $TaskId) + $Suffix
}

function Get-SuperBrainCanonicalTaskPath([string]$Root,[string]$TaskId,[string]$Suffix = '.json') {
  if ([string]::IsNullOrWhiteSpace($Root)) { throw 'TASK_STATE_ROOT_REQUIRED' }
  return Join-Path ([System.IO.Path]::GetFullPath($Root)) (Get-SuperBrainCanonicalTaskFileName $TaskId $Suffix)
}

function Test-SuperBrainChildPath([string]$Parent,[string]$Child) {
  try {
    $prefix = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
    return [System.IO.Path]::GetFullPath($Child).StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase)
  } catch { return $false }
}

function Get-SuperBrainCanonicalTaskStateEntityPath(
  [string]$TaskId,
  [ValidateSet('context','checkpoint','task_card')][string]$EntityKind,
  [string]$WorkspaceRoot,
  [string]$SharedRoot,
  [string]$RequestedPath = '',
  [switch]$RequireCanonical
) {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'TASK_STATE_TASK_ID_REQUIRED' }
  $workspace = [System.IO.Path]::GetFullPath($WorkspaceRoot)
  $shared = [System.IO.Path]::GetFullPath($SharedRoot)
  $roots = @()
  $suffix = '.json'
  switch ($EntityKind) {
    'context' { $roots = @(Join-Path $workspace 'guard-state\current-task-contexts') }
    'checkpoint' {
      $roots = @(
        (Join-Path $workspace 'runtime-state\checkpoints\active'),
        (Join-Path $workspace 'runtime-state\checkpoints\completed')
      )
    }
    'task_card' {
      $suffix = '.task.json'
      $roots = @('active','paused','blocked','completed' | ForEach-Object { Join-Path $shared (Join-Path 'tasks' $_) })
    }
  }
  $requested = if ([string]::IsNullOrWhiteSpace($RequestedPath)) { '' } else { [System.IO.Path]::GetFullPath($RequestedPath) }
  $targetRoot = $null
  if ($requested) {
    foreach ($candidate in $roots) {
      if (Test-SuperBrainChildPath $candidate $requested) { $targetRoot = $candidate; break }
    }
    if (-not $targetRoot) { throw "TASK_STATE_TARGET_OUTSIDE_ROOT kind=$EntityKind path=$requested" }
  } elseif ($roots.Count -eq 1) {
    $targetRoot = $roots[0]
  } else {
    throw "TASK_STATE_TARGET_PATH_REQUIRED kind=$EntityKind"
  }
  $expected = Get-SuperBrainCanonicalTaskPath $targetRoot $TaskId $suffix
  if ($RequireCanonical -and -not [string]::Equals($requested,$expected,[System.StringComparison]::OrdinalIgnoreCase)) {
    throw "TASK_STATE_TARGET_TASK_MISMATCH expected=$expected actual=$requested taskId=$TaskId"
  }
  return $expected
}

function ConvertTo-SuperBrainTaskStateAgentId(
  [string]$AgentId = '',
  [string]$Platform = ''
) {
  $platformToken = ([string]$Platform).Trim().ToLowerInvariant()
  $platformToken = ($platformToken -replace '[^a-z0-9._-]','').Trim([char[]]@('-','_','.'))
  if ([string]::IsNullOrWhiteSpace($platformToken)) { $platformToken = 'super-brain' }
  $candidate = ([string]$AgentId).Trim()
  if ([string]::IsNullOrWhiteSpace($candidate)) {
    if ($platformToken -eq 'super-brain') { return 'super-brain-control-plane' }
    return ($platformToken + 'id-default')
  }
  $legacyDefault = $platformToken + '-agent'
  if ([string]::Equals($candidate,$legacyDefault,[System.StringComparison]::OrdinalIgnoreCase)) {
    if ($platformToken -eq 'super-brain') { return 'super-brain-control-plane' }
    return ($platformToken + 'id-default')
  }
  return $candidate
}

function Get-SuperBrainTaskStateOwnerInput(
  [object]$EntityValue = $null,
  [string]$AgentId = '',
  [string]$SessionId = '',
  [string]$Platform = '',
  [string]$Workspace = ''
) {
  if ($EntityValue) {
    if ([string]::IsNullOrWhiteSpace($AgentId) -and $EntityValue.PSObject.Properties['agentId']) { $AgentId = [string]$EntityValue.agentId }
    if ([string]::IsNullOrWhiteSpace($SessionId) -and $EntityValue.PSObject.Properties['sessionId']) { $SessionId = [string]$EntityValue.sessionId }
    if ([string]::IsNullOrWhiteSpace($Platform) -and $EntityValue.PSObject.Properties['platform']) { $Platform = [string]$EntityValue.platform }
    if ([string]::IsNullOrWhiteSpace($Workspace) -and $EntityValue.PSObject.Properties['workspace']) { $Workspace = [string]$EntityValue.workspace }
  }
  if ([string]::IsNullOrWhiteSpace($Workspace)) { $Workspace = Get-NormalizedSuperBrainRoot $SuperBrainRoot }
  else { try { $Workspace = [System.IO.Path]::GetFullPath($Workspace).TrimEnd('\','/') } catch { $Workspace = $Workspace.Trim() } }
  if ([string]::IsNullOrWhiteSpace($Platform)) { $Platform = if ($env:SUPER_BRAIN_PLATFORM) { [string]$env:SUPER_BRAIN_PLATFORM } else { 'super-brain' } }
  if ([string]::IsNullOrWhiteSpace($AgentId) -and $env:SUPER_BRAIN_AGENT_ID) { $AgentId = [string]$env:SUPER_BRAIN_AGENT_ID }
  $AgentId = ConvertTo-SuperBrainTaskStateAgentId $AgentId $Platform
  if ([string]::IsNullOrWhiteSpace($SessionId)) {
    $SessionId = if ($env:SUPER_BRAIN_SESSION_ID) { [string]$env:SUPER_BRAIN_SESSION_ID } else { 'session-' + (Get-SuperBrainStableHash ("$AgentId|$Platform|$Workspace") 16) }
  }
  return [pscustomobject]@{ agentId=$AgentId.Trim(); sessionId=$SessionId.Trim(); platform=$Platform.Trim(); workspace=$Workspace }
}

function Get-NormalizedSuperBrainRoot([string]$Root = $SuperBrainRoot) {
  return ([System.IO.Path]::GetFullPath($Root)).TrimEnd('\','/')
}

function Get-SuperBrainMcpPathHash([string]$Root = $SuperBrainRoot) {
  # This value crosses the PowerShell installer / Python MCP boundary. Keep
  # its normalization identical to runtime/brain_core.py::_mcp_path_hash.
  # Windows paths are case-insensitive, so installer casing must not make a
  # correctly restarted MCP look stale.
  $normalized = (Get-NormalizedSuperBrainRoot $Root).ToLowerInvariant()
  return Get-SuperBrainStableHash $normalized 64
}

function Get-SuperBrainWorkspaceKey([string]$Workspace = '') {
  $value = $Workspace
  if ([string]::IsNullOrWhiteSpace($value) -and -not [string]::IsNullOrWhiteSpace($env:SUPER_BRAIN_WORKSPACE_KEY)) {
    $value = $env:SUPER_BRAIN_WORKSPACE_KEY
  }
  if ([string]::IsNullOrWhiteSpace($value)) { $value = (Get-Location).Path }
  $value = ([string]$value).Trim()
  if ($value -match '^ws-[0-9a-f]{24}$') { return $value.ToLowerInvariant() }
  try { $value = [System.IO.Path]::GetFullPath($value).TrimEnd('\','/') } catch {}
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($value.ToLowerInvariant()))
    return 'ws-' + (-join ($hash[0..11] | ForEach-Object { $_.ToString('x2') }))
  } finally {
    $sha.Dispose()
  }
}

function Test-SuperBrainWorkspaceKey([string]$RecordedKey,[string]$CurrentKey = '') {
  if ([string]::IsNullOrWhiteSpace($RecordedKey)) { return $false }
  $current = Get-SuperBrainWorkspaceKey $CurrentKey
  $recorded = Get-SuperBrainWorkspaceKey $RecordedKey
  return $recorded.Equals($current,[System.StringComparison]::OrdinalIgnoreCase)
}

function Get-SuperBrainTaskWorkspaceToken([string]$TaskId,[string]$WorkspaceKey = '') {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'TASK_STATE_TASK_ID_REQUIRED' }
  $resolvedWorkspaceKey = Get-SuperBrainWorkspaceKey $WorkspaceKey
  return $resolvedWorkspaceKey + '__' + ([string]$TaskId).Trim()
}

function Get-SuperBrainTaskWorkspaceArtifactPath([string]$Root,[string]$TaskId,[string]$WorkspaceKey = '',[string]$Suffix = '.json') {
  if ([string]::IsNullOrWhiteSpace($Root)) { throw 'TASK_STATE_ROOT_REQUIRED' }
  return Get-SuperBrainCanonicalTaskPath $Root (Get-SuperBrainTaskWorkspaceToken $TaskId $WorkspaceKey) $Suffix
}

function Get-SuperBrainStepLedgerPath([string]$WorkspaceRoot,[string]$TaskId,[string]$WorkspaceKey = '') {
  if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { throw 'TASK_STATE_ROOT_REQUIRED' }
  $ledgerRoot = Join-Path ([System.IO.Path]::GetFullPath($WorkspaceRoot)) 'guard-state\step-ledgers'
  return Get-SuperBrainTaskWorkspaceArtifactPath $ledgerRoot $TaskId $WorkspaceKey '.json'
}

function Get-SuperBrainRelevantStepLedger([string]$WorkspaceRoot,[string]$TaskId,[string]$WorkspaceKey = '',[switch]$AllowLegacyRead) {
  $result = [ordered]@{ ledger=$null; path=''; source='missing'; workspaceKey=(Get-SuperBrainWorkspaceKey $WorkspaceKey); taskId=([string]$TaskId).Trim() }
  if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { return [pscustomobject]$result }
  try { $workspace = [System.IO.Path]::GetFullPath($WorkspaceRoot) } catch { return [pscustomobject]$result }

  function Read-StepLedgerCandidate([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
  }
  function Test-StepLedgerScope([object]$Value) {
    if (-not $Value -or [string]::IsNullOrWhiteSpace($result.taskId)) { return $false }
    if (-not $Value.PSObject.Properties['taskId'] -or -not [string]::Equals([string]$Value.taskId,$result.taskId,[StringComparison]::Ordinal)) { return $false }
    if (-not $Value.PSObject.Properties['workspaceKey'] -or [string]::IsNullOrWhiteSpace([string]$Value.workspaceKey)) { return $false }
    return Test-SuperBrainWorkspaceKey ([string]$Value.workspaceKey) $result.workspaceKey
  }

  if (-not [string]::IsNullOrWhiteSpace($result.taskId)) {
    $currentPath = Get-SuperBrainStepLedgerPath $workspace $result.taskId $result.workspaceKey
    $current = Read-StepLedgerCandidate $currentPath
    if (Test-StepLedgerScope $current) {
      $result.ledger = $current; $result.path = $currentPath; $result.source = 'task_workspace_scoped'
      return [pscustomobject]$result
    }

    # v3 used a task-only filename. It remains a read-only migration source so
    # a same-task record cannot be silently discarded during the P5 cutover.
    $v3Path = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'guard-state\step-ledgers') $result.taskId '.json'
    $v3 = Read-StepLedgerCandidate $v3Path
    if (Test-StepLedgerScope $v3) {
      $result.ledger = $v3; $result.path = $v3Path; $result.source = 'task_scoped_legacy'
      return [pscustomobject]$result
    }
  }

  if ($AllowLegacyRead) {
    $legacyPath = Join-Path $workspace 'step-ledger.json'
    $legacy = Read-StepLedgerCandidate $legacyPath
    if ([string]::IsNullOrWhiteSpace($result.taskId) -or (Test-StepLedgerScope $legacy)) {
      if ($legacy) {
        $result.ledger = $legacy; $result.path = $legacyPath; $result.source = 'legacy_global_read_only'
      }
    }
  }
  return [pscustomobject]$result
}

function Get-SuperBrainCurrentTaskContext([string]$WorkspaceRoot,[string]$WorkspaceKey = '') {
  if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { return $null }
  try { $resolvedRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot) } catch { return $null }
  $resolvedKey = Get-SuperBrainWorkspaceKey $WorkspaceKey
  $pointerRoot = Join-Path $resolvedRoot 'guard-state\current-task-context-pointers'
  $pointerPath = Get-SuperBrainCanonicalTaskPath $pointerRoot $resolvedKey '.json'

  function Read-ContextProjection([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
  }

  function Test-CurrentContextProjection([object]$Value,[string]$ExpectedWorkspaceKey) {
    if (-not $Value -or [string]$Value.status -ne 'active' -or $Value.stale -eq $true) { return $false }
    if ($Value.PSObject.Properties['wakeEligible'] -and $Value.wakeEligible -eq $false) { return $false }
    if (-not $Value.PSObject.Properties['taskId'] -or [string]::IsNullOrWhiteSpace([string]$Value.taskId)) { return $false }
    if (-not $Value.PSObject.Properties['workspaceKey'] -or -not (Test-SuperBrainWorkspaceKey ([string]$Value.workspaceKey) $ExpectedWorkspaceKey)) { return $false }
    if ($Value.PSObject.Properties['expiresAt'] -and -not [string]::IsNullOrWhiteSpace([string]$Value.expiresAt)) {
      try {
        if ([datetimeoffset]::Parse([string]$Value.expiresAt) -le [datetimeoffset]::Now) { return $false }
      } catch { return $false }
    }
    $manifestPath = Join-Path $SuperBrainRoot 'manifest.json'
    if ($Value.PSObject.Properties['version'] -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
      try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not [string]::IsNullOrWhiteSpace([string]$Value.version) -and [string]$Value.version -ne [string]$manifest.version) { return $false }
      } catch { return $false }
    }
    return $true
  }

  $pointerExists = Test-Path -LiteralPath $pointerPath -PathType Leaf
  if ($pointerExists) {
    $context = Read-ContextProjection $pointerPath
    $source = 'workspace_scoped'
    $sourcePath = $pointerPath
  } else {
    $sourcePath = Join-Path $resolvedRoot 'current-task-context.json'
    $context = Read-ContextProjection $sourcePath
    $source = 'legacy_global'
  }
  if (-not (Test-CurrentContextProjection $context $resolvedKey)) { return $null }
  $context | Add-Member -NotePropertyName contextProjectionSource -NotePropertyValue $source -Force
  $context | Add-Member -NotePropertyName contextProjectionPath -NotePropertyValue $sourcePath -Force
  return $context
}

function Get-SuperBrainRelevantCheckpoint([string]$WorkspaceRoot,[object]$CurrentTaskContext = $null,[string]$WorkspaceKey = '',[string]$ExpectedTaskId = '') {
  $currentKey = Get-SuperBrainWorkspaceKey $WorkspaceKey
  function Read-ContinuityJson([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
  }
  function Get-ContinuityTaskSafeId([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $safe = (($Value -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
    if ($safe.Length -gt 120) { $safe = $safe.Substring(0,120) }
    return $safe
  }

  $context = $CurrentTaskContext
  $contextActive = ($context -and [string]$context.status -eq 'active' -and $context.stale -ne $true -and -not [string]::IsNullOrWhiteSpace([string]$context.taskId))
  if ($contextActive -and $context.expiresAt) {
    try { $contextActive = ([datetime]::Parse([string]$context.expiresAt) -gt (Get-Date)) } catch { $contextActive = $false }
  }
  $contextKey = if ($context -and $context.PSObject.Properties['workspaceKey']) { [string]$context.workspaceKey } else { '' }
  $contextState = if (-not $contextActive) { 'none' } elseif ([string]::IsNullOrWhiteSpace($contextKey)) { 'legacy_unscoped' } elseif (Test-SuperBrainWorkspaceKey $contextKey $currentKey) { 'relevant' } else { 'foreign_workspace' }
  $relevantContext = if ($contextState -eq 'relevant') { $context } else { $null }

  $expectedTask = if (-not [string]::IsNullOrWhiteSpace($ExpectedTaskId)) { $ExpectedTaskId.Trim() } elseif ($relevantContext) { [string]$relevantContext.taskId } else { '' }
  $candidateLocations = @()
  if (-not [string]::IsNullOrWhiteSpace($expectedTask)) {
    $checkpointRoot = Join-Path $WorkspaceRoot 'runtime-state\checkpoints\active'
    $candidateLocations += [pscustomobject]@{ path=(Get-SuperBrainCanonicalTaskPath $checkpointRoot $expectedTask '.json'); source='runtime-state/checkpoints/active' }
    $safeTaskId = Get-ContinuityTaskSafeId $expectedTask
    if (-not [string]::IsNullOrWhiteSpace($safeTaskId)) {
      $candidateLocations += [pscustomobject]@{ path=(Join-Path $checkpointRoot ($safeTaskId + '.json')); source='runtime-state/checkpoints/active' }
    }
  }
  $candidateLocations += [pscustomobject]@{ path=(Join-Path $WorkspaceRoot 'active-checkpoint.json'); source='active-checkpoint.json' }

  $candidateRecords = @()
  $seenPaths = @{}
  foreach ($location in $candidateLocations) {
    $pathKey = try { [IO.Path]::GetFullPath([string]$location.path).ToLowerInvariant() } catch { ([string]$location.path).ToLowerInvariant() }
    if ($seenPaths.ContainsKey($pathKey)) { continue }
    $seenPaths[$pathKey] = $true
    $item = Read-ContinuityJson ([string]$location.path)
    if (-not $item) { continue }

    $itemTaskId = [string]$item.taskId
    $itemKey = if ($item.PSObject.Properties['workspaceKey']) { [string]$item.workspaceKey } else { '' }
    $itemState = 'none'
    if ([string]$item.status -ne 'active') {
      $itemState = 'inactive'
    } elseif (-not [string]::IsNullOrWhiteSpace($expectedTask) -and $itemTaskId -ne $expectedTask) {
      $itemState = 'parallel_unselected'
    } elseif (-not [string]::IsNullOrWhiteSpace($itemKey)) {
      $itemState = if (Test-SuperBrainWorkspaceKey $itemKey $currentKey) { 'relevant' } else { 'foreign_workspace' }
    } elseif (-not [string]::IsNullOrWhiteSpace($expectedTask) -and $itemTaskId -eq $expectedTask) {
      $itemState = 'legacy_compatible'
    } else {
      $itemState = 'legacy_unscoped'
    }
    $candidateRecords += [pscustomobject]@{ value=$item; source=[string]$location.source; state=$itemState }
  }

  # Exact workspace evidence always wins, even when an earlier task-scoped file is legacy or foreign.
  $selectedRecord = @($candidateRecords | Where-Object { $_.state -eq 'relevant' } | Select-Object -First 1)
  if ($selectedRecord.Count -eq 0) {
    $selectedRecord = @($candidateRecords | Where-Object { $_.state -eq 'legacy_compatible' } | Select-Object -First 1)
  }
  $selectedRecord = if ($selectedRecord.Count -gt 0) { $selectedRecord[0] } else { $null }
  $diagnosticRecord = $selectedRecord
  if (-not $diagnosticRecord) {
    foreach ($diagnosticState in @('foreign_workspace','parallel_unselected','legacy_unscoped','inactive')) {
      $match = @($candidateRecords | Where-Object { $_.state -eq $diagnosticState } | Select-Object -First 1)
      if ($match.Count -gt 0) { $diagnosticRecord = $match[0]; break }
    }
  }
  $state = if ($selectedRecord) { [string]$selectedRecord.state } elseif ($diagnosticRecord) { [string]$diagnosticRecord.state } else { 'none' }
  $selected = if ($selectedRecord) { $selectedRecord.value } else { $null }
  $candidate = if ($diagnosticRecord) { $diagnosticRecord.value } else { $null }
  $source = if ($diagnosticRecord) { [string]$diagnosticRecord.source } else { '' }

  return [pscustomobject]@{
    ok = $true
    state = $state
    contextState = $contextState
    workspaceKey = $currentKey
    source = $source
    checkpoint = $selected
    context = $relevantContext
    confidence = if ($state -eq 'relevant') { 'high' } elseif ($state -eq 'legacy_compatible') { 'low' } else { 'none' }
    legacyCompatibility = ($state -eq 'legacy_compatible')
    candidateCount = @($candidateRecords).Count
    candidateTaskId = if ($candidate) { [string]$candidate.taskId } else { '' }
    ignoredTaskId = if ($candidate -and -not $selected) { [string]$candidate.taskId } else { '' }
    guard = 'Exact task-and-workspace checkpoints outrank all compatibility pointers. A missing workspace key is low-confidence legacy evidence only; an explicit foreign workspace key is never inferred from task identity.'
  }
}

function Get-SuperBrainLockPath([string]$Path) {
  $full = [System.IO.Path]::GetFullPath($Path)
  return $full + '.lock'
}

function Invoke-SuperBrainFileLock([string]$Path, [scriptblock]$Body, [int]$TimeoutMs = 15000, [int]$StaleAfterSeconds = 120) {
  $lockPath = Get-SuperBrainLockPath $Path
  $lockDir = Split-Path -Parent $lockPath
  if (-not [string]::IsNullOrWhiteSpace($lockDir) -and -not (Test-Path $lockDir)) {
    New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
  }

  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  $lockStream = $null
  $ownerToken = [Guid]::NewGuid().ToString('N')
  while ([DateTime]::UtcNow -lt $deadline) {
    try {
      if (Test-Path $lockPath) {
        try {
            $age = (Get-Date) - (Get-Item -LiteralPath $lockPath -ErrorAction Stop).LastWriteTime
          if ($age.TotalSeconds -gt $StaleAfterSeconds) {
            $staleProbe = [System.IO.File]::Open($lockPath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
            try { $staleProbe.Dispose(); Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue } finally { try { $staleProbe.Dispose() } catch {} }
          }
        } catch {}
      }
      $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
      $lockInfo = [System.Text.Encoding]::UTF8.GetBytes("owner=$ownerToken pid=$PID acquiredAt=$((Get-Date).ToString('o')) path=$Path")
      $lockStream.Write($lockInfo, 0, $lockInfo.Length)
      $lockStream.Flush()
      break
    } catch [System.IO.IOException] {
      Start-Sleep -Milliseconds 40
    }
  }

  if ($null -eq $lockStream) {
    throw "MEMORY_LOCK_TIMEOUT path=$Path lock=$lockPath timeoutMs=$TimeoutMs"
  }

  try {
    return & $Body
  } finally {
    try { $lockStream.Dispose() } catch {}
    try {
      if (Test-Path -LiteralPath $lockPath) {
        $ownedProbe = [System.IO.File]::Open($lockPath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        try {
          $reader = [System.IO.StreamReader]::new($ownedProbe,[System.Text.Encoding]::UTF8,$true,1024,$true)
          try { $lockText = $reader.ReadToEnd() } finally { $reader.Dispose() }
          if ($lockText -like "owner=$ownerToken *") { $ownedProbe.Dispose(); Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue }
        } finally { try { $ownedProbe.Dispose() } catch {} }
      }
    } catch {}
  }
}

function Publish-SuperBrainImmutableFile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$SourcePath,
    [Parameter(Mandatory=$true)][string]$DestinationPath,
    [Parameter(Mandatory=$true)][string]$ExpectedSha256,
    [string]$CollisionCode = 'IMMUTABLE_FILE_COLLISION',
    [string]$SourceMismatchCode = 'IMMUTABLE_FILE_SOURCE_MISMATCH'
  )

  $sourceFull = [IO.Path]::GetFullPath($SourcePath)
  $destinationFull = [IO.Path]::GetFullPath($DestinationPath)
  $expected = $ExpectedSha256.Trim().ToLowerInvariant()
  if ($expected -notmatch '^[a-f0-9]{64}$') { throw 'IMMUTABLE_FILE_EXPECTED_HASH_INVALID' }
  if (-not (Test-Path -LiteralPath $sourceFull -PathType Leaf)) { throw "$SourceMismatchCode source_missing" }
  if ([string]::Equals($sourceFull,$destinationFull,[StringComparison]::OrdinalIgnoreCase)) { throw 'IMMUTABLE_FILE_SOURCE_EQUALS_DESTINATION' }

  $destinationDirectory = Split-Path -Parent $destinationFull
  if (-not (Test-Path -LiteralPath $destinationDirectory)) { New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null }

  return Invoke-SuperBrainFileLock $destinationFull {
    $sourceHash = Get-SuperBrainFileSha256 $sourceFull
    if ($sourceHash -ne $expected) { throw "$SourceMismatchCode expected=$expected actual=$sourceHash" }

    if (Test-Path -LiteralPath $destinationFull -PathType Leaf) {
      $existingHash = Get-SuperBrainFileSha256 $destinationFull
      if ($existingHash -ne $expected) { throw "$CollisionCode expected=$expected actual=$existingHash" }
      return [pscustomobject]@{ ok=$true; published=$false; replayed=$true; path=$destinationFull; sha256=$existingHash }
    }

    $pending = Join-Path $destinationDirectory ('.pending-' + [guid]::NewGuid().ToString('n') + '.tmp')
    try {
      [IO.File]::Copy($sourceFull,$pending,$false)
      $pendingHash = Get-SuperBrainFileSha256 $pending
      if ($pendingHash -ne $expected) { throw "$SourceMismatchCode expected=$expected actual=$pendingHash" }
      [IO.File]::Move($pending,$destinationFull)
      $publishedHash = Get-SuperBrainFileSha256 $destinationFull
      if ($publishedHash -ne $expected) { throw "$CollisionCode expected=$expected actual=$publishedHash" }
      return [pscustomobject]@{ ok=$true; published=$true; replayed=$false; path=$destinationFull; sha256=$publishedHash }
    } finally {
      if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue }
    }
  }
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  Invoke-SuperBrainFileLock $Path {
    $tmpName = '.sb-write-' + $PID + '-' + ([Guid]::NewGuid().ToString('N').Substring(0,12)) + '.tmp'
    $tmp = if ([string]::IsNullOrWhiteSpace($dir)) { Join-Path ([Environment]::CurrentDirectory) $tmpName } else { Join-Path $dir $tmpName }
    try {
      [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.UTF8Encoding]::new($false))
      if (Test-Path $Path) {
        Move-Item -LiteralPath $tmp -Destination $Path -Force
      } else {
        Move-Item -LiteralPath $tmp -Destination $Path
      }
    } finally {
      if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
  } | Out-Null
}

function Add-Utf8LineLocked([string]$Path, [string]$Line) {
  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  Invoke-SuperBrainFileLock $Path {
    $value = if ($Line.EndsWith("`n")) { $Line } else { $Line + "`n" }
    [System.IO.File]::AppendAllText($Path, $value, [System.Text.UTF8Encoding]::new($false))
  } | Out-Null
}

function Write-JsonUtf8NoBom([string]$Path, [object]$Value, [int]$Depth = 8, [switch]$Compress) {
  Write-Utf8NoBom $Path ($Value | ConvertTo-Json -Depth $Depth -Compress:$Compress)
}

function ConvertFrom-SuperBrainJsonOutput([string]$Text, [string]$Context = 'JSON output') {
  $value = if ($null -eq $Text) { '' } else { $Text.Trim() }
  if ([string]::IsNullOrWhiteSpace($value)) { throw "SUPER_BRAIN_JSON_EMPTY context=$Context" }
  $offset = 0
  while ($offset -lt $value.Length) {
    $objectStart = $value.IndexOf('{', $offset)
    $arrayStart = $value.IndexOf('[', $offset)
    if ($objectStart -lt 0 -and $arrayStart -lt 0) { break }
    if ($objectStart -lt 0) { $start = $arrayStart }
    elseif ($arrayStart -lt 0) { $start = $objectStart }
    else { $start = [Math]::Min($objectStart, $arrayStart) }
    try { return ($value.Substring($start) | ConvertFrom-Json) } catch { $offset = $start + 1 }
  }
  throw "SUPER_BRAIN_JSON_INVALID context=$Context"
}

function Invoke-SuperBrainTaskStateStore([hashtable]$Parameters) {
  $storeScript = Join-Path $PSScriptRoot 'task-state-store.ps1'
  if (-not (Test-Path -LiteralPath $storeScript)) { throw "TASK_STATE_STORE_SCRIPT_MISSING path=$storeScript" }
  $Parameters.Json = $true
  $raw = @(& $storeScript @Parameters 2>&1)
  $exitCode = $LASTEXITCODE
  $text = (@($raw | ForEach-Object { [string]$_ }) -join "`n")
  if ($text.Trim() -eq 'null') {
    if ($exitCode -ne 0) { throw "TASK_STATE_STORE_SYNC_FAILED null result" }
    return $null
  }
  $start = $text.IndexOf('{')
  $end = $text.LastIndexOf('}')
  if ($start -lt 0 -or $end -lt $start) { throw "TASK_STATE_STORE_NO_JSON output=$text" }
  $result = $text.Substring($start,$end-$start+1) | ConvertFrom-Json
  if ($exitCode -ne 0 -or ($result.PSObject.Properties['ok'] -and $result.ok -ne $true)) {
    $detail = if ($result.PSObject.Properties['error'] -and -not [string]::IsNullOrWhiteSpace([string]$result.error)) { [string]$result.error } else { $text }
    throw "TASK_STATE_STORE_SYNC_FAILED $detail"
  }
  return $result
}

function Get-SuperBrainTaskStateExpectedRevision([string]$TaskId) {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'TASK_STATE_TASK_ID_REQUIRED' }
  $projection = Invoke-SuperBrainTaskStateStore @{ Action='Get'; TaskId=$TaskId }
  if (-not $projection) { return 0 }
  return [int]$projection.revision
}

function Set-SuperBrainTaskStatePayloadTargetPath([object]$EntityValue,[string]$RequestedPath,[string]$CanonicalPath) {
  if (-not $EntityValue) { return }
  foreach ($propertyName in @('path','sourcePath')) {
    $property = $EntityValue.PSObject.Properties[$propertyName]
    if ($property -and ([string]::IsNullOrWhiteSpace([string]$property.Value) -or [string]::Equals([string]$property.Value,$RequestedPath,[System.StringComparison]::OrdinalIgnoreCase))) {
      $EntityValue | Add-Member -NotePropertyName $propertyName -NotePropertyValue $CanonicalPath -Force
    }
  }
}

function Sync-SuperBrainTaskState(
  [string]$TaskId,
  [ValidateSet('context','checkpoint','task_card')][string]$EntityKind,
  [ValidateSet('upsert','clear')][string]$Operation,
  [string]$EntityPath,
  [string]$Source
) {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'TASK_STATE_TASK_ID_REQUIRED' }
  $parameters = @{ Action='Record'; TaskId=$TaskId; EntityKind=$EntityKind; Operation=$Operation; Source=$Source; MaintenanceOverride=$true; MaintenanceReason=('legacy sync: ' + $Source) }
  if (-not [string]::IsNullOrWhiteSpace($EntityPath)) { $parameters.EntityPath = $EntityPath }
  return Invoke-SuperBrainTaskStateStore $parameters
}

function Commit-SuperBrainTaskState(
  [string]$TaskId,
  [ValidateSet('context','checkpoint','task_card')][string]$EntityKind,
  [object]$EntityValue,
  [string]$EntityPath,
  [string]$Source,
  [ValidateSet('upsert','clear')][string]$Operation = 'upsert',
  [int]$ExpectedRevision = -1,
  [string]$OwnerWorkspace = '',
  [string]$OwnerAgentId = '',
  [string]$OwnerSessionId = '',
  [string]$OwnerPlatform = '',
  [switch]$MaintenanceOverride,
  [string]$MaintenanceReason = ''
) {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'TASK_STATE_TASK_ID_REQUIRED' }
  if ($Operation -eq 'upsert' -and $null -eq $EntityValue) { throw 'TASK_STATE_ENTITY_VALUE_REQUIRED' }
  $root = Split-Path -Parent $PSScriptRoot
  $workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $root) 'workspace'
  $shared = Get-SuperBrainSharedMemoryRoot $root
  $canonicalPath = Get-SuperBrainCanonicalTaskStateEntityPath $TaskId $EntityKind $workspace $shared $EntityPath
  Set-SuperBrainTaskStatePayloadTargetPath $EntityValue $EntityPath $canonicalPath
  $stageDir = Join-Path (Join-Path $workspace 'task-state-store\staging') (Get-SuperBrainCanonicalTaskToken $TaskId)
  if (-not (Test-Path -LiteralPath $stageDir)) { New-Item -ItemType Directory -Force -Path $stageDir | Out-Null }
  $payloadPath = ''
  if ($null -ne $EntityValue) {
    $payloadPath = Join-Path $stageDir (([guid]::NewGuid().ToString('n')) + '.json')
    Write-JsonUtf8NoBom $payloadPath $EntityValue 12
  }
  $owner = Get-SuperBrainTaskStateOwnerInput $EntityValue $OwnerAgentId $OwnerSessionId $OwnerPlatform $OwnerWorkspace
  if ($ExpectedRevision -lt 0 -and -not $MaintenanceOverride) { $ExpectedRevision = Get-SuperBrainTaskStateExpectedRevision $TaskId }
  $parameters = @{ Action='Commit'; TaskId=$TaskId; EntityKind=$EntityKind; Operation=$Operation; EntityPath=$canonicalPath; Source=$Source; ExpectedRevision=$ExpectedRevision; OwnerAgentId=$owner.agentId; OwnerSessionId=$owner.sessionId; OwnerPlatform=$owner.platform; OwnerWorkspace=$owner.workspace; MaintenanceOverride=[bool]$MaintenanceOverride; MaintenanceReason=$MaintenanceReason }
  if ($payloadPath) { $parameters.PayloadPath = $payloadPath }
  return Invoke-SuperBrainTaskStateStore $parameters
}

function Clear-SuperBrainTaskState(
  [string]$TaskId,
  [ValidateSet('context','checkpoint','task_card')][string]$EntityKind,
  [string]$EntityPath,
  [string]$Source,
  [string]$OwnerWorkspace = '',
  [int]$ExpectedRevision = -1,
  [string]$OwnerAgentId = '',
  [string]$OwnerSessionId = '',
  [string]$OwnerPlatform = '',
  [switch]$MaintenanceOverride,
  [string]$MaintenanceReason = ''
) {
  return Commit-SuperBrainTaskState -TaskId $TaskId -EntityKind $EntityKind -EntityValue $null -EntityPath $EntityPath -Source $Source -Operation clear -ExpectedRevision $ExpectedRevision -OwnerWorkspace $OwnerWorkspace -OwnerAgentId $OwnerAgentId -OwnerSessionId $OwnerSessionId -OwnerPlatform $OwnerPlatform -MaintenanceOverride:$MaintenanceOverride -MaintenanceReason $MaintenanceReason
}

function Complete-SuperBrainTaskState(
  [string]$TaskId,
  [string]$WorkspaceKey,
  [object]$CompletedCheckpoint,
  [object]$CompletedTaskCard,
  [string]$ExecutionContractPath,
  [string]$VerificationPath,
  [string]$ExpectedPlanFingerprint,
  [int]$ExpectedContractRevision,
  [string]$OwnerSessionKey,
  [string]$CallerSessionKey = '',
  [string]$Source,
  [int]$ExpectedRevision = -1,
  [string]$OwnerWorkspace = '',
  [string]$OwnerAgentId = '',
  [string]$OwnerSessionId = '',
  [string]$OwnerPlatform = '',
  [switch]$MaintenanceOverride,
  [string]$MaintenanceReason = '',
  [string]$FaultPoint = 'none',
  [int]$FaultAfterMaterialization = 0
) {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'TASK_STATE_TASK_ID_REQUIRED' }
  if (-not $CompletedCheckpoint -or -not $CompletedTaskCard) { throw 'TASK_STATE_COMPLETION_PAYLOAD_REQUIRED' }
  $root = Split-Path -Parent $PSScriptRoot
  $workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $root) 'workspace'
  $stageDir = Join-Path (Join-Path $workspace 'task-state-store\staging') (Get-SuperBrainCanonicalTaskToken $TaskId)
  if (-not (Test-Path -LiteralPath $stageDir)) { New-Item -ItemType Directory -Force -Path $stageDir | Out-Null }
  $stamp = [guid]::NewGuid().ToString('n').Substring(0,12)
  $checkpointPayloadPath = Join-Path $stageDir ($stamp + '-completed-checkpoint.json')
  $taskCardPayloadPath = Join-Path $stageDir ($stamp + '-completed-task-card.json')
  $manifestPath = Join-Path $stageDir ($stamp + '-completion-manifest.json')
  Write-JsonUtf8NoBom $checkpointPayloadPath $CompletedCheckpoint 12
  Write-JsonUtf8NoBom $taskCardPayloadPath $CompletedTaskCard 12
  $resolvedWorkspaceKey = Get-SuperBrainWorkspaceKey $WorkspaceKey
  $resolvedOwnerSessionKey = Get-SuperBrainLocalSessionKey $OwnerSessionKey
  $resolvedCallerSessionKey = Get-SuperBrainLocalSessionKey $CallerSessionKey
  $contractRecord = $null
  try { if (-not [string]::IsNullOrWhiteSpace($ExecutionContractPath) -and (Test-Path -LiteralPath $ExecutionContractPath -PathType Leaf)) { $contractRecord = Get-Content -LiteralPath $ExecutionContractPath -Raw -Encoding UTF8 | ConvertFrom-Json } } catch {}
  $expectedTaskInstanceId = if($contractRecord -and $contractRecord.PSObject.Properties['taskInstanceId']){[string]$contractRecord.taskInstanceId}else{''}
  $verificationRecord = $null
  try { if (-not [string]::IsNullOrWhiteSpace($VerificationPath) -and (Test-Path -LiteralPath $VerificationPath -PathType Leaf)) { $verificationRecord = Get-Content -LiteralPath $VerificationPath -Raw -Encoding UTF8 | ConvertFrom-Json } } catch {}
  $verificationBinding = if ($verificationRecord -and $verificationRecord.PSObject.Properties['evidenceBinding']) { $verificationRecord.evidenceBinding } else { $null }
  $completionEvidenceBinding = $null
  if ($verificationBinding) {
    $completionEvidenceBinding = [pscustomobject]@{
      schema = [string]$verificationBinding.schema
      packageVersion = [string]$verificationBinding.packageVersion
      gitTreeHash = [string]$verificationBinding.gitTreeHash
      treeAlgorithm = [string]$verificationBinding.treeAlgorithm
      gitHeadTreeHash = [string]$verificationBinding.gitHeadTreeHash
      taskId = [string]$verificationBinding.taskId
      workspaceKey = [string]$verificationBinding.workspaceKey
      ownerSessionKey = [string]$verificationBinding.ownerSessionKey
      artifactHash = Get-SuperBrainFileSha256 $VerificationPath
      artifactKind = 'task_verification'
    }
  }
  $manifest = [pscustomobject]@{
    schema = 'super-brain.task-completion-manifest.v1'
    taskId = $TaskId
    workspaceKey = $resolvedWorkspaceKey
    packageVersion = [string](Get-SuperBrainManifest $root).version
    completionStatus = 'completed'
    ownerSessionKey = $resolvedOwnerSessionKey
    callerSessionKey = $resolvedCallerSessionKey
    expectedTaskInstanceId = $expectedTaskInstanceId
    expectedPlanFingerprint = $ExpectedPlanFingerprint
    expectedContractRevision = $ExpectedContractRevision
    completedCheckpointPayloadPath = $checkpointPayloadPath
    completedTaskCardPayloadPath = $taskCardPayloadPath
    executionContractPath = $ExecutionContractPath
    verificationPath = $VerificationPath
    evidenceBinding = $completionEvidenceBinding
    source = $Source
  }
  Write-JsonUtf8NoBom $manifestPath $manifest 10
  if ($ExpectedRevision -lt 0 -and -not $MaintenanceOverride) { $ExpectedRevision = Get-SuperBrainTaskStateExpectedRevision $TaskId }
  $parameters = @{
    Action='CompleteTask'; TaskId=$TaskId; CompletionManifestPath=$manifestPath; ExpectedRevision=$ExpectedRevision; Source=$Source
    OwnerWorkspace=$OwnerWorkspace; OwnerAgentId=$OwnerAgentId; OwnerSessionId=$OwnerSessionId; OwnerPlatform=$OwnerPlatform; CallerSessionKey=$resolvedCallerSessionKey
    MaintenanceOverride=[bool]$MaintenanceOverride; MaintenanceReason=$MaintenanceReason; FaultPoint=$FaultPoint; FaultAfterMaterialization=$FaultAfterMaterialization
  }
  return Invoke-SuperBrainTaskStateStore $parameters
}

function Get-SuperBrainFileLockStatus([string]$Path, [int]$StaleAfterSeconds = 120) {
  $full = [System.IO.Path]::GetFullPath($Path)
  $lockPath = Get-SuperBrainLockPath $full
  $exists = Test-Path $lockPath
  $ageSeconds = 0
  $lastWriteTime = $null
  $preview = ''
  if ($exists) {
    try {
      $item = Get-Item -LiteralPath $lockPath
      $lastWriteTime = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
      $ageSeconds = [Math]::Round(((Get-Date) - $item.LastWriteTime).TotalSeconds, 2)
      try { $preview = ([System.IO.File]::ReadAllText($lockPath, [System.Text.Encoding]::UTF8)).Trim() } catch {}
      if ($preview.Length -gt 180) { $preview = $preview.Substring(0, 180) + '...' }
    } catch {}
  }
  return [pscustomobject]@{
    target = $full
    lock = $lockPath
    exists = $exists
    ageSeconds = $ageSeconds
    staleAfterSeconds = $StaleAfterSeconds
    stale = ($exists -and $ageSeconds -gt $StaleAfterSeconds)
    lastWriteTime = $lastWriteTime
    preview = $preview
  }
}

function Get-SuperBrainKnownLockStatuses([string]$Root = $SuperBrainRoot, [int]$StaleAfterSeconds = 120) {
  $memoryBase = Get-SuperBrainMemoryBaseRoot $Root
  $memoryRoot = Get-SuperBrainActiveMemoryRoot $Root
  $workspace = Join-Path $memoryBase 'workspace'
  $targets = @(
    (Join-Path $memoryRoot 'sandglass.txt'),
    (Join-Path $memoryRoot 'decision_particles.txt'),
    (Join-Path $memoryBase 'graph.jsonl'),
    (Join-Path $workspace 'active-checkpoint.json'),
    (Join-Path $workspace 'status-card.json'),
    (Join-Path $workspace 'last-status-snapshot.json'),
    (Join-Path $workspace 'last-verify-package.json'),
    (Join-Path $workspace 'last-ci.json'),
    (Join-Path $workspace 'session-binding.json')
  )
  return @($targets | ForEach-Object { Get-SuperBrainFileLockStatus $_ $StaleAfterSeconds } | Where-Object { $_.exists })
}

function Get-SuperBrainSkillNames {
  # Only the public Super Brain adapter belongs in the host skill catalog.
  # ORC, G1, NexSandglass, skill evolution, and skill-pool management remain
  # package-owned internal/cold capabilities behind this entry.
  return @('super-memory-brain')
}

function Get-SuperBrainManifest([string]$Root = $SuperBrainRoot) {
  return Get-Content -LiteralPath (Join-Path $Root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-SuperBrainRuntimeFiles([string]$Root = $SuperBrainRoot) {
  $manifest = Get-SuperBrainManifest $Root
  if ($manifest.runtimeFiles) {
    return @($manifest.runtimeFiles)
  }
  return @(
    'sandglass_paths.py','sandglass_lock.py','sandglass_vault.py','sandglass_sqlite.py','sandglass_log.py','sandglass.py',
    'sandglass_think.py','sandglass_archive.py','sandglass_mcp.py','nexsandglass.py','nightwatch.py',
    'pulse.py','heartbeat.py','persona_l3.py','offset_l3.py','emotion_l3.py','scene_l3.py',
    'weave_l3.py','weavethread.py','l3_tasks.py','l3_persona_verify.py','l3_search_core.py',
    'l3_persona.py','discipline.py','offset_signals.py','decision_particles.py','emotion_vocab.py',
    'shadow_sand.py','search_router.py','l0_buffer.py','soul_diff.py','plugin.py','migrate_v2_4.py','metrics.py'
  )
}


function Get-SafeSuperBrainName([string]$Name, [string]$Fallback = 'default') {
  $safeName = ($Name -replace '[^A-Za-z0-9._-]','-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = $Fallback }
  return $safeName.ToLowerInvariant()
}

function Get-SuperBrainRuntimeSourceRoot([string]$Root = $SuperBrainRoot) {
  $manifest = Get-SuperBrainManifest $Root
  $relative = [string]$manifest.runtimeSourceRoot
  if ([string]::IsNullOrWhiteSpace($relative)) {
    $relative = 'vendor\NexSandglass-Agent-DedicatedMemory'
  }
  $source = Get-FullPath (Join-Path $Root $relative)
  if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw "SUPER_BRAIN_RUNTIME_SOURCE_MISSING: $source"
  }
  return $source
}

function Get-SuperBrainRuntimePythonPath([string]$Root = $SuperBrainRoot) {
  return Get-SuperBrainRuntimeSourceRoot $Root
}

function Get-SuperBrainRuntimeLayout([string]$Root = $SuperBrainRoot) {
  $path = Join-Path $Root 'runtime-layout.json'
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try {
    $layout = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$layout.schema -ne 'super-brain.runtime-layout.v1') { return $null }
    return $layout
  } catch { return $null }
}

function Get-SuperBrainRuntimeWorkspaceRoot([string]$Root = $SuperBrainRoot) {
  $runtimeRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\','/')
  if ([string]::Equals((Split-Path -Leaf $runtimeRoot),'CORE',[StringComparison]::OrdinalIgnoreCase)) {
    return (Split-Path -Parent $runtimeRoot).TrimEnd('\','/')
  }
  return $runtimeRoot
}

function Test-SuperBrainRuntimeLayoutWorkspacePath([string]$WorkspaceRoot,[string]$Candidate) {
  try {
    $workspace = [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/')
    $full = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\','/')
    if ([string]::Equals($workspace,$full,[StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $full.StartsWith(($workspace + [System.IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)
  } catch { return $false }
}

function Resolve-SuperBrainRuntimeLayoutPath([string]$Root,[string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $runtimeRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\','/')
  $workspaceRoot = Get-SuperBrainRuntimeWorkspaceRoot $runtimeRoot
  $expanded = [Environment]::ExpandEnvironmentVariables($Value.Trim())
  $candidate = if ([System.IO.Path]::IsPathRooted($expanded)) { $expanded } else { Join-Path $runtimeRoot $expanded }
  $full = [System.IO.Path]::GetFullPath($candidate).TrimEnd('\','/')
  if (-not (Test-SuperBrainRuntimeLayoutWorkspacePath $workspaceRoot $full)) {
    throw "SUPER_BRAIN_RUNTIME_LAYOUT_PATH_OUTSIDE_WORKSPACE: $Value"
  }
  return $full
}

function Get-SuperBrainMemoryBaseRoot([string]$Root = $SuperBrainRoot) {
  if (-not [string]::IsNullOrWhiteSpace($env:SUPER_BRAIN_STATE_ROOT)) {
    return [System.IO.Path]::GetFullPath($env:SUPER_BRAIN_STATE_ROOT).TrimEnd('\','/')
  }
  $layout = Get-SuperBrainRuntimeLayout $Root
  if ($layout -and -not [string]::IsNullOrWhiteSpace([string]$layout.stateRoot)) {
    return Resolve-SuperBrainRuntimeLayoutPath $Root ([string]$layout.stateRoot)
  }
  $workspaceRoot = Get-SuperBrainRuntimeWorkspaceRoot $Root
  if (-not (Test-SuperBrainSamePath $workspaceRoot $Root)) { return Join-Path $workspaceRoot 'private-state' }
  return Join-Path $Root 'memory'
}

function Get-SuperBrainArchiveRoot([string]$Root = $SuperBrainRoot) {
  if (-not [string]::IsNullOrWhiteSpace($env:SUPER_BRAIN_ARCHIVE_ROOT)) {
    return [System.IO.Path]::GetFullPath($env:SUPER_BRAIN_ARCHIVE_ROOT).TrimEnd('\','/')
  }
  $layout = Get-SuperBrainRuntimeLayout $Root
  if ($layout -and -not [string]::IsNullOrWhiteSpace([string]$layout.archiveRoot)) {
    return Resolve-SuperBrainRuntimeLayoutPath $Root ([string]$layout.archiveRoot)
  }
  $workspaceRoot = Get-SuperBrainRuntimeWorkspaceRoot $Root
  if (-not (Test-SuperBrainSamePath $workspaceRoot $Root)) { return Join-Path $workspaceRoot 'private-archive' }
  return Join-Path $Root 'archives'
}

function Test-SuperBrainWritableArchiveDirectory([string]$Path) {
  $probe = ''
  $lockPath = ''
  $lockStream = $null
  try {
    $resolved = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
    New-Item -ItemType Directory -Force -Path $resolved -ErrorAction Stop | Out-Null
    # Verify the descendant used by backup-retention, including its exclusive
    # lock contract. A root can accept ordinary writes while rejecting lock
    # creation in that descendant (for example under a restricted sandbox).
    $probeDir = Join-Path $resolved 'backup-retention\previews'
    New-Item -ItemType Directory -Force -Path $probeDir -ErrorAction Stop | Out-Null
    $probe = Join-Path $probeDir ('.write-probe-' + [guid]::NewGuid().ToString('n'))
    [System.IO.File]::WriteAllText($probe, '', [System.Text.UTF8Encoding]::new($false))
    $lockPath = $probe + '.lock'
    $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    return $true
  } catch {
    return $false
  } finally {
    try { if ($null -ne $lockStream) { $lockStream.Dispose() } } catch {}
    foreach ($cleanupPath in @($lockPath,$probe)) {
      try { if (-not [string]::IsNullOrWhiteSpace($cleanupPath) -and (Test-Path -LiteralPath $cleanupPath)) { Remove-Item -LiteralPath $cleanupPath -Force -ErrorAction SilentlyContinue } } catch {}
    }
  }
}

function Get-SuperBrainWritableArchiveRoot([string]$Root = $SuperBrainRoot) {
  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\','/')
  $candidates = @(
    (Get-SuperBrainArchiveRoot $rootFull),
    (Join-Path (Get-SuperBrainMemoryBaseRoot $rootFull) 'archive'),
    (Join-Path (Split-Path -Parent $rootFull) 'output\archive')
  )
  $seen = @{}
  foreach ($candidate in @($candidates)) {
    if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
    $resolved = [System.IO.Path]::GetFullPath([string]$candidate).TrimEnd('\','/')
    $key = $resolved.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    if (Test-SuperBrainWritableArchiveDirectory $resolved) { return $resolved }
  }
  throw 'SUPER_BRAIN_WRITABLE_ARCHIVE_ROOT_UNAVAILABLE'
}

function Get-SuperBrainInstallBackupRoot([string]$Root = $SuperBrainRoot) {
  return Join-Path (Get-SuperBrainWritableArchiveRoot $Root) 'install-backups'
}

function Get-SuperBrainSharedMemoryRoot([string]$Root = $SuperBrainRoot) {
  return Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'shared'
}

function Get-SuperBrainSharingPolicyPath([string]$Root = $SuperBrainRoot) {
  return Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'memory-sharing-policy.json'
}

function Get-SuperBrainDefaultSharingPolicy([string]$Root = $SuperBrainRoot) {
  $sharedRoot = (Get-NormalizedSuperBrainRoot (Get-SuperBrainSharedMemoryRoot $Root))
  return [pscustomobject]@{
    initialized = $true
    mode = 'shared'
    activeRoot = $sharedRoot
    sharedRoot = $sharedRoot
    rootAuthority = 'stateRoot/shared'
    legacyRootsReadOnly = $true
    members = @('all-agents')
    updatedAt = ''
    note = 'The stateRoot/shared directory is the only live Super Brain memory root. Historical agent, group, ZCode, and Codex roots are read-only migration sources.'
  }
}

function Get-SuperBrainSharingPolicy([string]$Root = $SuperBrainRoot) {
  $path = Get-SuperBrainSharingPolicyPath $Root
  $canonical = Get-SuperBrainDefaultSharingPolicy $Root
  if (Test-Path $path) {
    try {
      $stored = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($stored -and $stored.PSObject.Properties['updatedAt']) {
        $canonical.updatedAt = [string]$stored.updatedAt
      }
    } catch {}
  }
  return $canonical
}

function Write-SuperBrainSharingPolicy([string]$Root, [string]$Mode, [string]$ActiveRoot, [string[]]$Members = @()) {
  $path = Get-SuperBrainSharingPolicyPath $Root
  # Super Brain has one live memory authority.  Host/agent-specific roots are
  # migration evidence only; task, workspace, and session provenance separate
  # concurrent work inside the shared store.
  $sharedRoot = Get-SuperBrainSharedMemoryRoot $Root
  $policy = [pscustomobject]@{
    initialized = $true
    mode = 'shared'
    requestedMode = $Mode
    activeRoot = (Get-NormalizedSuperBrainRoot $sharedRoot)
    sharedRoot = (Get-NormalizedSuperBrainRoot $sharedRoot)
    rootAuthority = 'stateRoot/shared'
    legacyRootsReadOnly = $true
    members = @('all-agents')
    updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    note = 'The shared Super Brain root is the only live write target. Agent, group, ZCode, and Codex roots are legacy migration sources; task, workspace, and session provenance isolate concurrent work.'
  }
  Write-JsonUtf8NoBom $path $policy 6
  return $policy
}

function Test-SuperBrainMemoryRootReady([string]$MemoryRoot) {
  if ([string]::IsNullOrWhiteSpace($MemoryRoot)) { return $false }
  try {
    $candidate = Get-NormalizedSuperBrainRoot $MemoryRoot
  } catch {
    return $false
  }
  return (
    (Test-Path -LiteralPath $candidate -PathType Container) -and
    (Test-Path -LiteralPath (Join-Path $candidate 'sandglass.txt') -PathType Leaf)
  )
}

function Get-SuperBrainActiveMemoryRoot([string]$Root = $SuperBrainRoot) {
  # Never reactivate a historical per-agent/group root from an old policy file.
  return Get-SuperBrainSharedMemoryRoot $Root
}

function Resolve-SuperBrainActiveMemoryRoot {
  [CmdletBinding()]
  param(
    [string]$Root = $SuperBrainRoot,
    [string]$Candidate = '',
    [string]$Operation = 'resolve-memory-root'
  )

  $activeRoot = Get-NormalizedSuperBrainRoot (Get-SuperBrainActiveMemoryRoot $Root)
  if ([string]::IsNullOrWhiteSpace($Candidate)) { return $activeRoot }

  $candidateRoot = Get-NormalizedSuperBrainRoot $Candidate
  if (-not (Test-SuperBrainSamePath $candidateRoot $activeRoot)) {
    throw "MEMORY_ROOT_OVERRIDE_RETIRED: $Operation requested '$candidateRoot', but the only live Super Brain root is '$activeRoot'. Set SUPER_BRAIN_STATE_ROOT to an explicit state root for an isolated fixture, then use its shared child."
  }
  return $activeRoot
}

function Get-SuperBrainMemoryLifecyclePolicy([string]$Root = $SuperBrainRoot) {
  $defaults = [pscustomobject]@{
    enabled = $true
    maxLines = 240
    maxChars = 180000
    warnAt = 0.8
    maxLinesByLayer = [pscustomobject]@{ profile = 32; project = 120; decision = 96; task = 48; session = 24 }
    retentionDays = [pscustomobject]@{ profile = 3650; project = 730; decision = 1095; task = 120; session = 30 }
    preserveTags = @('[CURRENT]','[VERIFIED]','[PROFILE]','[DECISION]')
    autoArchive = [pscustomobject]@{ exactDuplicates = $true; explicitExpiry = $true; staleHistory = $false; budgetOverflow = $false; requireConfirmationForBudgetOverflow = $true }
  }
  try {
    $path = Join-Path $Root 'memory-policy.json'
    $policy = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($policy.PSObject.Properties['lifecycle'] -and $policy.lifecycle) { return $policy.lifecycle }
  } catch {}
  return $defaults
}

function Get-SuperBrainMemoryLineRecord([string]$Line, [int]$LineNumber = 0) {
  $value = if ($null -eq $Line) { '' } else { [string]$Line }
  $match = [regex]::Match($value, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \| ([^|]+) \| (.*)$')
  $timestamp = $null
  $sender = ''
  $text = $value
  if ($match.Success) {
    try { $timestamp = [datetime]::ParseExact($match.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) } catch {}
    $sender = (($match.Groups[2].Value -replace ';sm1:.*$','').Trim())
    $text = $match.Groups[3].Value
  }
  $tags = @([regex]::Matches($text, '\[[A-Z_]+\]') | ForEach-Object { $_.Value } | Select-Object -Unique)
  $layer = 'project'
  foreach ($candidate in @('profile','decision','task','session','project')) {
    if ($text.Contains("[$($candidate.ToUpperInvariant())]")) { $layer = $candidate; break }
  }
  if ($text.Contains('[ADR]')) { $layer = 'decision' }
  $expiryMatch = [regex]::Match($text, 'expires=(\d{4}-\d{2}-\d{2})')
  $expired = $false
  $expiry = ''
  if ($expiryMatch.Success) {
    $expiry = $expiryMatch.Groups[1].Value
    try { $expired = ([datetime]::ParseExact($expiry, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) -lt (Get-Date).Date) } catch { $expired = $true }
  }
  $ageDays = 0.0
  if ($timestamp) { $ageDays = [Math]::Max(0, ((Get-Date) - $timestamp).TotalDays) }
  return [pscustomobject]@{
    line = $LineNumber
    raw = $value
    text = $text
    timestamp = $timestamp
    sender = $sender
    tags = @($tags)
    layer = $layer
    expired = $expired
    expiry = $expiry
    ageDays = [Math]::Round($ageDays, 2)
    current = $text.Contains('[CURRENT]')
    verified = $text.Contains('[VERIFIED]')
    stale = $text.Contains('[STALE]')
    history = $text.Contains('[HISTORY]')
    protected = ($text.Contains('[CURRENT]') -and $text.Contains('[VERIFIED]'))
  }
}

function Get-SuperBrainMemoryBudget([object[]]$Records, [string]$CandidateText = '', [string]$CandidateLayer = '', [string]$Root = $SuperBrainRoot) {
  $lifecycle = Get-SuperBrainMemoryLifecyclePolicy $Root
  $items = @($Records | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.raw) })
  $maxLines = [int]$lifecycle.maxLines
  $maxChars = [int]$lifecycle.maxChars
  $currentLines = $items.Count
  $currentChars = 0
  foreach ($item in $items) { $currentChars += ([string]$item.raw).Length }
  $candidate = if ([string]::IsNullOrWhiteSpace($CandidateText)) { $null } else { [string]$CandidateText }
  $projectedLines = $currentLines + $(if ($candidate) { 1 } else { 0 })
  $projectedChars = [int]$currentChars + $(if ($candidate) { $candidate.Length } else { 0 })
  $layerCounts = [ordered]@{}
  $layerUtilization = [ordered]@{}
  foreach ($layer in @('profile','project','decision','task','session')) {
    $count = @($items | Where-Object { [string]$_.layer -eq $layer }).Count
    if ($candidate -and $CandidateLayer -eq $layer) { $count += 1 }
    $limit = [int]$lifecycle.maxLinesByLayer.$layer
    $layerCounts[$layer] = $count
    $layerUtilization[$layer] = [Math]::Round($(if ($limit -gt 0) { $count / $limit } else { 0 }), 4)
  }
  $lineUtilization = if ($maxLines -gt 0) { $projectedLines / $maxLines } else { 1 }
  $charUtilization = if ($maxChars -gt 0) { $projectedChars / $maxChars } else { 1 }
  $layerBlocked = @($layerUtilization.Keys | Where-Object { [double]$layerUtilization[$_] -gt 1 }).Count -gt 0
  $blocked = ($projectedLines -gt $maxLines -or $projectedChars -gt $maxChars -or $layerBlocked)
  $warning = (-not $blocked -and ($lineUtilization -ge [double]$lifecycle.warnAt -or $charUtilization -ge [double]$lifecycle.warnAt -or @($layerUtilization.Values | Where-Object { [double]$_ -ge [double]$lifecycle.warnAt }).Count -gt 0))
  return [pscustomobject]@{
    enabled = [bool]$lifecycle.enabled
    status = if ($blocked) { 'blocked' } elseif ($warning) { 'warning' } else { 'ok' }
    admissionStatus = if ($blocked) { 'blocked' } elseif ($warning) { 'warning' } else { 'allowed' }
    currentLines = $currentLines
    currentChars = [int]$currentChars
    projectedLines = $projectedLines
    projectedChars = $projectedChars
    maxLines = $maxLines
    maxChars = $maxChars
    warnAt = [double]$lifecycle.warnAt
    lineUtilization = [Math]::Round($lineUtilization, 4)
    charUtilization = [Math]::Round($charUtilization, 4)
    layerCounts = $layerCounts
    layerUtilization = $layerUtilization
    retentionDays = $lifecycle.retentionDays
    reason = if ($blocked) { 'memory_budget_exceeded' } elseif ($warning) { 'memory_budget_near_limit' } else { 'within_memory_budget' }
  }
}

function Test-SuperBrainSamePath([string]$Left, [string]$Right) {
  if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
  return ((Get-NormalizedSuperBrainRoot $Left) -eq (Get-NormalizedSuperBrainRoot $Right))
}

function Assert-SuperBrainMemoryWriteAllowed([string]$Root, [string]$MemoryRoot, [string]$Operation = 'write') {
  try {
    [void](Resolve-SuperBrainActiveMemoryRoot -Root $Root -Candidate $MemoryRoot -Operation $Operation)
  } catch {
    throw "MEMORY_SCOPE_MISMATCH: $($_.Exception.Message)"
  }
}

function Read-SuperBrainMemoryRootMarker([string]$SkillDir) {
  $markerPath = Join-Path $SkillDir 'memory-root.txt'
  if (-not (Test-Path $markerPath)) { return '' }
  return ([System.IO.File]::ReadAllText($markerPath, [System.Text.Encoding]::UTF8)).Trim()
}

function Get-SuperBrainExtensionManifests([string[]]$Extensions = @(), [string]$Root = $SuperBrainRoot) {
  $extensionRoot = Join-Path $Root 'extensions'
  if (-not (Test-Path $extensionRoot)) { return @() }
  $manifests = @()
  foreach ($manifestPath in @(Get-ChildItem -LiteralPath $extensionRoot -Filter 'extension.json' -Recurse -File -ErrorAction SilentlyContinue)) {
    try {
      $manifest = Get-Content -LiteralPath $manifestPath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      $manifest | Add-Member -NotePropertyName manifestPath -NotePropertyValue $manifestPath.FullName -Force
      $manifest | Add-Member -NotePropertyName extensionRoot -NotePropertyValue (Split-Path -Parent $manifestPath.FullName) -Force
      if ($Extensions.Count -eq 0 -or ($Extensions -contains [string]$manifest.id)) { $manifests += $manifest }
    } catch {}
  }
  return @($manifests)
}

function Get-SuperBrainExtensionCatalog([string]$Root = $SuperBrainRoot) {
  $catalog = @()
  foreach ($extension in @(Get-SuperBrainExtensionManifests @() $Root | Sort-Object { [string]$_.id })) {
    if ($extension.PSObject.Properties['catalogVisibility'] -and [string]$extension.catalogVisibility -eq 'internal') { continue }
    $summary = ''
    foreach ($property in @('summary','description','installNote','setupRequired')) {
      if ($extension.PSObject.Properties[$property] -and -not [string]::IsNullOrWhiteSpace([string]$extension.$property)) {
        $summary = [string]$extension.$property
        break
      }
    }
    if ([string]::IsNullOrWhiteSpace($summary)) { $summary = 'Bundled extension skills.' }
    $catalog += [pscustomobject]@{
      id = [string]$extension.id
      name = [string]$extension.name
      summary = $summary
      defaultEnabled = [bool]$extension.defaultEnabled
      skillCount = @($extension.skills).Count
      skills = @($extension.skills | ForEach-Object { [string]$_.name })
      setupRequired = if ($extension.PSObject.Properties['setupRequired']) { [string]$extension.setupRequired } else { '' }
      installNote = if ($extension.PSObject.Properties['installNote']) { [string]$extension.installNote } else { '' }
    }
  }
  return @($catalog)
}

function Resolve-SuperBrainExtensionIds([string[]]$Extensions = @(), [string]$Root = $SuperBrainRoot) {
  $catalog = @(Get-SuperBrainExtensionCatalog $Root)
  $known = @{}
  foreach ($item in $catalog) { $known[[string]$item.id.ToLowerInvariant()] = [string]$item.id }
  $selected = @()
  $unknown = @()
  $seen = @{}
  foreach ($extensionId in @($Extensions)) {
    $value = ([string]$extensionId).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    $key = $value.ToLowerInvariant()
    if (-not $known.ContainsKey($key)) { $unknown += $value; continue }
    if (-not $seen.ContainsKey($key)) {
      $seen[$key] = $true
      $selected += $known[$key]
    }
  }
  if ($unknown.Count -gt 0) { throw "EXTENSION_ID_UNKNOWN: $($unknown -join ', '). Available: $(@($catalog | ForEach-Object { $_.id }) -join ', ')" }
  return @($selected)
}

function Get-SuperBrainHostAdapterItems {
  # Super Memory Brain is the only host-facing adapter. All other modules and
  # extension sources are package-owned cold capabilities and must never be
  # copied into an agent's top-level skill catalog.
  $items = @(
    @{ name='super-memory-brain'; source='super-memory-brain' }
  )
  return @($items)
}

function Get-SuperBrainSourceItems {
  [CmdletBinding()]
  param(
    [string[]]$Extensions = @()
  )

  # Compatibility wrapper for callers that still use the historical helper.
  # An extension selector must never turn a package-owned cold source into a
  # host skill install candidate.
  $requestedExtensions = @($Extensions | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  if ($requestedExtensions.Count -gt 0) {
    throw ('ABSORBED_PROVENANCE_ONLY_NO_STANDALONE_INSTALL: -Extensions selects package-owned cold provenance only, not host skills. Requested: ' + ($requestedExtensions -join ', ') + '. Install or refresh super-memory-brain without -Extensions.')
  }
  return @(Get-SuperBrainHostAdapterItems)
}

function Write-SuperBrainMemoryScope([string]$MemoryRoot, [string]$Scope, [string[]]$Members = @(), [string]$Root = $SuperBrainRoot) {
  $MemoryRoot = Resolve-SuperBrainActiveMemoryRoot -Root $Root -Candidate $MemoryRoot -Operation 'write-memory-scope'
  $scopeInfo = [pscustomobject]@{
    scope = $Scope
    members = @($Members)
    packageRoot = (Get-NormalizedSuperBrainRoot $Root)
    memoryRoot = (Get-NormalizedSuperBrainRoot $MemoryRoot)
    updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  }
  Write-JsonUtf8NoBom (Join-Path $MemoryRoot '.memory-scope.json') $scopeInfo 6
}

function Initialize-SuperBrainMemoryRoot([string]$MemoryRoot, [string]$Root = $SuperBrainRoot, [string]$Scope = 'custom', [string[]]$Members = @()) {
  $MemoryRoot = Resolve-SuperBrainActiveMemoryRoot -Root $Root -Candidate $MemoryRoot -Operation 'initialize-memory-root'
  New-Item -ItemType Directory -Force -Path $MemoryRoot,(Join-Path $MemoryRoot 'persona'),(Join-Path $MemoryRoot 'archive') | Out-Null
  foreach ($seed in @('sandglass.txt','decision_particles.txt')) {
    $seedPath = Join-Path $MemoryRoot $seed
    if (-not (Test-Path -LiteralPath $seedPath -PathType Leaf)) {
      Write-Utf8NoBom $seedPath ''
    }
  }
  Write-SuperBrainMemoryScope $MemoryRoot $Scope $Members $Root
}

function Write-SuperBrainPackageRootMarker([string]$SkillDir, [string]$Root = $SuperBrainRoot) {
  $normalized = Get-NormalizedSuperBrainRoot $Root
  if (-not (Test-Path -LiteralPath $normalized)) { throw "PACKAGE_ROOT_MARKER_SOURCE_MISSING: $normalized" }
  $path = Join-Path $SkillDir 'package-root.txt'
  Write-Utf8NoBom $path ($normalized + "`n")
  $written = ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)).Trim()
  if (-not (Test-SuperBrainSamePath $written $normalized)) { throw "PACKAGE_ROOT_MARKER_VERIFY_FAILED: $path" }
}

function Write-SuperBrainMemoryRootMarker([string]$SkillDir, [string]$MemoryRoot, [string]$Root = $SuperBrainRoot) {
  $normalized = Resolve-SuperBrainActiveMemoryRoot -Root $Root -Candidate $MemoryRoot -Operation 'write-memory-root-marker'
  if (-not (Test-Path -LiteralPath $normalized)) { throw "MEMORY_ROOT_MARKER_SOURCE_MISSING: $normalized" }
  $path = Join-Path $SkillDir 'memory-root.txt'
  Write-Utf8NoBom $path ($normalized + "`n")
  $written = ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)).Trim()
  if (-not (Test-SuperBrainSamePath $written $normalized)) { throw "MEMORY_ROOT_MARKER_VERIFY_FAILED: $path" }
}

function Get-SuperBrainRuntimeReadiness {
  [CmdletBinding()]
  param(
    [bool]$EntryAdapterReady,
    [bool]$MemoryRootReady,
    [bool]$McpBindingReady,
    [Alias('McpFunctionalReady')]
    [bool]$McpLiveHandshakeReady,
    [bool]$ActivationCoreReady,
    [bool]$CliRuntimeReady = $false
  )

  $mcpRuntimeReady = ($McpBindingReady -and $McpLiveHandshakeReady)
  $transportReady = ($mcpRuntimeReady -or $CliRuntimeReady)
  $coreRuntimeReady = ($MemoryRootReady -and $transportReady -and $ActivationCoreReady)
  # Host adapters are optional projections.  Their absence must never turn a
  # healthy H7 runtime into a user-visible degraded Super Brain state.
  $adapterState = if ($EntryAdapterReady) { 'ready' } else { 'optional_missing' }
  $availability = if ($coreRuntimeReady) { 'full' } else { 'withheld' }
  $action = if (-not $MemoryRootReady) { 'repair_memory_root' } elseif (-not $transportReady) { 'repair_mcp_on_first_load' } elseif (-not $ActivationCoreReady) { 'inspect_activation' } else { 'ready' }
  return [pscustomobject]@{
    ok = [bool]$coreRuntimeReady
    coreRuntimeReady = [bool]$coreRuntimeReady
    adapterRequired = $false
    adapterState = $adapterState
    availability = $availability
    transport = if ($mcpRuntimeReady) { 'h7_mcp' } elseif ($CliRuntimeReady) { 'h7_cli' } else { 'withheld' }
    action = $action
  }
}

function Get-SuperBrainMcpProbeAssessment {
  [CmdletBinding()]
  param(
    [bool]$StaticBindingOk,
    [bool]$LegacyBindingMatches,
    [object]$RecordedLegacyHandshake = $null
  )

  # The production MCP runs as a local Broker-backed stdio process.  Its
  # initialize/status handshake is process-local and deliberately does not
  # update the legacy deployment binding file.  A static bootstrap therefore
  # cannot turn a v1 binding record into live proof, nor may it prescribe an
  # app restart merely because that record has no old-style handshake.
  $recordedLegacy = $null -ne $RecordedLegacyHandshake
  if (-not $StaticBindingOk) {
    return [pscustomobject]@{
      configurationState = 'configuration_missing_or_stale'
      liveHandshakeState = 'configuration_missing_or_stale'
      executionReady = $false
      executionState = 'configuration_missing_or_stale'
      executionProbe = 'Repair the one registered Super Brain MCP entry, then call brain_status from Codex.'
      action = 'repair_mcp_registration'
      availability = 'withheld'
      recordedLegacyHandshake = $recordedLegacy
      legacyBindingMatches = $LegacyBindingMatches
    }
  }
  return [pscustomobject]@{
    configurationState = if ($LegacyBindingMatches) { 'configuration_current' } else { 'configuration_current_legacy_metadata_unobserved' }
    liveHandshakeState = 'runtime_probe_required'
    executionReady = $false
    executionState = 'runtime_probe_required'
    executionProbe = 'Call the registered MCP brain_status; require runtimeIdentity.state=current, liveMcpHandshake.state=current, mcpRuntimeBinding.state=current, and runtimeMode=local_stdio_scope_broker.'
    action = 'verify_live_mcp_in_codex'
    availability = 'h7_cli_ready_mcp_probe_required'
    recordedLegacyHandshake = $recordedLegacy
    legacyBindingMatches = $LegacyBindingMatches
  }
}

function Get-SuperBrainGlobalStartupMaxChars() { return 0 }

function Get-SuperBrainGlobalStartupBlock([string]$Root = $SuperBrainRoot) {
  $gitHow = -join [char[]]@(24590,20040,20889)
  $gitWhat = -join [char[]]@(21602)
  $howCommit = -join [char[]]@(24590,20040,25552,20132)
  $lines = @(
    '<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_START -->',
    '## Super Memory Brain Bootstrap',
    '',
    '- Entry: explicit Super Brain/G1 or semantic governed task intent (progress/status/next step/continuation/recovery/recall/learning/repair/maintenance), or the configured git workflow phrases load `super-memory-brain`; literal naming is not required, then use H7 `brain_turn`.',
    ('- Git workflow trigger: `git' + $gitHow + '`/`git' + $gitWhat + '`/`' + $howCommit + '` routes to Super Brain canonical workflow handling.'),
    '- Authority: bootstrap only. All behavioral policy, priority, progress truth, and stage rules come solely from the package `super-brain-rules.json` and H7 contract/runtime; this file must never duplicate or override them.',
    '- Safety: Host transport is permanently retired. Never read, bind, wait for, retry, start, bridge, or persist Host tail, context, thread, readback, or metadata. Reject every legacy Host input immediately with `H7_HOST_TRANSPORT_RETIRED`; use only the current cwd, `SUPER_BRAIN_LOCAL_SESSION_ID`, scoped execution contract, current local progress receipt, and live project proof. If H7 MCP is unavailable, use the same H7 CLI; if no current scoped receipt is possible, block and repair. Never use Hook/P7 or summaries as a substitute.',
    '- Refresh: package marker resolves the current Super Brain root; refresh this bootstrap together with the one Super Brain adapter after a verified package update.',
    '',
    '## Browser Route',
    '',
    'Use Playwright for normal browser automation; load `browser-act` only on request or if Playwright cannot reliably complete visible state.',
    '<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_END -->'
  )
  $block = $lines -join "`r`n"
  $maxChars = Get-SuperBrainGlobalStartupMaxChars
  if ($maxChars -gt 0 -and $block.Length -gt $maxChars) { throw "SUPER_BRAIN_GLOBAL_STARTUP_TOO_LARGE: $($block.Length) > $maxChars" }
  return $block
}

function Get-SuperBrainAgentHomeFromSkillRoot([string]$SkillRoot) {
  if ([string]::IsNullOrWhiteSpace($SkillRoot)) { return '' }
  $full = Get-FullPath $SkillRoot
  $leaf = Split-Path -Leaf $full
  if ($leaf -ieq 'skills') { return Split-Path -Parent $full }
  return $full
}

function Get-SuperBrainGlobalStartupTargets([string]$SkillRoot, [switch]$ExistingOnly) {
  $agentHome = Get-SuperBrainAgentHomeFromSkillRoot $SkillRoot
  if ([string]::IsNullOrWhiteSpace($agentHome)) { return @() }
  $known = @('AGENTS.md','CLAUDE.md','GEMINI.md')
  $existing = @()
  foreach ($name in $known) {
    $path = Join-Path $agentHome $name
    if (Test-Path -LiteralPath $path) { $existing += $path }
  }
  if ($existing.Count -gt 0) { return @($existing | Select-Object -Unique) }
  if ($ExistingOnly) { return @() }
  return @((Join-Path $agentHome 'AGENTS.md'))
}

function Write-SuperBrainGlobalStartup([string]$SkillRoot, [string]$Root = $SuperBrainRoot, [switch]$NoBackup) {
  $targets = @(Get-SuperBrainGlobalStartupTargets $SkillRoot)
  $written = @()
  if ($targets.Count -eq 0) { return @() }
  $block = Get-SuperBrainGlobalStartupBlock $Root
  $pattern = '(?s)<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_START -->.*?<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_END -->'
  $legacyPattern = '(?s)\A# Codex Global Bootstrap\s+## Super Memory Brain Short Router.*?## Browser Route.*?(?=\r?\n\r?\n## Shiroyama Output Rule)'
  $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  foreach ($path in $targets) {
    $old = ''
    if (Test-Path -LiteralPath $path) {
      $old = Get-Content -LiteralPath $path -Raw -Encoding UTF8
      if (-not $NoBackup) { Copy-Item -LiteralPath $path -Destination "$path.bak-super-brain-bootstrap-$timestamp" -Force }
    }
    if ($old -match $legacyPattern) {
      $old = [regex]::Replace($old, $legacyPattern, "# Codex Global Bootstrap`r`n", 1)
    }
    if ($old -match $pattern) {
      $new = [regex]::Replace($old, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block }, 1)
    } elseif ([string]::IsNullOrWhiteSpace($old)) {
      $new = $block + "`r`n"
    } else {
      $new = $old.TrimEnd() + "`r`n`r`n" + $block + "`r`n"
    }
    Write-Utf8NoBom $path $new
    $written += $path
  }
  return @($written)
}

function Test-SuperBrainGlobalStartup([string]$SkillRoot, [switch]$OptionalWhenNoHostTarget) {
  # A secondary skill copy is managed only after its host instruction file contains
  # our bootstrap marker. Marker-only or unrelated legacy agent homes are discovery
  # candidates, not core startup dependencies for the active Codex/ZCode install.
  $existingTargets = @(Get-SuperBrainGlobalStartupTargets $SkillRoot -ExistingOnly)
  if ($OptionalWhenNoHostTarget -and $existingTargets.Count -eq 0) {
    return [pscustomobject]@{
      ok = $true
      applicable = $false
      skipped = $true
      reason = 'no_existing_host_startup_target'
      paths = @()
      expected = @()
      failed = @()
    }
  }

  if ($OptionalWhenNoHostTarget) {
    $secondaryBound = $false
    foreach ($path in $existingTargets) {
      try {
        if ((Get-Content -LiteralPath $path -Raw -Encoding UTF8).Contains('<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_START -->')) {
          $secondaryBound = $true
          break
        }
      } catch {}
    }
    if (-not $secondaryBound) {
      return [pscustomobject]@{
        ok = $true
        applicable = $false
        skipped = $true
        reason = 'secondary_host_bootstrap_not_bound'
        paths = @()
        expected = @($existingTargets)
        failed = @()
      }
    }
  }

  $targets = if ($existingTargets.Count -gt 0) { $existingTargets } else { @(Get-SuperBrainGlobalStartupTargets $SkillRoot) }
  $found = @()
  $failed = @()
  $expectedBlock = (Get-SuperBrainGlobalStartupBlock $SuperBrainRoot) -replace "`r`n?", "`n"
  foreach ($path in $targets) {
    if (-not (Test-Path -LiteralPath $path)) { $failed += [pscustomobject]@{ path=$path; reason='startup_target_missing' }; continue }
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $blockMatch = [regex]::Match($text, '(?s)<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_START -->.*?<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_END -->')
    $singleBlock = ([regex]::Matches($text, '<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_START -->')).Count -eq 1
    $singleRouter = ([regex]::Matches($text, '## Super Memory Brain Bootstrap')).Count -eq 1
    $withinBudget = $blockMatch.Success
    $actualBlock = if ($blockMatch.Success) { $blockMatch.Value -replace "`r`n?", "`n" } else { '' }
    # The generator is the single startup-contract authority. Do not keep a second,
    # hand-maintained keyword list here; that list drifts whenever the short router changes.
    $canonicalBlock = $blockMatch.Success -and ($actualBlock.TrimEnd() -eq $expectedBlock.TrimEnd())
    if ($singleBlock -and $singleRouter -and $withinBudget -and $canonicalBlock) {
      $found += $path
    } else {
      $reason = if (-not $blockMatch.Success) { 'startup_block_missing' }
      elseif (-not $singleBlock) { 'startup_block_duplicate' }
      elseif (-not $singleRouter) { 'startup_router_duplicate' }
      else { 'startup_generated_contract_mismatch' }
      $failed += [pscustomobject]@{ path=$path; reason=$reason }
    }
  }
  $isCurrent = ($targets.Count -gt 0 -and $found.Count -eq $targets.Count)
  return [pscustomobject]@{
    ok = $isCurrent
    applicable = $true
    skipped = $false
    reason = if ($isCurrent) { 'startup_generated_contract_current' } else { 'startup_generated_contract_invalid' }
    paths = @($found)
    expected = @($targets)
    failed = @($failed)
  }
}

function Test-SuperBrainInstalledForPackage([string]$SkillRoot, [string]$Root = $SuperBrainRoot) {
  if ([string]::IsNullOrWhiteSpace($SkillRoot)) { return $false }
  $marker = Join-Path $SkillRoot 'super-memory-brain\package-root.txt'
  if (-not (Test-Path -LiteralPath $marker)) { return $false }
  try {
    $actual = ([System.IO.File]::ReadAllText($marker, [System.Text.Encoding]::UTF8)).Trim()
    return ((Get-NormalizedSuperBrainRoot $actual) -eq (Get-NormalizedSuperBrainRoot $Root))
  } catch {
    return $false
  }
}

function Get-SuperBrainInstalledSkillRoots([string[]]$SeedRoots = @(), [string]$Root = $SuperBrainRoot) {
  $roots = @()
  foreach ($seed in @($SeedRoots)) {
    if (-not [string]::IsNullOrWhiteSpace($seed) -and (Test-SuperBrainInstalledForPackage -SkillRoot $seed -Root $Root)) { $roots += (Get-FullPath $seed) }
  }

  $profile = $env:USERPROFILE
  if (-not [string]::IsNullOrWhiteSpace($profile) -and (Test-Path -LiteralPath $profile)) {
    foreach ($dir in @(Get-ChildItem -LiteralPath $profile -Force -Directory -ErrorAction SilentlyContinue)) {
      $skillRoot = Join-Path $dir.FullName 'skills'
      if (Test-SuperBrainInstalledForPackage -SkillRoot $skillRoot -Root $Root) { $roots += (Get-FullPath $skillRoot) }
    }
  }

  return @($roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Get-SuperBrainAdrState([object[]]$DecisionNodes, [object]$Policy) {
  $validStatuses = if ($Policy.adr.statuses) { @($Policy.adr.statuses) } else { @('proposed','accepted','deprecated','superseded','rejected') }
  $currentStatuses = if ($Policy.adr.currentStatuses) { @($Policy.adr.currentStatuses) } else { @('proposed','accepted') }
  $requiredRelations = if ($Policy.adr.requiredRelations) { @($Policy.adr.requiredRelations) } else { @('decides','has_title','has_status','has_context','has_consequence') }
  $bySubject = @{}

  function Get-AdrMeta([string]$Subject) {
    if (-not $bySubject.ContainsKey($Subject)) {
      $bySubject[$Subject] = [pscustomobject]@{ subject=$Subject; relations=@{}; status=''; supersedes=@(); supersededBy=@(); isAdr=$false }
    }
    return $bySubject[$Subject]
  }

  foreach ($node in @($DecisionNodes)) {
    $subject = [string]$node.subject
    if ([string]::IsNullOrWhiteSpace($subject)) { continue }
    $meta = Get-AdrMeta $subject
    $tags = [string]$node.tags
    $relation = [string]$node.relation
    # A reverse supersession pointer may target a legacy non-ADR decision and is not an ADR schema root by itself.
    $isAdrSchemaRelation = $relation -in @('has_title','has_status','has_context','has_consequence','has_owner','affects','has_alternative')
    if (($tags.Contains('[ADR]') -and $relation -ne 'superseded_by') -or $isAdrSchemaRelation) { $meta.isAdr = $true }
    if (-not $meta.relations.ContainsKey($relation)) { $meta.relations[$relation] = @() }
    $meta.relations[$relation] = @($meta.relations[$relation] + [string]$node.object)
    if ($relation -eq 'has_status') { $meta.status = [string]$node.object }
    if ($relation -eq 'supersedes') { $meta.supersedes = @($meta.supersedes + [string]$node.object) }
    if ($relation -eq 'superseded_by') { $meta.supersededBy = @($meta.supersededBy + [string]$node.object) }
  }

  foreach ($node in @($DecisionNodes | Where-Object { [string]$_.relation -eq 'supersedes' })) {
    $oldSubject = [string]$node.object
    if ($oldSubject.StartsWith('decision:')) {
      $oldMeta = Get-AdrMeta $oldSubject
      $oldMeta.supersededBy = @($oldMeta.supersededBy + [string]$node.subject | Select-Object -Unique)
    }
  }

  $subjects = @($bySubject.Values | Where-Object { $_.isAdr })
  $missingSchema = @()
  $invalidStatus = @()
  $supersedesMissing = @()
  foreach ($adr in $subjects) {
    foreach ($relation in $requiredRelations) {
      if (-not $adr.relations.ContainsKey($relation) -or @($adr.relations[$relation]).Count -eq 0) { $missingSchema += "$($adr.subject):$relation" }
    }
    if ([string]::IsNullOrWhiteSpace([string]$adr.status) -or $validStatuses -notcontains [string]$adr.status) { $invalidStatus += "$($adr.subject):$($adr.status)" }
    foreach ($oldSubject in @($adr.supersedes)) {
      if (-not $bySubject.ContainsKey([string]$oldSubject)) { $supersedesMissing += "$($adr.subject)->$oldSubject" }
    }
  }
  $currentSubjects = @($subjects | Where-Object { $currentStatuses -contains [string]$_.status -and @($_.supersededBy).Count -eq 0 })
  $currentConflicts = @($currentSubjects | Group-Object subject | Where-Object { $_.Count -gt 1 })
  $supersededSubjects = @($subjects | Where-Object { @($_.supersededBy).Count -gt 0 -or [string]$_.status -eq 'superseded' })
  $schemaIssueCount = $missingSchema.Count + $invalidStatus.Count + $supersedesMissing.Count + $currentConflicts.Count
  return [pscustomobject]@{
    ok=($schemaIssueCount -eq 0)
    subjectCount=$subjects.Count
    currentCount=$currentSubjects.Count
    supersededCount=$supersededSubjects.Count
    schemaIssueCount=$schemaIssueCount
    missingSchema=@($missingSchema)
    invalidStatus=@($invalidStatus)
    supersedesMissing=@($supersedesMissing)
    currentConflictCount=$currentConflicts.Count
  }
}

function Test-SuperBrainRootMarker([string]$SkillDir, [string]$MarkerName, [string]$ExpectedRoot = '', [string[]]$RequiredChildren = @()) {
  $markerPath = Join-Path $SkillDir $MarkerName
  $exists = Test-Path $markerPath
  $actual = ''
  $matches = $true
  $targetOk = $false
  if ($exists) {
    try {
      $actual = ([System.IO.File]::ReadAllText($markerPath, [System.Text.Encoding]::UTF8)).Trim()
      if (-not [string]::IsNullOrWhiteSpace($actual)) { $actual = Get-NormalizedSuperBrainRoot $actual }
      if (-not [string]::IsNullOrWhiteSpace($ExpectedRoot)) { $matches = ($actual -eq (Get-NormalizedSuperBrainRoot $ExpectedRoot)) }
      $targetOk = Test-Path $actual
      foreach ($child in $RequiredChildren) {
        if (-not (Test-Path (Join-Path $actual $child))) { $targetOk = $false }
      }
    } catch { $actual = $_.Exception.Message }
  }
  return [pscustomobject]@{ ok=($exists -and $matches -and $targetOk); exists=$exists; matches=$matches; targetOk=$targetOk; marker=$markerPath; actual=$actual; expected=$ExpectedRoot }
}

function Test-SuperBrainPackageRootMarker([string]$SkillDir, [string]$Root = $SuperBrainRoot) {
  # Memory is an explicit, separately marked private-state root. The public
  # package root is CORE and must not require a second memory junction inside
  # the source tree.
  return Test-SuperBrainRootMarker $SkillDir 'package-root.txt' $Root @('manifest.json','scripts','runtime')
}

function Test-SuperBrainMemoryRootMarker([string]$SkillDir, [string]$Root = $SuperBrainRoot) {
  $expected = Get-SuperBrainActiveMemoryRoot $Root
  return Test-SuperBrainRootMarker $SkillDir 'memory-root.txt' $expected @('sandglass.txt')
}

function Get-SuperBrainHookPath([string]$HookPath = '') {
  if (-not [string]::IsNullOrWhiteSpace($HookPath)) {
    return Get-FullPath $HookPath
  }

  $hooksRoot = Join-Path $env:USERPROFILE '.zcode\cli\plugins\cache\zcode-plugins-official\superpowers'
  $candidates = @()
  if (Test-Path $hooksRoot) {
    $candidates = @(Get-ChildItem -LiteralPath $hooksRoot -Directory -ErrorAction SilentlyContinue |
      ForEach-Object {
        $path = Join-Path $_.FullName 'hooks\session-start'
        if (Test-Path $path) {
          [pscustomobject]@{ path = $path; version = $_.Name; modified = (Get-Item -LiteralPath $path).LastWriteTime }
        }
      })
  }

  if ($candidates.Count -gt 0) {
    foreach ($candidate in $candidates) {
      $versionText = $candidate.version -replace '[^0-9\.]',''
      try { $candidate | Add-Member -NotePropertyName parsedVersion -NotePropertyValue ([version]$versionText) -Force }
      catch { $candidate | Add-Member -NotePropertyName parsedVersion -NotePropertyValue ([version]'0.0.0') -Force }
    }
    return ($candidates | Sort-Object @{ Expression = 'parsedVersion'; Descending = $true }, @{ Expression = 'modified'; Descending = $true } | Select-Object -First 1).path
  }

  return Join-Path $hooksRoot '5.1.0\hooks\session-start'
}

function Limit-SuperBrainPacketText([string]$Value,[int]$Max=180) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $clean = ($Value.Trim() -replace '\s+',' ')
  if ($clean.Length -gt $Max) { return $clean.Substring(0,$Max) + '...' }
  return $clean
}

function Remove-SuperBrainExecutableActions([object]$Value) {
  if ($null -eq $Value) { return $null }
  if ($Value -is [string] -or $Value -is [System.ValueType]) { return $Value }
  if ($Value -is [System.Collections.IDictionary]) {
    $copy = [ordered]@{}
    foreach ($key in @($Value.Keys)) {
      $name = ([string]$key).ToLowerInvariant()
      if ($name -in @('nextaction','authorizednextaction','knownnextaction','phasenextaction','suggestednextaction','resumenextaction','currentaction','assistantcommitment','lastconfirmedsentence','currentstep','taskgoal','goal','summary','lastsummary')) { $copy[$key] = ''; continue }
      if ($name -in @('nextsteps','pendingsteps','recommendedactions','verificationcommands','commands','completedsteps','verificationresults','activechecklist','supersededcheckliststeps')) { $copy[$key] = @(); continue }
      if ($name -in @('hasconcretenextaction','claimallowed','planauthorized','mutationauthorized','worklinemutationauthorized','canresumeparent')) { $copy[$key] = $false; continue }
      if ($name -eq 'actionauthorization') { $copy[$key] = 'withheld'; continue }
      $copy[$key] = Remove-SuperBrainExecutableActions $Value[$key]
    }
    return [pscustomobject]$copy
  }
  if ($Value -is [System.Collections.IEnumerable]) {
    return @($Value | ForEach-Object { Remove-SuperBrainExecutableActions $_ })
  }
  $properties = @($Value.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty','Property','AliasProperty','ScriptProperty') })
  if ($properties.Count -eq 0) { return $Value }
  $result = [ordered]@{}
  foreach ($property in $properties) {
    $name = ([string]$property.Name).ToLowerInvariant()
    if ($name -in @('nextaction','authorizednextaction','knownnextaction','phasenextaction','suggestednextaction','resumenextaction','currentaction','assistantcommitment','lastconfirmedsentence','currentstep','taskgoal','goal','summary','lastsummary')) { $result[$property.Name] = ''; continue }
    if ($name -in @('nextsteps','pendingsteps','recommendedactions','verificationcommands','commands','completedsteps','verificationresults','activechecklist','checklist','activeworkpackagependingsteps','activeworkpackagecompletedsteps','activeworkpackagechecklist','supersededcheckliststeps')) { $result[$property.Name] = @(); continue }
    if ($name -in @('hasconcretenextaction','claimallowed','planauthorized','mutationauthorized','worklinemutationauthorized','canresumeparent')) { $result[$property.Name] = $false; continue }
    if ($name -eq 'actionauthorization') { $result[$property.Name] = 'withheld'; continue }
    $result[$property.Name] = Remove-SuperBrainExecutableActions $property.Value
  }
  return [pscustomobject]$result
}

function ConvertTo-SuperBrainCompactPlan([object]$Plan,[int]$NextActionMax=180) {
  if (-not $Plan) { return $null }
  return [pscustomobject]@{
    focusId = Limit-SuperBrainPacketText ([string]$Plan.focusId) 120
    focusLabel = Limit-SuperBrainPacketText ([string]$Plan.focusLabel) 100
    nextAction = Limit-SuperBrainPacketText ([string]$Plan.nextAction) $NextActionMax
    topicKeys = @($Plan.topicKeys | Select-Object -First 6 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 48 })
    priority = if ($Plan.priority) { [pscustomobject]@{ executionRank=[int]$Plan.priority.executionRank; source=Limit-SuperBrainPacketText ([string]$Plan.priority.source) 48; reason=Limit-SuperBrainPacketText ([string]$Plan.priority.reason) 100 } } else { $null }
    hasConcreteNextAction = [bool]$Plan.hasConcreteNextAction
  }
}

function ConvertTo-SuperBrainCompactStateCard([object]$Card) {
  if (-not $Card) { return $null }
  return [pscustomobject]@{
    schema = Limit-SuperBrainPacketText ([string]$Card.schema) 80
    taskId = Limit-SuperBrainPacketText ([string]$Card.taskId) 160
    workspaceKey = Limit-SuperBrainPacketText ([string]$Card.workspaceKey) 64
    revision = [int]$Card.revision
    stateFingerprint = Limit-SuperBrainPacketText ([string]$Card.stateFingerprint) 32
    mainLineId = Limit-SuperBrainPacketText ([string]$Card.mainLineId) 120
    activeLineId = Limit-SuperBrainPacketText ([string]$Card.activeLineId) 120
    activeLineLabel = Limit-SuperBrainPacketText ([string]$Card.activeLineLabel) 100
    parentLineId = Limit-SuperBrainPacketText ([string]$Card.parentLineId) 120
    lineRole = Limit-SuperBrainPacketText ([string]$Card.lineRole) 32
    instructionMode = Limit-SuperBrainPacketText ([string]$Card.instructionMode) 48
    phase = Limit-SuperBrainPacketText ([string]$Card.phase) 120
    currentStep = Limit-SuperBrainPacketText ([string]$Card.currentStep) 180
    completedSteps = @($Card.completedSteps | Select-Object -First 6 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 150 })
    pendingSteps = @($Card.pendingSteps | Select-Object -First 6 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 150 })
    activeChecklist = @($Card.activeChecklist | Select-Object -First 12 | ForEach-Object { [pscustomobject]@{ ordinal=[int]$_.ordinal; status=Limit-SuperBrainPacketText ([string]$_.status) 16; label=Limit-SuperBrainPacketText ([string]$_.label) 150 } })
    activeChecklistCount = if ($Card.PSObject.Properties['activeChecklistCount']) { [int]$Card.activeChecklistCount } else { @($Card.activeChecklist).Count }
    canonicalPlanId = if ($Card.PSObject.Properties['canonicalPlanId']) { Limit-SuperBrainPacketText ([string]$Card.canonicalPlanId) 80 } else { '' }
    canonicalGeneration = if ($Card.PSObject.Properties['canonicalGeneration']) { [int]$Card.canonicalGeneration } else { 0 }
    canonicalFingerprint = if ($Card.PSObject.Properties['canonicalFingerprint']) { Limit-SuperBrainPacketText ([string]$Card.canonicalFingerprint) 32 } else { '' }
    activeWorkPackageCompletedSteps = @($Card.activeWorkPackageCompletedSteps | Select-Object -First 6 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 150 })
    activeWorkPackagePendingSteps = @($Card.activeWorkPackagePendingSteps | Select-Object -First 6 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 150 })
    activeWorkPackageChecklist = @($Card.activeWorkPackageChecklist | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ ordinal=[int]$_.ordinal; status=Limit-SuperBrainPacketText ([string]$_.status) 16; label=Limit-SuperBrainPacketText ([string]$_.label) 140 } })
    activeWorkPackageChecklistCount = if ($Card.PSObject.Properties['activeWorkPackageChecklistCount']) { [int]$Card.activeWorkPackageChecklistCount } else { @($Card.activeWorkPackageChecklist).Count }
    checklistUpdateMode = Limit-SuperBrainPacketText ([string]$Card.checklistUpdateMode) 24
    blockers = @($Card.blockers | Select-Object -First 4 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 150 })
    evidence = @($Card.evidence | Select-Object -First 6 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 150 })
    verificationResults = @($Card.verificationResults | Select-Object -First 4 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 150 })
    nextAction = Limit-SuperBrainPacketText ([string]$Card.nextAction) 200
    assistantCommitment = Limit-SuperBrainPacketText ([string]$Card.assistantCommitment) 220
    lastConfirmedSentence = Limit-SuperBrainPacketText ([string]$Card.lastConfirmedSentence) 220
    lastConfirmedSource = Limit-SuperBrainPacketText ([string]$Card.lastConfirmedSource) 48
    constraints = @($Card.constraints | Select-Object -First 5 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 140 })
    acceptanceCriteria = @($Card.acceptanceCriteria | Select-Object -First 5 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 140 })
    priorityOrder = @($Card.priorityOrder | Select-Object -First 5 | ForEach-Object { [pscustomobject]@{ executionRank=[int]$_.executionRank; focusId=Limit-SuperBrainPacketText ([string]$_.focusId) 120; focusLabel=Limit-SuperBrainPacketText ([string]$_.focusLabel) 80; role=Limit-SuperBrainPacketText ([string]$_.role) 40; source=Limit-SuperBrainPacketText ([string]$_.source) 56 } })
    suspendedLineIds = @($Card.suspendedLineIds | Select-Object -First 4 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 120 })
    unfinishedLineIds = @($Card.unfinishedLineIds | Select-Object -First 6 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 120 })
    returnStack = @($Card.returnStack | Select-Object -First 4 | ForEach-Object { [pscustomobject]@{ focusId=Limit-SuperBrainPacketText ([string]$_.focusId) 120; focusLabel=Limit-SuperBrainPacketText ([string]$_.focusLabel) 80; currentPhase=Limit-SuperBrainPacketText ([string]$_.currentPhase) 100; currentStep=Limit-SuperBrainPacketText ([string]$_.currentStep) 140; nextAction=Limit-SuperBrainPacketText ([string]$_.nextAction) 140; pendingSteps=@($_.pendingSteps | Select-Object -First 3 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 120 }); blockers=@($_.blockers | Select-Object -First 2 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 120 }) } })
    latestMessageClassification = ConvertTo-SuperBrainCompactMessageClassification $Card.latestMessageClassification
    source = Limit-SuperBrainPacketText ([string]$Card.source) 100
    capturedAt = Limit-SuperBrainPacketText ([string]$Card.capturedAt) 48
  }
}

function ConvertTo-SuperBrainCompactMessageClassification([object]$Classification) {
  if (-not $Classification) { return $null }
  return [pscustomobject]@{
    mode = Limit-SuperBrainPacketText ([string]$Classification.mode) 48
    topicAffinity = Limit-SuperBrainPacketText ([string]$Classification.topicAffinity) 120
    targetLineId = Limit-SuperBrainPacketText ([string]$Classification.targetLineId) 120
    targetLineLabel = Limit-SuperBrainPacketText ([string]$Classification.targetLineLabel) 100
    confidence = Limit-SuperBrainPacketText ([string]$Classification.confidence) 32
    matchedKeys = @($Classification.matchedKeys | Select-Object -First 8 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 48 })
    candidateLineIds = @($Classification.candidateLineIds | Select-Object -First 6 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 120 })
    needsClarification = [bool]$Classification.needsClarification
    recommendedInstructionMode = Limit-SuperBrainPacketText ([string]$Classification.recommendedInstructionMode) 48
    reason = Limit-SuperBrainPacketText ([string]$Classification.reason) 180
    rawInstructionStored = [bool]$Classification.rawInstructionStored
  }
}

function ConvertTo-SuperBrainCompactWorkLineStatus([object]$Status) {
  if (-not $Status) { return $null }
  $activePlan = ConvertTo-SuperBrainCompactPlan $Status.activePlan 200
  $mainPlan = ConvertTo-SuperBrainCompactPlan $Status.mainPlan 160
  $nextPlan = ConvertTo-SuperBrainCompactPlan $Status.nextPlan 160
  $activePath = @()
  if ($Status.PSObject.Properties['lineage']) {
    $activePath = @($Status.lineage | Select-Object -First 5 | ForEach-Object { [pscustomobject]@{
      focusId = Limit-SuperBrainPacketText ([string]$_.focusId) 120
      label = Limit-SuperBrainPacketText ([string]$_.focusLabel) 80
      role = Limit-SuperBrainPacketText ([string]$_.role) 32
      status = Limit-SuperBrainPacketText ([string]$_.status) 24
    } })
  }
  return [pscustomobject]@{
    canonicalMain = if ($Status.PSObject.Properties['canonicalMain'] -and $Status.canonicalMain) { [pscustomobject]@{
      planId = Limit-SuperBrainPacketText ([string]$Status.canonicalMain.planId) 80
      generation = [int]$Status.canonicalMain.generation
      rootFocusId = Limit-SuperBrainPacketText ([string]$Status.canonicalMain.rootFocusId) 120
      currentFingerprint = Limit-SuperBrainPacketText ([string]$Status.canonicalMain.currentFingerprint) 32
      orderConfidence = Limit-SuperBrainPacketText ([string]$Status.canonicalMain.orderConfidence) 32
      itemCount = [int]$Status.canonicalMain.itemCount
      completedCount = [int]$Status.canonicalMain.completedCount
      pendingCount = [int]$Status.canonicalMain.pendingCount
      cancelledCount = [int]$Status.canonicalMain.cancelledCount
    } } else { $null }
    activeWorkPackage = if ($Status.PSObject.Properties['activeWorkPackage'] -and $Status.activeWorkPackage) { [pscustomobject]@{
      focusId = Limit-SuperBrainPacketText ([string]$Status.activeWorkPackage.focusId) 120
      focusLabel = Limit-SuperBrainPacketText ([string]$Status.activeWorkPackage.focusLabel) 100
      role = Limit-SuperBrainPacketText ([string]$Status.activeWorkPackage.role) 32
      status = Limit-SuperBrainPacketText ([string]$Status.activeWorkPackage.status) 24
      nextAction = Limit-SuperBrainPacketText ([string]$Status.activeWorkPackage.nextAction) 180
      checklistCount = [int]$Status.activeWorkPackage.checklistCount
    } } else { $null }
    mainLine = Limit-SuperBrainPacketText ([string]$Status.mainLine) 120
    activeLine = Limit-SuperBrainPacketText ([string]$Status.activeLine) 120
    currentLineCount = if ($Status.PSObject.Properties['currentLineCount']) { [int]$Status.currentLineCount } else { @($activePath).Count + @($Status.unfinishedLines).Count }
    lineageLineCount = if ($Status.PSObject.Properties['lineageLineCount']) { [int]$Status.lineageLineCount } else { @($activePath).Count }
    unfinishedLineCount = if ($Status.PSObject.Properties['unfinishedLineCount']) { [int]$Status.unfinishedLineCount } else { @($Status.unfinishedLines).Count }
    activePath = @($activePath)
    completedRecent = @($Status.completedRecent | Select-Object -First 6 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 120 })
    unfinishedLines = @($Status.unfinishedLines | Select-Object -First 6 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 120 })
    suspendedLines = @($Status.suspendedLines | Select-Object -First 4 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 120 })
    defaultNextLine = Limit-SuperBrainPacketText ([string]$Status.defaultNextLine) 120
    priorityPolicy = Limit-SuperBrainPacketText ([string]$Status.priorityPolicy) 120
    priorityOrder = @($Status.priorityOrder | Select-Object -First 4 | ForEach-Object { [pscustomobject]@{ executionRank=[int]$_.executionRank; focusId=Limit-SuperBrainPacketText ([string]$_.focusId) 120; focusLabel=Limit-SuperBrainPacketText ([string]$_.focusLabel) 80; role=Limit-SuperBrainPacketText ([string]$_.role) 48; source=Limit-SuperBrainPacketText ([string]$_.source) 64 } })
    activePlan = $activePlan
    mainPlan = $mainPlan
    nextPlan = $nextPlan
    suspendedPlans = @($Status.suspendedPlans | Select-Object -First 4 | ForEach-Object { ConvertTo-SuperBrainCompactPlan $_ 140 })
    unfinishedPlans = @($Status.unfinishedPlans | Select-Object -First 6 | ForEach-Object { ConvertTo-SuperBrainCompactPlan $_ 140 })
    latestMessageClassification = ConvertTo-SuperBrainCompactMessageClassification $Status.latestMessageClassification
    requiresUserDisambiguation = [bool]$Status.requiresUserDisambiguation
    planRecoveryRequired = [bool]$Status.planRecoveryRequired
    userView = [pscustomobject]@{
      main = if ($mainPlan) { [pscustomobject]@{ focusId=$mainPlan.focusId; label=$mainPlan.focusLabel; status=if([string]$Status.mainLine -eq [string]$Status.activeLine){'active'}else{'suspended'} } } else { $null }
      current = if ($activePlan) { [pscustomobject]@{ focusId=$activePlan.focusId; label=$activePlan.focusLabel; status='active'; role=if(@($Status.suspendedLines).Count -gt 0){'side_branch'}else{'main_line'} } } else { $null }
      currentLineCount = if ($Status.PSObject.Properties['currentLineCount']) { [int]$Status.currentLineCount } else { @($activePath).Count + @($Status.unfinishedLines).Count }
      path = @($activePath | ForEach-Object { [string]$_.label })
      directParent = if (@($activePath).Count -gt 1) { $activePath[-2] } else { $null }
    }
  }
}

function ConvertTo-SuperBrainCompactExecutionResolution([object]$Resolution) {
  if (-not $Resolution) { return $null }
  $result = [pscustomobject]@{
    ok = [bool]$Resolution.ok
    resumeFrom = [string]$Resolution.resumeFrom
    resolutionSource = Limit-SuperBrainPacketText ([string]$Resolution.resolutionSource) 64
    claimAllowed = [bool]$Resolution.claimAllowed
    needsConfirmation = [bool]$Resolution.needsConfirmation
    taskId = [string]$Resolution.taskId
    workspaceKey = [string]$Resolution.workspaceKey
    focusId = Limit-SuperBrainPacketText ([string]$Resolution.focusId) 120
    focusLabel = Limit-SuperBrainPacketText ([string]$Resolution.focusLabel) 100
    instructionMode = Limit-SuperBrainPacketText ([string]$Resolution.instructionMode) 48
    returnTo = if ($Resolution.returnTo) { [pscustomobject]@{ focusId=Limit-SuperBrainPacketText ([string]$Resolution.returnTo.focusId) 120; focusLabel=Limit-SuperBrainPacketText ([string]$Resolution.returnTo.focusLabel) 100; nextAction=Limit-SuperBrainPacketText ([string]$Resolution.returnTo.nextAction) 160 } } else { $null }
    canResumeParent = [bool]$Resolution.canResumeParent
    unfinishedWorkLines = @($Resolution.unfinishedWorkLines | Select-Object -First 6 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 120 })
    continuityStateCard = ConvertTo-SuperBrainCompactStateCard $Resolution.continuityStateCard
    workLineStatus = ConvertTo-SuperBrainCompactWorkLineStatus $Resolution.workLineStatus
    latestMessageClassification = ConvertTo-SuperBrainCompactMessageClassification $Resolution.latestMessageClassification
    nextAction = Limit-SuperBrainPacketText ([string]$Resolution.nextAction) 220
    contractRevision = [int]$Resolution.contractRevision
    planFingerprint = if ($Resolution.PSObject.Properties['planFingerprint']) { Limit-SuperBrainPacketText ([string]$Resolution.planFingerprint) 32 } else { '' }
    guard = Limit-SuperBrainPacketText ([string]$Resolution.guard) 220
    actionAuthorization = if ($Resolution.PSObject.Properties['actionAuthorization']) { [string]$Resolution.actionAuthorization } elseif ($Resolution.claimAllowed -eq $true -and $Resolution.needsConfirmation -ne $true) { 'allowed' } else { 'withheld' }
    sessionAccess = if ($Resolution.PSObject.Properties['sessionAccess']) { Limit-SuperBrainPacketText ([string]$Resolution.sessionAccess) 48 } else { '' }
    foreignContextDetected = ($Resolution.foreignContextDetected -eq $true)
    foreignContextSessionAccess = if ($Resolution.PSObject.Properties['foreignContextSessionAccess']) { Limit-SuperBrainPacketText ([string]$Resolution.foreignContextSessionAccess) 48 } else { '' }
  }
  $noContractApplies = ($result.resolutionSource -eq 'none' -and $result.actionAuthorization -eq 'not_applicable')
  if ($noContractApplies) {
    $result.claimAllowed = $true
    $result.needsConfirmation = $false
    $result.actionAuthorization = 'not_applicable'
    $result.canResumeParent = $false
  } elseif ($result.claimAllowed -ne $true -or $result.needsConfirmation -eq $true -or $result.actionAuthorization -ne 'allowed') {
    $result.claimAllowed = $false
    $result.needsConfirmation = $true
    $result.actionAuthorization = 'withheld'
    $result.canResumeParent = $false
    $result.returnTo = Remove-SuperBrainExecutableActions $result.returnTo
    $result.workLineStatus = Remove-SuperBrainExecutableActions $result.workLineStatus
  }
  return $result
}

function Get-SuperBrainPercentileMs([object[]]$Samples,[double]$Percentile=0.95) {
  $values = @($Samples | ForEach-Object {
    try { [double]$_ } catch { $null }
  } | Where-Object { $null -ne $_ -and $_ -ge 0 })
  if ($values.Count -eq 0) { return 0 }
  [Array]::Sort($values)
  $boundedPercentile = [Math]::Max(0.0, [Math]::Min(1.0, [double]$Percentile))
  $position = [int][Math]::Ceiling($values.Count * $boundedPercentile) - 1
  $index = [Math]::Max(0, [Math]::Min($values.Count - 1, $position))
  return ([int][Math]::Round($values[$index]))
}

function Get-SuperBrainOwnedProcessTree([int]$ProcessId) {
  $seen = @{}
  $pending = New-Object System.Collections.Queue
  $pending.Enqueue($ProcessId)
  while ($pending.Count -gt 0) {
    $current = [int]$pending.Dequeue()
    if ($seen.ContainsKey($current)) { continue }
    $seen[$current] = $true
    $children = @()
    try {
      $children = @(Get-CimInstance -ClassName Win32_Process -Filter ("ParentProcessId = {0}" -f $current) -ErrorAction Stop)
    } catch {
      try { $children = @(Get-WmiObject -Class Win32_Process -Filter ("ParentProcessId = {0}" -f $current) -ErrorAction Stop) } catch { $children = @() }
    }
    foreach ($child in @($children)) {
      if ($null -ne $child.ProcessId) { $pending.Enqueue([int]$child.ProcessId) }
    }
  }
  return @($seen.Keys | ForEach-Object { [int]$_ })
}

function Stop-SuperBrainOwnedProcessTree([int]$ProcessId) {
  $stopped = @()
  # Snapshot the complete owned tree before touching the root.  If the root is
  # killed first, a subsequent parent query can no longer discover descendants
  # and timeout cleanup may strand Python/Pester workers.
  $observedTree = @(Get-SuperBrainOwnedProcessTree $ProcessId)
  if ($observedTree.Count -eq 0) { $observedTree = @([int]$ProcessId) }
  $childFirst = @($observedTree | Where-Object { [int]$_ -ne [int]$ProcessId } | Sort-Object -Descending)
  foreach ($ownedId in $childFirst) {
    try {
      Stop-Process -Id ([int]$ownedId) -Force -ErrorAction Stop
      $stopped += [int]$ownedId
    } catch { }
  }
  try {
    Stop-Process -Id $ProcessId -Force -ErrorAction Stop
    $stopped += [int]$ProcessId
  } catch { }

  # CIM/WMI process-parent queries can be denied in restricted Desktop
  # sessions. Use taskkill only as a descendant-aware fallback after the
  # pre-captured child-first pass, then verify every observed PID.
  $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
  if (Test-Path -LiteralPath $taskkill -PathType Leaf) {
    try {
      & $taskkill /PID ([string]$ProcessId) /T /F 2>$null | Out-Null
    } catch { }
  }
  Start-Sleep -Milliseconds 80
  foreach ($ownedId in $observedTree) {
    try {
      Get-Process -Id ([int]$ownedId) -ErrorAction Stop | Out-Null
      # A process still present after taskkill is not reported as terminated.
    } catch {
      $stopped += [int]$ownedId
    }
  }
  return @($stopped | Sort-Object -Unique)
}

function Get-SuperBrainOwnedProcessOutputSnapshot {
  param([Parameter(Mandatory=$true)][object]$Handle)
  $stdout = if (Test-Path -LiteralPath $Handle.stdoutPath) { try { [System.IO.File]::ReadAllText($Handle.stdoutPath) } catch { '' } } else { '' }
  $stderr = if (Test-Path -LiteralPath $Handle.stderrPath) { try { [System.IO.File]::ReadAllText($Handle.stderrPath) } catch { '' } } else { '' }
  return [pscustomobject]@{ stdout=$stdout; stderr=$stderr; stdoutTruncated=$false; stderrTruncated=$false }
}

function Test-SuperBrainPersistentScriptMutation {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][string]$ScriptPath)

  # The manifest also contains the tiny Windows launchers (.bat/.vbs).  They
  # are not PowerShell source and therefore cannot be sent through the
  # PowerShell AST parser.  Analyze their small command surface directly so a
  # launcher remains covered without turning a valid wrapper into a parse
  # failure (or treating a legacy parser error as a mutation).
  $extension = [IO.Path]::GetExtension($ScriptPath).ToLowerInvariant()
  if ($extension -in @('.bat','.cmd','.vbs')) {
    try {
      $text = [IO.File]::ReadAllText([IO.Path]::GetFullPath($ScriptPath), [Text.Encoding]::UTF8)
    } catch {
      return [pscustomobject]@{ ok=$false; code='SUPER_BRAIN_SCRIPT_MUTATION_READ_INVALID'; mutations=@(); parseErrors=@([string]$_.Exception.Message); language=$extension.TrimStart('.') }
    }
    $patterns = if ($extension -eq '.vbs') {
      @('(?im)\b(?:DeleteFile|MoveFile|CopyFile|CreateTextFile|OpenTextFile)\b')
    } else {
      @('(?im)^\s*(?:del|erase|rd|rmdir|move|copy|xcopy|robocopy)\b')
    }
    $mutations = @()
    foreach ($pattern in $patterns) {
      foreach ($match in [regex]::Matches($text, $pattern)) {
        $mutations += [pscustomobject]@{ command=[string]$match.Value.Trim(); extent=[string]$match.Value.Trim() }
      }
    }
    return [pscustomobject]@{
      ok=$true
      code='SUPER_BRAIN_LAUNCHER_MUTATION_ANALYSIS_CURRENT'
      mutations=@($mutations)
      parseErrors=@()
      language=$extension.TrimStart('.')
    }
  }
  if ($extension -ne '.ps1') {
    return [pscustomobject]@{ ok=$false; code='SUPER_BRAIN_SCRIPT_MUTATION_LANGUAGE_UNSUPPORTED'; mutations=@(); parseErrors=@("Unsupported script extension: $extension"); language=$extension.TrimStart('.') }
  }

  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile(
    [IO.Path]::GetFullPath($ScriptPath),
    [ref]$tokens,
    [ref]$errors
  )
  if (@($errors).Count -gt 0) {
    return [pscustomobject]@{ ok=$false; code='SUPER_BRAIN_SCRIPT_MUTATION_PARSE_INVALID'; mutations=@(); parseErrors=@($errors | ForEach-Object { [string]$_.Message }) }
  }

  $mutatingCommands = @('Remove-Item','Set-Content','Add-Content','Copy-Item','New-Item','Compress-Archive')
  $mutations = @()
  foreach ($command in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))) {
    $name = [string]$command.GetCommandName()
    if ($mutatingCommands -notcontains $name) { continue }
    $elements = @($command.CommandElements)
    $targets = @($elements | Select-Object -Skip 1 | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] })
    # PowerShell's AST represents a parameter value as a separate command
    # element on Windows PowerShell 5.1.  Treating every non-parameter element
    # as a target therefore mistakes e.g. ``SilentlyContinue`` for a path in
    # ``Remove-Item Env:\NAME -ErrorAction SilentlyContinue``.  The narrow
    # environment-only exemption must inspect the first actual Remove-Item
    # target, not unrelated option values.  Dynamic or ambiguous targets remain
    # mutations and fail closed.
    $firstRemoveItemTarget = $null
    if ($name -eq 'Remove-Item') {
      $targetParameterNames = @('path','literalpath')
      $switchParameterNames = @('force','recurse','confirm','whatif','verbose','debug','usetransaction')
      for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
          $parameterName = ([string]$element.ParameterName).ToLowerInvariant()
          if ($targetParameterNames -contains $parameterName) {
            if (($index + 1) -lt $elements.Count -and $elements[$index + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
              $firstRemoveItemTarget = $elements[$index + 1]
              break
            }
            continue
          }
          if ($switchParameterNames -notcontains $parameterName -and ($index + 1) -lt $elements.Count -and $elements[$index + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            # This is a non-target parameter value such as -ErrorAction
            # SilentlyContinue; skip it before looking for the positional path.
            $index++
          }
          continue
        }
        $firstRemoveItemTarget = $element
        break
      }
    }
    $ephemeralEnvironmentOnly = (
      $name -eq 'Remove-Item' -and
      $null -ne $firstRemoveItemTarget -and
      (([string]$firstRemoveItemTarget.Extent.Text).Trim().Trim('"',"'") -match '^(?i:env):\\')
    )
    if ($ephemeralEnvironmentOnly) { continue }
    $mutations += [pscustomobject]@{ command=$name; extent=[string]$command.Extent.Text }
  }
  return [pscustomobject]@{ ok=$true; code='SUPER_BRAIN_SCRIPT_MUTATION_ANALYSIS_CURRENT'; mutations=@($mutations); parseErrors=@() }
}

function Start-SuperBrainOwnedProcess {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string]$ArgumentLine = '',
    [string]$WorkingDirectory = ''
  )

  $token = [guid]::NewGuid().ToString('n')
  $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("super-brain-process-$token.stdout.txt")
  $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("super-brain-process-$token.stderr.txt")
  $stdoutSink = $null
  $stderrSink = $null
  $stdoutPump = $null
  $stderrPump = $null
  $process = $null
  $started = $false
  $startError = ''
  $watch = [Diagnostics.Stopwatch]::StartNew()
  try {
    # Desktop Codex can provide both Path and PATH. Start-Process builds a
    # case-insensitive environment dictionary and fails before launching; the
    # .NET process API inherits the Windows environment without that collision.
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $ArgumentLine
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $startInfo.WorkingDirectory = $WorkingDirectory }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stdoutSink = [System.IO.File]::Open($stdoutPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::ReadWrite)
    $stderrSink = [System.IO.File]::Open($stderrPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::ReadWrite)
    $started = [bool]$process.Start()
    if ($started) {
      # Do not use PowerShell event callbacks here: they can crash Windows
      # PowerShell 5.1 when callbacks cross the process-reader thread. The
      # .NET copy tasks continuously drain both pipes into owned temp files,
      # preserving incremental progress reads without a pipe-buffer deadlock.
      $stdoutPump = $process.StandardOutput.BaseStream.CopyToAsync($stdoutSink)
      $stderrPump = $process.StandardError.BaseStream.CopyToAsync($stderrSink)
    }
  } catch {
    $startError = $_.Exception.Message
    if ($started -and $null -ne $process) { try { $process.Kill() } catch { } }
    if ($null -ne $stdoutSink) { try { $stdoutSink.Dispose() } catch { } }
    if ($null -ne $stderrSink) { try { $stderrSink.Dispose() } catch { } }
    Remove-Item -LiteralPath $stdoutPath,$stderrPath -Force -ErrorAction SilentlyContinue
    $started = $false
  }
  return [pscustomobject]@{
    started = $started
    process = $process
    processId = if ($null -ne $process) { [int]$process.Id } else { 0 }
    startError = $startError
    stdoutPath = $stdoutPath
    stderrPath = $stderrPath
    stdoutSink = $stdoutSink
    stderrSink = $stderrSink
    stdoutPump = $stdoutPump
    stderrPump = $stderrPump
    watch = $watch
  }
}

function Complete-SuperBrainOwnedProcess {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][object]$Handle,
    [switch]$TimedOut,
    [int]$TimeoutSeconds = 0
  )

  $process = $Handle.process
  $timedOut = [bool]$TimedOut
  $terminatedProcessIds = @()
  $exitCode = -1
  $stdout = ''
  $stderr = ''
  $stdoutTruncated = $false
  $stderrTruncated = $false
  $processExited = $false
  try {
    if ($null -ne $process) {
      $hasExited = $false
      try { $process.Refresh(); $hasExited = [bool]$process.HasExited } catch { }
      if ($timedOut -and -not $hasExited) {
        $terminatedProcessIds = @(Stop-SuperBrainOwnedProcessTree $process.Id)
        try { $hasExited = [bool]$process.WaitForExit(5000) } catch { $hasExited = $false }
        if (-not $hasExited) {
          try { $process.Kill() } catch { }
          try { $hasExited = [bool]$process.WaitForExit(1000) } catch { $hasExited = $false }
        }
      } elseif ($hasExited) {
        try { $process.WaitForExit() } catch { }
      } else {
        try { $hasExited = [bool]$process.WaitForExit(5000) } catch { $hasExited = $false }
      }
      $processExited = $hasExited
      if ($hasExited) { try { $exitCode = [int]$process.ExitCode } catch { $exitCode = -1 } }
    }
  } finally {
    if ($Handle.watch) { try { $Handle.watch.Stop() } catch { } }
    foreach ($pump in @($Handle.stdoutPump,$Handle.stderrPump)) {
      if ($null -ne $pump) { try { [void]$pump.Wait(2000) } catch { } }
    }
    foreach ($sink in @($Handle.stdoutSink,$Handle.stderrSink)) {
      if ($null -ne $sink) { try { $sink.Dispose() } catch { } }
    }
    $snapshot = Get-SuperBrainOwnedProcessOutputSnapshot $Handle
    $stdout = [string]$snapshot.stdout
    $stderr = [string]$snapshot.stderr
    $stdoutTruncated = [bool]$snapshot.stdoutTruncated
    $stderrTruncated = [bool]$snapshot.stderrTruncated
    Remove-Item -LiteralPath $Handle.stdoutPath,$Handle.stderrPath -Force -ErrorAction SilentlyContinue
  }
  return [pscustomobject]@{
    started = [bool]$Handle.started
    processId = [int]$Handle.processId
    exitCode = $exitCode
    timedOut = $timedOut
    timeoutSeconds = $TimeoutSeconds
    durationMs = if ($Handle.watch) { [int]$Handle.watch.ElapsedMilliseconds } else { 0 }
    terminatedProcessIds = @($terminatedProcessIds)
    startError = [string]$Handle.startError
    stdout = $stdout
    stderr = $stderr
    stdoutTruncated = $stdoutTruncated
    stderrTruncated = $stderrTruncated
    processExited = $processExited
  }
}

function Invoke-SuperBrainOwnedProcess {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string]$ArgumentLine = '',
    [string]$WorkingDirectory = '',
    [int]$TimeoutSeconds = 0
  )

  $handle = Start-SuperBrainOwnedProcess -FilePath $FilePath -ArgumentLine $ArgumentLine -WorkingDirectory $WorkingDirectory
  if (-not $handle.started) { return (Complete-SuperBrainOwnedProcess -Handle $handle -TimeoutSeconds $TimeoutSeconds) }
  while ($true) {
    $hasExited = $false
    try { $handle.process.Refresh(); $hasExited = [bool]$handle.process.HasExited } catch { $hasExited = $true }
    if ($hasExited) { return (Complete-SuperBrainOwnedProcess -Handle $handle -TimeoutSeconds $TimeoutSeconds) }
    if ($TimeoutSeconds -gt 0 -and $handle.watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
      return (Complete-SuperBrainOwnedProcess -Handle $handle -TimedOut -TimeoutSeconds $TimeoutSeconds)
    }
    Start-Sleep -Milliseconds 100
  }
}


