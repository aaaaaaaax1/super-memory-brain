$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$startupScript = Join-Path $root 'scripts\startup-check.ps1'
$preflightScript = Join-Path $root 'scripts\cognitive-preflight.ps1'
$scriptTiersScript = Join-Path $root 'scripts\script-tiers.ps1'
. (Join-Path $root 'scripts\common.ps1')

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-OptionalHostUtf8([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path,$Text,$utf8NoBom)
}

function New-OptionalHostAdapter([string]$SkillsRoot, [string]$MemoryRoot) {
  $adapter = Join-Path $SkillsRoot 'super-memory-brain'
  New-Item -ItemType Directory -Force -Path $adapter,$MemoryRoot | Out-Null
  Copy-Item -LiteralPath (Join-Path $root 'super-memory-brain\SKILL.md') -Destination (Join-Path $adapter 'SKILL.md') -Force
  Write-OptionalHostUtf8 (Join-Path $adapter 'package-root.txt') ($root + [Environment]::NewLine)
  Write-OptionalHostUtf8 (Join-Path $adapter 'memory-root.txt') ($MemoryRoot + [Environment]::NewLine)
  return $adapter
}

function New-OptionalHostProfile([string]$Base) {
  $profile = Join-Path $Base 'profile'
  $stateRoot = Join-Path $Base 'state'
  $memoryRoot = Join-Path $stateRoot 'shared'
  $codexSkills = Join-Path $profile '.codex\skills'
  New-Item -ItemType Directory -Force -Path $profile,$stateRoot,$memoryRoot | Out-Null
  $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
    Initialize-SuperBrainMemoryRoot $memoryRoot $root 'shared' @('all-agents')
  } finally {
    if ($null -eq $previousStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $previousStateRoot }
  }
  New-OptionalHostAdapter $codexSkills $memoryRoot | Out-Null
  Write-OptionalHostUtf8 (Join-Path $profile '.codex\AGENTS.md') (Get-SuperBrainGlobalStartupBlock $root)
  return [pscustomobject]@{ profile=$profile; stateRoot=$stateRoot; memoryRoot=$memoryRoot; codexSkills=$codexSkills; zcodeSkills=(Join-Path $profile '.zcode\skills') }
}

function Invoke-OptionalHostStartup([object]$Fixture,[switch]$IncludeZCode) {
  $oldProfile = $env:USERPROFILE
  $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:USERPROFILE = $Fixture.profile
    $env:SUPER_BRAIN_STATE_ROOT = $Fixture.stateRoot
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$startupScript,'-MemoryRoot',$Fixture.memoryRoot,'-Isolated','-Json')
    if ($IncludeZCode) { $arguments += '-IncludeZCode' }
    $raw = @(& powershell.exe @arguments 2>$null)
    $exitCode = $LASTEXITCODE
  } finally {
    $env:USERPROFILE = $oldProfile
    if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
  }
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{ exitCode=$exitCode; text=$text; value=if($text){$text | ConvertFrom-Json}else{$null} }
}

