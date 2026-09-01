[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Prompt','Shared','SplitMemory')]
  [string]$MemoryMode = 'Shared',
  [string]$Neurobase = '',
  [string]$ZCodeSkills = "$env:USERPROFILE\.zcode\skills",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills",
  [switch]$IncludeZCode,
  [switch]$SkipVerify,
  [switch]$NoBackup,
  [switch]$PreflightOnly,
  [string]$TransactionRoot = '',
  [string]$HookPath = '',
  [ValidateSet('','after-install-skills-and-startup','after-hookless-audit','after-runtime','after-first-load')]
  [string]$TestFailAfter = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'internal\install-transaction.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$defaultZCodeSkills = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.zcode\skills')).TrimEnd('\','/')
$defaultCodexSkills = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex\skills')).TrimEnd('\','/')
$targetZCodeSkills = [IO.Path]::GetFullPath($ZCodeSkills).TrimEnd('\','/')
$targetCodexSkills = [IO.Path]::GetFullPath($CodexSkills).TrimEnd('\','/')
$repairDefaultZCodeHook = $IncludeZCode -and $targetZCodeSkills.Equals($defaultZCodeSkills,[StringComparison]::OrdinalIgnoreCase)
$skipAbsentDefaultZCode = $repairDefaultZCodeHook -and -not (Test-Path -LiteralPath (Split-Path -Parent $targetZCodeSkills))
$isIsolatedInstall = (-not $targetCodexSkills.Equals($defaultCodexSkills,[StringComparison]::OrdinalIgnoreCase)) -or ($IncludeZCode -and -not $repairDefaultZCodeHook)
if ([string]::IsNullOrWhiteSpace($Neurobase)) { $Neurobase = Get-SuperBrainSharedMemoryRoot $Root }
$Neurobase = Get-NormalizedSuperBrainRoot $Neurobase
$requestedMemoryMode = $MemoryMode
if ($MemoryMode -ne 'Shared') {
  Write-Host "MEMORY_MODE_RETIRED requested=$MemoryMode resolved=Shared reason=single-super-brain-memory-authority"
  $MemoryMode = 'Shared'
}
$zcodeMemoryRoot = $Neurobase
$codexMemoryRoot = $Neurobase
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$statusPath = Join-Path $workspace 'last-bootstrap.json'
$stages = @()
$transaction = $null
$runtimeInstall = $null

function Invoke-BytecodeSafePowerShell([string]$ScriptPath,[string[]]$Arguments=@(),[switch]$CaptureOutput) {
  $previousDontWriteBytecode = [Environment]::GetEnvironmentVariable('PYTHONDONTWRITEBYTECODE','Process')
  try {
    # Verification stages can invoke Python; do not let that mutate the package being verified.
    [Environment]::SetEnvironmentVariable('PYTHONDONTWRITEBYTECODE','1','Process')
    if ($CaptureOutput) {
      $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1)
    } else {
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
      $output = @()
    }
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{ exitCode=$exitCode; output=@($output) }
  } finally {
    [Environment]::SetEnvironmentVariable('PYTHONDONTWRITEBYTECODE',$previousDontWriteBytecode,'Process')
  }
}

function Invoke-Stage([string]$Name,[string]$ScriptName,[string[]]$Arguments=@()) {
  $scriptPath = Join-Path $PSScriptRoot $ScriptName
  $stage = Invoke-BytecodeSafePowerShell $scriptPath $Arguments
  $code = $stage.exitCode
  $script:stages += [pscustomobject]@{ name=$Name; script=$ScriptName; ok=($code -eq 0); exitCode=$code }
  if ($code -ne 0) { throw "BOOTSTRAP_STAGE_FAILED name=$Name exitCode=$code" }
}

function Invoke-JsonStage([string]$Name,[string]$ScriptName,[string[]]$Arguments=@()) {
  $scriptPath = Join-Path $PSScriptRoot $ScriptName
  $stage = Invoke-BytecodeSafePowerShell $scriptPath $Arguments -CaptureOutput
  $raw = @($stage.output)
  $code = $stage.exitCode
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  $value = $null
  try { $value = ConvertFrom-SuperBrainJsonOutput $text "bootstrap stage $Name" } catch {}
  $ok = ($code -eq 0 -and $value -and $value.ok -eq $true)
  $script:stages += [pscustomobject]@{ name=$Name; script=$ScriptName; ok=$ok; exitCode=$code }
  if (-not $ok) { throw "BOOTSTRAP_STAGE_FAILED name=$Name exitCode=$code" }
  return $value
}

function Test-BootstrapPreflight {
  $required = @(
    'install.ps1','install-runtime.ps1','retire-codex-super-brain-hooks.ps1',
    'first-load-bootstrap.ps1','verify-package.ps1',
    'internal\install-transaction.ps1'
  )
  $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $_)) })
  $python = Get-Command python -ErrorAction SilentlyContinue
  $codexCli = Get-Command codex.exe -ErrorAction SilentlyContinue
  if (-not $codexCli) { $codexCli = Get-Command codex -ErrorAction SilentlyContinue }
  if (-not $codexCli) {
    $known = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    $codexCli = Get-ChildItem -LiteralPath $known -Recurse -File -Filter 'codex.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  }
  return [pscustomobject]@{
    ok = ($missing.Count -eq 0 -and $null -ne $python -and $null -ne $codexCli)
    schema = 'super-brain.bootstrap-preflight.v1'
    packageRoot = $Root
    codexSkills = $CodexSkills
    zcodeSkills = $ZCodeSkills
    includeZCode = [bool]$IncludeZCode
    memoryRoot = $codexMemoryRoot
    missingFiles = @($missing)
    pythonFound = ($null -ne $python)
    codexCliFound = ($null -ne $codexCli)
  }
}

