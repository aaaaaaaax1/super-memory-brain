param(
  [switch]$SmokeTest
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$script:LogBox = $null
$script:MainForm = $null
$script:Tabs = $null
$script:ClearLogButton = $null
$script:UiTaskRunning = $false
$script:AgentCandidates = @()
$script:UiEventLogPath = Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'last-install-ui-events.log'
$script:LastScriptOutput = ''

$RequiredUiScripts = @(
  'bootstrap.ps1',
  'install.ps1',
  'install-agent.ps1',
  'first-load-bootstrap.ps1',
  'health-check.ps1',
  'host-cache-check.ps1',
  'cleanup-install-backups.ps1',
  'migrate-memory-layout.ps1',
  'hot-refresh-skills.ps1',
  'brain.ps1',
  'health-summary.ps1',
  'smart-next.ps1',
  'intent-router.ps1',
  'agent-scorecard.ps1',
  'dispatch-learning.ps1',
  'ci.ps1'
)

function Initialize-InstallUiAssemblies {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
}

function Test-LegacyBrainUiCompatibility {
  $missing = @()
  $brainUiPath = Join-Path $PSScriptRoot 'brain-ui.vbs'
  $installUiVbsPath = Join-Path $PSScriptRoot 'install-ui.vbs'
  if (-not (Test-Path -LiteralPath $brainUiPath)) {
    return [pscustomobject]@{ ok = $false; missing = @('brain-ui.vbs') }
  }
  if (-not (Test-Path -LiteralPath $installUiVbsPath)) {
    return [pscustomobject]@{ ok = $false; missing = @('install-ui.vbs') }
  }

  $brainUiText = [System.IO.File]::ReadAllText($brainUiPath, [System.Text.Encoding]::UTF8)
  $installUiVbsText = [System.IO.File]::ReadAllText($installUiVbsPath, [System.Text.Encoding]::UTF8)
  foreach ($token in @('LEGACY_BRAIN_UI_COMPATIBILITY', 'install-ui.vbs', 'install-ui.ps1', 'wscript.exe', 'does not install')) {
    if (-not $brainUiText.Contains($token)) { $missing += "brain-ui.vbs marker $token" }
  }
  foreach ($token in @('Option Explicit', 'install-ui.ps1', 'WScript.Quit exitCode')) {
    if (-not $installUiVbsText.Contains($token)) { $missing += "install-ui.vbs marker $token" }
  }

  $obsoletePatterns = @(
    '(?im)^\s*installer\s*=.*windows_install\.ps1',
    '(?im)^\s*appModule\s*=.*brain_console_app\.py',
    '(?im)^\s*appScript\s*=.*brain_console\.py',
    '(?im)^\s*rc\s*=.*run_brain_console\.ps1'
  )
  foreach ($pattern in $obsoletePatterns) {
    if ([regex]::IsMatch($brainUiText, $pattern)) { $missing += "brain-ui.vbs active legacy reference $pattern" }
  }
  return [pscustomobject]@{ ok = ($missing.Count -eq 0); missing = @($missing) }
}

function Test-InstallUiPrerequisites {
  Initialize-InstallUiAssemblies
  $missing = @()
  foreach ($script in $RequiredUiScripts) {
    if (-not (Test-Path (Join-Path $PSScriptRoot $script))) {
      $missing += $script
    }
  }
  $vbsPath = Join-Path $PSScriptRoot 'install-ui.vbs'
  if (-not (Test-Path $vbsPath)) {
    $missing += 'install-ui.vbs'
  }
  $uiText = [System.IO.File]::ReadAllText($PSCommandPath, [System.Text.Encoding]::UTF8)
  foreach ($marker in @('技能注入','记忆导入','清理备份','返回技能注入页','吸收能力')) {
    if (-not $uiText.Contains($marker)) { $missing += "install-ui marker $marker" }
  }
  $legacyCompatibility = Test-LegacyBrainUiCompatibility
  if (-not $legacyCompatibility.ok) {
    $missing += @($legacyCompatibility.missing)
  }
  return [pscustomobject]@{ ok = ($missing.Count -eq 0); missing = $missing }
}

if ($SmokeTest) {
  $result = Test-InstallUiPrerequisites
  if ($result.ok) {
    Write-Host 'INSTALL_UI_SMOKE_OK'
    exit 0
  }
  Write-Host ('INSTALL_UI_SMOKE_FAILED missing=' + ($result.missing -join ','))
  exit 1
}

Initialize-InstallUiAssemblies
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
  param($sender, $eventArgs)
  Add-LogSafe "UI_THREAD_ERROR $($eventArgs.Exception.Message)"
  [System.Windows.Forms.MessageBox]::Show("界面操作失败：`r`n$($eventArgs.Exception.Message)", '超级大脑', 'OK', 'Error') | Out-Null
})
[AppDomain]::CurrentDomain.add_UnhandledException({
  param($sender, $eventArgs)
  $exception = $eventArgs.ExceptionObject
  $message = if ($exception -is [System.Exception]) { $exception.Message } else { [string]$exception }
  Add-LogSafe "UI_UNHANDLED_ERROR $message"
})

