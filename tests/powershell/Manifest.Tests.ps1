Describe 'Super Memory Brain package manifest' {
  It 'parses manifest and includes core automation scripts' {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    [string]::IsNullOrWhiteSpace($manifest.version) | Should Be $false
    @($manifest.scripts) -contains 'ci.ps1' | Should Be $true
    @($manifest.scripts) -contains 'common.ps1' | Should Be $true
    @($manifest.scripts) -contains 'engineering-decision-gate.ps1' | Should Be $true
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'engineering-decision-gate.ps1' }).tier | Should Be 'T1'
    @($manifest.runtimeFiles) -contains 'sandglass_vault.py' | Should Be $true
  }
}
