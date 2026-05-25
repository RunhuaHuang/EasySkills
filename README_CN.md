<div align="center">

# EasySkills

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Windows-brightgreen.svg)](#安装方式)
[![Agents](https://img.shields.io/badge/支持Agent-25+-orange.svg)](#支持的-agent-列表)
[![Version](https://img.shields.io/badge/版本-1.2.1-purple.svg)](https://github.com/RunhuaHuang/EasySkills/releases)

**面向 AI 编程 Agent 的本地技能控制台。**

只维护一份技能。EasySkills 会自动检测本地主流 Agent，并通过原生链接，把 Claude Code、Codex、Cursor、Gemini、Copilot、Windsurf、Trae 等 25+ Agent 的技能目录统一起来。

本地优先。空闲零 CPU。自带 WebUI。

[**English**](README.md)

</div>

---

## 为什么需要 EasySkills

AI 编程工具正在变成一套工作栈，但它们的技能目录仍然彼此隔离。

同一个技能，可能要放进 Claude Code、Cursor、Codex、Gemini、Copilot，以及下一个你刚装的新 Agent。复制一开始没问题，直到你改了技能、忘了同步某个目录，旧版本就开始悄悄留下来。

EasySkills 保留每个 Agent 原生 skills 目录的使用方式，但不再让你维护多份副本。它会检测本机已安装的受支持 Agent，把共享技能映射进去，同时不影响各个 Agent 自己专属的 skills 继续使用。

| 你需要 | EasySkills 提供 |
|:---|:---|
| 一个技能库 | 所有技能统一放在 `~/EasySkills` |
| 不再版本漂移 | Agent 读取同一份真实文件，而不是复制副本 |
| 快速接入新 Agent | 自动检测本地受支持 Agent，只映射真实存在的路径 |
| 实时映射更新 | 监听 `~/EasySkills` 顶层技能文件夹的新增和删除，自动刷新映射 |
| 不侵入 Agent | 共享技能通过链接并列映射，Agent 自己的专属 skills 继续正常使用 |
| 可视化管理 | 本地 WebUI 管理状态、连接、清理和更新 |
| 安全默认值 | 跳过真实本地目录，使用锁保护同步，并仅监听 localhost |

---

## 安装方式

### 一行命令安装

**macOS / Linux：**
```bash
curl -fsSL https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.sh | bash
```

**Windows（PowerShell）：**
```powershell
irm https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.ps1 | iex
```

安装器会创建 `~/EasySkills`，映射所有已检测到的 Agent，启动后台监听，并在所需运行时可用时拉起本地 WebUI。

### 双击安装

克隆或下载本仓库，然后：

| | 安装 | 卸载 |
|---|---|---|
| **macOS** | 双击 `install_mac.command` | 双击 `uninstall_mac.command` |
| **Windows** | 双击 `install_windows.bat` | 双击 `uninstall_windows.bat` |

安装完成后可以删除下载的仓库；运行时文件会保留在 `~/EasySkills`。

### 让 AI Agent 自动安装

如果你的 Agent 支持技能加载，直接说：

> *"帮我初始化 EasySkills。"*

Agent 会读取 [SKILL.md](SKILL.md)，识别系统，运行安装脚本，并在需要时询问自定义 Agent 路径。

---

## WebUI 控制台

EasySkills 提供本地可视化控制台。你可以查看监听状态、手动同步、连接 Agent、编辑路径、清理无效链接、检查更新。

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

## 工作原理

```
~/EasySkills/
├── _maintenance/        ← 引擎（对 Agent 不可见）
├── MyAwesomeSkill/      ← 放进来一次
├── CodeReviewSkill/     ← 所有 Agent 都能看到
└── DeployHelper/        ← 即时、自动、全局同步
        │
        ▼ 软链接 / 目录联结（不是复制）
┌─────────────────────────────────────────────┐
│ ~/.claude/skills/MyAwesomeSkill  ──→  ✓     │
│ ~/.cursor/skills/MyAwesomeSkill  ──→  ✓     │
│ ~/.gemini/config/skills/MyAwesomeSkill ──→ ✓│
│ ~/.codex/skills/MyAwesomeSkill   ──→  ✓     │
│ ~/.copilot/skills/MyAwesomeSkill ──→  ✓     │
│ ... 25+ 个目标，全部同步，始终一致         │
└─────────────────────────────────────────────┘
```

EasySkills 在 macOS/Linux 上使用软链接，在 Windows 上使用 NTFS 目录联结。Agent 看到的是自己的标准技能目录，实际读取的是 `~/EasySkills` 中的同一份共享源文件。EasySkills 不会替换 Agent 的 skills 目录，也不会删除 Agent 自己已有的专属技能。顶层技能文件夹的新增和删除由轻量监听服务自动同步；技能内部文件修改会即时生效，不需要重新同步。

---

## 核心特性

| 能力 | 说明 |
|:---|:---|
| 本地 WebUI | `http://localhost:6633` 控制台，管理监听状态、技能库、Agent 连接、清理和更新 |
| Agent 自动检测 | 自动识别本地主流 Agent，只为真实存在的路径建立连接 |
| 实时技能映射 | `~/EasySkills` 中共享技能新增或删除后，自动更新映射 |
| 非侵入式链接 | 共享技能与 Agent 专属技能并列存在，不影响原有专属 skills |
| Windows 免提权映射 | 使用 NTFS 目录联结，无需管理员权限或开发者模式 |
| 静默监听 | macOS 使用 `launchd` + `WatchPaths`，Windows 使用计划任务 + 隐藏 `FileSystemWatcher` 服务 |
| 本地优先保护 | 遇到已有真实目录会跳过，不覆盖 Agent 自有技能 |
| 并发安全 | macOS 使用 PID 锁，Windows 使用命名互斥锁，避免同步重入 |

### 监听运行时
| | macOS | Windows |
|---|---|---|
| **机制** | `launchd` + `WatchPaths`（内核 FSEvents） | 计划任务 → `FileSystemWatcher` |
| **空闲 CPU** | 0% | 0% |
| **开机自启** | LaunchAgent plist | 计划任务（启动快捷方式兜底） |
| **控制台窗口** | 无（守护进程） | 隐藏（`WindowStyle=0`） |

## 使用方法

将任意共享技能文件夹放入 `~/EasySkills`。后台监听会在几秒内映射到所有已检测到的 Agent。Agent 自己已有的专属技能会保留在原位；映射技能内部文件修改不需要重新同步，因为 Agent 读取的是同一份链接源。

### 命令行工具

```bash
# macOS
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
| `--webui` | 启动本地 WebUI 管理面板（端口 6633） |
| `--cleanup` | 清除所有 EasySkills 创建的软链接 |
| `--help` | 显示帮助 |

### 用自然语言管理

EasySkills 加载为技能后，直接对你的 AI 助手说：

| 任务 | 提示词 |
|---|---|
| 初始化 | *"运行 EasySkills，帮我初始化技能同步系统"* |
| 添加自定义路径 | *"帮我把技能映射到 `/path/to/agent/skills`"* |
| 查看映射状态 | *"列出 EasySkills 当前所有映射"* |
| 移除路径 | *"从 EasySkills 移除 `/path/to/agent/skills`"* |

---

## 支持的 Agent 列表

开箱即用支持 25+ 个 Agent 目标路径，可随时通过命令行或对话添加自定义路径。

| # | Agent | macOS 路径 | Windows 路径 |
|:-:|:---|:---|:---|
| 1 | **Antigravity CLI** | `~/.gemini/config/skills` | `%USERPROFILE%\.gemini\config\skills` |
| 1b | **Antigravity IDE** | `~/.gemini/antigravity/skills` | `%USERPROFILE%\.gemini\antigravity\skills` |
| 2 | **Codex (OpenAI)** | `~/.codex/skills` | `%USERPROFILE%\.codex\skills` |
| 3 | **Claude Code** | `~/.claude/skills` | `%USERPROFILE%\.claude\skills` |
| 4 | **GitHub Copilot** | `~/.copilot/skills` | `%USERPROFILE%\.copilot\skills` |
| 5 | **Pi** | `~/.pi/skills` | `%USERPROFILE%\.pi\skills` |
| 6 | **OpenCode** | `~/.opencode/skills` | `%USERPROFILE%\.opencode\skills` |
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
| 19 | **Windsurf** | `~/.windsurf/skills` | `%USERPROFILE%\.windsurf\skills` |
| 20 | **Firebender** | `~/.firebender/skills` | `%USERPROFILE%\.firebender\skills` |
| 21 | **Augment** | `~/.augment/skills` | `%USERPROFILE%\.augment\skills` |
| 22 | **Continue** | `~/.continue/skills` | `%USERPROFILE%\.continue\skills` |
| 23 | **Goose (Block/AAIF)** | `~/.goose/skills` | `%USERPROFILE%\.goose\skills` |
| 24 | **Agents (Standard)** | `~/.agents/skills` | `%USERPROFILE%\.agents\skills` |
| 25 | **Run** | `~/.run/global-skills/skills` | `%USERPROFILE%\.run\global-skills\skills` |

> Trae 和 Trae CN 同时映射到 `~/Library/Application Support/Trae[-CN]/skills`（macOS）和 `%APPDATA%\Trae[-CN]\skills`（Windows）。

---

## 项目结构

```
EasySkills/
├── README.md                  # 英文文档
├── README_CN.md               # 中文文档（本文件）
├── SKILL.md                   # AI Agent 技能接口定义
├── LICENSE                    # MIT 许可证
├── install.sh                 # macOS/Linux 远程安装脚本（curl）
├── install.ps1                # Windows 远程安装脚本（irm）
├── install_mac.command        # macOS 双击安装器
├── install_windows.bat        # Windows 双击安装器
├── uninstall_mac.command      # macOS 卸载器
├── uninstall_windows.bat      # Windows 卸载器
├── docs/assets/               # README 截图
├── _maintenance/              # 核心引擎（不会被映射为技能）
│   ├── deploy.sh / deploy.ps1 # 映射与命令行工具
│   ├── webui.py / webui.ps1   # 本地 WebUI 后端
│   ├── watch.sh / watch.ps1   # 监听安装器
│   ├── unwatch.sh / unwatch.ps1 # 监听卸载器
│   ├── register-tasks.ps1     # Windows 计划任务注册
│   ├── watcher-service.ps1    # Windows FileSystemWatcher 守护
│   ├── webui-service.ps1      # Windows WebUI 守护
│   └── .version               # 版本号
└── [你的技能]/                 # 把自定义技能放这里
```

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
