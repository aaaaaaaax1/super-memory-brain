param(
  [string]$Version = '0.2.4',
  [string]$Status = '[CURRENT][VERIFIED]',
  [string]$Note = 'baseline updated'
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Baseline = Join-Path $Root 'CURRENT_BASELINE.md'
$MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$MemoryScripts = Join-Path $MemoryRoot 'scripts'
$Today = Get-Date -Format 'yyyy-MM-dd'

$content = @"
# CURRENT_BASELINE

Last Updated: $Today
Status: $Status
Package Version: $Version

## Current State

super-memory-brain-package is the active distributable Super Memory Brain package.

Package path:

````text
$Root
````

Package-local memory root:

````text
$MemoryRoot
````

Main memory file:

````text
$(Join-Path $MemoryRoot 'sandglass.txt')
````

## Active Architecture

````text
super-memory-brain
- skill-orchestrator                 # ORC / Super Brain / routing
- plusunm-g1                         # G1 / memory governance
- nexsandglass-dedicated-memory      # NexSandglass / local deep memory
````

## Active Memory Policy

````text
G1 reviews memory; ORC routes; Sandglass stores stable state only; private memory requires confirmation and [PRIVACY].
````

## Verified Capabilities

- [VERIFIED] Startup hook includes Default Super Brain startup rule.
- [VERIFIED] Startup hook includes Memory shortcut.
- [VERIFIED] Startup hook includes Recall trigger.
- [VERIFIED] Package-local NexSandglass memory read/write works.
- [VERIFIED] write-memory.ps1 gates low-quality/private memory.
- [VERIFIED] audit-memory.ps1 reports memory health.
- [VERIFIED] prepare-share.ps1 creates a privacy-clean package copy.
- [VERIFIED] verify-package.ps1 checks content, version alignment, mojibake markers, recall order, graph lineage, PowerShell syntax, and memory backend access.
- [VERIFIED] verify-share.ps1 confirms share packages exclude private memory files.

## Known Limitations

- [KNOWN_LIMITATION] plusunm-g1 currently works primarily as a skill-policy/governance layer; do not assume `python -m brain_memory` exists. Use package root markers and the PowerShell/NexSandglass script entry points under `scripts/` and `<memory-root>\scripts`.
- [PRIVACY] Do not share memory/ unless intentionally sharing private local memory.

## If Asked What Changed Recently

Answer from this order:

1. CURRENT_BASELINE.md
2. manifest.json
3. CHANGELOG.md
4. memory/sandglass.txt / NexSandglass search
5. live file verification
"@

Set-Content -LiteralPath $Baseline -Value $content -Encoding UTF8

$env:NEXSANDBASE_HOME = $MemoryRoot
$env:PYTHONPATH = $MemoryScripts
$memory = "[CURRENT][VERIFIED] super-memory-brain-package v$Version current baseline: $Note; package=$Root; memory=$MemoryRoot"
$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($memory))
python -c "import base64; from sandglass_log import log_message; print(log_message(base64.b64decode('$b64').decode('utf-8'), 'user'))"
Write-Host "BASELINE_UPDATED $Baseline"
