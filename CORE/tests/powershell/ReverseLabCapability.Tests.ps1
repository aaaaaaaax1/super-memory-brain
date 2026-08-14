$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Invoke-CapabilityMapJson([string]$ScriptName, [string]$Query, [int]$TopK = 8) {
  $script = Join-Path $Root "scripts\$ScriptName"
  Test-Path -LiteralPath $script | Should Be $true
  $json = & $script -Query $Query -TopK $TopK -Json
  if ($LASTEXITCODE -ne 0) { throw "$ScriptName failed for query '$Query'" }
  return ($json | ConvertFrom-Json)
}

function Get-CapabilityByName($Result, [string]$Name) {
  return @($Result.capabilities | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
}

Describe 'ReverseLab capability regression' {
  $casesPath = Join-Path $Root 'tests\reverselab-capability-regression-cases.json'
  $cases = Get-Content -Raw -LiteralPath $casesPath -Encoding UTF8 | ConvertFrom-Json

  It 'keeps ReverseLab positive extension triggers strong and first' {
    foreach ($case in @($cases.positiveCases)) {
      $result = Invoke-CapabilityMapJson 'extension-capability-map.ps1' $case.query 5
      $first = @($result.capabilities | Select-Object -First 1)
      $first.name | Should Be $case.expectedExtensionFirst
      $first.matchStrength | Should Be $case.expectedExtensionStrength
    }
  }

  It 'keeps ReverseLab visible in skill capability map for positive triggers' {
    foreach ($case in @($cases.positiveCases)) {
      $result = Invoke-CapabilityMapJson 'skill-capability-map.ps1' $case.query 8
      $match = Get-CapabilityByName $result $case.expectedSkillName
      $null -eq $match | Should Be $false
      [int]$match.score | Should BeGreaterThan ([int]$case.minimumSkillScore - 1)
    }
  }

  It 'does not strong-match ReverseLab in extension map for generic reverse or security phrases' {
    foreach ($case in @($cases.negativeCases)) {
      $result = Invoke-CapabilityMapJson 'extension-capability-map.ps1' $case.query 8
      $strongReverseLab = @($result.capabilities | Where-Object {
        $_.name -eq $case.blockedExtensionStrongName -and $_.matchStrength -eq 'strong'
      })
      @($strongReverseLab).Count | Should Be 0
    }
  }

  It 'does not treat skill map TopK visibility as a ReverseLab trigger for negative phrases' {
    foreach ($case in @($cases.negativeCases)) {
      $result = Invoke-CapabilityMapJson 'skill-capability-map.ps1' $case.query 8
      $first = @($result.capabilities | Select-Object -First 1)
      if ($null -ne $first) {
        $first.name | Should Not Be $case.blockedSkillFirstName
      }
      $match = Get-CapabilityByName $result $case.blockedSkillFirstName
      if ($null -ne $match) {
        [int]$match.score | Should BeLessThan ([int]$case.maximumSkillScore + 1)
      }
    }
  }
}