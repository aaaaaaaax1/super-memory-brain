Describe 'Super Memory Brain CI script' {
  It 'exists and writes last-ci.json in normal operation' {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Test-Path (Join-Path $root 'scripts\ci.ps1') | Should Be $true
    (Get-Content -LiteralPath (Join-Path $root 'scripts\ci.ps1') -Raw -Encoding UTF8).Contains('last-ci.json') | Should Be $true
  }
}
