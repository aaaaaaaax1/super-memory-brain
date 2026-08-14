$root = Split-Path -Parent (Split-Path $PSScriptRoot)
$scriptPath = Join-Path $root 'scripts\longmemeval-v2.ps1'

function Invoke-LmeV2([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments 2>$null)
  return [pscustomobject]@{ exitCode=$LASTEXITCODE; value=(($raw -join "`n") | ConvertFrom-Json) }
}

Describe 'LongMemEval-V2 private bootstrap' {
  It 'reports a safe readiness snapshot without a model call or corpus download' {
    $result = Invoke-LmeV2 @('-Action','Status','-Json')

    $result.exitCode | Should Be 0
    $result.value.ok | Should Be $true
    $result.value.schema | Should Be 'super-brain.longmemeval-v2-bootstrap.v1'
    $result.value.harness.expectedCommit | Should Be '6f020ac2fc3275e46c706d3406e02c3ed79b7be2'
    $result.value.data.requiredTrajectoryBytes | Should Be 1195604539
    $result.value.data.textOnlyClassification | Should Be 'official_harness_text_memory_ablation_not_leaderboard'
    $result.value.privateRuntime.autoBootstrapAvailable | Should Be $true
    $result.value.privateRuntime.installer.version | Should Be '3.11.9'
    $result.value.privateRuntime.installer.sha256 | Should Be '5ee42c4eee1e6b4464bb23722f90b45303f79442df63083f05322f1785f5fdde'
    $result.value.rawPromptStored | Should Be $false
    $result.value.rawAnswerStored | Should Be $false
  }

  It 'requires Apply before any environment or corpus mutation' {
    foreach ($action in @('Prepare','FetchTextData')) {
      $result = Invoke-LmeV2 @('-Action',$action,'-Json')
      $result.exitCode | Should Be 1
      $result.value.ok | Should Be $false
      $result.value.code | Should Be 'LME_V2_APPLY_REQUIRED'
      if ($action -eq 'Prepare') { $result.value.nextAction | Should Match 'hash-verified private Python 3.11 runtime' }
    }
  }

  It 'keeps Python installation private and data retrieval explicitly bounded' {
    $text = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8

    $text.Contains('LongMemEval-V2-python311') | Should Be $true
    $text.Contains('python-3.11.9-amd64.exe') | Should Be $true
    $text.Contains('Get-AuthenticodeSignature') | Should Be $true
    $text.Contains('InstallAllUsers=0') | Should Be $true
    $text.Contains('PrependPath=0') | Should Be $true
    $text.Contains('Include_launcher=0') | Should Be $true
    $text.Contains('TargetDir=') | Should Be $true
    $text.Contains('winget ') | Should Be $false
    $text.Contains('hf_hub_download') | Should Be $true
    $text.Contains('trajectory_screenshots') | Should Be $false
    $text.Contains('PATH, launcher, and file associations remain disabled.') | Should Be $true
    $text.Contains('rawPromptStored=$false') | Should Be $true
    $text | Should Match '\$pipUpgradeOutput = @\(& \$venvPython -m pip install --upgrade pip 2>&1\)'
    $text | Should Match '\$pipInstallOutput = @\(& \$venvPython -m pip install -r'
  }

  It 'keeps native Python probes compatible with Windows PowerShell argument passing' {
    $text = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8

    $text | Should Not Match 'print\("%d\.%d\.%d" % sys\.version_info\[:3\]\)'
    $text | Should Match "print\(''%d\.%d\.%d'' % sys\.version_info\[:3\]\)"
    $text | Should Not Match '\$venvPython -c \$downloadProgram'
    $text | Should Match '\[IO\.File\]::WriteAllText\(\$programPath, \$downloadProgram'
  }

  It 'accepts the final downloader JSON after non-JSON Hub diagnostics' {
    $text = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8

    $text.Contains('function ConvertFrom-LmeV2FinalJsonLine') | Should Be $true
    $text.Contains('for ($index = $Lines.Count - 1; $index -ge 0; $index--)') | Should Be $true
    $text.Contains('$result = ConvertFrom-LmeV2FinalJsonLine $raw') | Should Be $true
    $text.Contains("if (`$result.ok -ne `$true) { throw 'LME_V2_DATA_FETCH_RESULT_INVALID' }") | Should Be $true
    $text.Contains('$nativeErrorActionPreference = $ErrorActionPreference') | Should Be $true
    $text.Contains("`$ErrorActionPreference = 'Continue'") | Should Be $true
    $text.Contains('$ErrorActionPreference = $nativeErrorActionPreference') | Should Be $true
    $text.Contains('if isinstance(image, str) and image.strip():') | Should Be $true
    $text.Contains('image_files = sorted(image_files)') | Should Be $true
    $text.Contains('files = base_files[:-1] + image_files') | Should Be $true
    $text.Contains('if image_path.is_absolute() or ".." in image_path.parts:') | Should Be $true
    $text.Contains('image_cache = root / ".image-hf-cache"') | Should Be $true
    $text.Contains('def download_image(name):') | Should Be $true
    $text.Contains('cached_path = fetch_with_retry(name, cache_dir=str(image_cache))') | Should Be $true
    $text.Contains('shutil.copy2(cached_path, destination)') | Should Be $true
    $text.Contains('from huggingface_hub.utils import close_session') | Should Be $true
    $text.Contains('for attempt in range(4):') | Should Be $true
    $text.Contains('close_session()') | Should Be $true
    $text.Contains('time.sleep(2 ** attempt)') | Should Be $true
  }
}
