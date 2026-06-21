param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$templatePath = Join-Path $workspace 'agent-teams.json'
New-Item -ItemType Directory -Force -Path $workspace | Out-Null

function New-DefaultAgentTeams {
  return [pscustomobject]@{
    schemaVersion = '1.0'
    updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    templates = @(
      [pscustomobject]@{ name='Explore Team'; id='explore-team'; dispatchLevels=@('single_delegate','team_parallel'); triggers=@('broad_search','parallelizable','unknown_codebase','docs_scan'); roles=@('code-explorer','docs-explorer','state-reader'); purpose='Understand project state with evidence before implementation.' },
      [pscustomobject]@{ name='Review Team'; id='review-team'; dispatchLevels=@('review_board'); triggers=@('architecture_change','logic_safety_required','memory_sensitive','repeated_failure_or_drift'); roles=@('evidence-checker','architecture-reviewer','regression-checker'); purpose='Prevent fabricated logic and review high-risk changes.' },
      [pscustomobject]@{ name='Release Team'; id='release-team'; dispatchLevels=@('team_parallel','review_board'); triggers=@('release','share','hot_refresh','verification_required'); roles=@('verify-runner','docs-checker','share-safety-checker'); purpose='Check verification, docs, share privacy, and hot-refresh readiness.' },
      [pscustomobject]@{ name='Solo Delegate'; id='solo-delegate'; dispatchLevels=@('single_delegate'); triggers=@('focused_lookup','small_broad_search'); roles=@('focused-explorer'); purpose='Use one bounded delegate when a full team is unnecessary.' }
    )
  }
}

if (-not (Test-Path $templatePath)) {
  Write-JsonUtf8NoBom $templatePath (New-DefaultAgentTeams) 10
}

$config = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$result = [pscustomobject]@{
  ok = $true
  path = $templatePath
  schemaVersion = $config.schemaVersion
  templateCount = @($config.templates).Count
  templates = @($config.templates)
}

if ($Json) {
  $result | ConvertTo-Json -Depth 10
} else {
  Write-Host "TEAM_TEMPLATE_LIST count=$($result.templateCount) path=$templatePath"
  foreach ($template in @($result.templates)) {
    Write-Host "TEAM_TEMPLATE id=$($template.id) name=$($template.name) roles=$(@($template.roles) -join ',') triggers=$(@($template.triggers) -join ',')"
  }
}
exit 0
