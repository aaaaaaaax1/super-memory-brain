Describe 'Super Memory Brain common helpers' {
  BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $root 'scripts\common.ps1')
  }

  It 'resolves an explicit hook path' {
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) 'super-brain-hook-test'
    Get-SuperBrainHookPath $temp | Should Be ([System.IO.Path]::GetFullPath($temp))
  }

  It 'writes UTF-8 without BOM' {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('super-brain-nobom-' + [guid]::NewGuid().ToString() + '.json')
    Write-Utf8NoBom $path '{"ok":true}'
    try {
      $bytes = [System.IO.File]::ReadAllBytes($path)
      (($bytes.Length -ge 3) -and ($bytes[0] -eq 239) -and ($bytes[1] -eq 187) -and ($bytes[2] -eq 191)) | Should Be $false
    } finally {
      Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
  }
}
