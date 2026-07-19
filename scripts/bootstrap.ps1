[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Prompt','Shared','SplitMemory')]
  [string]$MemoryMode = 'Shared',
  [string]$Neurobase = '',
  [string]$ZCodeSkills = "$env:USERPROFILE\.zcode\skills",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills",
  [switch]$SkipVerify,
  [switch]$NoBackup,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Neurobase)) { $Neurobase = Get-SuperBrainSharedMemoryRoot $Root }
$Neurobase = Get-NormalizedSuperBrainRoot $Neurobase
$codexMemoryRoot = if ($MemoryMode -eq 'SplitMemory') { Get-SuperBrainAgentMemoryRoot 'codex' $Root } else { $Neurobase }
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$statusPath = Join-Path $workspace 'last-bootstrap.json'
$stages = @()

function Invoke-Stage([string]$Name,[string]$ScriptName,[string[]]$Arguments=@()) {
  $scriptPath = Join-Path $PSScriptRoot $ScriptName
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments
  $code = $LASTEXITCODE
  $script:stages += [pscustomobject]@{ name=$Name; script=$ScriptName; ok=($code -eq 0); exitCode=$code }
  if ($code -ne 0) { throw "BOOTSTRAP_STAGE_FAILED name=$Name exitCode=$code" }
}

function Invoke-JsonStage([string]$Name,[string]$ScriptName,[string[]]$Arguments=@()) {
  $scriptPath = Join-Path $PSScriptRoot $ScriptName
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments 2>&1)
  $code = $LASTEXITCODE
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  $start = $text.IndexOf('{')
  $value = $null
  if ($start -ge 0) { try { $value = $text.Substring($start) | ConvertFrom-Json } catch {} }
  $ok = ($code -eq 0 -and $value -and $value.ok -eq $true)
  $script:stages += [pscustomobject]@{ name=$Name; script=$ScriptName; ok=$ok; exitCode=$code }
  if (-not $ok) { throw "BOOTSTRAP_STAGE_FAILED name=$Name exitCode=$code" }
  return $value
}

try {
  $installArgs = @('-ZCodeSkills',$ZCodeSkills,'-CodexSkills',$CodexSkills,'-Neurobase',$Neurobase,'-MemoryMode',$MemoryMode)
  if ($NoBackup) { $installArgs += '-NoBackup' }
  Invoke-Stage 'install' 'install.ps1' $installArgs
  Invoke-Stage 'repair-hook' 'repair-hook.ps1' @('-PackageRoot',$Root)
  Invoke-Stage 'encoding-check' 'encoding-check.ps1' @('-Fix')
  Invoke-Stage 'graph-normalize' 'graph-normalize.ps1' @('-Fix')
  $firstLoadArgs = @('-CodexHome',(Split-Path -Parent $CodexSkills),'-CodexSkills',$CodexSkills,'-MemoryRoot',$codexMemoryRoot,'-RepairMcp','-FailOnNotReady','-Json')
  $firstLoad = Invoke-JsonStage 'first-load-bootstrap' 'first-load-bootstrap.ps1' $firstLoadArgs
  if (-not $SkipVerify) { Invoke-Stage 'verify-package-integration' 'verify-package.ps1' @('-Integration') }
  $postLoad = Invoke-JsonStage 'post-verify-first-load-bootstrap' 'first-load-bootstrap.ps1' $firstLoadArgs
  $result = [pscustomobject]@{
    ok = $true
    schema = 'super-brain.bootstrap.v2'
    action = 'one-click-install'
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    version = (Get-SuperBrainManifest $Root).version
    packageRoot = $Root
    memoryMode = $MemoryMode
    memoryRoot = $Neurobase
    codexMemoryRoot = $codexMemoryRoot
    stages = @($stages)
    firstLoad = $firstLoad
    postVerifyFirstLoad = $postLoad
    nextAction = 'Open a new Codex task so the repaired MCP registration is discovered.'
    rollback = 'Restore the newest install backup under the configured archive root, or run install-runtime.ps1 -Remove to remove MCP.'
  }
  New-Item -ItemType Directory -Force -Path $workspace | Out-Null
  Write-JsonUtf8NoBom $statusPath $result 14
  if ($Json) { $result | ConvertTo-Json -Depth 14 } else { Write-Host "BOOTSTRAP_OK version=$($result.version) mode=$MemoryMode stages=$(@($stages).Count) mcp=$($postLoad.mcpBindingOk)" }
  exit 0
} catch {
  $failure = [pscustomobject]@{
    ok = $false
    schema = 'super-brain.bootstrap.v2'
    action = 'one-click-install'
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    version = (Get-SuperBrainManifest $Root).version
    packageRoot = $Root
    memoryMode = $MemoryMode
    memoryRoot = $Neurobase
    stages = @($stages)
    error = 'BOOTSTRAP_FAILED'
    nextAction = 'Read the failed stage and rerun bootstrap.ps1 after correcting its prerequisite.'
  }
  New-Item -ItemType Directory -Force -Path $workspace | Out-Null
  Write-JsonUtf8NoBom $statusPath $failure 10
  if ($Json) { $failure | ConvertTo-Json -Depth 10 } else { Write-Host "BOOTSTRAP_FAILED stageCount=$(@($stages).Count)" }
  exit 1
}
