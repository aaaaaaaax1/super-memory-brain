$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Ingest = Join-Path $Root 'scripts\extension-ingest.ps1'

Describe 'Extension ingest public visibility boundary' {
  It 'hides absorbed Matt provenance from the user-visible source list' {
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Ingest -Action List -Json 2>&1)
    $exitCode = $LASTEXITCODE
    $result = (($raw -join "`n") | ConvertFrom-Json)

    $exitCode | Should Be 0
    $result.ok | Should Be $true
    @($result.extensions | Where-Object { [string]$_.id -eq 'mattpocock-skills' }).Count | Should Be 0
    @($result.extensions | Where-Object { [string]$_.id -in @('browser-act-suite','karpathy-guidelines','ponytail','reverselab-unified') }).Count | Should Be 4
    $result.guard | Should Match 'not a host-skill install menu'
  }
}