function Get-FileRollbackPlans([string[]]$Paths) {
  $seen = @{}
  $plans = @()
  foreach ($candidate in @($Paths)) {
    if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
    $path = [IO.Path]::GetFullPath([string]$candidate)
    $key = $path.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $exists = Test-Path -LiteralPath $path -PathType Leaf
    $plans += [pscustomobject]@{
      path = $path
      existed = [bool]$exists
      hash = if ($exists) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { '' }
      content = if ($exists) { [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) } else { '' }
      backup = ''
    }
  }
  return @($plans)
}

function Capture-FileRollbackBackups([object[]]$Plans,[string]$Pattern,[datetime]$NotBefore) {
  foreach ($plan in @($Plans)) {
    if (-not $plan.existed) { continue }
    $parent = Split-Path -Parent ([string]$plan.path)
    $leaf = Split-Path -Leaf ([string]$plan.path)
    $candidate = Get-ChildItem -LiteralPath $parent -File -Filter ($leaf + $Pattern) -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -ge $NotBefore } |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if ($candidate) { $plan.backup = $candidate.FullName }
  }
}

function Set-RecordedRollbackBackups([object[]]$Plans,[object[]]$Entries) {
  foreach ($entry in @($Entries)) {
    foreach ($plan in @($Plans)) {
      if ([string]$plan.path -ieq [string]$entry.path -and -not [string]::IsNullOrWhiteSpace([string]$entry.backup)) {
        $plan.backup = [string]$entry.backup
      }
    }
  }
}

function Restore-FileRollbackPlans([object[]]$Plans) {
  $errors = @()
  foreach ($plan in @($Plans | Sort-Object { ([string]$_.path).Length } -Descending)) {
    try {
      $existsNow = Test-Path -LiteralPath ([string]$plan.path)
      if (-not $plan.existed) {
        if ($existsNow) { Remove-Item -LiteralPath ([string]$plan.path) -Force }
        continue
      }
      $hashNow = if ($existsNow) { (Get-FileHash -LiteralPath ([string]$plan.path) -Algorithm SHA256).Hash } else { '' }
      if ($hashNow -eq [string]$plan.hash) { continue }
      if ([string]::IsNullOrWhiteSpace([string]$plan.backup) -or -not (Test-Path -LiteralPath ([string]$plan.backup))) {
        if ($null -eq $plan.content) { throw 'ROLLBACK_BACKUP_MISSING' }
        Write-Utf8NoBom ([string]$plan.path) ([string]$plan.content)
        continue
      }
      Copy-Item -LiteralPath ([string]$plan.backup) -Destination ([string]$plan.path) -Force
    } catch {
      $errors += "path=$($plan.path) error=$($_.Exception.Message)"
    }
  }
  return @($errors)
}

