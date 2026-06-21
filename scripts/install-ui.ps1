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
$script:UiEventLogPath = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'memory\workspace') 'last-install-ui-events.log'
$script:LastScriptOutput = ''

$RequiredUiScripts = @(
  'install.ps1',
  'install-agent.ps1',
  'health-check.ps1',
  'cleanup-install-backups.ps1',
  'migrate-memory-layout.ps1',
  'release-share.ps1',
  'release-private.ps1',
  'hot-refresh-skills.ps1',
  'repair-hook.ps1',
  'brain.ps1',
  'health-summary.ps1',
  'smart-next.ps1',
  'intent-router.ps1',
  'agent-scorecard.ps1',
  'dispatch-learning.ps1',
  'release-readiness.ps1',
  'ci.ps1'
)

function Initialize-InstallUiAssemblies {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
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
  foreach ($marker in @('Invoke-ShareReleaseInlineFromUi','prepare-share.ps1','verify-share.ps1','Write-UiReleaseStatus','RELEASE_SHARE_OK')) {
    if (-not $uiText.Contains($marker)) { $missing += "install-ui marker $marker" }
  }
  foreach ($marker in @('技能注入','记忆导入','分享包','清理备份','返回技能注入页','生成分享包','打开最近输出目录','刷新最近结果','打开分享包页')) {
    if (-not $uiText.Contains($marker)) { $missing += "install-ui marker $marker" }
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

$releaseTab = New-Object System.Windows.Forms.TabPage
$releaseTab.Text = '分享包'
$tabs.TabPages.Add($releaseTab) | Out-Null

$backupTab = New-Object System.Windows.Forms.TabPage
$backupTab.Text = '清理备份'
$tabs.TabPages.Add($backupTab) | Out-Null

# Skill injection tab
$injectTab.Controls.Add((New-Label '1. 全局注入 ZCode + Codex' 18 18 300))
$globalHelp = New-Label '默认把超级大脑四个技能注入到 ZCode 和 Codex，并指向同一个全局共享记忆。' 18 44 760 36
$injectTab.Controls.Add($globalHelp)
$globalInstallButton = New-Button '一键全局注入/刷新' 18 84 220 36
$globalInstallButton.Add_Click({ Invoke-SuperBrainScript 'install.ps1' @('-MemoryMode','Shared') | Out-Null })
$injectTab.Controls.Add($globalInstallButton)
$openBackupTabButton = New-Button '打开清理备份页' 260 84 180 36
$openBackupTabButton.Add_Click({ $tabs.SelectedTab = $backupTab })
$injectTab.Controls.Add($openBackupTabButton)
$openMemoryImportTabButton = New-Button '打开记忆导入页' 460 84 180 36
$openMemoryImportTabButton.Add_Click({ $tabs.SelectedTab = $memoryImportTab })
$injectTab.Controls.Add($openMemoryImportTabButton)
$openReleaseTabButton = New-Button '打开分享包页' 660 84 180 36
$openReleaseTabButton.Add_Click({ $tabs.SelectedTab = $releaseTab })
$injectTab.Controls.Add($openReleaseTabButton)
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
$agentHelp = New-Label '勾选其它 Agent 的 skills 目录后注入技能；默认接入全局共享记忆，后续可在对应 Agent 内切换私有记忆。' 18 174 780 36
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
$memoryImportTab.Controls.Add((New-Label '旧记忆导入 / 合并覆盖' 18 22 360))
$backFromMemoryImportButton = New-Button '返回技能注入页' 742 18 150
$backFromMemoryImportButton.Add_Click({ $tabs.SelectedTab = $injectTab })
$memoryImportTab.Controls.Add($backFromMemoryImportButton)
$memoryImportHelp = New-Label '把旧 memory 文件内容放入 merge-overlay；也可以直接把整个 memory 文件夹放进去，脚本会自动识别 merge-overlay\memory。成功后会自动删除导入文件夹。' 18 50 880 42
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

function Invoke-MemoryImport([string]$ImportMode, [string]$ConfirmWord) {
  try {
    $plan = Refresh-MemoryImportStatus
    if (-not $plan.exists -or $plan.files -eq 0) {
      [System.Windows.Forms.MessageBox]::Show('没有检测到旧记忆文件。请先把旧 memory 文件放入 merge-overlay 导入目录。', '超级大脑', 'OK', 'Information') | Out-Null
      return
    }
    if (-not (Require-ExactConfirmation $ConfirmWord "确认执行旧记忆 $ImportMode。成功后会删除导入目录：`r`n$memoryImportRoot")) { return }
    $exitCode = Invoke-SuperBrainScript 'migrate-memory-layout.ps1' @('-ImportRoot',$memoryImportRoot,'-Mode',$ImportMode,'-Apply','-CleanupImport')
    if ($exitCode -eq 0) {
      Refresh-MemoryImportStatus | Out-Null
      [System.Windows.Forms.MessageBox]::Show("旧记忆 $ImportMode 成功，导入目录已清理。", '超级大脑', 'OK', 'Information') | Out-Null
    } else {
      [System.Windows.Forms.MessageBox]::Show("旧记忆 $ImportMode 失败，导入目录已保留，请查看日志。", '超级大脑', 'OK', 'Error') | Out-Null
    }
  } catch {
    Add-Log "MEMORY_IMPORT_ERROR $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '超级大脑', 'OK', 'Error') | Out-Null
  }
}

$refreshMemoryImportButton = New-Button '刷新检测' 18 214 160
$refreshMemoryImportButton.Add_Click({ Refresh-MemoryImportStatus | Out-Null })
$memoryImportTab.Controls.Add($refreshMemoryImportButton)
$mergeMemoryButton = New-Button '输入 MERGE 后合并旧记忆' 198 214 240
$mergeMemoryButton.Add_Click({ Invoke-MemoryImport 'Merge' 'MERGE' })
$memoryImportTab.Controls.Add($mergeMemoryButton)
$overwriteMemoryButton = New-Button '输入 OVERWRITE 后覆盖冲突文件' 458 214 280
$overwriteMemoryButton.Add_Click({ Invoke-MemoryImport 'Overwrite' 'OVERWRITE' })
$memoryImportTab.Controls.Add($overwriteMemoryButton)
$memoryImportNote = New-Label '合并：文本冲突追加旧内容，非文本冲突保留新文件。覆盖：旧文件覆盖同名新文件，但不会删除新目录中旧目录没有的文件。' 18 270 860 54
$memoryImportTab.Controls.Add($memoryImportNote)

# Release tab
$releaseTab.Controls.Add((New-Label '生成分享包' 18 22 360))
$backFromReleaseButton = New-Button '返回技能注入页' 742 18 150
$backFromReleaseButton.Add_Click({ $tabs.SelectedTab = $injectTab })
$releaseTab.Controls.Add($backFromReleaseButton)
$releaseHelp = New-Label '默认生成无记忆分享包，可安全发给别人；只有勾选“包含记忆”时才会生成含本地记忆的私人包。' 18 50 860 42
$releaseTab.Controls.Add($releaseHelp)
$includeMemoryCheck = New-Object System.Windows.Forms.CheckBox
$includeMemoryCheck.Text = '包含记忆（私人包，不建议分享给别人）'
$includeMemoryCheck.Checked = $false
$includeMemoryCheck.Location = New-Object System.Drawing.Point(18, 106)
$includeMemoryCheck.Size = New-Object System.Drawing.Size(360, 28)
$releaseTab.Controls.Add($includeMemoryCheck)
$releaseTab.Controls.Add((New-Label '输出目录（可留空自动生成）' 18 152 190))
$releaseDestination = New-Object System.Windows.Forms.TextBox
$releaseDestination.Location = New-Object System.Drawing.Point(210, 148)
$releaseDestination.Size = New-Object System.Drawing.Size(515, 24)
$releaseTab.Controls.Add($releaseDestination)
$browseReleaseDestinationButton = New-Button '浏览' 742 144 80
$browseReleaseDestinationButton.Add_Click({
  $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
  if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $releaseDestination.Text = $dialog.SelectedPath }
})
$releaseTab.Controls.Add($browseReleaseDestinationButton)

function Read-LastReleaseStatus {
  $statusPath = Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'last-release.json'
  if (-not (Test-Path $statusPath)) { return $null }
  try { return Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Write-UiReleaseStatus([bool]$Ok, [bool]$IncludesMemory, [string]$Destination, [string]$Message) {
  $statusPath = Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'last-release.json'
  Write-JsonUtf8NoBom $statusPath ([pscustomobject]@{
    ok = $Ok
    kind = if ($IncludesMemory) { 'private' } else { 'share' }
    includesMemory = $IncludesMemory
    destination = if ($Ok -or (Test-Path $Destination)) { $Destination } else { '' }
    message = $Message
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  }) 6
}

function Invoke-ShareReleaseInlineFromUi([string]$Destination) {
  if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path (Split-Path -Parent $Root) ('super-memory-brain-package-share-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  }
  Add-Log "运行：release-share.ps1 -QuietVerify inline destination=$Destination"
  try {
    Set-UiBusy $true
    & (Join-Path $PSScriptRoot 'prepare-share.ps1') -Destination $Destination *> $null
    if (-not $?) {
      Write-UiReleaseStatus $false $false $Destination 'Share preparation failed.'
      Add-Log 'RELEASE_UI_PREPARE_FAILED'
      return 1
    }
    & (Join-Path $PSScriptRoot 'verify-share.ps1') -Destination $Destination -SkipPrepare *> $null
    if ($LASTEXITCODE -ne 0) {
      Write-UiReleaseStatus $false $false $Destination 'Share verification failed.'
      Add-Log 'RELEASE_UI_VERIFY_FAILED'
      return $LASTEXITCODE
    }
    Write-UiReleaseStatus $true $false $Destination 'Share release excludes private memory files.'
    Add-Log "RELEASE_SHARE_OK $Destination"
    return 0
  } catch {
    Write-UiReleaseStatus $false $false $Destination $_.Exception.Message
    Add-Log "RELEASE_UI_INLINE_ERROR $($_.Exception.Message)"
    return 1
  } finally {
    Set-UiBusy $false
  }
}

function Invoke-ReleasePackageFromUi {
  try {
    $includeMemory = [bool]$includeMemoryCheck.Checked
    $scriptName = if ($includeMemory) { 'release-private.ps1' } else { 'release-share.ps1' }
    $destinationText = $releaseDestination.Text.Trim()
    if ($includeMemory) {
      if (-not (Require-ExactConfirmation 'PRIVATE' '确认生成包含本地记忆的私人包。它可能包含 sandglass、persona、archive、workspace 等记忆数据。')) { return }
      $args = @()
      if (-not [string]::IsNullOrWhiteSpace($destinationText)) { $args += @('-Destination', $destinationText) }
      $exitCode = Invoke-SuperBrainScript $scriptName $args
    } else {
      $exitCode = Invoke-ShareReleaseInlineFromUi $destinationText
    }
    $releaseStatus = Read-LastReleaseStatus
    Update-ReleaseStatusBox | Out-Null
    if ($exitCode -eq 0 -and $null -ne $releaseStatus -and $releaseStatus.ok -eq $true) {
      $kind = if ($includeMemory) { '含记忆私人包' } else { '无记忆分享包' }
      Add-Log "RELEASE_UI_OK destination=$($releaseStatus.destination)"
      $releaseStatusBox.Text = "最近结果：成功 / $kind`r`n输出目录：$($releaseStatus.destination)`r`n说明：$($releaseStatus.message)`r`n时间：$($releaseStatus.checkedAt)`r`n状态：已生成并完成校验，UI 保持打开。"
      [System.Windows.Forms.MessageBox]::Show($script:MainForm, "$kind 生成成功：`r`n$($releaseStatus.destination)`r`n`r`n记录已保留在当前页面，窗口不会自动关闭。", '超级大脑', 'OK', 'Information') | Out-Null
      if ($script:MainForm -ne $null -and -not $script:MainForm.IsDisposed) {
        $script:MainForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $script:MainForm.Activate()
      }
    } else {
      $message = if ($null -ne $releaseStatus) { "$($releaseStatus.message)`r`n目标：$($releaseStatus.destination)" } else { '未写入 release 状态文件。' }
      Add-Log "RELEASE_UI_FAILED $message"
      [System.Windows.Forms.MessageBox]::Show("分享包生成失败：`r`n$message", '超级大脑', 'OK', 'Error') | Out-Null
    }
  } catch {
    Add-Log "RELEASE_PACKAGE_ERROR $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '超级大脑', 'OK', 'Error') | Out-Null
  }
}

$createReleaseButton = New-Button '生成分享包' 18 206 180
$createReleaseButton.Add_Click({ Invoke-ReleasePackageFromUi })
$releaseTab.Controls.Add($createReleaseButton)
$releaseNote = New-Label '无记忆包会运行 release-share.ps1 并验证隐私清理；含记忆包会运行 release-private.ps1，执行前必须输入 PRIVATE。' 218 204 720 48
$releaseTab.Controls.Add($releaseNote)

$releaseStatusBox = New-Object System.Windows.Forms.TextBox
$releaseStatusBox.Location = New-Object System.Drawing.Point(18, 270)
$releaseStatusBox.Size = New-Object System.Drawing.Size(870, 86)
$releaseStatusBox.Multiline = $true
$releaseStatusBox.ReadOnly = $true
$releaseStatusBox.ScrollBars = 'Vertical'
$releaseStatusBox.Text = '最近结果：尚未读取。'
$releaseTab.Controls.Add($releaseStatusBox)
$openLastReleaseButton = New-Button '打开最近输出目录' 18 370 180
$releaseTab.Controls.Add($openLastReleaseButton)
$refreshReleaseStatusButton = New-Button '刷新最近结果' 218 370 180
$releaseTab.Controls.Add($refreshReleaseStatusButton)

function Update-ReleaseStatusBox {
  $releaseStatus = Read-LastReleaseStatus
  if ($null -eq $releaseStatus) {
    $releaseStatusBox.Text = '最近结果：没有 last-release.json。尚未生成分享包，或生成流程没有写入状态。'
    return $null
  }
  $statusText = if ($releaseStatus.ok -eq $true) { '成功' } else { '失败' }
  $memoryText = if ($releaseStatus.includesMemory -eq $true) { '包含记忆' } else { '无记忆' }
  $destinationText = if ([string]::IsNullOrWhiteSpace([string]$releaseStatus.destination)) { '无可打开目录' } else { [string]$releaseStatus.destination }
  $releaseStatusBox.Text = "最近结果：$statusText / $memoryText`r`n输出目录：$destinationText`r`n说明：$($releaseStatus.message)`r`n时间：$($releaseStatus.checkedAt)"
  return $releaseStatus
}

$openLastReleaseButton.Add_Click({
  $releaseStatus = Update-ReleaseStatusBox
  if ($null -eq $releaseStatus -or [string]::IsNullOrWhiteSpace([string]$releaseStatus.destination)) {
    [System.Windows.Forms.MessageBox]::Show('没有可打开的最近输出目录。', '超级大脑', 'OK', 'Information') | Out-Null
    return
  }
  if (-not (Test-Path $releaseStatus.destination)) {
    [System.Windows.Forms.MessageBox]::Show("最近输出目录不存在：`r`n$($releaseStatus.destination)", '超级大脑', 'OK', 'Error') | Out-Null
    return
  }
  Start-Process explorer.exe -ArgumentList @($releaseStatus.destination) | Out-Null
})
$refreshReleaseStatusButton.Add_Click({ Update-ReleaseStatusBox | Out-Null })

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
  $backups = @(Get-ChildItem -LiteralPath $Root -Directory -Filter 'install-backup-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
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
    $parent = Get-NormalizedSuperBrainRoot $Root
    $name = Split-Path -Leaf $full
    if (-not $full.StartsWith($parent + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { throw "拒绝删除包目录外路径：$full" }
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
Update-ReleaseStatusBox | Out-Null
Add-Log 'INSTALL_UI_READY'
[void]$form.ShowDialog()
