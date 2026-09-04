$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Runner = Join-Path $Root 'scripts\autonomous-executor-e2e.ps1'

Describe 'Autonomous executor end-to-end user path' {
  It 'proves the P0 canonical plan path and its fail-closed counterexamples in one isolated run' {
    $outputPath = Join-Path $TestDrive 'autonomous-executor-e2e.json'
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Runner -Json -OutputPath $outputPath 2>$null)
    $LASTEXITCODE | Should Be 0
    $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
    $result = $text | ConvertFrom-Json

    $result.ok | Should Be $true
    $result.path | Should Be ([IO.Path]::GetFullPath($outputPath))
    foreach($name in @(
      'p0-approved-plan-creates-canonical-a-through-g',
      'p0-formal-phase-is-bound-to-current-contract',
      'p0-additive-user-request-appends-h-and-i',
      'p0-side-branch-keeps-canonical-a-through-i-visible',
      'p0-return-to-parent-restores-canonical-main',
      'p0-compatibility-completion-keeps-workspaces-isolated',
      'p0-h7-runtime-observes-current-plan',
      'p0-h7-runtime-never-promotes-local-work-package',
      'p0-formal-phase-rejects-static-only-advance',
      'p0-legacy-closeout-schema-is-rejected',
      'p0-h7-closeout-binding-mismatch-is-rejected',
      'p0-missing-full-plan-stops-at-admission-gate',
      'p0-reconciliation-conflict-blocks-local-execution',
      'phase-closeout-generalizes-h7-current-policy-beyond-p0'
    )){
      $check = @($result.checks | Where-Object { $_.name -eq $name })
      $check.Count | Should Be 1
      $check[0].ok | Should Be $true
    }
  }
}
