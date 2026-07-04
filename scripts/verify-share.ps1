param(
  [string]$Destination = "",
  [switch]$SkipPrepare
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Destination)) {
  $Destination = Join-Path (Split-Path -Parent $Root) 'super-memory-brain-package-share'
}

if (-not $SkipPrepare) {
  & (Join-Path $PSScriptRoot 'prepare-share.ps1') -Destination $Destination | Out-Null
}

$ok = $true
function Fail([string]$Message) {
  Write-Host "FAILED $Message"
  $script:ok = $false
}
function Pass([string]$Message) {
  Write-Host "OK $Message"
}

function Get-RelativePath([string]$BasePath, [string]$Path) {
  $baseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
  $pathFull = [System.IO.Path]::GetFullPath($Path)
  $baseUri = [System.Uri]::new($baseFull)
  $pathUri = [System.Uri]::new($pathFull)
  return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString()).Replace('/', '\')
}

$manifestPath = Join-Path $Destination 'manifest.json'
if (Test-Path $manifestPath) {
  $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  Pass 'manifest parse'
} else {
  Fail 'missing manifest.json'
  $manifest = [pscustomobject]@{ scripts = @(); internalScripts = @() }
}

$markerPath = Join-Path $Destination '.super-memory-brain-share-marker'
if (Test-Path $markerPath) { Pass 'share marker present' } else { Fail 'share marker missing' }

$gitIgnorePath = Join-Path $Destination '.gitignore'
if (Test-Path $gitIgnorePath) { Pass 'public .gitignore present' } else { Fail 'public .gitignore missing' }

$forbiddenFiles = @(
  'memory\sandglass.txt',
  'memory\sandglass.idx',
  'memory\sandglass.db',
  'memory\shadow_sand.db',
  'memory\decision_particles.txt',
  'memory\workspace\sandglass.txt',
  'memory\workspace\shadow_sand.db',
  'memory\workspace\last-verify-package.json',
  'memory\workspace\last-memory-eval.json',
  'memory\workspace\memory-sharing-policy.json',
  'memory\workspace\super-brain-state.json',
  'memory\shared\sandglass.txt',
  'memory\shared\sandglass.idx',
  'memory\shared\sandglass.db',
  'memory\shared\decision_particles.txt'
)
foreach ($rel in $forbiddenFiles) {
  $path = Join-Path $Destination $rel
  if (Test-Path $path) { Fail "forbidden file $rel" } else { Pass "missing file $rel" }
}

$allFiles = @(Get-ChildItem -LiteralPath $Destination -Recurse -Force -File -ErrorAction SilentlyContinue)
$allDirs = @(Get-ChildItem -LiteralPath $Destination -Recurse -Force -Directory -ErrorAction SilentlyContinue)
$rootMarkers = @($allFiles | Where-Object { $_.Name -in @('package-root.txt','memory-root.txt','.memory-scope.json','memory-sharing-policy.json') })
if ($rootMarkers.Count -eq 0) { Pass 'no root markers in share' } else { Fail ('root marker leaked ' + (($rootMarkers | Select-Object -First 10 | ForEach-Object { Get-RelativePath $Destination $_.FullName }) -join ',')) }

$forbiddenPublicDirs = @(
  '^\.git$',
  '^.*\\\.git$',
  '^install-backup-[^\\]+$',
  '^.*\\install-backup-[^\\]+$',
  '^super-memory-brain-package-private[^\\]*$',
  '^.*\\super-memory-brain-package-private[^\\]*$'
)
foreach ($pattern in $forbiddenPublicDirs) {
  $matches = @($allDirs | Where-Object { (Get-RelativePath $Destination $_.FullName) -match $pattern })
  if ($matches.Count -eq 0) {
    Pass "no forbidden public dir $pattern"
  } else {
    Fail ("forbidden public dir $pattern " + (($matches | Select-Object -First 5 | ForEach-Object { Get-RelativePath $Destination $_.FullName }) -join ','))
  }
}