function Add-UiEvent([string]$Text) {
  if ([string]::IsNullOrEmpty($Text)) { return }
  try {
    $dir = Split-Path -Parent $script:UiEventLogPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Add-Content -LiteralPath $script:UiEventLogPath -Encoding UTF8 -Value ("$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Text")
  } catch {}
}

function Add-Log([string]$Text) {
  if ([string]::IsNullOrEmpty($Text)) { return }
  Add-UiEvent $Text
  if ($script:LogBox -eq $null) {
    Write-Host $Text
    return
  }
  $script:LogBox.AppendText($Text.TrimEnd() + [Environment]::NewLine)
  $script:LogBox.SelectionStart = $script:LogBox.TextLength
  $script:LogBox.ScrollToCaret()
  [System.Windows.Forms.Application]::DoEvents()
}

function Add-LogSafe([string]$Text) {
  if ([string]::IsNullOrEmpty($Text)) { return }
  if ($script:LogBox -eq $null -or -not $script:LogBox.InvokeRequired) {
    Add-Log $Text
    return
  }
  [void]$script:LogBox.BeginInvoke([Action[string]]{ param($line) Add-Log $line }, [object[]]@($Text))
}

function New-PowerShellLiteral([string]$Value) {
  return "'" + ($Value -replace "'", "''") + "'"
}

