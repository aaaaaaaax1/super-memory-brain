Describe 'Super Brain version bump privacy boundary' {
  BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $versionBump = Join-Path $root 'scripts\version-bump.ps1'
  }

  It 'updates versioned source metadata without writing private memory or a graph record' {
    $text = Get-Content -LiteralPath $versionBump -Raw -Encoding UTF8
    $text.Contains("'maintenance-policy.json'") | Should Be $true
    $text.Contains("'super-brain-rules.json'") | Should Be $true
    $text.Contains("'memory\graph.jsonl'") | Should Be $false
    $text.Contains('graph-add.ps1') | Should Be $false

    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $versionBump -Version '0.6.0' -Summary 'preview only' -Supersedes '0.5.98' -Json 2>&1)
    $LASTEXITCODE | Should Be 0
    $result = ($raw -join "`n") | ConvertFrom-Json
    $paths = @($result.actions | ForEach-Object { [string]$_.path })
    ($paths -contains 'maintenance-policy.json') | Should Be $true
    ($paths -contains 'super-brain-rules.json') | Should Be $true
    ($paths -contains 'memory\graph.jsonl') | Should Be $false
  }

  It 'uses the runtime canonical JSON algorithm when re-signing the core rule registry' {
    $fixture = Join-Path $TestDrive 'version-bump-registry-hash'
    $scripts = Join-Path $fixture 'scripts'
    $runtime = Join-Path $fixture 'runtime'
    $tests = Join-Path $fixture 'tests'
    New-Item -ItemType Directory -Force -Path $scripts,$runtime,$tests | Out-Null
    foreach ($name in @('manifest.json','README.md','CHANGELOG.md','CURRENT_BASELINE.md','BASELINE_HISTORY.md','maintenance-policy.json','super-brain-rules.json')) {
      Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $fixture $name) -Force
    }
    foreach ($name in @('common.ps1','version-bump.ps1')) {
      Copy-Item -LiteralPath (Join-Path $root ('scripts\' + $name)) -Destination (Join-Path $scripts $name) -Force
    }
    Copy-Item -LiteralPath (Join-Path $root 'tests\memory-recall-tests.json') -Destination (Join-Path $tests 'memory-recall-tests.json') -Force
    Copy-Item -LiteralPath (Join-Path $root 'runtime\core_rule_registry.py') -Destination (Join-Path $runtime 'core_rule_registry.py') -Force

    $fixtureBump = Join-Path $scripts 'version-bump.ps1'
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixtureBump -Version '0.6.1' -Summary 'fixture registry re-sign' -Supersedes '0.6.0' -Apply -Json 2>&1)
    $LASTEXITCODE | Should Be 0
    (($raw -join "`n") | ConvertFrom-Json).mode | Should Be 'applied'

    $probe = @'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "runtime"))
from core_rule_registry import load_registry

manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
result = load_registry(root, manifest=manifest)
assert result["status"] == "current", result
assert result["packageVersion"] == "0.6.1", result
'@
    $probePath = Join-Path $fixture 'probe_registry.py'
    [IO.File]::WriteAllText($probePath,$probe,[Text.UTF8Encoding]::new($false))
    $probeOutput = @(& python $probePath $fixture 2>&1)
    $LASTEXITCODE | Should Be 0
    $probeOutput | Should BeNullOrEmpty
  }
}
