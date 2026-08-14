$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Describe 'Super Brain Hookless retirement' {
  It 'removes only marked Super Brain nested commands and artifacts after explicit apply' {
    $testCodexHome = Join-Path $TestDrive 'codex-home'
    $hooksPath = Join-Path $testCodexHome 'hooks.json'
    $stableRoot = Join-Path $testCodexHome 'hooks\super-memory-brain'
    New-Item -ItemType Directory -Force -Path $stableRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $stableRoot 'handler.json'),'{"legacy":true}',[Text.UTF8Encoding]::new($false))
    $document = [ordered]@{
      features = [ordered]@{ hooks = $true }
      hooks = [ordered]@{
        UserPromptSubmit = @([ordered]@{ hooks = @(
          [ordered]@{ type='command'; command='python C:\old\codex_prompt_hook.py'; statusMessage='Super Brain legacy' },
          [ordered]@{ type='command'; command='python C:\other\codex_prompt_hook.py'; statusMessage='Other provider' }
        ) })
        Stop = @([ordered]@{ hooks = @(
          [ordered]@{ type='command'; command='python C:\old\codex_stop_hook.py'; name='Super Brain Stop' }
        ) })
      }
    }
    [IO.File]::WriteAllText($hooksPath,($document | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    $script = Join-Path $Root 'scripts\retire-codex-super-brain-hooks.ps1'

    $report = (@(& $script -CodexHome $testCodexHome -Json) -join [Environment]::NewLine) | ConvertFrom-Json
    $report.configurationChanged | Should Be $true
    (Test-Path -LiteralPath $stableRoot) | Should Be $true

    $applied = (@(& $script -CodexHome $testCodexHome -Apply -NoBackup -Json) -join [Environment]::NewLine) | ConvertFrom-Json
    $applied.ok | Should Be $true
    $applied.superBrainArtifactRemoved | Should Be $true
    (Test-Path -LiteralPath $stableRoot) | Should Be $false

    $saved = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $saved.features.hooks | Should Be $true
    @($saved.hooks.UserPromptSubmit[0].hooks).Count | Should Be 1
    $saved.hooks.UserPromptSubmit[0].hooks[0].command | Should Be 'python C:\other\codex_prompt_hook.py'
    $saved.hooks.PSObject.Properties['Stop'] | Should BeNullOrEmpty
  }

  It 'preserves an unattributed generic Codex hook filename' {
    $testCodexHome = Join-Path $TestDrive 'codex-home-unattributed'
    $hooksPath = Join-Path $testCodexHome 'hooks.json'
    New-Item -ItemType Directory -Force -Path $testCodexHome | Out-Null
    $document = [ordered]@{
      hooks = [ordered]@{
        UserPromptSubmit = @([ordered]@{
          type = 'command'
          command = 'python C:\other\codex_prompt_hook.py'
          statusMessage = 'Other provider'
        })
      }
    }
    [IO.File]::WriteAllText($hooksPath,($document | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    $script = Join-Path $Root 'scripts\retire-codex-super-brain-hooks.ps1'

    $report = (@(& $script -CodexHome $testCodexHome -Json) -join [Environment]::NewLine) | ConvertFrom-Json
    $report.configurationChanged | Should Be $false
    $report.superBrainArtifactPresent | Should Be $false

    $applied = (@(& $script -CodexHome $testCodexHome -Apply -NoBackup -Json) -join [Environment]::NewLine) | ConvertFrom-Json
    $applied.configurationChanged | Should Be $false
    $saved = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $saved.hooks.UserPromptSubmit[0].command | Should Be 'python C:\other\codex_prompt_hook.py'
  }
}