$privatePathPatterns = @(
  '^memory\\workspace\\.*\.json$',
  '^memory\\shared\\.*$',
  '^memory\\agents\\.*$',
  '^memory\\groups\\.*$',
  '^memory\\.*\.db$',
  '^memory\\.*\.idx$',
  '^memory\\.*\.bak.*$',
  '^memory\\.*\\.*\.bak.*$',
  '^\.env$',
  '^.*\\\.env$',
  '^.*\.secret$',
  '^.*\.key$',
  '^.*\.pem$',
  '^.*\.pfx$'
)
foreach ($pattern in $privatePathPatterns) {
  $matches = @($allFiles | Where-Object { (Get-RelativePath $Destination $_.FullName) -match $pattern })
  if ($matches.Count -eq 0) {
    Pass "privacy path clean $pattern"
  } else {
    Fail ("privacy path leak $pattern " + (($matches | Select-Object -First 5 | ForEach-Object { Get-RelativePath $Destination $_.FullName }) -join ','))
  }
}

$textFiles = @($allFiles | Where-Object { $_.Extension -in @('.md','.json','.ps1','.bat','.py','.txt','.toml','.yaml','.yml') })
$sensitivePattern = '(?i)(api[_-]?key|secret[_-]?key|access[_-]?token|refresh[_-]?token|password|cookie|authorization)\s*[=:]\s*[''\"]?[A-Za-z0-9_\-\./+=]{16,}'
$sensitiveHits = @()
foreach ($file in $textFiles) {
  try {
    $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
    if ($text -match $sensitivePattern) {
      $sensitiveHits += (Get-RelativePath $Destination $file.FullName)
    }
  } catch {}
}
if ($sensitiveHits.Count -eq 0) { Pass 'sensitive text scan clean' } else { Fail ('sensitive text hit ' + (($sensitiveHits | Select-Object -First 10) -join ',')) }

$localPathPatterns = @(
  'C:\\Users\\MSJ',
  'G:\\Ai\\Zcode项目'
)
$localPathHits = @()
foreach ($file in $textFiles) {
  try {
    $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
    foreach ($pattern in $localPathPatterns) {
      if ($text -match $pattern) {
        $localPathHits += ((Get-RelativePath $Destination $file.FullName) + " => $pattern")
        break
      }
    }
  } catch {}
}
if ($localPathHits.Count -eq 0) { Pass 'local absolute path scan clean' } else { Fail ('local absolute path hit ' + (($localPathHits | Select-Object -First 10) -join ',')) }

$emptyDirs = @('memory\persona','memory\archive','memory\shared','memory\agents','memory\groups')
foreach ($rel in $emptyDirs) {
  $path = Join-Path $Destination $rel
  if (-not (Test-Path $path)) {
    Pass "missing private dir $rel"
    continue
  }
  $items = @(Get-ChildItem -LiteralPath $path -Force)
  if ($items.Count -eq 0) { Pass "empty private dir $rel" } else { Fail "non-empty private dir $rel" }
}

$required = @(
  'README.md','QUICK_START.md','COMMANDS.md','manifest.json','CHANGELOG.md','CURRENT_BASELINE.md','BASELINE_HISTORY.md','memory-policy.json',
  'tests\memory-recall-tests.json','tests\memory-eval-tests.json',
  'super-memory-brain\SKILL.md',
  'references\index.md',
  'references\single-agent-subagent-workflow.md',
  'references\automatic-evolution-policy.md',
  'references\base-instructions\gpt-5.5-base-instructions.md',
  'modules\skill-orchestrator\SKILL.md',
  'modules\plusunm-g1\SKILL.md',
  'modules\nexsandglass-dedicated-memory\SKILL.md',
  'vendor\NexSandglass-Agent-DedicatedMemory\sandglass_log.py',
  'memory\scripts\sandglass_log.py',
  'memory\scripts\sandglass_vault.py'
)
foreach ($rel in $required) {
  $path = Join-Path $Destination $rel
  if (Test-Path $path) { Pass "required $rel" } else { Fail "missing $rel" }
}

$manifestScripts = @($manifest.scripts)
$duplicates = @($manifestScripts | Group-Object | Where-Object { $_.Count -gt 1 })
if ($duplicates.Count -eq 0) { Pass 'manifest scripts unique' } else { Fail ('duplicate manifest scripts ' + (($duplicates | ForEach-Object { $_.Name }) -join ',')) }