Describe 'Optional host startup and current policy surface' {
  It 'keeps the Codex primary entry ready when ZCode is absent by default' {
    $fixture = New-OptionalHostProfile (Join-Path $TestDrive 'zcode-absent')
    $result = Invoke-OptionalHostStartup $fixture

    $result.exitCode | Should Be 0
    $result.value.ok | Should Be $true
    $result.value.coreAvailable | Should Be $true
    $result.value.adapterAvailable | Should Be $true
    $result.value.adapterState | Should Be 'ready'
    $zcodeStartup = @($result.value.adapterChecks | Where-Object { $_.name -eq 'ZCode global startup bootstrap' })
    $zcodeStartup.Count | Should Be 1
    $zcodeStartup[0].ok | Should Be $true
    $zcodeStartup[0].skipped | Should Be $true
    @($result.value.checks | Where-Object { $_.name -eq 'ZCode global startup bootstrap' }).Count | Should Be 0
  }

  It 'reports a stale ZCode startup block only when compatibility is explicitly requested' {
    $fixture = New-OptionalHostProfile (Join-Path $TestDrive 'zcode-stale')
    New-OptionalHostAdapter $fixture.zcodeSkills $fixture.memoryRoot | Out-Null
    Write-OptionalHostUtf8 (Join-Path $fixture.profile '.zcode\AGENTS.md') @'
<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_START -->
## Super Memory Brain Bootstrap

- stale optional ZCode bootstrap fixture
<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_END -->
'@
    $result = Invoke-OptionalHostStartup $fixture -IncludeZCode

    $result.exitCode | Should Be 0
    $result.value.ok | Should Be $true
    $result.value.coreAvailable | Should Be $true
    $result.value.adapterState | Should Be 'ready'
    $zcodeStartup = @($result.value.adapterChecks | Where-Object { $_.name -eq 'ZCode global startup bootstrap' })[0]
    $zcodeStartup.ok | Should Be $false
    $zcodeStartup.optional | Should Be $true
    $zcodeStartup.state | Should Be 'stale'
  }

  It 'keeps an unbound generic Agent root outside the Codex primary startup chain' {
    $fixture = New-OptionalHostProfile (Join-Path $TestDrive 'generic-agent-scan')
    $agentSkills = Join-Path $fixture.profile '.generic-agent\skills'
    $agentAdapter = Join-Path $agentSkills 'super-memory-brain'
    New-Item -ItemType Directory -Force -Path $agentAdapter | Out-Null
    Write-OptionalHostUtf8 (Join-Path $agentAdapter 'package-root.txt') ($root + [Environment]::NewLine)
    Write-OptionalHostUtf8 (Join-Path $fixture.profile '.generic-agent\AGENTS.md') @'
<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_START -->
## Super Memory Brain Bootstrap

- invalid bound generic-host bootstrap fixture
<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_END -->
'@
    $result = Invoke-OptionalHostStartup $fixture

    $result.exitCode | Should Be 0
    $result.value.ok | Should Be $true
    $result.value.coreAvailable | Should Be $true
    @($result.value.checks | Where-Object { $_.name -like 'Installed agent global startup bootstrap*' }).Count | Should Be 0
  }

  It 'projects TodoWrite as a generic optional host-tool boundary' {
    $stateRoot = Join-Path $TestDrive 'preflight-state'
    New-Item -ItemType Directory -Force -Path (Join-Path $stateRoot 'workspace') | Out-Null
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $preflightScript -Query 'review the current host tool boundary' -MaxItems 12 -Json 2>$null)
      $exitCode = $LASTEXITCODE
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
    }
    $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
    $result = $text | ConvertFrom-Json

    $exitCode | Should Be 0
    $result.outputDiscipline.hostToolBoundary.optionalToolsMustBePresent | Should Be $true
    $result.outputDiscipline.hostToolBoundary.todoWrite | Should Be 'optional_host_tool'
    $result.outputDiscipline.hostToolBoundary.absentToolBehavior | Should Be 'do_not_invoke_simulate_or_require'
    @($result.cards | Where-Object { $_.claim -like '*TodoWrite is an optional host-specific tool*' }).Count | Should Be 1
    $result.outputDiscipline.PSObject.Properties['noTodoWriteInZCode'] | Should BeNullOrEmpty
    $text.Contains('In ZCode sessions') | Should Be $false
  }

  It 'keeps one active policy root, current registry metadata, and retired helpers off the active script surface' {
    $fixture = New-OptionalHostProfile (Join-Path $TestDrive 'policy-surface')
    $startup = Invoke-OptionalHostStartup $fixture

    $startup.exitCode | Should Be 0
    $startup.value.ok | Should Be $true

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $fixture.stateRoot
      Write-SuperBrainSharingPolicy $root 'shared' $fixture.memoryRoot @('all-agents') | Out-Null
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
    }

    $policy = Get-Content -LiteralPath (Join-Path $fixture.stateRoot 'workspace\memory-sharing-policy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $policy.initialized | Should Be $true
    $policy.mode | Should Be 'shared'
    $policy.requestedMode | Should Be 'shared'
    (Get-NormalizedSuperBrainRoot ([string]$policy.activeRoot)) | Should Be (Get-NormalizedSuperBrainRoot $fixture.memoryRoot)
    (Get-NormalizedSuperBrainRoot ([string]$policy.sharedRoot)) | Should Be (Get-NormalizedSuperBrainRoot $fixture.memoryRoot)
    $policy.rootAuthority | Should Be 'stateRoot/shared'
    $policy.legacyRootsReadOnly | Should Be $true
    @($policy.members) | Should Be @('all-agents')
    $policy.PSObject.Properties['legacyReadOnlyRoots'] | Should BeNullOrEmpty

    $manifestPath = Join-Path $root 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $rules = Get-Content -LiteralPath (Join-Path $root 'super-brain-rules.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest.coreRuleRegistry.PSObject.Properties['registryVersion'] | Should BeNullOrEmpty
    $manifest.coreRuleRegistry.PSObject.Properties['payloadHash'] | Should BeNullOrEmpty
    foreach ($retired in @('add-current-state-priority.py','update-entry-skill.py')) {
      (Test-Path -LiteralPath (Join-Path $root ('scripts\' + $retired)) -PathType Leaf) | Should Be $true
      @($manifest.internalScripts | Where-Object { [string]$_ -eq $retired }).Count | Should Be 0
      @($manifest.scriptMetadata | Where-Object { [string]$_.path -eq $retired }).Count | Should Be 0
    }

    $tiersRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptTiersScript -IncludeInternal -Full -Json 2>$null)
    $tiers = (($tiersRaw | ForEach-Object { [string]$_ }) -join "`n") | ConvertFrom-Json
    @($tiers.scripts | Where-Object { [string]$_.path -in @('add-current-state-priority.py','update-entry-skill.py') }).Count | Should Be 0

    $documentPaths = @('README.md','QUICK_START.md','COMMANDS.md','START_HERE.md') | ForEach-Object { Join-Path $root $_ }
    foreach ($path in $documentPaths) {
      $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
      $text | Should Not Match '(?im)-Mode\s+(SplitMemory|Agent|Group)\b'
      $text | Should Not Match '(?im)-Extensions[^\r\n]*mattpocock-skills'
    }
    (Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw -Encoding UTF8) | Should Match 'Codex'
    (Get-Content -LiteralPath (Join-Path $root 'scripts\install.ps1') -Raw -Encoding UTF8) | Should Match '\[switch\]\$IncludeZCode'
  }
}