function New-EncodedScriptCommand([string]$ScriptPath, [object[]]$Arguments) {
  $argumentParts = @()
  foreach ($argument in @($Arguments)) {
    if ($argument -is [hashtable] -and $argument.ContainsKey('Switch')) {
      $argumentParts += ('-' + [string]$argument.Switch)
    } else {
      $argumentParts += (New-PowerShellLiteral ([string]$argument))
    }
  }
  $argumentText = ($argumentParts -join ' ')
  $command = "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; `$OutputEncoding=[System.Text.Encoding]::UTF8; & $(New-PowerShellLiteral $ScriptPath) $argumentText; exit `$LASTEXITCODE"
  return [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
}

function Set-UiBusy([bool]$Busy) {
  $script:UiTaskRunning = $Busy
  if ($script:Tabs -ne $null) { $script:Tabs.Enabled = -not $Busy }
  if ($script:ClearLogButton -ne $null) { $script:ClearLogButton.Enabled = -not $Busy }
  if ($script:MainForm -ne $null) {
    if ($Busy) { $script:MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    else { $script:MainForm.Cursor = [System.Windows.Forms.Cursors]::Default }
  }
  [System.Windows.Forms.Application]::DoEvents()
}

function Format-ScriptArguments([object[]]$Arguments) {
  $parts = @()
  foreach ($argument in @($Arguments)) {
    if ($argument -is [hashtable] -and $argument.ContainsKey('Switch')) { $parts += ('-' + [string]$argument.Switch) }
    else { $parts += [string]$argument }
  }
  return ($parts -join ' ')
}

function Invoke-SuperBrainScript([string]$ScriptName, [object[]]$Arguments = @()) {
  if ($script:UiTaskRunning) {
    Add-Log '已有任务正在运行，请等待完成。'
    return 1
  }

  $scriptPath = Join-Path $PSScriptRoot $ScriptName
  if (-not (Test-Path $scriptPath)) {
    Add-Log "缺少脚本：$ScriptName"
    [System.Windows.Forms.MessageBox]::Show("缺少脚本：$ScriptName", '超级大脑', 'OK', 'Error') | Out-Null
    return 1
  }

  Add-Log ""
  Add-Log "运行：$ScriptName $(Format-ScriptArguments $Arguments)"
  $encodedCommand = New-EncodedScriptCommand $scriptPath $Arguments

  $output = New-Object System.Text.StringBuilder
  $errorOutput = New-Object System.Text.StringBuilder
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
  $process.StartInfo.FileName = 'powershell.exe'
  $process.StartInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
  $process.StartInfo.UseShellExecute = $false
  $process.StartInfo.RedirectStandardOutput = $true
  $process.StartInfo.RedirectStandardError = $true
  $process.StartInfo.CreateNoWindow = $true

  $outputHandler = [System.Diagnostics.DataReceivedEventHandler]{
    param($sender, $eventArgs)
    if ($null -ne $eventArgs.Data) {
      [void]$output.AppendLine($eventArgs.Data)
      Add-LogSafe $eventArgs.Data
    }
  }
  $errorHandler = [System.Diagnostics.DataReceivedEventHandler]{
    param($sender, $eventArgs)
    if ($null -ne $eventArgs.Data) {
      [void]$errorOutput.AppendLine($eventArgs.Data)
      Add-LogSafe $eventArgs.Data
    }
  }
  $process.add_OutputDataReceived($outputHandler)
  $process.add_ErrorDataReceived($errorHandler)

  try {
    Set-UiBusy $true
    [void]$process.Start()
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()
    while (-not $process.WaitForExit(100)) {
      [System.Windows.Forms.Application]::DoEvents()
    }
    $process.WaitForExit()
  } finally {
    try { $process.CancelOutputRead() } catch {}
    try { $process.CancelErrorRead() } catch {}
    try { $process.remove_OutputDataReceived($outputHandler) } catch {}
    try { $process.remove_ErrorDataReceived($errorHandler) } catch {}
    Set-UiBusy $false
  }

  $script:LastScriptOutput = ($output.ToString() + $errorOutput.ToString())
  Add-Log "完成：$ScriptName，退出码 $($process.ExitCode)"
  return $process.ExitCode
}

function Read-UiText([string]$Title, [string]$Prompt, [string]$Default = '') {
  $dialog = New-Object System.Windows.Forms.Form
  $dialog.Text = $Title
  $dialog.StartPosition = 'CenterParent'
  $dialog.Size = New-Object System.Drawing.Size(460, 170)
  $dialog.FormBorderStyle = 'FixedDialog'
  $dialog.MaximizeBox = $false
  $dialog.MinimizeBox = $false

  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Prompt
  $label.Location = New-Object System.Drawing.Point(12, 12)
  $label.Size = New-Object System.Drawing.Size(420, 45)
  $dialog.Controls.Add($label)

  $textBox = New-Object System.Windows.Forms.TextBox
  $textBox.Text = $Default
  $textBox.Location = New-Object System.Drawing.Point(12, 62)
  $textBox.Size = New-Object System.Drawing.Size(420, 24)
  $dialog.Controls.Add($textBox)

  $okButton = New-Object System.Windows.Forms.Button
  $okButton.Text = '确定'
  $okButton.Location = New-Object System.Drawing.Point(276, 98)
  $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $dialog.AcceptButton = $okButton
  $dialog.Controls.Add($okButton)

  $cancelButton = New-Object System.Windows.Forms.Button
  $cancelButton.Text = '取消'
  $cancelButton.Location = New-Object System.Drawing.Point(357, 98)
  $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $dialog.CancelButton = $cancelButton
  $dialog.Controls.Add($cancelButton)

  $result = $dialog.ShowDialog()
  if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return $textBox.Text.Trim() }
  return $null
}

function Require-ExactConfirmation([string]$Expected, [string]$Message) {
  $value = Read-UiText '需要确认' "$Message`r`n输入 $Expected 后继续。" ''
  return ($value -eq $Expected)
}

function Get-AgentCandidatesForUi {
  $candidates = New-Object System.Collections.Generic.List[object]
  $seen = @{}

  function Add-Candidate([string]$Name, [string]$Path, [string]$Reason) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    try { $full = [System.IO.Path]::GetFullPath($expanded) } catch { return }
    $key = $full.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { return }
    $seen[$key] = $true
    $exists = Test-Path $full
    $display = "$(Get-SafeSuperBrainName $Name 'agent') - $full ($(if ($exists) { '已存在' } else { '不存在/安装时创建' }); $Reason)"
    $candidates.Add([pscustomobject]@{ name = (Get-SafeSuperBrainName $Name 'agent'); path = $full; exists = $exists; reason = $Reason; display = $display }) | Out-Null
  }

  Add-Candidate 'zcode' "$env:USERPROFILE\.zcode\skills" '已知 ZCode 技能目录'
  Add-Candidate 'codex' "$env:USERPROFILE\.codex\skills" '已知 Codex 技能目录'
  Add-Candidate 'claude' "$env:USERPROFILE\.claude\skills" '常见 Claude Code 技能目录'
  Add-Candidate 'claude' "$env:APPDATA\Claude\skills" '常见 Claude AppData 技能目录'
  Add-Candidate 'cursor' "$env:USERPROFILE\.cursor\skills" '常见 Cursor 技能目录'
  Add-Candidate 'cursor' "$env:APPDATA\Cursor\skills" '常见 Cursor AppData 技能目录'
  Add-Candidate 'windsurf' "$env:USERPROFILE\.windsurf\skills" '常见 Windsurf 技能目录'
  Add-Candidate 'windsurf' "$env:APPDATA\Windsurf\skills" '常见 Windsurf AppData 技能目录'
  Add-Candidate 'roo' "$env:USERPROFILE\.roo\skills" '常见 Roo Code 技能目录'
  Add-Candidate 'cline' "$env:USERPROFILE\.cline\skills" '常见 Cline 技能目录'
  Add-Candidate 'continue' "$env:USERPROFILE\.continue\skills" '常见 Continue 技能目录'
  Add-Candidate 'gemini' "$env:USERPROFILE\.gemini\skills" '常见 Gemini CLI 技能目录'
  Add-Candidate 'opencode' "$env:USERPROFILE\.opencode\skills" '常见 OpenCode 技能目录'
  Add-Candidate 'aider' "$env:USERPROFILE\.aider\skills" '常见 Aider 技能目录'

  $scanRoots = @($env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA, (Split-Path -Parent $Root)) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path $_) }
  foreach ($scanRoot in $scanRoots) {
    try {
      foreach ($dir in @(Get-ChildItem -LiteralPath $scanRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -in @('.git','node_modules','vendor') -or $dir.Name -like 'install-backup-*') { continue }
        foreach ($skillDir in @(Get-ChildItem -LiteralPath $dir.FullName -Directory -Filter 'skills' -ErrorAction SilentlyContinue)) {
          if ($skillDir.FullName.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
          Add-Candidate $dir.Name $skillDir.FullName '自动识别到的 skills 目录'
        }
      }
    } catch {}
  }

  return @($candidates | Sort-Object @{ Expression = 'exists'; Descending = $true }, name, path)
}

