param(
  [Parameter(Mandatory=$true)][string]$InputText
)

$ErrorActionPreference = 'Continue'

$rules = @(
  @{ Type = 'SYSTEM_RULE'; Pattern = 'default|rule|must|never|prefer|priority' },
  @{ Type = 'DECISION'; Pattern = 'accept|adopt|choose|decide' },
  @{ Type = 'PROJECT_STATE'; Pattern = 'version|path|created|installed|verified|state' },
  @{ Type = 'WORKFLOW'; Pattern = 'step|flow|script|command|run' },
  @{ Type = 'BLOCKER'; Pattern = 'failed|error|missing|blocked|unavailable|MISSING' },
  @{ Type = 'KNOWN_LIMITATION'; Pattern = 'limit|temporary|cannot|login required|unconfigured' }
)

$sentences = $InputText -split '[.;\r\n]+'
foreach ($sentence in $sentences) {
  $text = $sentence.Trim()
  if (-not $text) { continue }

  foreach ($rule in $rules) {
    if ($text -match $rule.Pattern) {
      $tag = '[HISTORY][VERIFIED]'
      if ($rule.Type -eq 'DECISION') { $tag = '[DECISION][VERIFIED]' }
      elseif ($rule.Type -eq 'BLOCKER') { $tag = '[BLOCKER]' }
      elseif ($rule.Type -eq 'KNOWN_LIMITATION') { $tag = '[KNOWN_LIMITATION]' }

      [pscustomobject]@{
        type = $rule.Type
        candidate = $text
        suggestedTag = $tag
      } | ConvertTo-Json -Compress
      break
    }
  }
}
