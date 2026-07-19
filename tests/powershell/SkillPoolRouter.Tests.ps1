$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $root 'modules\skill-pool-router\scripts\manage-skill-pool.ps1'
$utf8 = New-Object System.Text.UTF8Encoding($false)

Describe 'Skill pool content health' {
  BeforeEach {
    $caseRoot = Join-Path ([IO.Path]::GetTempPath()) ('skill-pool-health-' + [Guid]::NewGuid().ToString('N'))
    $active = Join-Path $caseRoot 'active'
    $cold = Join-Path $caseRoot 'cold'
    New-Item -ItemType Directory -Force -Path $active,$cold | Out-Null
  }

  AfterEach {
    if(Test-Path -LiteralPath $caseRoot){Remove-Item -LiteralPath $caseRoot -Recurse -Force}
  }

  It 'reports valid UTF-8 skill content as healthy' {
    $skill = Join-Path $cold 'healthy\SKILL.md'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $skill) | Out-Null
    $healthyDescription=-join(@(27491,24120,20013,25991)|ForEach-Object{[char]$_})
    $healthyTitle=-join(@(27491,24120,25216,33021)|ForEach-Object{[char]$_})
    [IO.File]::WriteAllText($skill,"---`nname: healthy`ndescription: $healthyDescription`n---`n`n# $healthyTitle`n",$utf8)

    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Report -ActiveRoot $active -ColdRoot $cold -Json
    $LASTEXITCODE | Should Be 0
    $report = ($output -join "`n") | ConvertFrom-Json
    $report.ok | Should Be $true
    $report.contentProblemCount | Should Be 0
  }

  It 'rejects semantic mojibake even when the file is valid UTF-8' {
    $skill = Join-Path $cold 'broken\SKILL.md'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $skill) | Out-Null
    $brokenTitle=-join(@(37711,23944,22402,37922,29111,27992)|ForEach-Object{[char]$_})
    [IO.File]::WriteAllText($skill,"---`nname: broken`ndescription: valid metadata`n---`n`n# $brokenTitle`n",$utf8)

    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Report -ActiveRoot $active -ColdRoot $cold -Json
    $LASTEXITCODE | Should Be 1
    $report = ($output -join "`n") | ConvertFrom-Json
    $report.ok | Should Be $false
    $report.contentProblemCount | Should Be 1
    $report.contentProblems[0].problem | Should Be 'mojibake_marker'
  }

  It 'excludes backup control directories from every live catalog scan' {
    . (Join-Path $root 'modules\skill-pool-router\scripts\skill-catalog.ps1')
    foreach($folder in @('live-skill','.removed-backup\archived-skill','.repair-backups\repaired-skill')) {
      $skill = Join-Path (Join-Path $cold $folder) 'SKILL.md'
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $skill) | Out-Null
      [IO.File]::WriteAllText($skill,"---`nname: $(Split-Path -Leaf (Split-Path -Parent $skill))`ndescription: Catalog fixture.`n---`n",$utf8)
    }

    $files = @(Get-SkillCatalogFiles $cold)
    $files.Count | Should Be 1
    $files[0].FullName.Contains('live-skill') | Should Be $true
    @($files | Where-Object { $_.FullName -match '\\.removed-backup|\\.repair-backups' }).Count | Should Be 0
  }
}