function Open-FolderForUi([string]$Path) {
  if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Force -Path $Path | Out-Null }
  Start-Process explorer.exe -ArgumentList @($Path) | Out-Null
}

function Get-MemoryImportPlan([string]$Path) {
  if (-not (Test-Path $Path)) {
    return [pscustomobject]@{ exists = $false; files = 0; directories = 0; bytes = 0; nestedMemory = $false }
  }
  $effectivePath = $Path
  $nestedMemory = Join-Path $Path 'memory'
  $nested = $false
  if (Test-Path $nestedMemory -PathType Container) {
    $rootItems = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'memory' })
    if ($rootItems.Count -eq 0) {
      $effectivePath = $nestedMemory
      $nested = $true
    }
  }
  $items = @(Get-ChildItem -LiteralPath $effectivePath -Force -Recurse -ErrorAction SilentlyContinue)
  $files = @($items | Where-Object { -not $_.PSIsContainer })
  $dirs = @($items | Where-Object { $_.PSIsContainer })
  $bytes = 0L
  foreach ($file in $files) { $bytes += [int64]$file.Length }
  return [pscustomobject]@{ exists = $true; files = $files.Count; directories = $dirs.Count; bytes = $bytes; nestedMemory = $nested }
}

function Format-ByteSize([int64]$Bytes) {
  if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
  if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
  return "$Bytes B"
}

function New-Button([string]$Text, [int]$X, [int]$Y, [int]$Width = 220, [int]$Height = 32) {
  $button = New-Object System.Windows.Forms.Button
  $button.Text = $Text
  $button.Location = New-Object System.Drawing.Point($X, $Y)
  $button.Size = New-Object System.Drawing.Size($Width, $Height)
  return $button
}

function New-Label([string]$Text, [int]$X, [int]$Y, [int]$Width = 180, [int]$Height = 20) {
  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Text
  $label.Location = New-Object System.Drawing.Point($X, $Y)
  $label.Size = New-Object System.Drawing.Size($Width, $Height)
  return $label
}

$manifest = Get-SuperBrainManifest $Root
$form = New-Object System.Windows.Forms.Form
$script:MainForm = $form
$form.Text = "超级大脑技能注入器 v$($manifest.version)"
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1040, 760)
$form.MinimumSize = New-Object System.Drawing.Size(980, 680)
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.Add_FormClosing({
  param($sender, $eventArgs)
  Add-UiEvent "FORM_CLOSING reason=$($eventArgs.CloseReason) taskRunning=$script:UiTaskRunning"
  if ($script:UiTaskRunning) {
    [System.Windows.Forms.MessageBox]::Show('任务正在运行，请等待完成后再关闭窗口。', '超级大脑', 'OK', 'Information') | Out-Null
    $eventArgs.Cancel = $true
  }
})

