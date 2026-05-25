<div align="center">

# EasySkills

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Windows-brightgreen.svg)](#安装方式)
[![Agents](https://img.shields.io/badge/支持Agent-35+-orange.svg)](#支持的-agent-列表)
[![Version](https://img.shields.io/badge/版本-1.2.2-purple.svg)](https://github.com/RunhuaHuang/EasySkills/releases)

**一个技能库，所有 Agent，始终同步。**

只需将技能文件夹放入 `~/EasySkills` 一次，
它就会通过原生链接，自动出现在 Claude Code、Codex、Cursor、Gemini、Copilot、Windsurf、Trae 等 35+ Agent 的技能目录中。

本地优先 &bull; 空闲零 CPU &bull; 自带 WebUI

[**English**](README.md)

</div>

---

## 快速开始

<table>
<tr>
<td><b>macOS / Linux</b></td>
<td>

```bash
curl -fsSL https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.sh | bash
```

</td>
</tr>
<tr>
<td><b>Windows</b></td>
<td>

```powershell
irm https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.ps1 | iex
```

</td>
</tr>
</table>

安装器会创建 `~/EasySkills`，自动检测已安装的 Agent，映射共享技能，启动后台监听，并拉起本地 WebUI。

> **其他方式：** 克隆仓库后双击 `install_mac.command`（macOS）或 `install_windows.bat`（Windows）。
> 或直接对 Agent 说：*"帮我初始化 EasySkills。"*

---

## 工作原理

```
~/EasySkills/                           ← 你的统一技能库
├── _maintenance/                       ← 引擎（对 Agent 不可见）
├── MyAwesomeSkill/                     ← 放进来一次
├── CodeReviewSkill/
└── DeployHelper/
        │
        ▼ 软链接 (macOS/Linux) / 目录联结 (Windows)
┌─────────────────────────────────────────────┐
│ ~/.claude/skills/MyAwesomeSkill  ──→  ✓     │
│ ~/.cursor/skills/MyAwesomeSkill  ──→  ✓     │
│ ~/.gemini/config/skills/MyAwesomeSkill ──→ ✓│
│ ~/.codex/skills/MyAwesomeSkill   ──→  ✓     │
│ ~/.copilot/skills/MyAwesomeSkill ──→  ✓     │
│ ... 35+ 个目标，全部同步，始终一致         │
└─────────────────────────────────────────────┘
```

EasySkills 使用原生链接（而非复制）将共享技能映射到各 Agent 的 skills 目录。修改一处，所有 Agent 即时看到。后台监听在顶层技能文件夹增删时自动同步。Agent 自己的专属技能不受影响。

---

## WebUI 控制台

通过本地控制台 `http://127.0.0.1:6633` 管理一切。

导入或删除共享技能、连接 Agent、为默认未支持的 Agent 注册 skills 文件夹路径、手动同步、清理无效链接、检查更新——全部在一个页面完成。

```bash
# macOS / Linux
bash ~/EasySkills/_maintenance/deploy.sh --webui

# Windows (PowerShell)
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" -WebUI
```

<p align="center">
  <img src="docs/assets/webui-dashboard-macos.jpg" alt="EasySkills macOS WebUI 控制台" width="100%">
</p>

<p align="center">
  <img src="docs/assets/webui-agents-macos.jpg" alt="EasySkills macOS Agent 连接管理界面" width="100%">
</p>

---

## 核心特性

| | 特性 | 说明 |
|:---:|:---|:---|
| **1** | **技能库导入/删除** | 通过 WebUI 导入技能文件夹；删除时弹窗确认 |
| **2** | **Agent 自动检测** | 自动识别 35+ 主流 Agent，只为真实存在的路径建立连接 |
| **3** | **实时映射** | 监听服务在几秒内同步技能增删 |
| **4** | **非侵入式** | 共享技能与 Agent 专属技能并列存在——原有 skills 不受影响 |
| **5** | **Windows 免提权** | 使用 NTFS 目录联结，无需管理员权限或开发者模式 |
| **6** | **静默监听** | macOS: `launchd` + `WatchPaths` &bull; Windows: 计划任务 + 隐藏 `FileSystemWatcher` |
| **7** | **本地优先安全** | 跳过已有真实目录，使用文件锁，仅监听 `127.0.0.1` |
| **8** | **并发安全** | macOS PID 锁 / Windows 命名互斥锁，防止同步重入 |

---

## 命令行工具

```bash
# macOS / Linux
bash ~/EasySkills/_maintenance/deploy.sh [选项]

# Windows (PowerShell)
powershell -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" [选项]
```

| 选项 | 说明 |
|---|---|
| *（无）* / `--sync` | 同步所有技能到所有 Agent |
| `--list` | 列出所有活跃映射 |
| `--add <路径>` | 添加并持久化自定义 Agent 路径 |
| `--remove <路径>` | 移除已持久化的自定义路径 |
| `--watch` | 安装后台监听 |
| `--unwatch` | 卸载后台监听 |
| `--webui` | 启动本地 WebUI（端口 6633） |
| `--cleanup` | 清除所有 EasySkills 软链接 |
| `--help` | 显示帮助 |

### 自然语言管理

EasySkills 加载为技能后，直接对 AI 助手说：

| 任务 | 提示词 |
|---|---|
| 初始化 | *"运行 EasySkills，帮我初始化技能同步系统"* |
| 添加自定义路径 | *"帮我把技能映射到 `/path/to/agent/skills`"* |
| 查看映射状态 | *"列出 EasySkills 当前所有映射"* |
| 移除路径 | *"从 EasySkills 移除 `/path/to/agent/skills`"* |

---

## 支持的 Agent 列表

开箱即用支持 35+ 个 Agent 目标路径，可随时通过命令行、WebUI 或对话添加自定义路径。

<details>
<summary><b>查看完整列表</b></summary>

| # | Agent | macOS 路径 | Windows 路径 |
|:-:|:---|:---|:---|
| 1 | **Antigravity CLI** | `~/.gemini/config/skills` | `%USERPROFILE%\.gemini\config\skills` |
| 1b | **Antigravity IDE** | `~/.gemini/antigravity/skills` | `%USERPROFILE%\.gemini\antigravity\skills` |
| 2 | **Codex (OpenAI)** | `~/.codex/skills` | `%USERPROFILE%\.codex\skills` |
| 3 | **Claude Code** | `~/.claude/skills` | `%USERPROFILE%\.claude\skills` |
| 4 | **GitHub Copilot** | `~/.copilot/skills` | `%USERPROFILE%\.copilot\skills` |
| 5 | **Pi** | `~/.pi/agent/skills` | `%USERPROFILE%\.pi\agent\skills` |
| 6 | **OpenCode** | `~/.config/opencode/skills` | `%USERPROFILE%\.config\opencode\skills` |
| 7 | **Trae (Global)** | `~/.trae/skills` | `%USERPROFILE%\.trae\skills` |
| 8 | **Trae CN** | `~/.trae-cn/skills` | `%USERPROFILE%\.trae-cn\skills` |
| 9 | **Kimi Code (Moonshot)** | `~/.kimi/skills` | `%USERPROFILE%\.kimi\skills` |
| 10 | **OpenClaw** | `~/.openclaw/skills` | `%USERPROFILE%\.openclaw\skills` |
| 11 | **Hermes Agent** | `~/.hermes/skills` | `%USERPROFILE%\.hermes\skills` |
| 12 | **Proma** | `~/.proma/default-skills` | `%USERPROFILE%\.proma\default-skills` |
| 13 | **Cursor** | `~/.cursor/skills` | `%USERPROFILE%\.cursor\skills` |
| 14 | **Kiro Agent (AWS)** | `~/.kiro/skills` | `%USERPROFILE%\.kiro\skills` |
| 15 | **Junie (JetBrains)** | `~/.junie/skills` | `%USERPROFILE%\.junie\skills` |
| 16 | **Cline** | `~/.cline/skills` | `%USERPROFILE%\.cline\skills` |
| 17 | **Roo Code** | `~/.roo/skills` | `%USERPROFILE%\.roo\skills` |
| 18 | **Warp** | `~/.warp/skills` | `%USERPROFILE%\.warp\skills` |
| 19 | **Windsurf** | `~/.codeium/windsurf/skills` | `%USERPROFILE%\.codeium\windsurf\skills` |
| 20 | **Firebender** | `~/.firebender/skills` | `%USERPROFILE%\.firebender\skills` |
| 21 | **Augment** | `~/.augment/skills` | `%USERPROFILE%\.augment\skills` |
| 22 | **Continue** | `~/.continue/skills` | `%USERPROFILE%\.continue\skills` |
| 23 | **Goose (Block/AAIF)** | `~/.config/goose/skills` | `%USERPROFILE%\.config\goose\skills` |
| 24 | **Agents (Standard)** | `~/.agents/skills` | `%USERPROFILE%\.agents\skills` |
| 25 | **Run** | `~/.run/global-skills/skills` | `%USERPROFILE%\.run\global-skills\skills` |
| 26 | **Qoder** | `~/.qoder/skills` | `%USERPROFILE%\.qoder\skills` |
| 27 | **Qwen Code** | `~/.qwen/skills` | `%USERPROFILE%\.qwen\skills` |
| 28 | **CodeBuddy** | `~/.codebuddy/skills` | `%USERPROFILE%\.codebuddy\skills` |
| 29 | **Amp** | `~/.config/agents/skills` | `%USERPROFILE%\.config\agents\skills` |
| 30 | **OpenHands** | `~/.openhands/skills` | `%USERPROFILE%\.openhands\skills` |
| 31 | **Kilo Code** | `~/.kilocode/skills` | `%USERPROFILE%\.kilocode\skills` |
| 32 | **Zencoder** | `~/.zencoder/skills` | `%USERPROFILE%\.zencoder\skills` |
| 33 | **iFlow CLI** | `~/.iflow/skills` | `%USERPROFILE%\.iflow\skills` |
| 34 | **Droid** | `~/.factory/skills` | `%USERPROFILE%\.factory\skills` |
| 35 | **Devin for Terminal** | `~/.config/devin/skills` | `%USERPROFILE%\.config\devin\skills` |

> Trae 和 Trae CN 同时映射到 `~/Library/Application Support/Trae[-CN]/skills`（macOS）和 `%APPDATA%\Trae[-CN]\skills`（Windows）。

</details>

---

## 注意事项

**Windows Defender** — 安装器可通过 UAC 弹窗自动添加白名单。也可以手动在 Windows 安全中心将 `%USERPROFILE%\EasySkills` 加入排除项。

**监听范围** — 后台监听只监控 `~/EasySkills` **顶层目录**的文件夹增删。不监听子目录内部——因为技能是通过软链映射的，内部文件修改会即时反映到所有 Agent，无需重新同步。如果存在 `~/.proma`，EasySkills 会每 5 分钟轮询 Proma workspace 的 `skills` 目录，自动发现新工作区。

---

## 参与贡献

添加新 Agent 支持：

1. 在 `_maintenance/deploy.sh` 和 `_maintenance/deploy.ps1` 的 `TARGETS` 数组中添加路径
2. 在两个文件的 `get_agent_name` / `Get-AgentName` 函数中添加名称映射
3. 更新 `README.md`、`README_CN.md` 和 `SKILL.md` 中的 Agent 表格
4. 提交 Pull Request

---

## 许可证

[MIT](LICENSE) &copy; 2026 Runhua Huang

---

<details>
<summary>Star History</summary>

<div align="center">

[![Star History Chart](https://api.star-history.com/svg?repos=RunhuaHuang/EasySkills&type=Date)](https://star-history.com/#RunhuaHuang/EasySkills&Date)

</div>

</details>
