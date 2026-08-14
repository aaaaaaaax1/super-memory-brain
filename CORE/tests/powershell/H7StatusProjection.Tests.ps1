$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $Root 'scripts\common.ps1')

function New-H7StatusProjectionFixture {
  $profile = Join-Path $TestDrive ('h7-status-' + [guid]::NewGuid().ToString('n'))
  $codexSkills = Join-Path $profile 'codex\skills'
  $zcodeSkills = Join-Path $profile 'missing-zcode\skills'
  $codexHome = Split-Path -Parent $codexSkills
  $memoryRoot = Get-SuperBrainActiveMemoryRoot $Root
  $encoding = [Text.UTF8Encoding]::new($false)

  New-Item -ItemType Directory -Force -Path $codexSkills | Out-Null
  [IO.File]::WriteAllText(
    (Join-Path $codexHome 'AGENTS.md'),
    ((Get-SuperBrainGlobalStartupBlock $Root) + "`n"),
    $encoding
  )
  foreach ($skillName in Get-SuperBrainSkillNames) {
    $skillDir = Join-Path $codexSkills $skillName
    New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $skillDir 'SKILL.md'),"---`nname: fixture`n---`n",$encoding)
    [IO.File]::WriteAllText((Join-Path $skillDir 'package-root.txt'),($Root + "`n"),$encoding)
    [IO.File]::WriteAllText((Join-Path $skillDir 'memory-root.txt'),($memoryRoot + "`n"),$encoding)
  }
  return [pscustomobject]@{ codexHome=$codexHome; codexSkills=$codexSkills; zcodeSkills=$zcodeSkills; memoryRoot=$memoryRoot }
}

Describe 'H7 status projection' {
  It 'fails closed on a Super Brain retired-transport registration conflict without reviving legacy axes' {
    $fixture = New-H7StatusProjectionFixture
    [IO.File]::WriteAllText(
      (Join-Path $fixture.codexHome 'hooks.json'),
      '{"hooks":{"UserPromptSubmit":[{"command":"python super-memory-brain legacy-entry.py"}]}}',
      [Text.UTF8Encoding]::new($false)
    )

    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\startup-check.ps1') -ZCodeSkills $fixture.zcodeSkills -CodexSkills $fixture.codexSkills -MemoryRoot $fixture.memoryRoot -Isolated -Json 2>&1)
    $LASTEXITCODE | Should Be 1
    $result = (($raw -join "`n") | ConvertFrom-Json)

    $result.coreAvailable | Should Be $false
    $result.turnRuntime.state | Should Be 'withheld'
    $result.retiredTransportGuard.state | Should Be 'withheld'
    $result.retiredTransportGuard.code | Should Be 'H7_SUPER_BRAIN_HOOK_REGISTRATION_CONFLICT'
    $result.retiredTransportGuard.requiredForCore | Should Be $true
    $result.retiredTransportGuard.actionAuthorization | Should Be 'not_authorizing'
    (@($result.PSObject.Properties.Name) -contains 'hookAcceleration') | Should Be $false
    (@($result.PSObject.Properties.Name) -contains 'p7') | Should Be $false
  }
}