$header = New-Object System.Windows.Forms.Label
$header.Text = "超级大脑技能注入器  |  默认全局共享记忆  |  包路径：$Root  |  版本：$($manifest.version)"
$header.Dock = 'Top'
$header.Height = 30
$header.TextAlign = 'MiddleLeft'
$form.Controls.Add($header)

$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Dock = 'Bottom'
$script:LogBox.Multiline = $true
$script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.ReadOnly = $true
$script:LogBox.Height = 170
$script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($script:LogBox)

$tabs = New-Object System.Windows.Forms.TabControl
$script:Tabs = $tabs
$tabs.Dock = 'Fill'
$form.Controls.Add($tabs)

$injectTab = New-Object System.Windows.Forms.TabPage
$injectTab.Text = '技能注入'
$tabs.TabPages.Add($injectTab) | Out-Null

$memoryImportTab = New-Object System.Windows.Forms.TabPage
$memoryImportTab.Text = '记忆导入'
$tabs.TabPages.Add($memoryImportTab) | Out-Null

$backupTab = New-Object System.Windows.Forms.TabPage
$backupTab.Text = '清理备份'
$tabs.TabPages.Add($backupTab) | Out-Null

# Skill injection tab
  $injectTab.Controls.Add((New-Label '1. 全局注入可用宿主' 18 18 300))
  $globalHelp = New-Label '默认只安装/刷新 Codex 的单一超级大脑入口；包内能力由超级大脑按需路由，不单独注入宿主。ZCode 仅作为显式兼容目标。' 18 44 760 36
  $injectTab.Controls.Add($globalHelp)
  $globalInstallButton = New-Button '安装/刷新 Codex 超级大脑' 18 84 220 36
  $globalInstallButton.Add_Click({ Invoke-SuperBrainScript 'bootstrap.ps1' @('-MemoryMode','Shared') | Out-Null })
$injectTab.Controls.Add($globalInstallButton)
$openBackupTabButton = New-Button '打开清理备份页' 260 84 180 36
$openBackupTabButton.Add_Click({ $tabs.SelectedTab = $backupTab })
$injectTab.Controls.Add($openBackupTabButton)
$openMemoryImportTabButton = New-Button '打开记忆导入页' 460 84 180 36
$openMemoryImportTabButton.Add_Click({ $tabs.SelectedTab = $memoryImportTab })
$injectTab.Controls.Add($openMemoryImportTabButton)
$hotRefreshButton = New-Button '热刷新已安装技能' 748 300 180 36
$hotRefreshButton.Add_Click({
  $exitCode = Invoke-SuperBrainScript 'hot-refresh-skills.ps1' @('-AllKnown')
  $statusPath = Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'last-hot-refresh.json'
  if ($exitCode -eq 0) {
    [System.Windows.Forms.MessageBox]::Show("热刷新完成。已更新安装到当前包的 Agent 技能副本。`r`n结果：$statusPath`r`n如果 Agent 缓存技能内容，请新开会话。", '超级大脑', 'OK', 'Information') | Out-Null
  } else {
    [System.Windows.Forms.MessageBox]::Show("热刷新失败，请查看日志和结果文件：`r`n$statusPath", '超级大脑', 'OK', 'Error') | Out-Null
  }
})
$injectTab.Controls.Add($hotRefreshButton)

$injectTab.Controls.Add((New-Label '2. 自动识别 Agent 技能目录' 18 148 300))
  $agentHelp = New-Label '勾选其它 Agent 的 skills 目录后注入；全部使用同一共享记忆，以任务、工作区和会话作用域区分并发工作。' 18 174 780 36
$injectTab.Controls.Add($agentHelp)
$agentList = New-Object System.Windows.Forms.CheckedListBox
$agentList.Location = New-Object System.Drawing.Point(18, 216)
$agentList.Size = New-Object System.Drawing.Size(710, 132)
$injectTab.Controls.Add($agentList)
$refreshAgentsButton = New-Button '刷新目录列表' 748 216 180
$refreshAgentsButton.Add_Click({
  $agentList.Items.Clear()
  $script:AgentCandidates = @(Get-AgentCandidatesForUi)
  foreach ($candidate in $script:AgentCandidates) { [void]$agentList.Items.Add($candidate.display, $false) }
  Add-Log "AGENT_CANDIDATES $($script:AgentCandidates.Count)"
})
$injectTab.Controls.Add($refreshAgentsButton)
$installSelectedButton = New-Button '注入勾选目录' 748 258 180
  $installSelectedButton.Add_Click({
  if ($agentList.CheckedIndices.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show('请至少勾选一个 Agent 技能目录。', '超级大脑', 'OK', 'Information') | Out-Null
    return
  }
    foreach ($index in $agentList.CheckedIndices) {
    $candidate = $script:AgentCandidates[$index]
    if (-not $candidate.exists) {
      if (-not (Require-ExactConfirmation 'YES' "SkillRoot 不存在，安装时将创建：`r`n$($candidate.path)")) { continue }
    }
      Invoke-SuperBrainScript 'install-agent.ps1' @('-AgentName',$candidate.name,'-SkillRoot',$candidate.path,'-Mode','Shared') | Out-Null
  }
})
$injectTab.Controls.Add($installSelectedButton)

