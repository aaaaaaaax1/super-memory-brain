$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$queueScript = Join-Path $root 'scripts\self-improvement-queue.ps1'
$reflectionScript = Join-Path $root 'scripts\reflection-promotion.ps1'

function Write-QueueTestJson([string]$Path, $Value) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
}

function Invoke-QueueTest([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $queueScript @Arguments 2>$null)
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{ exitCode=$LASTEXITCODE; text=$text; value=$(if([string]::IsNullOrWhiteSpace($text)){$null}else{$text|ConvertFrom-Json}) }
}

function Invoke-ReflectionTest([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $reflectionScript @Arguments 2>$null)
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{ exitCode=$LASTEXITCODE; text=$text; value=$(if([string]::IsNullOrWhiteSpace($text)){$null}else{$text|ConvertFrom-Json}) }
}

function New-QueueCandidate([string]$Id,[string]$Kind,[string]$Title,[string]$SeenAt,[int]$SeenCount=1,[string]$Priority='medium',[string]$Status='candidate') {
  return [pscustomobject]@{ id=$Id;kind=$Kind;title=$Title;status=$Status;priority=$Priority;problem='problem';expected='expected';evidence=@($Id);source='test';createdAt=$SeenAt;lastSeenAt=$SeenAt;seenCount=$SeenCount }
}

