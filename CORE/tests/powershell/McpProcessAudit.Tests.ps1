$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Describe 'read-only MCP process audit' {
  It 'separates current-package processes and conservatively reports possible orphans' {
    $script = Join-Path $Root 'scripts\mcp-process-audit.ps1'
    $packageRoot = [IO.Path]::GetFullPath($Root)
    $fixture = @(
      [pscustomobject]@{
        processId = 41001
        parentProcessId = 41002
        name = 'python.exe'
        commandLine = "python `"$packageRoot\runtime\brain_mcp.py`" --package-root `"$packageRoot`" --memory-root `"$TestDrive\memory`""
        creationDate = '20260820000000.000000+000'
        privateMemoryBytes = 26000000
        workingSetBytes = 35000000
        cwd = $packageRoot
      }
      [pscustomobject]@{
        processId = 41002
        parentProcessId = 1
        name = 'codex.exe'
        commandLine = 'codex'
        creationDate = '20260820000000.000000+000'
      }
      [pscustomobject]@{
        processId = 41003
        parentProcessId = 49999
        name = 'python.exe'
        commandLine = "python `"$packageRoot\runtime\brain_mcp.py`" --package-root `"$packageRoot`""
        creationDate = '20200101000000.000000+000'
        privateMemoryBytes = 27000000
        workingSetBytes = 36000000
      }
      [pscustomobject]@{
        processId = 41004
        parentProcessId = 1
        name = 'python.exe'
        commandLine = 'python C:\other\runtime\brain_mcp.py --package-root C:\other'
        creationDate = '20200101000000.000000+000'
      }
    ) | ConvertTo-Json -Depth 8 -Compress
    $fixturePath = Join-Path $TestDrive 'mcp-process-fixture.json'
    [IO.File]::WriteAllText($fixturePath,$fixture,[Text.UTF8Encoding]::new($false))

    $raw = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script -PackageRoot $packageRoot -ProcessRecordsPath $fixturePath -OrphanAfterSeconds 300 -Json 2>&1)
    $LASTEXITCODE | Should Be 0
    $result = (($raw -join "`n") | ConvertFrom-Json)
    $result.schema | Should Be 'super-brain.mcp-process-audit.v1'
    $result.ok | Should Be $true
    $result.readOnly | Should Be $true
    $result.mutation | Should Be 'none'
    $result.canTerminate | Should Be $false
    $result.counts.currentPackage | Should Be 2
    $result.counts.possibleOrphan | Should Be 1
    $result.counts.staleForeignPackage | Should Be 1
    @($result.processes | Where-Object { $_.pid -eq 41001 -and $_.parentState -eq 'active' -and $_.state -eq 'active_or_unverified' }).Count | Should Be 1
    @($result.processes | Where-Object { $_.pid -eq 41003 -and $_.possibleOrphan -eq $true -and $_.action -eq 'report_only' }).Count | Should Be 1
  }

  It 'does not contain process termination or configuration mutation commands' {
    $text = Get-Content -LiteralPath (Join-Path $Root 'scripts\mcp-process-audit.ps1') -Raw -Encoding UTF8
    $text | Should Not Match '(?i)Stop-Process|taskkill|Remove-Item|Set-Content|Out-File|WriteAllText|Start-Process'
  }
}
