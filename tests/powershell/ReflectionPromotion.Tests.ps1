$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $root 'scripts\reflection-promotion.ps1'

function Write-ReflectionJson([string]$Path, $Value) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}

function Invoke-Reflection([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments 2>$null)
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{ exitCode=$LASTEXITCODE; text=$text; value=$(if([string]::IsNullOrWhiteSpace($text)){$null}else{$text|ConvertFrom-Json}) }
}

function New-Correction([string]$Id, [string]$Status = 'pending_verification') {
  return [pscustomobject]@{ schema='super-brain.correction-candidate.v1'; candidateId=$Id; capturedAt='2026-07-16 00:00:00'; promptHash='abcdef123456'; promptLength=38; signals=@('strong_correction'); workspaceKey='ws-test'; status=$Status; rawPromptStored=$false; durablePromotionAllowed=$false }
}

Describe 'ReflectionPromotion correction lifecycle' {
  It 'moves a linked pending correction to analyzed only with a compact explicit summary' {
    $workspace = Join-Path $TestDrive 'analyze'
    $id = 'correction-abcdef123456'
    $candidatePath = Join-Path $workspace "reflection\correction-candidates\$id.json"
    Write-ReflectionJson $candidatePath (New-Correction $id)
    $summary = 'The verified fix binds the exact requested skill before overlapping defaults and keeps raw prompts out.'

    $result = Invoke-Reflection @('-Mode','Analyze','-TriggerType','user_correction','-Summary',$summary,'-Evidence',"correctionCandidate=$id",'-WorkspaceRoot',$workspace,'-Json')
    $result.exitCode | Should Be 0
    $candidate = Get-Content -LiteralPath $candidatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $candidate.status | Should Be 'analyzed'
    $candidate.analysisSummary | Should Be $summary
    $candidate.analysisSummaryHash.Length | Should Be 24
    $candidate.rawPromptStored | Should Be $false
    $candidate.durablePromotionAllowed | Should Be $false
    $result.value.correctionLifecycle.analyzed | Should Be 1
    $result.value.linkedCorrectionCandidate.status | Should Be 'analyzed'
  }

  It 'rejects an unverified short summary and leaves the correction pending' {
    $workspace = Join-Path $TestDrive 'short'
    $id = 'correction-123456abcdef'
    $candidatePath = Join-Path $workspace "reflection\correction-candidates\$id.json"
    Write-ReflectionJson $candidatePath (New-Correction $id)

    $result = Invoke-Reflection @('-Mode','Analyze','-TriggerType','user_correction','-Summary','too short','-Evidence',"correctionCandidate=$id",'-WorkspaceRoot',$workspace,'-Json')
    $result.exitCode | Should Not Be 0
    (Get-Content -LiteralPath $candidatePath -Raw -Encoding UTF8 | ConvertFrom-Json).status | Should Be 'pending_verification'
  }

  It 'reports pending analyzed and closed correction counts without reading prompt bodies' {
    $workspace = Join-Path $TestDrive 'list'
    $rootPath = Join-Path $workspace 'reflection\correction-candidates'
    Write-ReflectionJson (Join-Path $rootPath 'correction-pending.json') (New-Correction 'correction-pending')
    Write-ReflectionJson (Join-Path $rootPath 'correction-analyzed.json') (New-Correction 'correction-analyzed' 'analyzed')
    Write-ReflectionJson (Join-Path $rootPath 'correction-closed.json') (New-Correction 'correction-closed' 'closed')

    $result = Invoke-Reflection @('-Mode','List','-WorkspaceRoot',$workspace,'-Json')
    $result.exitCode | Should Be 0
    $result.value.correctionLifecycle.pending | Should Be 1
    $result.value.correctionLifecycle.analyzed | Should Be 1
    $result.value.correctionLifecycle.closed | Should Be 1
    $result.value.rawPromptStored | Should Be $false
  }
}
