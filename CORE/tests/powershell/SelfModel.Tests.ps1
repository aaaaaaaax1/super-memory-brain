$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SelfModel = Join-Path $Root 'scripts\self-model.ps1'
$Maintenance = Join-Path $Root 'scripts\post-task-maintenance.ps1'

function Write-SelfModelJson([string]$Path, $Value) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}

function Invoke-SelfModel([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SelfModel @Arguments 2>$null)
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{ exitCode=$LASTEXITCODE; value=$(if([string]::IsNullOrWhiteSpace($text)){$null}else{$text|ConvertFrom-Json}) }
}

Describe 'Bounded self-model lifecycle' {
  BeforeEach {
    $script:SelfModelWorkspace = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $script:SelfModelWorkspace | Out-Null
  }

  It 'reports a missing snapshot as unknown without creating it' {
    $result = Invoke-SelfModel @('-Action','Status','-WorkspaceRoot',$script:SelfModelWorkspace,'-Json')

    $result.exitCode | Should Be 0
    $result.value.snapshotExists | Should Be $false
    $result.value.snapshotStatus | Should Be 'missing'
    $result.value.evidenceStatus | Should Be 'missing'
    $result.value.rawPromptStored | Should Be $false
    (Test-Path (Join-Path $script:SelfModelWorkspace 'self-model.json')) | Should Be $false
  }

  It 'refreshes only bounded derived evidence and never records raw prompt text' {
    $sentinel = 'RAW-PROMPT-SENTINEL-SELF-MODEL-7f42'
    $packageVersion = (([IO.File]::ReadAllText((Join-Path $Root 'manifest.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json).version)
    Write-SelfModelJson (Join-Path $script:SelfModelWorkspace 'last-verify-package.json') ([pscustomobject]@{ok=$true;version=$packageVersion;checkedAt=(Get-Date).ToString('o');summary=$sentinel})
    Write-SelfModelJson (Join-Path $script:SelfModelWorkspace 'last-task-verification.json') ([pscustomobject]@{ok=$true;taskId='task-self-model';checkedAt=(Get-Date).ToString('o');summary=$sentinel})
    Write-SelfModelJson (Join-Path $script:SelfModelWorkspace 'user-adaptation\profile.json') ([pscustomobject]@{rawPromptStored=$false;entries=@([pscustomobject]@{status='active';habitKey='response_detail';value='concise';rawPromptStored=$false;evidence=$sentinel})})

    $result = Invoke-SelfModel @('-Action','Refresh','-WorkspaceRoot',$script:SelfModelWorkspace,'-Json')
    $snapshotPath = Join-Path $script:SelfModelWorkspace 'self-model.json'
    $snapshot = Get-Content -LiteralPath $snapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $stored = Get-Content -LiteralPath $snapshotPath -Raw -Encoding UTF8

    $result.exitCode | Should Be 0
    $result.value.evidenceStatus | Should Be 'verified'
    $result.value.verifiedCapabilityCount -gt 0 | Should Be $true
    $snapshot.rawPromptStored | Should Be $false
    $snapshot.alwaysOnInjection | Should Be $false
    $snapshot.sourceTreeBinding.schema | Should Be 'super-brain.self-model-tree-binding.v1'
    @($snapshot.evidence).Count -le 6 | Should Be $true
    @($snapshot.verifiedCapabilities).Count -le 5 | Should Be $true
    $stored.Contains($sentinel) | Should Be $false
  }

  It 'marks an expired verified snapshot stale instead of current' {
    $packageVersion = (([IO.File]::ReadAllText((Join-Path $Root 'manifest.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json).version)
    Write-SelfModelJson (Join-Path $script:SelfModelWorkspace 'self-model.json') ([pscustomobject]@{
      schema='super-brain.self-model.v1';packageVersion=$packageVersion;updatedAt=(Get-Date).AddHours(-25).ToString('o');evidenceStatus='verified';evidence=@('verified-before-expiry');rawPromptStored=$false;alwaysOnInjection=$false
    })

    $result = Invoke-SelfModel @('-Action','Status','-WorkspaceRoot',$script:SelfModelWorkspace,'-Json')

    $result.exitCode | Should Be 0
    $result.value.fresh | Should Be $false
    $result.value.snapshotStatus | Should Be 'stale'
    $result.value.evidenceStatus | Should Be 'unverified'
  }

  It 'rejects a source-tree-mismatched self-model snapshot instead of claiming current capability' {
    $packageVersion = (([IO.File]::ReadAllText((Join-Path $Root 'manifest.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json).version)
    Write-SelfModelJson (Join-Path $script:SelfModelWorkspace 'last-verify-package.json') ([pscustomobject]@{ok=$true;version=$packageVersion;checkedAt=(Get-Date).ToString('o')})
    (Invoke-SelfModel @('-Action','Refresh','-WorkspaceRoot',$script:SelfModelWorkspace,'-Json')).exitCode | Should Be 0
    $snapshotPath = Join-Path $script:SelfModelWorkspace 'self-model.json'
    $snapshot = Get-Content -LiteralPath $snapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $snapshot.sourceTreeBinding.gitTreeHash = ('0' * 64)
    Write-SelfModelJson $snapshotPath $snapshot

    $result = Invoke-SelfModel @('-Action','Status','-WorkspaceRoot',$script:SelfModelWorkspace,'-Json')

    $result.exitCode | Should Be 0
    $result.value.fresh | Should Be $false
    $result.value.snapshotStatus | Should Be 'invalid'
    $result.value.evidenceStatus | Should Be 'unverified'
    $result.value.treeBindingCurrent | Should Be $false
  }

  It 'projects V2 adaptation and measured learning state without injecting their bodies' {
    $packageVersion = (([IO.File]::ReadAllText((Join-Path $Root 'manifest.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json).version)
    Write-SelfModelJson (Join-Path $script:SelfModelWorkspace 'last-verify-package.json') ([pscustomobject]@{ok=$true;version=$packageVersion;checkedAt=(Get-Date).ToString('o')})
    Write-SelfModelJson (Join-Path $script:SelfModelWorkspace 'user-adaptation\store.v2.json') ([pscustomobject]@{
      schema='super-brain.user-adaptation-store.v2';revision=4;generation=1;rawPromptStored=$false
      profile=@([pscustomobject]@{status='active';habitKey='review_protocol';value='multi_pass';rawPromptStored=$false})
      candidates=@([pscustomobject]@{candidateId='candidate-1234567890abcdef';validation=[pscustomobject]@{status='validated';rawPromptStored=$false}})
      receipts=@([pscustomobject]@{receiptId='receipt-1234567890abcdef';rawPromptStored=$false})
    })
    Write-SelfModelJson (Join-Path $script:SelfModelWorkspace 'self-improvement-queue.json') ([pscustomobject]@{
      schema='super-brain.self-improvement-queue.v3';version=$packageVersion;rawPromptStored=$false;items=@(
        [pscustomobject]@{id='improve-1234567890ab';status='adopted';effect=[pscustomobject]@{status='scored';rawPromptStored=$false}},
        [pscustomobject]@{id='improve-abcdef123456';status='blocked';effect=[pscustomobject]@{status='not_scored';rawPromptStored=$false}}
      )
    })

    $result = Invoke-SelfModel @('-Action','Refresh','-WorkspaceRoot',$script:SelfModelWorkspace,'-Json')
    $snapshot = Get-Content -LiteralPath (Join-Path $script:SelfModelWorkspace 'self-model.json') -Raw -Encoding UTF8 | ConvertFrom-Json

    $result.exitCode | Should Be 0
    $snapshot.learning.adaptation.v2Available | Should Be $true
    $snapshot.learning.adaptation.validatedCandidates | Should Be 1
    $snapshot.learning.queue.adopted | Should Be 1
    $snapshot.learning.queue.blocked | Should Be 1
    $snapshot.learning.queue.effectScored | Should Be 1
    $snapshot.learning.queue.trustStatus | Should Be 'unverified'
    $result.value.evidenceStatus | Should Be 'degraded'
    @($snapshot.verifiedCapabilities) -contains 'evidence-gated learning lifecycle' | Should Be $false
    $snapshot.alwaysOnInjection | Should Be $false
  }

  It 'keeps post-task maintenance read-only until ApplySafe and refreshes only then' {
    $stateRoot = Join-Path $TestDrive 'maintenance-self-model'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $snapshotPath = Join-Path $stateRoot 'workspace\self-model.json'
      $plan = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Maintenance -Summary 'self model maintenance test' -Json | ConvertFrom-Json)
      ($plan.steps | Where-Object { $_.name -eq 'self-model' }).rawPreview.Contains('"action":  "Status"') | Should Be $true
      (Test-Path $snapshotPath) | Should Be $false

      $apply = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Maintenance -Summary 'self model maintenance test' -ApplySafe -Json | ConvertFrom-Json)
      ($apply.steps | Where-Object { $_.name -eq 'self-model' }).rawPreview.Contains('"action":  "Refresh"') | Should Be $true
      (Test-Path $snapshotPath) | Should Be $true
    } finally { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
  }
}