$injectTab.Controls.Add((New-Label '3. 手动指定 Agent 技能目录' 18 380 300))
$injectTab.Controls.Add((New-Label 'Agent 名称' 18 414 80))
$manualAgentName = New-Object System.Windows.Forms.TextBox
$manualAgentName.Location = New-Object System.Drawing.Point(100, 410)
$manualAgentName.Size = New-Object System.Drawing.Size(180, 24)
$injectTab.Controls.Add($manualAgentName)
$injectTab.Controls.Add((New-Label 'skills 目录' 300 414 90))
$manualSkillRoot = New-Object System.Windows.Forms.TextBox
$manualSkillRoot.Location = New-Object System.Drawing.Point(390, 410)
$manualSkillRoot.Size = New-Object System.Drawing.Size(335, 24)
$injectTab.Controls.Add($manualSkillRoot)
$browseButton = New-Button '浏览' 742 406 80
$browseButton.Add_Click({
  $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
  if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $manualSkillRoot.Text = $dialog.SelectedPath }
})
$injectTab.Controls.Add($browseButton)
$manualInstallButton = New-Button '注入手动目录' 836 406 150
$manualInstallButton.Add_Click({
  if ([string]::IsNullOrWhiteSpace($manualAgentName.Text) -or [string]::IsNullOrWhiteSpace($manualSkillRoot.Text)) {
    [System.Windows.Forms.MessageBox]::Show('请填写 Agent 名称和 skills 目录。', '超级大脑', 'OK', 'Warning') | Out-Null
    return
  }
  if (-not (Test-Path $manualSkillRoot.Text)) {
    if (-not (Require-ExactConfirmation 'YES' "SkillRoot 不存在，安装时将创建：`r`n$($manualSkillRoot.Text)")) { return }
  }
  Invoke-SuperBrainScript 'install-agent.ps1' @('-AgentName',$manualAgentName.Text.Trim(),'-SkillRoot',$manualSkillRoot.Text.Trim(),'-Mode','Shared') | Out-Null
})
$injectTab.Controls.Add($manualInstallButton)

# Memory import tab
$memoryImportRoot = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'merge-overlay'
$memoryImportTab.Controls.Add((New-Label '旧记忆受控导入' 18 22 360))
$backFromMemoryImportButton = New-Button '返回技能注入页' 742 18 150
$backFromMemoryImportButton.Add_Click({ $tabs.SelectedTab = $injectTab })
$memoryImportTab.Controls.Add($backFromMemoryImportButton)
$memoryImportHelp = New-Label '把旧 memory 文件放入 merge-overlay；也可以直接放入整个 memory 文件夹。导入会先建立私有清单和备份，原文件不会自动删除。' 18 50 880 42
$memoryImportTab.Controls.Add($memoryImportHelp)
$memoryImportTab.Controls.Add((New-Label '导入目录' 18 104 80))
$memoryImportPath = New-Object System.Windows.Forms.TextBox
$memoryImportPath.Location = New-Object System.Drawing.Point(100, 100)
$memoryImportPath.Size = New-Object System.Drawing.Size(625, 24)
$memoryImportPath.ReadOnly = $true
$memoryImportPath.Text = $memoryImportRoot
$memoryImportTab.Controls.Add($memoryImportPath)
$openMemoryImportButton = New-Button '打开导入目录' 742 96 150
$openMemoryImportButton.Add_Click({ Open-FolderForUi $memoryImportRoot })
$memoryImportTab.Controls.Add($openMemoryImportButton)
$memoryImportStatus = New-Label '尚未检测。' 18 148 820 48
$memoryImportTab.Controls.Add($memoryImportStatus)

