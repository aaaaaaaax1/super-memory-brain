param(
  [switch]$Json,
  [switch]$ApplySafe,
  [string]$Summary = '',
  [string]$TaskId = '',
  [string[]]$Evidence = @()
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$outPath = Join-Path $workspace 'last-post-task-maintenance.json'

function Invoke-JsonStep([string]$Name, [scriptblock]$Body) {
  $raw = @()
  $data = $null
  $ok = $false
  $exitCode = 1
  $errorText = ''
  try {
    $raw = @(& $Body 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    $jsonStart = -1
    for ($i = 0; $i -lt $raw.Count; $i++) { if ([string]$raw[$i] -match '^\s*[\{\[]') { $jsonStart = $i; break } }
    if ($jsonStart -ge 0) { $data = (@($raw[$jsonStart..($raw.Count - 1)]) -join "`n") | ConvertFrom-Json }
    $ok = ($exitCode -eq 0)
  } catch {
    $errorText = $_.Exception.Message
    $ok = $false
  }
  $preview = ($raw -join "`n")
  if ($preview.Length -gt 600) { $preview = $preview.Substring(0,600) + '...' }
  return [pscustomobject]@{ name=$Name; ok=$ok; exitCode=$exitCode; data=$data; error=$errorText; rawPreview=$preview }
}

$steps = New-Object System.Collections.ArrayList
[void]$steps.Add((Invoke-JsonStep 'workspace-lifecycle-manager' { & (Join-Path $PSScriptRoot 'workspace-lifecycle-manager.ps1') -Json -ApplySafe:$ApplySafe }))
[void]$steps.Add((Invoke-JsonStep 'auto-hygiene-runner' { & (Join-Path $PSScriptRoot 'auto-hygiene-runner.ps1') -Json -ApplySafe:$ApplySafe }))
[void]$steps.Add((Invoke-JsonStep 'self-improvement-queue' { & (Join-Path $PSScriptRoot 'self-improvement-queue.ps1') -Json -Summary $Summary -TaskId $TaskId -Evidence $Evidence }))
[void]$steps.Add((Invoke-JsonStep 'update-state' { & (Join-Path $PSScriptRoot 'update-state.ps1') -AllowStaleVerify -Json }))
$snapshotSummary = if ([string]::IsNullOrWhiteSpace($Summary)) { 'post-task maintenance' } else { $Summary }
[void]$steps.Add((Invoke-JsonStep 'status-snapshot-writer' { & (Join-Path $PSScriptRoot 'status-snapshot-writer.ps1') -Summary $snapshotSummary -NextAction 'Continue with the next user task; safe maintenance has already run.' -Evidence (@($Evidence) + @('post-task-maintenance.ps1','workspace-lifecycle-manager.ps1','auto-hygiene-runner.ps1','self-improvement-queue.ps1')) -Json }))

$failed = @($steps | Where-Object { $_.ok -ne $true })
$requiresConfirmation = 0
foreach ($step in @($steps)) {
  if ($step.data -and $step.data.PSObject.Properties['requiresConfirmation']) { $requiresConfirmation += [int]$step.data.requiresConfirmation }
}
$result = [pscustomobject]@{
  ok = ($failed.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = 'super-brain.post-task-maintenance.v1'
  version = [string]$manifest.version
  mode = if ($ApplySafe) { 'ApplySafe' } else { 'Plan' }
  summary = $Summary
  taskId = $TaskId
  requiresConfirmation = $requiresConfirmation
  failed = $failed.Count
  steps = @($steps | ForEach-Object { [pscustomobject]@{ name=$_.name; ok=$_.ok; exitCode=$_.exitCode; error=$_.error; rawPreview=$_.rawPreview } })
  outputs = [pscustomobject]@{
    workspaceLifecycle = Join-Path $workspace 'last-workspace-lifecycle.json'
    memoryHygiene = Join-Path $workspace 'last-memory-hygiene.json'
    selfImprovementQueue = Join-Path $workspace 'self-improvement-queue.json'
    statusSnapshot = Join-Path $workspace 'last-status-snapshot.json'
  }
}
Write-JsonUtf8NoBom $outPath $result 12
if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else {
  Write-Host "POST_TASK_MAINTENANCE ok=$($result.ok) mode=$($result.mode) failed=$($result.failed) requiresConfirmation=$($result.requiresConfirmation) path=$outPath"
}
if (-not $result.ok) { exit 1 }
exit 0