$manifestExtensions = @($manifest.extensions)
if ($manifestExtensions.Count -gt 0) { Pass 'manifest extensions present' } else { Fail 'manifest extensions missing' }
foreach ($extension in $manifestExtensions) {
  $extensionId = [string]$extension.id
  $extensionPathText = ([string]$extension.path).Replace('/', '\')
  if ([string]::IsNullOrWhiteSpace($extensionId)) {
    Fail 'manifest extension id missing'
    continue
  }
  if ([string]::IsNullOrWhiteSpace($extensionPathText)) {
    Fail "extension path missing $extensionId"
    continue
  }

  $extensionPath = Join-Path $Destination $extensionPathText
  if (Test-Path $extensionPath) { Pass "extension dir $extensionId" } else { Fail "missing extension dir $extensionId"; continue }

  $extensionManifestPath = Join-Path $extensionPath 'extension.json'
  if (Test-Path $extensionManifestPath) {
    Pass "extension manifest $extensionId"
    try { $extensionManifest = Get-Content -LiteralPath $extensionManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Fail "extension manifest parse $extensionId"; $extensionManifest = $null }
  } else {
    Fail "missing extension manifest $extensionId"
    $extensionManifest = $null
  }

  if ($extensionManifest -and [string]$extensionManifest.id -eq $extensionId) { Pass "extension id match $extensionId" } else { Fail "extension id mismatch $extensionId" }
  $extensionSkills = if ($extensionManifest) { @($extensionManifest.skills) } else { @($extension.skills) }
  if (@($extensionSkills).Count -gt 0) { Pass "extension skills listed $extensionId" } else { Fail "extension skills missing $extensionId" }
  foreach ($skill in $extensionSkills) {
    $skillName = [string]$skill.name
    $skillPathText = ([string]$skill.path).Replace('/', '\')
    if ([string]::IsNullOrWhiteSpace($skillName) -or [string]::IsNullOrWhiteSpace($skillPathText)) {
      Fail "extension skill metadata missing $extensionId"
      continue
    }
    $skillFile = Join-Path (Join-Path $extensionPath $skillPathText) 'SKILL.md'
    if (Test-Path $skillFile) { Pass "extension skill $extensionId/$skillName" } else { Fail "missing extension skill $extensionId/$skillName" }
  }
}

foreach ($script in $manifestScripts) {
  $path = Join-Path (Join-Path $Destination 'scripts') $script
  if (Test-Path $path) { Pass "manifest script $script" } else { Fail "missing manifest script $script" }
}

$actualPublicScripts = @(Get-ChildItem -LiteralPath (Join-Path $Destination 'scripts') -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.ps1','.bat','.vbs') } | ForEach-Object { $_.Name })
foreach ($script in $actualPublicScripts) {
  if ($manifestScripts -contains $script) { Pass "no extra public script $script" } else { Fail "extra public script $script" }
}

$internalScripts = @($manifest.internalScripts)
foreach ($script in $internalScripts) {
  $path = Join-Path (Join-Path $Destination 'scripts') $script
  if (Test-Path $path) { Fail "internal script leaked $script" } else { Pass "internal script excluded $script" }
}

$extraPythonScripts = @(Get-ChildItem -LiteralPath (Join-Path $Destination 'scripts') -File -Filter '*.py' -ErrorAction SilentlyContinue)
if ($extraPythonScripts.Count -eq 0) { Pass 'no python helpers in public scripts' } else { Fail ('python helper leaked ' + (($extraPythonScripts | ForEach-Object { $_.Name }) -join ',')) }

$forbiddenPaths = @(
  'vendor\NexSandglass-Agent-DedicatedMemory\.git',
  'vendor\NexSandglass-Agent-DedicatedMemory\NexSandglass_v2.9.9.zip',
  'vendor\NexSandglass-Agent-DedicatedMemory\demo'
)
foreach ($rel in $forbiddenPaths) {
  $path = Join-Path $Destination $rel
  if (Test-Path $path) { Fail "vendor bloat $rel" } else { Pass "no vendor bloat $rel" }
}

$cacheDirs = @(Get-ChildItem -LiteralPath $Destination -Directory -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq '__pycache__' })
if ($cacheDirs.Count -eq 0) { Pass 'no __pycache__ dirs' } else { Fail "__pycache__ dirs count=$($cacheDirs.Count)" }

$pycFiles = @(Get-ChildItem -LiteralPath $Destination -File -Recurse -Force -Filter '*.pyc' -ErrorAction SilentlyContinue)
if ($pycFiles.Count -eq 0) { Pass 'no pyc files' } else { Fail "pyc files count=$($pycFiles.Count)" }

if ($ok) {
  Write-Host 'VERIFY_SHARE_OK'
  exit 0
} else {
  Write-Host 'VERIFY_SHARE_FAILED'
  exit 1
}