function Refresh-MemoryImportStatus {
  $plan = Get-MemoryImportPlan $memoryImportRoot
  if (-not $plan.exists) {
    $memoryImportStatus.Text = "未找到导入目录。点击打开导入目录按钮会自动创建：$memoryImportRoot"
    Add-Log "MEMORY_IMPORT_MISSING path=$memoryImportRoot"
    return $plan
  }
  $nestedText = if ($plan.nestedMemory) { ' 已识别嵌套目录 merge-overlay\memory，将自动从该目录导入。' } else { '' }
  $memoryImportStatus.Text = "检测到旧记忆：文件 $($plan.files) 个，文件夹 $($plan.directories) 个，总大小 $(Format-ByteSize $plan.bytes)。$nestedText"
  Add-Log "MEMORY_IMPORT_SCAN path=$memoryImportRoot files=$($plan.files) dirs=$($plan.directories) bytes=$($plan.bytes) nestedMemory=$($plan.nestedMemory)"
  return $plan
}

function Invoke-MemoryImportPlan {
  $exitCode = Invoke-SuperBrainScript 'migrate-memory-layout.ps1' @('-Action','Plan','-ImportRoot',$memoryImportRoot)
  if ($exitCode -eq 0) { Refresh-MemoryImportStatus | Out-Null }
  return $exitCode
}

function Invoke-MemoryImport {
  try {
    $plan = Refresh-MemoryImportStatus
    if (-not $plan.exists -or $plan.files -eq 0) {
      [System.Windows.Forms.MessageBox]::Show('没有检测到旧记忆文件。请先把旧 memory 文件放入 merge-overlay 导入目录。', '超级大脑', 'OK', 'Information') | Out-Null
      return
    }
    if (-not (Require-ExactConfirmation 'IMPORT' "确认导入旧记忆。系统会建立私有备份、导入、核验并切换兼容适配器；原文件不会删除：`r`n$memoryImportRoot")) { return }
    $epochId = 'migration-ui-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
    $stages = @(
      [pscustomobject]@{action='Stage';args=@('-Action','Stage','-ImportRoot',$memoryImportRoot,'-EpochId',$epochId,'-Apply')},
      [pscustomobject]@{action='Import';args=@('-Action','Import','-EpochId',$epochId,'-Apply')},
      [pscustomobject]@{action='Verify';args=@('-Action','Verify','-EpochId',$epochId,'-Apply')},
      [pscustomobject]@{action='Cutover';args=@('-Action','Cutover','-EpochId',$epochId,'-AdapterName','legacy-memory-layout','-Apply')}
    )
    $exitCode = 0
    foreach ($stage in $stages) {
      $exitCode = Invoke-SuperBrainScript 'migrate-memory-layout.ps1' @($stage.args)
      if ($exitCode -ne 0) { break }
    }
    if ($exitCode -eq 0) {
      Refresh-MemoryImportStatus | Out-Null
      [System.Windows.Forms.MessageBox]::Show("旧记忆已导入并完成核验。原导入目录仍保留，确认无误后可单独清理。`r`n迁移编号：$epochId", '超级大脑', 'OK', 'Information') | Out-Null
    } else {
      [System.Windows.Forms.MessageBox]::Show("旧记忆迁移未完成，导入目录和私有备份均已保留，请查看日志。`r`n迁移编号：$epochId", '超级大脑', 'OK', 'Error') | Out-Null
    }
  } catch {
    Add-Log "MEMORY_IMPORT_ERROR $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '超级大脑', 'OK', 'Error') | Out-Null
  }
}

$refreshMemoryImportButton = New-Button '刷新检测' 18 214 160
$refreshMemoryImportButton.Add_Click({ Refresh-MemoryImportStatus | Out-Null })
$memoryImportTab.Controls.Add($refreshMemoryImportButton)
$previewMemoryButton = New-Button '预览迁移' 198 214 180
$previewMemoryButton.Add_Click({ Invoke-MemoryImportPlan | Out-Null })
$memoryImportTab.Controls.Add($previewMemoryButton)
$startMemoryImportButton = New-Button '输入 IMPORT 后开始迁移' 398 214 260
$startMemoryImportButton.Add_Click({ Invoke-MemoryImport })
$memoryImportTab.Controls.Add($startMemoryImportButton)
$memoryImportNote = New-Label '迁移只在核验通过后切换兼容适配器；源文件、私有归档和回滚证据都会保留。' 18 270 860 54
$memoryImportTab.Controls.Add($memoryImportNote)

