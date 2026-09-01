[CmdletBinding(PositionalBinding=$false)]
param(
  [string]$PackageRoot = '',
  [string]$HookPath = '',
  [int]$MaxStartupRuleChars = 320,
  [int]$MaxSessionLineChars = 900,
  [switch]$NoBackup,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($PackageRoot)) { $PackageRoot = Split-Path -Parent $PSScriptRoot }
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot)

# P7/session-start injection is retired.  Keep this path only so an old
# maintenance command fails closed instead of writing a Hook back into a host.
# H7 MCP/runtime repair remains a separately authorized operation because it
# can change global Codex configuration.
$result = [pscustomobject]@{
  ok = $false
  schema = 'super-brain.retired-hook-repair.v1'
  state = 'withheld'
  code = 'SUPER_BRAIN_HOOK_REPAIR_RETIRED'
  packageRoot = $PackageRoot
  hookWriteAttempted = $false
  hookWriteAllowed = $false
  rawPromptStored = $false
  rawTranscriptStored = $false
  h7Repair = [pscustomobject]@{
    entrypoint = 'scripts\first-load-bootstrap.ps1 -RepairMcp'
    authority = 'H7 MCP/runtime only'
    explicitApprovalRequired = $true
  }
  nextAction = 'Do not repair or reinstall a Super Brain Hook. Diagnose H7 with host-cache-check.ps1; authorize first-load-bootstrap.ps1 -RepairMcp separately only when an H7 binding repair is required.'
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "SUPER_BRAIN_HOOK_REPAIR_RETIRED package=$PackageRoot"
  Write-Host 'H7_REPAIR_REQUIRES_EXPLICIT_APPROVAL entrypoint=first-load-bootstrap.ps1 -RepairMcp'
}
exit 1