function Get-BootstrapSnapshotTargets {
  $targets = @()
  $hostSkillRoots = @($CodexSkills)
  if ($IncludeZCode) { $hostSkillRoots += $ZCodeSkills }
  foreach ($rootPath in $hostSkillRoots) {
    foreach ($item in @(Get-SuperBrainSourceItems)) {
      $targets += Join-Path $rootPath ([string]$item.name)
    }
  }
  $memoryRoots = @($codexMemoryRoot)
  if ($IncludeZCode) { $memoryRoots += $zcodeMemoryRoot }
  $memoryRoots = @($memoryRoots | Select-Object -Unique)
  foreach ($memoryRoot in @($memoryRoots)) {
    $targets += Join-Path $memoryRoot '.memory-scope.json'
  }
  # MCP deployment is an independent Codex-owned publish boundary.  A later
  # skill/bootstrap failure must never restore a whole config.toml snapshot or
  # split a freshly published registration from its runtime metadata.
  $targets += Get-SuperBrainSharingPolicyPath $Root
  $coldRoot = Join-Path $env:USERPROFILE '.codex-cold-skills'
  if (Test-Path -LiteralPath $coldRoot) {
    $targets += Join-Path $coldRoot 'skill-pool-index.json'
    $targets += Join-Path $coldRoot 'skill-name-index.tsv'
  }
  return @($targets)
}

function Invoke-BootstrapTestFailure([string]$Point) {
  if ($TestFailAfter -eq $Point) { throw "BOOTSTRAP_TEST_FAILURE_INJECTED point=$Point" }
}

$preflight = Test-BootstrapPreflight
if ($PreflightOnly) {
  $preflight | Add-Member -NotePropertyName action -NotePropertyValue 'preflight' -Force
  if ($Json) { $preflight | ConvertTo-Json -Depth 8 } else { Write-Host "BOOTSTRAP_PREFLIGHT_OK ok=$($preflight.ok) python=$($preflight.pythonFound) codex=$($preflight.codexCliFound)" }
  if (-not $preflight.ok) { exit 1 }
  exit 0
}

