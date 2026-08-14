$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$CapabilityMap = Join-Path $Root 'scripts\skill-capability-map.ps1'

function Write-TestCapabilityMap([string]$Path,[object]$Value) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}

function Invoke-TestCapabilityMap([string]$StateRoot,[string[]]$Arguments) {
  $previous = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $CapabilityMap @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $previous) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
    else { $env:SUPER_BRAIN_STATE_ROOT = $previous }
  }
  $text = ($raw -join "`n")
  return [pscustomobject]@{ exitCode=$exitCode; value=if($text){$text | ConvertFrom-Json}else{$null}; text=$text }
}

Describe 'Cold-start skill capability map' {
  It 'rebuilds the public derived cache when a fresh state root has no map' {
    $stateRoot = Join-Path $TestDrive ('cold-capability-map-' + [guid]::NewGuid().ToString('n'))
    $result = Invoke-TestCapabilityMap $stateRoot @('-Query','continue','-NoExtensions','-Json')

    $result.exitCode | Should Be 0
    $result.value.ok | Should Be $true
    $result.value.capabilityMapOrigin | Should Be 'package_public_seed'
    $result.value.capabilityMapRehydrated | Should Be $true
    $mapPath = Join-Path $stateRoot 'workspace\skill-capability-map.json'
    Test-Path -LiteralPath $mapPath | Should Be $true
    $stored = Get-Content -LiteralPath $mapPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $stored.source | Should Be 'package_public_seed'
    @($stored.capabilities | Where-Object { $_.name -eq 'grill-me' }).Count | Should Be 1
  }

  It 'keeps an explicit parseable state cache instead of replacing it with the seed' {
    $stateRoot = Join-Path $TestDrive ('explicit-capability-map-' + [guid]::NewGuid().ToString('n'))
    $mapPath = Join-Path $stateRoot 'workspace\skill-capability-map.json'
    Write-TestCapabilityMap $mapPath ([pscustomobject]@{
      schema='super-brain.skill-capability-map.v1'
      capabilities=@([pscustomobject]@{ name='local-test-capability'; category='rule'; role='local_test'; canDo=@('test'); cannotDo=@(); triggers=@('local'); applyAt=@('test'); verification=@('test') })
    })

    $result = Invoke-TestCapabilityMap $stateRoot @('-Name','local-test-capability','-NoExtensions','-Json')
    $result.exitCode | Should Be 0
    $result.value.capabilityMapOrigin | Should Be 'state_cache'
    $result.value.capabilityMapRehydrated | Should Be $false
    $result.value.count | Should Be 1
    $stored = Get-Content -LiteralPath $mapPath -Raw -Encoding UTF8 | ConvertFrom-Json
    @($stored.capabilities).Count | Should Be 1
    $stored.capabilities[0].name | Should Be 'local-test-capability'
  }
}
