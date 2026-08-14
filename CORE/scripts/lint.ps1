$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$ok = $true

$psScripts = @(Get-ChildItem -LiteralPath (Join-Path $Root 'scripts') -Filter '*.ps1' -File)
foreach ($script in $psScripts) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count -eq 0) {
    Write-Host "LINT_PARSE_OK scripts\$($script.Name)"
  } else {
    Write-Host "LINT_PARSE_FAILED scripts\$($script.Name) $($errors[0].Message)"
    $ok = $false
  }
}

$analyzer = Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue
if ($analyzer) {
  $issues = @(Invoke-ScriptAnalyzer -Path (Join-Path $Root 'scripts') -Recurse -Severity Error)
  if ($issues.Count -eq 0) {
    Write-Host 'LINT_SCRIPT_ANALYZER_OK'
  } else {
    foreach ($issue in $issues) {
      Write-Host "LINT_SCRIPT_ANALYZER_FAILED $($issue.ScriptName):$($issue.Line) $($issue.RuleName) $($issue.Message)"
    }
    $ok = $false
  }
} else {
  Write-Host 'LINT_SCRIPT_ANALYZER_SKIPPED reason=PSScriptAnalyzer_not_installed'
}

if ($ok) {
  Write-Host 'LINT_OK'
  exit 0
}

Write-Host 'LINT_FAILED'
exit 1
