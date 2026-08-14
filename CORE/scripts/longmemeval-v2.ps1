[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Status','Prepare','FetchTextData','PrepareHoldout','HoldoutStatus','MarkHoldoutIncomplete','MarkHoldoutComplete')]
  [string]$Action = 'Status',
  [string]$HarnessRoot = '',
  [string]$DataRoot = '',
  [string]$PythonPath = '',
  [ValidateSet('web','enterprise')]
  [string]$HoldoutDomain = 'web',
  [ValidateRange(1,12)]
  [int]$HoldoutPerQuestionType = 4,
  [string]$HoldoutOutputDir = '',
  [string]$HoldoutRegistryPath = '',
  [string]$HoldoutSetHash = '',
  [string]$HoldoutIncompleteReason = 'bridge_incomplete_response',
  [string]$HoldoutEvidenceHash = '',
  [string[]]$ExcludeQuestionPath = @(),
  [switch]$Apply,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$stateRoot = Get-SuperBrainMemoryBaseRoot $Root
$workspace = Join-Path $stateRoot 'workspace'
$externalRoot = Join-Path $workspace 'external-harness'
if ([string]::IsNullOrWhiteSpace($HarnessRoot)) { $HarnessRoot = Join-Path $externalRoot 'LongMemEval-V2' }
if ([string]::IsNullOrWhiteSpace($DataRoot)) { $DataRoot = Join-Path $externalRoot 'LongMemEval-V2-data' }
$HarnessRoot = [IO.Path]::GetFullPath($HarnessRoot)
$DataRoot = [IO.Path]::GetFullPath($DataRoot)
$venvRoot = Join-Path $externalRoot 'LongMemEval-V2-python311'
$venvPython = Join-Path $venvRoot 'Scripts\python.exe'
$privatePythonRuntimeRoot = Join-Path $externalRoot 'LongMemEval-V2-python311-runtime'
$privatePythonRuntime = Join-Path $privatePythonRuntimeRoot 'python.exe'
$privatePythonManifestPath = Join-Path $privatePythonRuntimeRoot 'super-brain-python-runtime.json'
$bootstrapCacheRoot = Join-Path $externalRoot 'bootstrap-cache'
$pythonInstallerVersion = '3.11.9'
$pythonInstallerUri = 'https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe'
$pythonInstallerSha256 = '5ee42c4eee1e6b4464bb23722f90b45303f79442df63083f05322f1785f5fdde'
$pythonInstallerPath = Join-Path $bootstrapCacheRoot 'python-3.11.9-amd64.exe'
$sourceManifestPath = Join-Path $DataRoot 'super-brain-source-manifest.json'
$phase8Root = Join-Path $workspace 'phase8-longmemeval-v2'
$holdoutRoot = Join-Path $phase8Root 'holdouts'
$holdoutSelectorPath = Join-Path $Root 'runtime\longmemeval_v2_holdout.py'
$officialRepo = 'https://github.com/xiaowu0162/LongMemEval-V2'
$officialCommit = '6f020ac2fc3275e46c706d3406e02c3ed79b7be2'
$officialDataset = 'xiaowu0162/longmemeval-v2'
$officialDatasetRevision = 'f152293e235517d504809563c833d7190b8c713b'
$requiredTextFiles = @('questions.jsonl','trajectories.jsonl','haystacks\lme_v2_small.json','checksums.sha256')
$fullTrajectoryBytes = [int64]1195604539
$fullTrajectoryScreenshotBytes = [int64](3354163660 + 2562302847)

function Write-LmeV2Result($Value,[int]$ExitCode=0) {
  if ($Json) { $Value | ConvertTo-Json -Depth 20 }
  elseif ($Value.ok) { Write-Host "LONGMEMEVAL_V2 action=$Action status=$($Value.status)" }
  else { Write-Host "LONGMEMEVAL_V2_FAILED code=$($Value.code)" }
  exit $ExitCode
}

function ConvertFrom-LmeV2FinalJsonLine([object[]]$Lines) {
  for ($index = $Lines.Count - 1; $index -ge 0; $index--) {
    $candidate = ([string]$Lines[$index]).Trim()
    if (-not $candidate.StartsWith('{')) { continue }
    try { return ($candidate | ConvertFrom-Json) } catch {}
  }
  throw 'LME_V2_DATA_FETCH_RESULT_MISSING'
}

function Get-LmeV2Python([string]$RequestedPath) {
  $candidates = New-Object System.Collections.ArrayList
  if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) { [void]$candidates.Add([pscustomobject]@{ path=[IO.Path]::GetFullPath($RequestedPath); source='explicit_path' }) }
  if (Test-Path -LiteralPath $venvPython -PathType Leaf) { [void]$candidates.Add([pscustomobject]@{ path=$venvPython; source='private_venv' }) }
  if (Test-Path -LiteralPath $privatePythonRuntime -PathType Leaf) { [void]$candidates.Add([pscustomobject]@{ path=$privatePythonRuntime; source='private_runtime' }) }
  $pyCommand = Get-Command py -ErrorAction SilentlyContinue
  if ($pyCommand) {
    try {
      $path = @(& $pyCommand.Source -3.11 -c 'import sys; print(sys.executable)' 2>$null | Select-Object -Last 1)[0]
      if (-not [string]::IsNullOrWhiteSpace([string]$path)) { [void]$candidates.Add([pscustomobject]@{ path=[string]$path; source='py_launcher' }) }
    } catch {}
  }
  foreach ($candidate in @($candidates | Sort-Object path -Unique)) {
    if (-not (Test-Path -LiteralPath $candidate.path -PathType Leaf)) { continue }
    try {
      # Windows PowerShell strips embedded double quotes when passing native -c arguments.
      $version = @(& $candidate.path -c 'import sys; print(''%d.%d.%d'' % sys.version_info[:3])' 2>$null | Select-Object -Last 1)[0]
      if ([string]$version -match '^3\.11\.\d+$') { return [pscustomobject]@{ found=$true; path=[IO.Path]::GetFullPath($candidate.path); version=[string]$version; officialCompatible=$true; source=[string]$candidate.source } }
    } catch {}
  }
  return [pscustomobject]@{ found=$false; path=''; version=''; officialCompatible=$false; source='missing' }
}