try {
  if (-not $preflight.ok) { throw "BOOTSTRAP_PREFLIGHT_FAILED missing=$($preflight.missingFiles -join ',') python=$($preflight.pythonFound) codex=$($preflight.codexCliFound)" }
  if ($NoBackup) { throw 'BOOTSTRAP_NO_BACKUP_UNSUPPORTED: one-click install requires a rollback transaction.' }

  $transaction = New-SuperBrainInstallTransaction -PackageRoot $Root -TargetPaths (Get-BootstrapSnapshotTargets) -TransactionRoot $TransactionRoot
  $transactionStarted = Get-Date
  $startupTargets = @(Get-SuperBrainGlobalStartupTargets $CodexSkills)
  if ($IncludeZCode) { $startupTargets += @(Get-SuperBrainGlobalStartupTargets $ZCodeSkills) }
  $startupPlans = Get-FileRollbackPlans @($startupTargets)
  $codexHome = Split-Path -Parent $CodexSkills
  # Bootstrap already owns a complete rollback snapshot.  Do not create a second
  # per-skill backup tree under it: that can exceed legacy Windows path limits.
  $installArgs = @('-ZCodeSkills',$ZCodeSkills,'-CodexSkills',$CodexSkills,'-Neurobase',$Neurobase,'-MemoryMode',$MemoryMode,'-SkipRuntime','-SkipHealthCheck','-NoBackup')
  if ($IncludeZCode -and -not $skipAbsentDefaultZCode) { $installArgs += '-IncludeZCode' } else { $installArgs += '-SkipZCode' }
  if ($isIsolatedInstall) { $installArgs += '-Isolated' }
  Invoke-Stage 'install-skills-and-startup' 'install.ps1' $installArgs
  Capture-FileRollbackBackups $startupPlans '.bak-super-brain-bootstrap-*' $transactionStarted
  Invoke-BootstrapTestFailure 'after-install-skills-and-startup'

  $hooklessAudit = Invoke-JsonStage 'hookless-retirement-audit' 'retire-codex-super-brain-hooks.ps1' @('-CodexHome',$codexHome,'-Json')
  Invoke-BootstrapTestFailure 'after-hookless-audit'

  $runtimeInstall = Invoke-JsonStage 'install-runtime' 'install-runtime.ps1' @('-CodexHome',$codexHome,'-MemoryRoot',$codexMemoryRoot,'-Json')
  Invoke-BootstrapTestFailure 'after-runtime'
  $codexHealthArgs = @('-ZCodeSkills',$ZCodeSkills,'-CodexSkills',$CodexSkills,'-MemoryRoot',$codexMemoryRoot)
  if ($IncludeZCode) { $codexHealthArgs += '-IncludeZCode' }
  if ($isIsolatedInstall) { $codexHealthArgs += '-Isolated' }
  Invoke-Stage 'post-install-health-check-codex' 'health-check.ps1' $codexHealthArgs
  $firstLoadArgs = @('-CodexHome',$codexHome,'-CodexSkills',$CodexSkills,'-MemoryRoot',$codexMemoryRoot,'-FailOnNotReady','-Json')
  $firstLoad = Invoke-JsonStage 'first-load-bootstrap' 'first-load-bootstrap.ps1' $firstLoadArgs
  Invoke-BootstrapTestFailure 'after-first-load'
  $verificationMode = 'skipped'
  if (-not $SkipVerify) {
    Invoke-Stage 'verify-package-integration' 'verify-package.ps1' @('-Integration')
    $verificationMode = 'package'
  }
  $postLoad = Invoke-JsonStage 'post-verify-first-load-bootstrap' 'first-load-bootstrap.ps1' $firstLoadArgs
  $commit = Complete-SuperBrainInstallTransaction $transaction

  $result = [pscustomobject]@{
    ok = $true
    schema = 'super-brain.bootstrap.v3'
    action = 'one-click-install'
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    version = (Get-SuperBrainManifest $Root).version
    packageRoot = $Root
    memoryMode = $MemoryMode
    requestedMemoryMode = $requestedMemoryMode
    memoryRoot = $Neurobase
    codexMemoryRoot = $codexMemoryRoot
    includeZCode = [bool]$IncludeZCode
    absorbedCapabilities = 'package-owned-cold-sources'
    isolatedInstall = [bool]$isIsolatedInstall
    verificationMode = $verificationMode
    preflight = $preflight
    transaction = $commit
    stages = @($stages)
    firstLoad = $firstLoad
    postVerifyFirstLoad = $postLoad
    hooklessRetirementAudit = $hooklessAudit
    nextAction = 'Open a new Codex task to discover the registered Super Brain MCP tools.'
    transactionRoot = [string]$transaction.root
    rollback = 'The committed transaction is retained under the selected writable package transaction root. Failed transactions restore package-owned skills, startup files, and memory markers; Codex MCP configuration is never whole-file restored.'
  }
  New-Item -ItemType Directory -Force -Path $workspace | Out-Null
  Write-JsonUtf8NoBom $statusPath $result 14
  if ($Json) { $result | ConvertTo-Json -Depth 14 } else { Write-Host "BOOTSTRAP_OK version=$($result.version) mode=$MemoryMode stages=$(@($stages).Count) mcp=$($postLoad.mcpBindingOk)" }
  exit 0
} catch {
  $rollbackErrors = @()
  if ($startupPlans -and $transactionStarted) { Capture-FileRollbackBackups $startupPlans '.bak-super-brain-bootstrap-*' $transactionStarted }
  if ($startupPlans) { $rollbackErrors += @(Restore-FileRollbackPlans $startupPlans) }
  $transactionRollback = $null
  if ($transaction) {
    try { $transactionRollback = Restore-SuperBrainInstallTransaction $transaction; $rollbackErrors += @($transactionRollback.errors) } catch { $rollbackErrors += "transaction=$($_.Exception.Message)" }
  }
  $failure = [pscustomobject]@{
    ok = $false
    schema = 'super-brain.bootstrap.v3'
    action = 'one-click-install'
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    version = (Get-SuperBrainManifest $Root).version
    packageRoot = $Root
    memoryMode = $MemoryMode
    requestedMemoryMode = $requestedMemoryMode
    includeZCode = [bool]$IncludeZCode
    absorbedCapabilities = 'package-owned-cold-sources'
    isolatedInstall = [bool]$isIsolatedInstall
    preflight = $preflight
    transaction = $transactionRollback
    stages = @($stages)
    error = 'BOOTSTRAP_FAILED'
    detail = $_.Exception.Message
    rollbackOk = ($rollbackErrors.Count -eq 0)
    rollbackErrors = @($rollbackErrors)
    nextAction = 'Read the failed stage and rollback result before retrying the one-click install.'
  }
  New-Item -ItemType Directory -Force -Path $workspace | Out-Null
  Write-JsonUtf8NoBom $statusPath $failure 12
  if ($Json) { $failure | ConvertTo-Json -Depth 12 } else { Write-Host "BOOTSTRAP_FAILED stageCount=$(@($stages).Count) rollbackOk=$($failure.rollbackOk)" }
  exit 1
}
