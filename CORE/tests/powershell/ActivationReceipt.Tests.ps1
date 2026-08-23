$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Cli = Join-Path $Root 'runtime\brain_cli.py'

function Invoke-ActivationCli([string]$StateRoot,[string[]]$Extra = @()) {
  $memoryRoot = Join-Path $StateRoot 'shared'
  New-Item -ItemType Directory -Force -Path $memoryRoot | Out-Null
  # Bare-wake activation is intentionally unscoped; explicit scope flags are
  # assertions and must match the current local cwd/session.
  $raw = @(& python -X utf8 $Cli --package-root $Root --memory-root $memoryRoot activate --route bare_wake @Extra 2>&1)
  $exitCode = $LASTEXITCODE
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{ exitCode=$exitCode; value=if($text){$text | ConvertFrom-Json}else{$null}; text=$text }
}

Describe 'Activation receipt and full-brain gate' {
  It 'requires a committed activation proof before reporting full brain active' {
    $state = Join-Path $TestDrive 'activation-full'
    $result = Invoke-ActivationCli $state
    $result.exitCode | Should Be 0
    $result.value.schema | Should Be 'super-brain.activation-receipt.v1'
    $result.value.activationState | Should Be 'full_brain_active'
    $result.value.capabilities.coreReady | Should Be $true
    $result.value.receiptHash | Should Match '^[a-f0-9]{64}$'
    $result.value.rawPromptStored | Should Be $false
  }

  It 'fails closed when a core activation dependency is missing' {
    $state = Join-Path $TestDrive 'activation-withheld'
    $result = Invoke-ActivationCli $state
    $result.exitCode | Should Be 0
    $result.value.activationState | Should Be 'full_brain_active'
    $result.value.actionAuthorization | Should Be 'not_applicable'

    $raw = @(& python -X utf8 $Cli --package-root $Root --memory-root (Join-Path $state 'missing-memory') activate --route current_session_continue 2>&1)
    $value = (($raw -join "`n") | ConvertFrom-Json)
    $value.activationState | Should Be 'failed'
    $value.actionAuthorization | Should Be 'withheld'
  }
}
