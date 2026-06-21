param(
  [switch]$Once
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Invoke-SuperBrainScript([string]$ScriptName, [string[]]$Arguments = @()) {
  $scriptPath = Join-Path $PSScriptRoot $ScriptName
  Write-Host "`nRUN $ScriptName $($Arguments -join ' ')"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) { Write-Host "FAILED $ScriptName exitCode=$exitCode" }
  return $exitCode
}

function Read-Choice([string]$Prompt, [string]$Default = '') {
  $suffix = if ([string]::IsNullOrWhiteSpace($Default)) { '' } else { " [$Default]" }
  $value = Read-Host "$Prompt$suffix"
  if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
  return $value.Trim()
}

function Get-AgentCandidates {
  $candidates = New-Object System.Collections.Generic.List[object]
  $seen = @{}

  function Add-Candidate([string]$Name, [string]$Path, [string]$Reason) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    try { $full = [System.IO.Path]::GetFullPath($expanded) } catch { return }
    $key = $full.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { return }
    $seen[$key] = $true
    $exists = Test-Path $full
    $candidates.Add([pscustomobject]@{ name = (Get-SafeSuperBrainName $Name 'agent'); path = $full; exists = $exists; reason = $Reason }) | Out-Null
  }

  Add-Candidate 'zcode' "$env:USERPROFILE\.zcode\skills" 'known ZCode skills root'
  Add-Candidate 'codex' "$env:USERPROFILE\.codex\skills" 'known Codex skills root'
  Add-Candidate 'claude' "$env:USERPROFILE\.claude\skills" 'common Claude Code skills root'
  Add-Candidate 'claude' "$env:APPDATA\Claude\skills" 'common Claude appdata skills root'
  Add-Candidate 'cursor' "$env:USERPROFILE\.cursor\skills" 'common Cursor skills root'
  Add-Candidate 'cursor' "$env:APPDATA\Cursor\skills" 'common Cursor appdata skills root'
  Add-Candidate 'windsurf' "$env:USERPROFILE\.windsurf\skills" 'common Windsurf skills root'
  Add-Candidate 'windsurf' "$env:APPDATA\Windsurf\skills" 'common Windsurf appdata skills root'
  Add-Candidate 'roo' "$env:USERPROFILE\.roo\skills" 'common Roo Code skills root'
  Add-Candidate 'cline' "$env:USERPROFILE\.cline\skills" 'common Cline skills root'
  Add-Candidate 'continue' "$env:USERPROFILE\.continue\skills" 'common Continue skills root'
  Add-Candidate 'gemini' "$env:USERPROFILE\.gemini\skills" 'common Gemini CLI skills root'
  Add-Candidate 'opencode' "$env:USERPROFILE\.opencode\skills" 'common OpenCode skills root'
  Add-Candidate 'aider' "$env:USERPROFILE\.aider\skills" 'common Aider skills root'

  $scanRoots = @($env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA, (Split-Path -Parent $Root)) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path $_) }
  foreach ($scanRoot in $scanRoots) {
    try {
      $dirs = @(Get-ChildItem -LiteralPath $scanRoot -Directory -ErrorAction SilentlyContinue)
      foreach ($dir in $dirs) {
        if ($dir.Name -in @('.git','node_modules','vendor') -or $dir.Name -like 'install-backup-*') { continue }
        foreach ($skillDir in @(Get-ChildItem -LiteralPath $dir.FullName -Directory -Filter 'skills' -ErrorAction SilentlyContinue)) {
          if ($skillDir.FullName.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
          Add-Candidate $dir.Name $skillDir.FullName 'auto-detected skills directory'
        }
      }
    } catch {}
  }

  return @($candidates | Sort-Object @{ Expression = 'exists'; Descending = $true }, name, path)
}

function Show-AgentCandidates {
  $candidates = @(Get-AgentCandidates)
  if ($candidates.Count -eq 0) {
    Write-Host 'No agent skill directories detected.'
    return @()
  }
  for ($i = 0; $i -lt $candidates.Count; $i += 1) {
    $mark = if ($candidates[$i].exists) { 'exists' } else { 'missing/create-on-install' }
    Write-Host ("[{0}] {1} - {2} ({3}; {4})" -f ($i + 1), $candidates[$i].name, $candidates[$i].path, $mark, $candidates[$i].reason)
  }
  return $candidates
}

function Install-ZCodeCodex {
  Write-Host 'Injecting Super Brain skills into ZCode + Codex with global shared memory.'
  Invoke-SuperBrainScript 'install.ps1' @('-MemoryMode','Shared') | Out-Null
}

function Install-SelectedAgents {
  $candidates = @(Show-AgentCandidates)
  if ($candidates.Count -eq 0) { return }
  $raw = Read-Choice 'Enter candidate numbers, comma-separated' ''
  if ([string]::IsNullOrWhiteSpace($raw)) { return }
  foreach ($part in $raw -split ',') {
    $index = 0
    if (-not [int]::TryParse($part.Trim(), [ref]$index)) { continue }
    if ($index -lt 1 -or $index -gt $candidates.Count) { continue }
    $candidate = $candidates[$index - 1]
    Invoke-SuperBrainScript 'install-agent.ps1' @('-AgentName',$candidate.name,'-SkillRoot',$candidate.path,'-Mode','Shared') | Out-Null
  }
}

function Install-ManualAgent {
  $agentName = Read-Choice 'AgentName' ''
  $skillRoot = Read-Choice 'SkillRoot path' ''
  if ([string]::IsNullOrWhiteSpace($agentName) -or [string]::IsNullOrWhiteSpace($skillRoot)) {
    Write-Host 'AgentName and SkillRoot are required.'
    return
  }
  if (-not (Test-Path $skillRoot)) {
    $confirm = Read-Choice "SkillRoot does not exist and will be created. Continue? Type YES" ''
    if ($confirm -ne 'YES') { return }
  }
  Invoke-SuperBrainScript 'install-agent.ps1' @('-AgentName',$agentName,'-SkillRoot',$skillRoot,'-Mode','Shared') | Out-Null
}

function Run-CleanupMenu {
  $keep = [int](Read-Choice 'Keep how many newest install backups' '1')
  $exitCode = Invoke-SuperBrainScript 'cleanup-install-backups.ps1' @('-Keep',"$keep")
  if ($exitCode -ne 0) { return }
  $confirm = Read-Choice "Type DELETE to remove older install backups beyond $keep" ''
  if ($confirm -ne 'DELETE') { return }
  Invoke-SuperBrainScript 'cleanup-install-backups.ps1' @('-Keep',"$keep",'-Apply') | Out-Null
}

function Show-Menu {
  Write-Host ''
  Write-Host '=== Super Memory Brain Skill Injector ==='
  Write-Host '1. Global inject / refresh ZCode + Codex (shared memory)'
  Write-Host '2. List auto-detected agent skill directories'
  Write-Host '3. Inject into selected auto-detected agent directories'
  Write-Host '4. Manual inject: AgentName + SkillRoot'
  Write-Host '5. Clean install-backup-* directories'
  Write-Host '0. Exit'
}

while ($true) {
  Show-Menu
  $choice = Read-Choice 'Choose' '1'
  switch ($choice) {
    '1' { Install-ZCodeCodex }
    '2' { Show-AgentCandidates | Out-Null }
    '3' { Install-SelectedAgents }
    '4' { Install-ManualAgent }
    '5' { Run-CleanupMenu }
    '0' { exit 0 }
    default { Write-Host 'Unknown choice.' }
  }
  if ($Once) { exit 0 }
}
