$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Describe 'H7-only maintenance and UI boundary' {
  It 'never includes retired Hook repair in confirmed maintenance actions' {
    $maintain = Get-Content -LiteralPath (Join-Path $Root 'scripts\maintain.ps1') -Raw -Encoding UTF8
    $start = $maintain.IndexOf('if ($ApplyConfirmed)')
    $end = $maintain.IndexOf('$safeActions =')
    $start | Should BeGreaterThan -1
    $end | Should BeGreaterThan $start
    $confirmedBlock = $maintain.Substring($start,$end-$start)
    $confirmedBlock.Contains('repair-hook.ps1') | Should Be $false
    $maintain.Contains('$separatelyAuthorizedH7Actions = @(''first-load-bootstrap.ps1 -RepairMcp'')') | Should Be $true
    $maintain.Contains('SUPER_BRAIN_HOOK_REPAIR_RETIRED') | Should Be $true
  }

  It 'keeps the retired Hook repair path fail-closed without modifying its supplied target' {
    $target = Join-Path $TestDrive 'legacy-session-start-hook.sh'
    [IO.File]::WriteAllText($target,"before`n",[Text.UTF8Encoding]::new($false))
    $before = Get-FileHash -LiteralPath $target -Algorithm SHA256
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\repair-hook.ps1') -PackageRoot $Root -HookPath $target -Json 2>&1)
    $LASTEXITCODE | Should Be 1
    $result = (($raw -join "`n") | ConvertFrom-Json)
    $result.ok | Should Be $false
    $result.state | Should Be 'withheld'
    $result.code | Should Be 'SUPER_BRAIN_HOOK_REPAIR_RETIRED'
    $result.hookWriteAttempted | Should Be $false
    $result.hookWriteAllowed | Should Be $false
    $result.h7Repair.entrypoint | Should Be 'scripts\first-load-bootstrap.ps1 -RepairMcp'
    (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash | Should Be $before.Hash
  }

  It 'makes the installer UI require H7 diagnostics instead of retired Hook repair' {
    $ui = Get-Content -LiteralPath (Join-Path $Root 'scripts\install-ui.ps1') -Raw -Encoding UTF8
    $start = $ui.IndexOf('$RequiredUiScripts = @(')
    $end = $ui.IndexOf('function Initialize-InstallUiAssemblies')
    $start | Should BeGreaterThan -1
    $end | Should BeGreaterThan $start
    $required = $ui.Substring($start,$end-$start)
    $required.Contains("'first-load-bootstrap.ps1'") | Should Be $true
    $required.Contains("'host-cache-check.ps1'") | Should Be $true
    $required.Contains("'repair-hook.ps1'") | Should Be $false
  }
}