# Backup cleanup tab
$backupTab.Controls.Add((New-Label '清理 install-backup-* 安装备份' 18 22 360))
$backFromBackupButton = New-Button '返回技能注入页' 742 18 150
$backFromBackupButton.Add_Click({ $tabs.SelectedTab = $injectTab })
$backupTab.Controls.Add($backFromBackupButton)
$backupHelp = New-Label '第一步只预览将删除哪些旧备份；确认无误后输入 DELETE，才会真正删除。' 18 50 760 36
$backupTab.Controls.Add($backupHelp)
$backupTab.Controls.Add((New-Label '保留最新备份数' 18 100 130))
$keepBackups = New-Object System.Windows.Forms.NumericUpDown
$keepBackups.Location = New-Object System.Drawing.Point(160, 96)
$keepBackups.Size = New-Object System.Drawing.Size(70, 24)
$keepBackups.Minimum = 0
$keepBackups.Maximum = 100
$keepBackups.Value = 1
$backupTab.Controls.Add($keepBackups)
function Get-InstallBackupCleanupPlan([int]$Keep) {
  if ($Keep -lt 0) { throw '保留数量不能小于 0。' }
  $installBackupRoot = Get-SuperBrainInstallBackupRoot $Root
  $backups = if (Test-Path -LiteralPath $installBackupRoot) { @(Get-ChildItem -LiteralPath $installBackupRoot -Directory -Filter 'install-backup-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending) } else { @() }
  $delete = @($backups | Select-Object -Skip $Keep)
  return [pscustomobject]@{ backups = $backups; keep = @($backups | Select-Object -First $Keep); delete = $delete }
}

function Write-InstallBackupPreview([int]$Keep) {
  $plan = Get-InstallBackupCleanupPlan $Keep
  Add-Log "INSTALL_BACKUP_CLEANUP total=$($plan.backups.Count) keep=$Keep delete=$($plan.delete.Count) apply=False"
  foreach ($dir in $plan.keep) { Add-Log "INSTALL_BACKUP_KEEP $($dir.FullName)" }
  foreach ($dir in $plan.delete) { Add-Log "INSTALL_BACKUP_DELETE_CANDIDATE $($dir.FullName)" }
  if ($plan.delete.Count -eq 0) { Add-Log 'INSTALL_BACKUP_CLEANUP_NO_CANDIDATES' }
  return $plan
}

function Remove-InstallBackupCandidates([int]$Keep) {
  $plan = Write-InstallBackupPreview $Keep
  foreach ($dir in $plan.delete) {
    $full = Get-NormalizedSuperBrainRoot $dir.FullName
    $parent = Get-NormalizedSuperBrainRoot (Get-SuperBrainInstallBackupRoot $Root)
    $name = Split-Path -Leaf $full
    if (-not $full.StartsWith($parent + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { throw "拒绝删除安装备份目录外路径：$full" }
    if ($name -notlike 'install-backup-*') { throw "拒绝删除非安装备份目录：$full" }
    Remove-Item -LiteralPath $dir.FullName -Recurse -Force
    Add-Log "INSTALL_BACKUP_DELETED $($dir.FullName)"
  }
  Add-Log 'INSTALL_BACKUP_CLEANUP_OK'
  return $plan.delete.Count
}

$previewBackupsButton = New-Button '只预览旧备份' 18 142 180
$previewBackupsButton.Add_Click({
  try {
    Write-InstallBackupPreview ([int]$keepBackups.Value) | Out-Null
  } catch {
    Add-Log "INSTALL_BACKUP_CLEANUP_ERROR $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '超级大脑', 'OK', 'Error') | Out-Null
  }
})
$backupTab.Controls.Add($previewBackupsButton)
$deleteBackupsButton = New-Button '输入 DELETE 后删除' 218 142 200
$deleteBackupsButton.Add_Click({
  try {
    $keep = [int]$keepBackups.Value
    Write-InstallBackupPreview $keep | Out-Null
    if (Require-ExactConfirmation 'DELETE' "确认删除超出最新 $keep 个之外的旧 install-backup-* 目录。") {
      $deleted = Remove-InstallBackupCandidates $keep
      [System.Windows.Forms.MessageBox]::Show("旧安装备份清理完成，已删除 $deleted 个目录。", '超级大脑', 'OK', 'Information') | Out-Null
    }
  } catch {
    Add-Log "INSTALL_BACKUP_CLEANUP_ERROR $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '超级大脑', 'OK', 'Error') | Out-Null
  }
})
$backupTab.Controls.Add($deleteBackupsButton)

$clearLogButton = New-Button '清空日志' 790 6 110 26
$script:ClearLogButton = $clearLogButton
$clearLogButton.Anchor = 'Top,Right'
$clearLogButton.Add_Click({ $script:LogBox.Clear() })
$form.Controls.Add($clearLogButton)

$tabs.SelectedTab = $injectTab
$refreshAgentsButton.PerformClick()
Add-Log 'INSTALL_UI_READY'
[void]$form.ShowDialog()