Describe 'Self improvement bounded lifecycle' {
  It 'keeps Status read-only and does not create state' {
    $workspace = Join-Path $TestDrive 'status-empty'
    $before = @(Get-ChildItem -Recurse -Force -LiteralPath $workspace -ErrorAction SilentlyContinue).Count
    $result = Invoke-QueueTest @('-Action','Status','-WorkspaceRoot',$workspace,'-Json')
    $after = @(Get-ChildItem -Recurse -Force -LiteralPath $workspace -ErrorAction SilentlyContinue).Count

    $result.exitCode | Should Be 0
    $result.value.action | Should Be 'Status'
    $result.value.sideEffectFree | Should Be $true
    $result.value.total | Should Be 0
    $after | Should Be $before
    Test-Path -LiteralPath $workspace | Should Be $false
    Test-Path (Join-Path $workspace 'self-improvement-queue.json') | Should Be $false
    Test-Path (Join-Path $workspace 'last-self-improvement-queue.json') | Should Be $false
  }

  It 'keeps reflection Preview read-only' {
    $workspace = Join-Path $TestDrive 'reflection-preview'
    $candidateRoot = Join-Path $workspace 'reflection\candidates'
    $result = Invoke-ReflectionTest @('-Mode','Preview','-TriggerType','completed_fix','-Summary','A verified reusable fix with bounded evidence and scope.','-Evidence','targeted test passed','-WorkspaceRoot',$workspace,'-Json')

    $result.exitCode | Should Be 0
    @($result.value.candidates).Count -gt 0 | Should Be $true
    @(Get-ChildItem -LiteralPath $candidateRoot -File -ErrorAction SilentlyContinue).Count | Should Be 0
    Test-Path (Join-Path $workspace 'last-reflection-promotion.json') | Should Be $false
    Test-Path (Join-Path $workspace 'last-lesson-scope-gate.json') | Should Be $false
  }

  It 'merges duplicate candidate instances into one stable family' {
    $workspace = Join-Path $TestDrive 'merge'
    $queuePath = Join-Path $workspace 'self-improvement-queue.json'
    $seenAt = (Get-Date).AddDays(-2).ToString('yyyy-MM-dd HH:mm:ss')
    Write-QueueTestJson $queuePath ([pscustomobject]@{ schema='super-brain.self-improvement-queue.v1';items=@(
      (New-QueueCandidate 'old-a' 'gap' 'Same durable gap' $seenAt 2),
      (New-QueueCandidate 'old-b' 'gap' 'Same durable gap' $seenAt 3)
    )})

    $result = Invoke-QueueTest @('-Action','Maintain','-WorkspaceRoot',$workspace,'-MaxActive','32','-Json')
    $queue = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json

    $result.exitCode | Should Be 0
    $result.value.merged | Should Be 1
    $result.value.archived | Should Be 2
    @($queue.items).Count | Should Be 1
    $queue.items[0].seenCount | Should Be 5
    $queue.items[0].mergedInstanceCount | Should Be 2
    ([string]$queue.items[0].familyKey).StartsWith('improvement-') | Should Be $true
    $archive = Get-Content -LiteralPath $result.value.archivePath -Raw -Encoding UTF8 | ConvertFrom-Json
    @($archive.queueItems).Count | Should Be 2
  }

  It 'archives closed stale and over-budget candidates without deleting evidence' {
    $workspace = Join-Path $TestDrive 'archive'
    $queuePath = Join-Path $workspace 'self-improvement-queue.json'
    $recent = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $old = (Get-Date).AddDays(-30).ToString('yyyy-MM-dd HH:mm:ss')
    $items = @(
      (New-QueueCandidate 'high-repeat' 'risk' 'Keep high repeated risk' $recent 8 'high'),
      (New-QueueCandidate 'closed' 'gap' 'Closed lesson' $recent 2 'medium' 'adopted'),
      (New-QueueCandidate 'stale' 'gap' 'Stale singleton' $old 1 'medium')
    )
    foreach ($index in 1..10) { $items += New-QueueCandidate ("extra-$index") 'gap' ("Extra family $index") $recent 1 'low' }
    Write-QueueTestJson $queuePath ([pscustomobject]@{ schema='super-brain.self-improvement-queue.v1';items=$items })

    $result = Invoke-QueueTest @('-Action','Maintain','-WorkspaceRoot',$workspace,'-MaxActive','8','-ArchiveAfterDays','14','-Json')
    $queue = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $archive = Get-Content -LiteralPath $result.value.archivePath -Raw -Encoding UTF8 | ConvertFrom-Json

    $result.exitCode | Should Be 0
    $result.value.active -le 8 | Should Be $true
    $result.value.archived -gt 0 | Should Be $true
    Test-Path -LiteralPath $result.value.archivePath | Should Be $true
    @($archive.queueItems | Where-Object { $_.id -eq 'closed' }).Count | Should Be 1
    @($archive.queueItems | Where-Object { $_.id -eq 'stale' }).Count | Should Be 1
    @($queue.items | Where-Object { $_.id -eq 'high-repeat' }).Count | Should Be 1
    ([string]$archive.restore).Length -gt 0 | Should Be $true
  }

  It 'requires evidence to resolve one exact family and archives it on maintenance' {
    $workspace = Join-Path $TestDrive 'resolve'
    $queuePath = Join-Path $workspace 'self-improvement-queue.json'
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-QueueTestJson $queuePath ([pscustomobject]@{ schema='super-brain.self-improvement-queue.v2';items=@(
      (New-QueueCandidate 'candidate-a' 'gap' 'Verified family' $now 3 'medium')
    )})

    $missing = Invoke-QueueTest @('-Action','Resolve','-WorkspaceRoot',$workspace,'-CandidateId','candidate-a','-Resolution','resolved','-Json')
    $missing.exitCode | Should Not Be 0

    $resolved = Invoke-QueueTest @('-Action','Resolve','-WorkspaceRoot',$workspace,'-CandidateId','candidate-a','-Resolution','resolved','-ResolutionEvidence','targeted replay passed','-Json')
    $afterResolve = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $resolved.exitCode | Should Be 0
    $resolved.value.resolved | Should Be 1
    $afterResolve.items[0].status | Should Be 'resolved'
    $afterResolve.items[0].resolutionEvidence[0] | Should Be 'targeted replay passed'

    $maintained = Invoke-QueueTest @('-Action','Maintain','-WorkspaceRoot',$workspace,'-Json')
    $maintained.exitCode | Should Be 0
    $maintained.value.total | Should Be 0
    $archive = Get-Content -LiteralPath $maintained.value.archivePath -Raw -Encoding UTF8 | ConvertFrom-Json
    @($archive.queueItems | Where-Object { $_.id -eq 'candidate-a' }).Count | Should Be 1
  }

  It 'reconciles a terminal reflection lifecycle into the queue' {
    $workspace = Join-Path $TestDrive 'reflection-resolution'
    $queuePath = Join-Path $workspace 'self-improvement-queue.json'
    $reflectionPath = Join-Path $workspace 'reflection\candidates\learn-family.json'
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $item = New-QueueCandidate 'queue-family' 'reflection_candidate' 'Reusable verified lesson' $now 4 'medium'
    $item.source = 'reflection-promotion.ps1'
    $item | Add-Member -NotePropertyName target -NotePropertyValue 'experience' -Force
    $item | Add-Member -NotePropertyName scope -NotePropertyValue 'project-a' -Force
    Write-QueueTestJson $queuePath ([pscustomobject]@{ schema='super-brain.self-improvement-queue.v2';items=@($item) })
    Write-QueueTestJson $reflectionPath ([pscustomobject]@{ id='learn-family';title='Reusable verified lesson';target='experience';scope='project-a';lifecycle=[pscustomobject]@{status='adopted';lastSeenAt=$now} })

    $result = Invoke-QueueTest @('-Action','Maintain','-WorkspaceRoot',$workspace,'-Json')
    $archive = Get-Content -LiteralPath $result.value.archivePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $result.exitCode | Should Be 0
    $result.value.resolved | Should Be 1
    $result.value.total | Should Be 0
    @($archive.queueItems | Where-Object { $_.id -eq 'queue-family' -and $_.status -eq 'adopted' }).Count | Should Be 1
  }
}