function Get-LmeV2PrivateRuntimeState {
  $manifest = $null
  if (Test-Path -LiteralPath $privatePythonManifestPath -PathType Leaf) {
    try { $manifest = Get-Content -LiteralPath $privatePythonManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  }
  $version = ''
  if (Test-Path -LiteralPath $privatePythonRuntime -PathType Leaf) {
    try { $version = [string](@(& $privatePythonRuntime -c 'import sys; print(''%d.%d.%d'' % sys.version_info[:3])' 2>$null | Select-Object -Last 1)[0]) } catch {}
  }
  return [pscustomobject]@{
    root=$privatePythonRuntimeRoot
    pythonPath=$privatePythonRuntime
    present=(Test-Path -LiteralPath $privatePythonRuntime -PathType Leaf)
    version=$version
    officialCompatible=($version -match '^3\.11\.\d+$')
    manifest=$manifest
    installer=[pscustomobject]@{ version=$pythonInstallerVersion; uri=$pythonInstallerUri; sha256=$pythonInstallerSha256; cachePath=$pythonInstallerPath }
    autoBootstrapAvailable=$true
  }
}

function Get-LmeV2InstallerSignature([string]$Path) {
  try {
    $signature = Get-AuthenticodeSignature -FilePath $Path
    return [pscustomobject]@{
      status=[string]$signature.Status
      subject=if($signature.SignerCertificate){[string]$signature.SignerCertificate.Subject}else{''}
      valid=($signature.Status -eq 'Valid' -and $signature.SignerCertificate -and [string]$signature.SignerCertificate.Subject -match 'Python Software Foundation')
    }
  } catch {
    return [pscustomobject]@{ status='unavailable'; subject=''; valid=$false }
  }
}

function Invoke-LmeV2PrivatePythonBootstrap {
  if (-not $Apply) {
    return [pscustomobject]@{ ok=$false; code='LME_V2_APPLY_REQUIRED'; status='preview_only'; nextAction='Rerun Prepare with -Apply to acquire the hash-verified private Python 3.11 runtime.' }
  }
  $runtime = Get-LmeV2PrivateRuntimeState
  if ($runtime.officialCompatible) {
    return [pscustomobject]@{ ok=$true; status='private_runtime_ready'; runtime=$runtime; reused=$true }
  }
  if ((Test-Path -LiteralPath $privatePythonRuntimeRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $privatePythonRuntimeRoot -Force -ErrorAction SilentlyContinue).Count -gt 0) {
    return [pscustomobject]@{ ok=$false; code='LME_V2_PRIVATE_RUNTIME_CONFLICT'; status='blocked'; runtime=$runtime; nextAction='Inspect or archive the incomplete private runtime before retrying; the bootstrap will not overwrite it.' }
  }
  if (-not (Test-Path -LiteralPath $bootstrapCacheRoot -PathType Container)) { New-Item -ItemType Directory -Force -Path $bootstrapCacheRoot | Out-Null }
  if (-not (Test-Path -LiteralPath $pythonInstallerPath -PathType Leaf)) {
    Invoke-WebRequest -Uri $pythonInstallerUri -OutFile $pythonInstallerPath -UseBasicParsing
  }
  $installerHash = (Get-FileHash -LiteralPath $pythonInstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($installerHash -ne $pythonInstallerSha256) { throw 'LME_V2_PYTHON_INSTALLER_HASH_MISMATCH' }
  $signature = Get-LmeV2InstallerSignature $pythonInstallerPath
  if (-not $signature.valid) { throw 'LME_V2_PYTHON_INSTALLER_SIGNATURE_INVALID' }
  $arguments = @(
    '/quiet','InstallAllUsers=0',("TargetDir=`"{0}`"" -f $privatePythonRuntimeRoot),
    'PrependPath=0','AssociateFiles=0','Include_launcher=0','InstallLauncherAllUsers=0',
    'Include_pip=1','Include_test=0','Include_doc=0','Include_tcltk=0','Include_tools=0','Shortcuts=0'
  )
  $process = Start-Process -FilePath $pythonInstallerPath -ArgumentList ($arguments -join ' ') -Wait -PassThru -WindowStyle Hidden
  if ($process.ExitCode -ne 0) { throw "LME_V2_PRIVATE_PYTHON_INSTALL_FAILED exitCode=$($process.ExitCode)" }
  $runtime = Get-LmeV2PrivateRuntimeState
  if (-not $runtime.officialCompatible) { throw 'LME_V2_PRIVATE_PYTHON_VERIFY_FAILED' }
  Write-JsonUtf8NoBom $privatePythonManifestPath ([ordered]@{
    schema='super-brain.longmemeval-v2-private-python.v1'
    interpreterPath=$privatePythonRuntime
    interpreterVersion=$runtime.version
    installerUri=$pythonInstallerUri
    installerSha256=$pythonInstallerSha256
    signerSubject=$signature.subject
    installationScope='private_state_only'
    pathMutation=$false
    launcherMutation=$false
    fileAssociationMutation=$false
    createdAt=(Get-Date).ToString('o')
  }) 10
  return [pscustomobject]@{ ok=$true; status='private_runtime_ready'; runtime=(Get-LmeV2PrivateRuntimeState); reused=$false; guard='The private runtime is hash- and signature-verified; PATH, launcher, and file associations remain disabled.' }
}

function Get-LmeV2HarnessState {
  $present = Test-Path -LiteralPath (Join-Path $HarnessRoot 'evaluation\harness.py') -PathType Leaf
  $commit = ''
  if ($present) {
    try { $commit = [string](@(& git -C $HarnessRoot rev-parse HEAD 2>$null | Select-Object -Last 1)[0]) } catch {}
  }
  return [pscustomobject]@{ present=$present; path=$HarnessRoot; officialRepo=$officialRepo; expectedCommit=$officialCommit; actualCommit=$commit; pinned=($present -and $commit -eq $officialCommit) }
}

function Get-LmeV2DataState {
  $files = @($requiredTextFiles | ForEach-Object { [pscustomobject]@{ path=$_; present=(Test-Path -LiteralPath (Join-Path $DataRoot $_) -PathType Leaf) } })
  $manifest = $null
  if (Test-Path -LiteralPath $sourceManifestPath -PathType Leaf) {
    try { $manifest = Get-Content -LiteralPath $sourceManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  }
  return [pscustomobject]@{
    root=$DataRoot
    requiredTextFiles=@($files)
    textReady=(@($files | Where-Object { -not $_.present }).Count -eq 0)
    sourceManifest=$manifest
    requiredTrajectoryBytes=$fullTrajectoryBytes
    optionalTrajectoryScreenshotBytes=$fullTrajectoryScreenshotBytes
    textOnlyClassification='official_harness_text_memory_ablation_not_leaderboard'
  }
}

function Get-LmeV2HoldoutExclusions([string]$TargetOutputPath) {
  $paths = New-Object System.Collections.Generic.List[string]
  foreach ($path in @($ExcludeQuestionPath)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
      [void]$paths.Add([IO.Path]::GetFullPath($path))
    }
  }
  if (Test-Path -LiteralPath $phase8Root -PathType Container) {
    $target = [IO.Path]::GetFullPath($TargetOutputPath)
    # Staged runtime inputs are often full source copies. Only a recorded run
    # contract constitutes evidence that an id entered an earlier diagnostic.
    Get-ChildItem -LiteralPath $phase8Root -Recurse -File -Filter 'run-contract.json' -ErrorAction SilentlyContinue |
      Where-Object { [IO.Path]::GetFullPath($_.FullName) -ne $target } |
      ForEach-Object { [void]$paths.Add([IO.Path]::GetFullPath($_.FullName)) }
  }
  return @($paths | Sort-Object -Unique)
}

function Invoke-LmeV2HoldoutSelector([object]$Python,[string]$SelectorAction) {
  if (-not $Python.found) {
    return [pscustomobject]@{ ok=$false; code='LME_V2_PYTHON_311_REQUIRED'; status='blocked'; nextAction='Run Prepare -Apply to acquire or select a compatible private Python runtime.' }
  }
  if (-not (Test-Path -LiteralPath $holdoutSelectorPath -PathType Leaf)) {
    return [pscustomobject]@{ ok=$false; code='LME_V2_HOLDOUT_SELECTOR_MISSING'; status='blocked' }
  }
  if ([string]::IsNullOrWhiteSpace($HoldoutRegistryPath)) { $HoldoutRegistryPath = Join-Path $holdoutRoot 'holdout-registry.json' }
  if ($SelectorAction -eq 'status') {
    $raw = @(& $Python.path $holdoutSelectorPath 'status' '--registry-path' $HoldoutRegistryPath 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ('LME_V2_HOLDOUT_STATUS_FAILED ' + ($raw -join "`n")) }
    return (ConvertFrom-LmeV2FinalJsonLine $raw)
  }
  if ($SelectorAction -eq 'mark-incomplete') {
    if ([string]::IsNullOrWhiteSpace($HoldoutSetHash)) {
      return [pscustomobject]@{ ok=$false; code='LME_V2_HOLDOUT_SET_HASH_REQUIRED'; status='blocked' }
    }
    $raw = @(& $Python.path $holdoutSelectorPath 'mark-incomplete' '--registry-path' $HoldoutRegistryPath '--set-hash' $HoldoutSetHash '--reason' $HoldoutIncompleteReason 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ('LME_V2_HOLDOUT_MARK_FAILED ' + ($raw -join "`n")) }
    return (ConvertFrom-LmeV2FinalJsonLine $raw)
  }
  if ($SelectorAction -eq 'mark-complete') {
    if ([string]::IsNullOrWhiteSpace($HoldoutSetHash) -or [string]::IsNullOrWhiteSpace($HoldoutEvidenceHash)) {
      return [pscustomobject]@{ ok=$false; code='LME_V2_HOLDOUT_COMPLETION_BINDING_REQUIRED'; status='blocked' }
    }
    $raw = @(& $Python.path $holdoutSelectorPath 'mark-complete' '--registry-path' $HoldoutRegistryPath '--set-hash' $HoldoutSetHash '--evidence-hash' $HoldoutEvidenceHash 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ('LME_V2_HOLDOUT_MARK_FAILED ' + ($raw -join "`n")) }
    return (ConvertFrom-LmeV2FinalJsonLine $raw)
  }
  if (-not (Test-Path -LiteralPath (Join-Path $DataRoot 'questions.jsonl') -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $DataRoot 'haystacks\lme_v2_small.json') -PathType Leaf) -or -not (Test-Path -LiteralPath $sourceManifestPath -PathType Leaf)) {
    return [pscustomobject]@{ ok=$false; code='LME_V2_TEXT_DATA_REQUIRED'; status='blocked'; nextAction='Run FetchTextData -Apply before preparing a private holdout.' }
  }
  if ([string]::IsNullOrWhiteSpace($HoldoutOutputDir)) {
    $HoldoutOutputDir = Join-Path $holdoutRoot ("{0}-{1}-{2}" -f $HoldoutDomain,(Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'),[guid]::NewGuid().ToString('N').Substring(0,8))
  }
  $excludePaths = Get-LmeV2HoldoutExclusions $HoldoutOutputDir
  $selectorArgs = @(
    $holdoutSelectorPath,'prepare',
    '--questions-path',(Join-Path $DataRoot 'questions.jsonl'),
    '--haystacks-path',(Join-Path $DataRoot 'haystacks\lme_v2_small.json'),
    '--source-manifest-path',$sourceManifestPath,
    '--output-dir',$HoldoutOutputDir,
    '--registry-path',$HoldoutRegistryPath,
    '--domain',$HoldoutDomain,
    '--per-question-type',[string]$HoldoutPerQuestionType
  )
  foreach ($path in $excludePaths) { $selectorArgs += @('--exclude-question-path',$path) }
  if ($Apply) { $selectorArgs += '--apply' }
  $raw = @(& $Python.path @selectorArgs 2>&1)
  $result = ConvertFrom-LmeV2FinalJsonLine $raw
  if ($LASTEXITCODE -ne 0 -or $result.ok -ne $true) {
    return [pscustomobject]@{ ok=$false; code=if($result.code){[string]$result.code}else{'LME_V2_HOLDOUT_PREPARE_FAILED'}; status='blocked'; selector=$result }
  }
  return $result
}

function Get-LmeV2DependencyState([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{ ready=$false; modules=@(); pythonPath='' } }
  $raw = @(& $Path -c 'import importlib.util, json; print(json.dumps({name: bool(importlib.util.find_spec(name)) for name in (''agents'', ''openai'', ''huggingface_hub'', ''transformers'', ''jinja2'')}))' 2>$null)
  try {
    $modules = (($raw -join "`n") | ConvertFrom-Json)
    $ready = ($modules.agents -eq $true -and $modules.openai -eq $true -and $modules.huggingface_hub -eq $true -and $modules.transformers -eq $true -and $modules.jinja2 -eq $true)
    return [pscustomobject]@{ ready=$ready; modules=$modules; pythonPath=$Path }
  } catch { return [pscustomobject]@{ ready=$false; modules=@(); pythonPath=$Path } }
}

function Get-LmeV2FreeBytes([string]$Path) {
  $rootPath = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
  $drive = Get-PSDrive -Name $rootPath.TrimEnd(':','\') -PSProvider FileSystem -ErrorAction SilentlyContinue
  if ($drive) { return [int64]$drive.Free }
  return [int64]0
}

function Invoke-LmeV2Prepare([object]$Python) {
  if (-not $Apply) { return [pscustomobject]@{ ok=$false; code='LME_V2_APPLY_REQUIRED'; status='preview_only'; nextAction='Rerun Prepare with -Apply to acquire the hash-verified private Python 3.11 runtime and create the environment.' } }
  if (-not $Python.found -and -not [string]::IsNullOrWhiteSpace($PythonPath)) { return [pscustomobject]@{ ok=$false; code='LME_V2_PYTHON_311_REQUIRED'; status='blocked'; nextAction='The explicit PythonPath is not a usable Python 3.11 interpreter.' } }
  if (-not $Python.found) {
    $bootstrap = Invoke-LmeV2PrivatePythonBootstrap
    if (-not $bootstrap.ok) { return $bootstrap }
    $Python = Get-LmeV2Python $privatePythonRuntime
  }
  if (-not $Python.found) { throw 'LME_V2_PRIVATE_PYTHON_RESOLUTION_FAILED' }
  $harness = Get-LmeV2HarnessState
  if (-not $harness.pinned) { return [pscustomobject]@{ ok=$false; code='LME_V2_HARNESS_PIN_REQUIRED'; status='blocked'; harness=$harness; nextAction='Clone the exact official LongMemEval-V2 commit into the private external-harness root.' } }
  if (-not (Test-Path -LiteralPath (Join-Path $HarnessRoot 'requirements.txt') -PathType Leaf)) { return [pscustomobject]@{ ok=$false; code='LME_V2_REQUIREMENTS_MISSING'; status='blocked' } }
  if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
    & $Python.path -m venv $venvRoot
    if ($LASTEXITCODE -ne 0) { throw 'LME_V2_VENV_CREATE_FAILED' }
  }
  $pipUpgradeOutput = @(& $venvPython -m pip install --upgrade pip 2>&1)
  if ($LASTEXITCODE -ne 0) { throw ('LME_V2_PIP_UPGRADE_FAILED ' + ($pipUpgradeOutput -join "`n")) }
  $pipInstallOutput = @(& $venvPython -m pip install -r (Join-Path $HarnessRoot 'requirements.txt') 2>&1)
  if ($LASTEXITCODE -ne 0) { throw ('LME_V2_DEPENDENCY_INSTALL_FAILED ' + ($pipInstallOutput -join "`n")) }
  # The official harness uses a Transformers chat template for text-memory token accounting.
  $jinjaOutput = @(& $venvPython -m pip install 'Jinja2==3.1.6' 2>&1)
  if ($LASTEXITCODE -ne 0) { throw ('LME_V2_JINJA2_INSTALL_FAILED ' + ($jinjaOutput -join "`n")) }
  $dependency = Get-LmeV2DependencyState $venvPython
  if (-not $dependency.ready) { throw 'LME_V2_DEPENDENCY_VERIFY_FAILED' }
  return [pscustomobject]@{ ok=$true; status='private_environment_ready'; venvPython=$venvPython; dependency=$dependency; dataDownloaded=$false; guard='No benchmark data, prompt, answer, or API request was created.' }
}

function Invoke-LmeV2FetchTextData([object]$Python) {
  if (-not $Apply) { return [pscustomobject]@{ ok=$false; code='LME_V2_APPLY_REQUIRED'; status='preview_only'; estimatedDownloadBytes=$fullTrajectoryBytes; nextAction='Rerun FetchTextData with -Apply after reviewing the 1.11 GiB trajectory download.' } }
  if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) { return [pscustomobject]@{ ok=$false; code='LME_V2_PRIVATE_ENV_REQUIRED'; status='blocked'; nextAction='Run Prepare -Apply first.' } }
  $dependency = Get-LmeV2DependencyState $venvPython
  if (-not $dependency.ready) { return [pscustomobject]@{ ok=$false; code='LME_V2_DEPENDENCY_REQUIRED'; status='blocked'; nextAction='Run Prepare -Apply first.' } }
  $harness = Get-LmeV2HarnessState
  if (-not $harness.pinned) { return [pscustomobject]@{ ok=$false; code='LME_V2_HARNESS_PIN_REQUIRED'; status='blocked'; harness=$harness } }
  if ((Get-LmeV2FreeBytes $DataRoot) -lt ($fullTrajectoryBytes + 2GB)) { return [pscustomobject]@{ ok=$false; code='LME_V2_DISK_SPACE_INSUFFICIENT'; status='blocked'; requiredBytes=($fullTrajectoryBytes + 2GB) } }
  $downloadProgram = @'
from __future__ import annotations
import hashlib
import json
import shutil
import sys
import time
from pathlib import Path
from huggingface_hub import hf_hub_download
from huggingface_hub.utils import close_session

root = Path(sys.argv[1]).resolve()
repo_id = sys.argv[2]
revision = sys.argv[3]
root.mkdir(parents=True, exist_ok=True)
image_cache = root / ".image-hf-cache"
def fetch_with_retry(name, **download_kwargs):
    for attempt in range(4):
        try:
            return hf_hub_download(repo_id=repo_id, repo_type="dataset", revision=revision, filename=name, **download_kwargs)
        except Exception as error:
            status_code = getattr(getattr(error, "response", None), "status_code", 0)
            if status_code and 400 <= int(status_code) < 500 and int(status_code) != 429:
                raise
            close_session()
            if attempt == 3:
                raise
            time.sleep(2 ** attempt)
def download_file(name):
    return fetch_with_retry(name, local_dir=str(root))
def download_image(name):
    image_path = Path(name)
    destination = root / image_path
    destination.parent.mkdir(parents=True, exist_ok=True)
    image_cache.mkdir(parents=True, exist_ok=True)
    cached_path = fetch_with_retry(name, cache_dir=str(image_cache))
    shutil.copy2(cached_path, destination)
    return destination
base_files = ["questions.jsonl", "trajectories.jsonl", "haystacks/lme_v2_small.json", "checksums.sha256"]
for name in base_files:
    download_file(name)
questions = []
for line in (root / "questions.jsonl").read_text(encoding="utf-8").splitlines():
    if line.strip():
        questions.append(json.loads(line))
image_files = set()
for row in questions:
    image = row.get("image")
    if isinstance(image, str) and image.strip():
        image_files.add(image.strip())
image_files = sorted(image_files)
for image in image_files:
    image_path = Path(image)
    if image_path.is_absolute() or ".." in image_path.parts:
        raise SystemExit(f"UNSAFE_IMAGE_PATH:{image}")
    (root / image_path.parent).mkdir(parents=True, exist_ok=True)
    download_image(image)
expected = {}
for line in (root / "checksums.sha256").read_text(encoding="utf-8").splitlines():
    parts = line.split()
    if len(parts) == 2:
        expected[parts[1]] = parts[0]
files = base_files[:-1] + image_files
hashes = {}
for name in files:
    path = root / name
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if expected.get(name) != digest:
        raise SystemExit(f"CHECKSUM_MISMATCH:{name}")
    hashes[name] = digest
manifest = {
    "schema": "super-brain.longmemeval-v2-source-manifest.v1",
    "dataset": repo_id,
    "revision": revision,
    "tier": "small",
    "textOnlyTrajectoryMemory": True,
    "files": hashes,
    "rawPromptStored": False,
    "rawAnswerStored": False,
}
(root / "super-brain-source-manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps({"ok": True, "fileCount": len(hashes), "questionCount": len(questions), "manifest": str(root / "super-brain-source-manifest.json")}))
'@
  # The multiline downloader contains string literals, so execute it from a private temporary file.
  $programPath = Join-Path $externalRoot ('.longmemeval-v2-fetch-' + [guid]::NewGuid().ToString('N') + '.py')
  $fetchExitCode = -1
  $nativeErrorActionPreference = $ErrorActionPreference
  try {
    [IO.File]::WriteAllText($programPath, $downloadProgram, (New-Object Text.UTF8Encoding($false)))
    # HF Hub warns on stderr for anonymous downloads; capture it without turning a zero-exit fetch into a PowerShell exception.
    $ErrorActionPreference = 'Continue'
    $raw = @(& $venvPython $programPath $DataRoot $officialDataset $officialDatasetRevision 2>&1)
    $fetchExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $nativeErrorActionPreference
    if (Test-Path -LiteralPath $programPath -PathType Leaf) { Remove-Item -LiteralPath $programPath -Force }
  }
  if ($fetchExitCode -ne 0) { throw ('LME_V2_DATA_FETCH_FAILED ' + ($raw -join "`n")) }
  $result = ConvertFrom-LmeV2FinalJsonLine $raw
  if ($result.ok -ne $true) { throw 'LME_V2_DATA_FETCH_RESULT_INVALID' }
  return [pscustomobject]@{ ok=$true; status='text_data_sealed'; result=$result; data=Get-LmeV2DataState; guard='Only the official small-tier text corpus and question images were downloaded. Trajectory screenshots remain absent.' }
}

try {
  $python = Get-LmeV2Python $PythonPath
  $privateRuntime = Get-LmeV2PrivateRuntimeState
  $harness = Get-LmeV2HarnessState
  $data = Get-LmeV2DataState
  $dependency = Get-LmeV2DependencyState $(if ($python.found) { $python.path } else { $venvPython })
  if ($Action -eq 'Status') {
    $ready = ($python.officialCompatible -and $harness.pinned -and $dependency.ready -and $data.textReady)
    Write-LmeV2Result ([pscustomobject]@{
      ok=$true; action='Status'; schema='super-brain.longmemeval-v2-bootstrap.v1'; status=if($ready){'ready_for_private_ab_preflight'}else{'not_ready'}
      harness=$harness; python=$python; dependency=$dependency; data=$data
      privateVenvRoot=$venvRoot; privateRuntime=$privateRuntime; diskFreeBytes=(Get-LmeV2FreeBytes $DataRoot)
      nextAction=if(-not $python.found){'Run Prepare -Apply to acquire a hash-verified private Python 3.11 runtime and create the private V2 environment.'}elseif(-not $dependency.ready){'Run Prepare -Apply to create the private V2 environment.'}elseif(-not $data.textReady){'Review the 1.11 GiB text-corpus download, then run FetchTextData -Apply.'}else{'Generate sealed baseline and treatment plans; do not run a paid model call until endpoint compatibility is proven.'}
      rawPromptStored=$false; rawAnswerStored=$false
    }) 0
  }
  if ($Action -eq 'Prepare') { Write-LmeV2Result (Invoke-LmeV2Prepare $python) $(if($Apply -and $python.found){0}else{1}) }
  if ($Action -eq 'FetchTextData') { Write-LmeV2Result (Invoke-LmeV2FetchTextData $python) $(if($Apply){0}else{1}) }
  if ($Action -eq 'PrepareHoldout') { Write-LmeV2Result (Invoke-LmeV2HoldoutSelector $python 'prepare') 0 }
  if ($Action -eq 'HoldoutStatus') { Write-LmeV2Result (Invoke-LmeV2HoldoutSelector $python 'status') 0 }
  if ($Action -eq 'MarkHoldoutIncomplete') { Write-LmeV2Result (Invoke-LmeV2HoldoutSelector $python 'mark-incomplete') 0 }
  if ($Action -eq 'MarkHoldoutComplete') { Write-LmeV2Result (Invoke-LmeV2HoldoutSelector $python 'mark-complete') 0 }
} catch {
  Write-LmeV2Result ([pscustomobject]@{ ok=$false; action=$Action; schema='super-brain.longmemeval-v2-bootstrap-error.v1'; code='LME_V2_BOOTSTRAP_ERROR'; error=$_.Exception.Message; rawPromptStored=$false; rawAnswerStored=$false }) 1
}
