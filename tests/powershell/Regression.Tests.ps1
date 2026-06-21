Describe '0.5.28 regression guards' {
  BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  }

  It 'keeps task verification parameters non-positional' {
    $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\task-verification.ps1') -Raw -Encoding UTF8
    $scriptText | Should Match '\[CmdletBinding\(PositionalBinding\s*=\s*\$false\)\]'
  }

  It 'restores memory sharing policy after smoke tests' {
    $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\smoke-test.ps1') -Raw -Encoding UTF8
    $scriptText.Contains('Get-SuperBrainSharingPolicyPath') | Should Be $true
    $scriptText.Contains('Write-Utf8NoBom $policyPath $originalPolicy') | Should Be $true
    $scriptText.Contains('Remove-Item -LiteralPath $policyPath -Force') | Should Be $true
  }

  It 'restores memory sharing policy after verify-package temp installs' {
    $scriptText = Get-Content -LiteralPath (Join-Path $root 'scripts\verify-package.ps1') -Raw -Encoding UTF8
    $scriptText.Contains('.tmp-verify-package') | Should Be $true
    $scriptText.Contains('Get-SuperBrainSharingPolicyPath') | Should Be $true
    $scriptText.Contains('Write-Utf8NoBom $policyPath $originalPolicy') | Should Be $true
    $scriptText.Contains('Remove-Item -LiteralPath $policyPath -Force') | Should Be $true
  }
}
