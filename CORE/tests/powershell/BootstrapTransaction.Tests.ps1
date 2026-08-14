Describe 'Super Memory Brain bootstrap transaction' {
  BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $root 'scripts\common.ps1')
    . (Join-Path $root 'scripts\internal\install-transaction.ps1')
  }

  It 'restores a modified file and removes a transaction-created file' {
    $archive = Join-Path $TestDrive 'archive'
    $existing = Join-Path $TestDrive 'existing.txt'
    $created = Join-Path $TestDrive 'created.txt'
    Set-Content -LiteralPath $existing -Value 'before' -Encoding UTF8

    $transaction = New-SuperBrainInstallTransaction -PackageRoot $root -TargetPaths @($existing,$created) -TransactionRoot $archive
    Set-Content -LiteralPath $existing -Value 'after' -Encoding UTF8
    Set-Content -LiteralPath $created -Value 'new' -Encoding UTF8

    $rollback = Restore-SuperBrainInstallTransaction $transaction

    $rollback.ok | Should Be $true
    (Get-Content -LiteralPath $existing -Raw -Encoding UTF8).Trim() | Should Be 'before'
    (Test-Path -LiteralPath $created) | Should Be $false
    ((Get-Content -LiteralPath $transaction.manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json).status) | Should Be 'rolled_back'
  }

  It 'parses a Codex JSON response after harmless CLI warning lines' {
    $parsed = ConvertFrom-SuperBrainJsonOutput "WARNING: first-run notice`n{`"ok`":true,`"name`":`"super-memory-brain`"}" 'test response'

    $parsed.ok | Should Be $true
    $parsed.name | Should Be 'super-memory-brain'
  }

  It 'restores a changed directory without touching unrelated siblings' {
    $archive = Join-Path $TestDrive 'directory-archive'
    $target = Join-Path $TestDrive 'installed-skill'
    $sibling = Join-Path $TestDrive 'unrelated.txt'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Set-Content -LiteralPath (Join-Path $target 'SKILL.md') -Value 'original' -Encoding UTF8
    Set-Content -LiteralPath $sibling -Value 'keep' -Encoding UTF8

    $transaction = New-SuperBrainInstallTransaction -PackageRoot $root -TargetPaths @($target) -TransactionRoot $archive
    Set-Content -LiteralPath (Join-Path $target 'SKILL.md') -Value 'changed' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $target 'extra.txt') -Value 'remove' -Encoding UTF8

    $rollback = Restore-SuperBrainInstallTransaction $transaction

    $rollback.ok | Should Be $true
    (Get-Content -LiteralPath (Join-Path $target 'SKILL.md') -Raw -Encoding UTF8).Trim() | Should Be 'original'
    (Test-Path -LiteralPath (Join-Path $target 'extra.txt')) | Should Be $false
    (Get-Content -LiteralPath $sibling -Raw -Encoding UTF8).Trim() | Should Be 'keep'
  }

  It 'rolls back a real isolated bootstrap failure after skill and startup writes' {
    $testRoot = Join-Path $TestDrive 'bootstrap-e2e'
    $stateRoot = Join-Path $testRoot 'state'
    $zcodeSkills = Join-Path $testRoot 'zcode\skills'
    $codexSkills = Join-Path $testRoot 'codex\skills'
    $transactionRoot = Join-Path $testRoot 'transactions'
    $startupPath = Join-Path (Split-Path -Parent $codexSkills) 'AGENTS.md'
    $existingSkill = Join-Path $codexSkills 'super-memory-brain\SKILL.md'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $codexSkills),(Split-Path -Parent $existingSkill) | Out-Null
    Set-Content -LiteralPath $startupPath -Value 'original-startup' -Encoding UTF8
    Set-Content -LiteralPath $existingSkill -Value 'original-skill' -Encoding UTF8
    $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
    try {
      $bootstrap = Join-Path $root 'scripts\bootstrap.ps1'
      $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bootstrap -ZCodeSkills $zcodeSkills -CodexSkills $codexSkills -TransactionRoot $transactionRoot -SkipVerify -TestFailAfter 'after-install-skills-and-startup' -Json 2>&1)
      $exitCode = $LASTEXITCODE
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $previousStateRoot
    }

    $exitCode | Should Be 1
    (Get-Content -LiteralPath $startupPath -Raw -Encoding UTF8).Trim() | Should Be 'original-startup'
    (Get-Content -LiteralPath $existingSkill -Raw -Encoding UTF8).Trim() | Should Be 'original-skill'
    (Test-Path -LiteralPath (Join-Path $zcodeSkills 'super-memory-brain')) | Should Be $false
    $transaction = Get-ChildItem -LiteralPath $transactionRoot -Directory -Filter 'install-transaction-*' | Select-Object -First 1
    $transaction | Should Not BeNullOrEmpty
    ((Get-Content -LiteralPath (Join-Path $transaction.FullName 'transaction.json') -Raw -Encoding UTF8 | ConvertFrom-Json).status) | Should Be 'rolled_back'
  }

  It 'completes the isolated one-click install pipeline with a committed transaction' {
    $testRoot = Join-Path $TestDrive 'bootstrap-success-e2e'
    $stateRoot = Join-Path $testRoot 'state'
    $zcodeSkills = Join-Path $testRoot 'zcode\skills'
    $codexSkills = Join-Path $testRoot 'codex\skills'
    $transactionRoot = Join-Path $testRoot 'transactions'
    $hookPath = Join-Path $testRoot 'legacy-hook-file.txt'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $zcodeSkills),(Split-Path -Parent $codexSkills) | Out-Null
    Set-Content -LiteralPath $hookPath -Value @('warning_escaped=$(escape_for_json "$warning_message")','session_context="old"') -Encoding UTF8
    $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
    try {
      $bootstrap = Join-Path $root 'scripts\bootstrap.ps1'
      $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bootstrap -ZCodeSkills $zcodeSkills -CodexSkills $codexSkills -TransactionRoot $transactionRoot -HookPath $hookPath -SkipVerify -Json 2>&1)
      $exitCode = $LASTEXITCODE
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $previousStateRoot
    }
    $jsonStart = -1
    for ($index = $output.Count - 1; $index -ge 0; $index--) {
      if ([string]$output[$index] -match '^\{') { $jsonStart = $index; break }
    }
    $result = if ($jsonStart -ge 0) { ($output[$jsonStart..($output.Count - 1)] -join "`n") | ConvertFrom-Json } else { $null }

    $exitCode | Should Be 0
    $result | Should Not BeNullOrEmpty
    $result.ok | Should Be $true
    $result.transaction.status | Should Be 'committed'
    $result.firstLoad.mcpBindingOk | Should Be $true
    $result.postVerifyFirstLoad.mcpBindingOk | Should Be $true
    (Get-Content -LiteralPath $hookPath -Raw -Encoding UTF8) -like '*SUPER_MEMORY_BRAIN_STARTUP*' | Should Be $false
    (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $codexSkills) 'hooks.json')) | Should Be $false
    (Test-Path -LiteralPath (Join-Path $codexSkills 'super-memory-brain\SKILL.md')) | Should Be $true
  }

  It 'keeps the shared-memory policy unchanged after a successful isolated bootstrap' {
    $testRoot = Join-Path $TestDrive 'bootstrap-policy-isolation'
    $stateRoot = Join-Path $testRoot 'state'
    $sharedRoot = Join-Path $stateRoot 'shared'
    $zcodeSkills = Join-Path $testRoot 'zcode\skills'
    $codexSkills = Join-Path $testRoot 'codex\skills'
    $memoryRoot = $sharedRoot
    $transactionRoot = Join-Path $testRoot 'transactions'
    $hookPath = Join-Path $testRoot 'session-start.sh'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $zcodeSkills),(Split-Path -Parent $codexSkills) | Out-Null
    Set-Content -LiteralPath $hookPath -Value @('warning_escaped=$(escape_for_json "$warning_message")','session_context="old"') -Encoding UTF8
    $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      Initialize-SuperBrainMemoryRoot $sharedRoot $root 'shared' @('all-agents')
      Write-SuperBrainSharingPolicy $root 'shared' $sharedRoot @('all-agents') | Out-Null
      $policyPath = Get-SuperBrainSharingPolicyPath $root
      $beforeHash = Get-SuperBrainFileSha256 $policyPath

      $bootstrap = Join-Path $root 'scripts\bootstrap.ps1'
      $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bootstrap -ZCodeSkills $zcodeSkills -CodexSkills $codexSkills -TransactionRoot $transactionRoot -HookPath $hookPath -SkipVerify -Json 2>&1)
      $exitCode = $LASTEXITCODE

      $after = Get-Content -LiteralPath $policyPath -Raw -Encoding UTF8
      $policy = $after | ConvertFrom-Json
      if ($exitCode -ne 0) {
        $failure = ((@($output | Select-Object -Last 8) | ForEach-Object { [string]$_ }) -join ' | ')
        throw "BOOTSTRAP_ISOLATED_EXIT_NONZERO:${exitCode}:$failure"
      }
      if ((Get-SuperBrainFileSha256 $policyPath) -ne $beforeHash) { throw 'BOOTSTRAP_ISOLATED_POLICY_MUTATED' }
      if ([string]$policy.activeRoot -ne [System.IO.Path]::GetFullPath($sharedRoot)) { throw 'BOOTSTRAP_ISOLATED_POLICY_ROOT_CHANGED' }
      if (-not (Test-Path -LiteralPath (Join-Path $memoryRoot 'sandglass.txt') -PathType Leaf)) { throw 'BOOTSTRAP_ISOLATED_SANDGLASS_MISSING' }
      if (-not (Test-Path -LiteralPath (Join-Path $memoryRoot 'decision_particles.txt') -PathType Leaf)) { throw 'BOOTSTRAP_ISOLATED_DECISION_PARTICLES_MISSING' }
    } finally {
      if ($null -eq $previousStateRoot) {
        Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue
      } else {
        $env:SUPER_BRAIN_STATE_ROOT = $previousStateRoot
      }
    }
  }

  It 'keeps one-click installation transactional and H7-only' {
    $bootstrap = Get-Content -LiteralPath (Join-Path $root 'scripts\bootstrap.ps1') -Raw -Encoding UTF8
    $install = Get-Content -LiteralPath (Join-Path $root 'scripts\install.ps1') -Raw -Encoding UTF8

    $bootstrap -like '*BOOTSTRAP_NO_BACKUP_UNSUPPORTED*' | Should Be $true
    $bootstrap -like '*New-SuperBrainInstallTransaction*' | Should Be $true
    $bootstrap -like '*Restore-SuperBrainInstallTransaction*' | Should Be $true
    $bootstrap -like '*retire-codex-super-brain-hooks.ps1*' | Should Be $true
    $bootstrap -like '*install-codex-user-prompt-hook*' | Should Be $false
    $bootstrap -like '*codex_prompt_hook_dispatcher.py*' | Should Be $false
    $bootstrap -like '*handler.json*' | Should Be $false
    $bootstrap -like '*install-runtime*' | Should Be $true
    $bootstrap -like '*post-install-health-check-codex*' | Should Be $true
    $installArgsLine = @($bootstrap -split "`r?`n" | Where-Object { $_ -match '^\s*\$installArgs\s*=' }) -join "`n"
    $installArgsLine -like "*'-NoBackup'*" | Should Be $true
    $installArgsLine -like '*InstallBackupRoot*' | Should Be $false
    $bootstrap -like '*-FailOnNotReady*' | Should Be $true
    $install -match '\[switch\]\$SkipHook' | Should Be $false
    $install -match '\[switch\]\$SkipHealthCheck' | Should Be $true
    $install -match '\[switch\]\$Isolated' | Should Be $true
    $install -match '\[switch\]\$IncludeZCode' | Should Be $true
    $install -match '\[string\]\$InstallBackupRoot' | Should Be $true
    $bootstrap -like '*$installArgs += ''-Isolated''*' | Should Be $true
    $install -like '*ZCode compatibility adapter was not installed*' | Should Be $true
  }
}

Describe 'Super Memory Brain bootstrap bytecode isolation' -Tags 'bootstrap-bytecode' {
  BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  }

}
