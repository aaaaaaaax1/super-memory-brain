# Super Memory Brain 朋友版安装

## 你收到的内容

请只使用 `super-memory-brain-package-share` 分享目录或压缩包。它是不含原作者私人记忆的公开安装包；首次安装后会在你的电脑上创建自己的本地记忆和状态。

## 前置条件

- Windows 10/11
- 已安装并能正常打开 Codex Desktop
- 已安装 Python 3，并且在 PowerShell 中执行 `python --version` 有输出
- 安装期间允许 PowerShell 修改 Codex 技能、hook 和 MCP 配置

## 一键安装

1. 解压分享包到任意普通目录，不要放进 `C:\Windows` 或 `C:\Program Files`。
2. 双击包根目录的 `install.bat`。
3. 等待窗口出现安装完成或失败结果；不要同时重复点击多个安装入口。
4. 关闭并重新打开 Codex，或者直接新建一个 Codex task。
5. 在新 task 中发送 `超级大脑`，让它完成首次检测。

根目录入口会调用已验证的 `scripts\bootstrap.ps1`，自动完成技能安装、记忆根初始化、hook、MCP 注册、路径校验和集成验证。需要图形界面时可双击 `install.bat ui`，需要交互菜单时运行 `install.bat console`。

## 安装后位置

- Codex 技能：`%USERPROFILE%\.codex\skills`
- ZCode 技能：`%USERPROFILE%\.zcode\skills`
- 本地记忆和状态：分享包目录下的 `memory`
- MCP：Codex 的 `super-memory-brain` 配置

首次安装只会注册本机路径。若首次加载报告 MCP 尚未发现，新建一个 Codex task 即可让桌面版重新发现工具；不需要重新解压或手动恢复技能。

## 隐私边界

这个包不包含原作者的 `memory\shared`、`memory\workspace`、persona、archive、token、API key 或安装备份。不要把自己的 `memory` 目录、`config.toml` 或 `.env` 上传给别人。

## 故障处理

在包目录打开 PowerShell，运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\runtime-status.ps1" -Json
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\first-load-bootstrap.ps1" -RepairMcp -Json
```

如果提示找不到 Python 或 Codex，请先确认前置条件，再重新双击根目录 `install.bat`。安装脚本默认会保留备份，不会静默删除旧配置。
