<div align="center">

# EasySkills

**Cross-Platform Automated Skills Manager for AI Coding Agents**

**跨平台 AI Agent 技能自动化管理器**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Windows-brightgreen.svg)](#-installation--安装)
[![Agents](https://img.shields.io/badge/Supported%20Agents-24+-orange.svg)](#-supported-agents--支持的-agent-列表)
[![Version](https://img.shields.io/badge/Version-1.0.1-purple.svg)](https://github.com/RunhuaHuang/EasySkills/releases)

<br>

One central skills directory. Automatic symlink mapping to every AI agent on your machine.<br>
Zero CPU background watching. Double-click install. No admin privileges needed on Windows.

一个中央技能目录，自动软链映射到所有本地 AI Agent。<br>
零 CPU 后台监听，双击安装，Windows 无需管理员权限。

<br>

[English](#-what-is-easyskills) | [中文](#-easyskills-是什么)

</div>

---

## What is EasySkills?

EasySkills creates a single `~/EasySkills` directory on your machine and automatically maps every skill folder you put in it to **all** your installed AI coding agents via symlinks (macOS) or NTFS junctions (Windows).

Drop a skill folder in, and it instantly appears in Claude Code, Cursor, Gemini, Codex, Copilot, Windsurf, Trae, and 17+ other agents — no manual copying, no configuration.

A background watcher monitors the directory for changes and re-syncs automatically with **zero CPU usage** when idle.

## EasySkills 是什么？

EasySkills 在你的电脑上创建一个 `~/EasySkills` 中央目录，通过软链接（macOS）或 NTFS 目录联结（Windows）将你放入的每个技能文件夹自动映射到**所有**已安装的 AI 编程助手。

放入一个技能文件夹，它会即刻出现在 Claude Code、Cursor、Gemini、Codex、Copilot、Windsurf、Trae 等 20+ 个 Agent 中——无需手动复制，无需任何配置。

后台监听服务会自动检测目录变化并重新同步，空闲时 **CPU 占用为零**。

---

## Key Features / 核心特性

### Centralized Skill Vault / 中央技能库

Install once, and `~/EasySkills` becomes your single source of truth. The `_maintenance` engine lives inside it; the rest of the directory is yours for custom skills. You can delete the cloned repo after installation — the daemon keeps running.

安装后 `~/EasySkills` 成为唯一的技能管理中心。`_maintenance` 引擎隐藏在内部，目录其余空间留给你的自定义技能。安装完成后可以删除克隆的仓库——后台服务独立运行。

### Zero-Privilege Windows Mapping / Windows 免提权映射

Windows symbolic links require admin/UAC. EasySkills uses **NTFS Directory Junctions** instead — a native NTFS feature that works under standard user permissions with full compatibility.

Windows 创建软链接需要管理员权限。EasySkills 使用 **NTFS 目录联结**替代——原生 NTFS 特性，普通用户权限即可创建，兼容性 100%。

### Silent Background Daemon / 静默后台守护

| | macOS | Windows |
|---|---|---|
| **Mechanism** | `launchd` + `WatchPaths` (kernel FSEvents) | `.lnk` → `.vbs` → `FileSystemWatcher` |
| **Idle CPU** | 0% | 0% |
| **Auto-start** | LaunchAgent plist | Startup folder shortcut |
| **Window** | None (daemon) | Hidden (WindowStyle=0) |

### Smart Agent Detection / 智能 Agent 检测

The engine only creates skill directories for agents that are **already installed**. It checks for the agent's root config directory before mapping — no phantom folders cluttering your home directory.

引擎只为**已安装**的 Agent 创建技能目录。映射前会检查 Agent 的根配置目录是否存在——不会在你的主目录下产生无用的空文件夹。

### Local-First Safety / 本地优先保护

If a skill with the same name already exists as a real directory in an agent's skills folder, the sync engine skips it with a warning. Your local skills are **never** overwritten.

如果 Agent 的技能目录中已有同名的真实文件夹，同步引擎会跳过并发出警告。你的本地技能**永远不会**被覆盖。

### Concurrency Protection / 并发安全

PID-based file lock on macOS, named system mutex on Windows. If the watcher triggers while a manual sync is running, the second invocation is safely skipped.

macOS 使用 PID 文件锁，Windows 使用系统命名互斥锁。后台同步与手动同步不会冲突。

---

## Installation / 安装

### Method A: Double-Click Install (Recommended) / 双击安装（推荐）

No terminal needed. Clone or download this repo, then:

无需打开终端。克隆或下载本仓库后：

| | Install / 安装 | Uninstall / 卸载 |
|---|---|---|
| **macOS** | Double-click `install_mac.command` | Double-click `uninstall_mac.command` |
| **Windows** | Double-click `install_windows.bat` | Double-click `uninstall_windows.bat` |

The installer copies the engine to `~/EasySkills`, maps all detected agents, and starts the background watcher. You can delete the downloaded repo afterward.

安装器将引擎复制到 `~/EasySkills`，映射所有检测到的 Agent，并启动后台监听。之后可以删除下载的仓库。

### Method B: Let Your AI Agent Do It / 让 AI Agent 自动安装

If your agent supports skills, just tell it:

如果你的 Agent 支持技能加载，直接告诉它：

> *"Help me initialize EasySkills"* / *"帮我运行 EasySkills 初始化"*

The agent reads [SKILL.md](SKILL.md), detects your OS, runs the installer, and asks if you have custom agent paths to add.

Agent 会读取 [SKILL.md](SKILL.md)，检测操作系统，执行安装，并询问你是否有自定义 Agent 路径需要添加。

---

## Usage / 使用方法

### Adding Skills / 添加技能

Just drop any skill folder into `~/EasySkills`:

只需将技能文件夹放入 `~/EasySkills`：

```
~/EasySkills/
  ├── _maintenance/          # Engine (auto-ignored)
  ├── MyCustomSkill/         # Your skill - auto-mapped!
  ├── AnotherSkill/          # Another one - also auto-mapped!
  └── ...
```

The background watcher detects the change and maps it to all agents within seconds.

后台监听服务会在几秒内检测到变化并映射到所有 Agent。

### CLI Commands / 命令行工具

```bash
# macOS
bash ~/EasySkills/_maintenance/deploy.sh [option]

# Windows (PowerShell)
powershell -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" [option]
```

| Option | Description / 说明 |
|---|---|
| *(no option)* / `-s` `--sync` | Sync all skills to all agents / 同步所有技能到所有 Agent |
| `-l` `--list` | List all active mappings / 列出所有活跃映射 |
| `-a` `--add` `<path>` | Add & persist a custom agent path / 添加自定义 Agent 路径 |
| `-r` `--remove` `<path>` | Remove a persisted custom path / 移除自定义 Agent 路径 |
| `-w` `--watch` | Install background watcher / 安装后台监听 |
| `-u` `--unwatch` | Uninstall background watcher / 卸载后台监听 |
| `-c` `--cleanup` | Remove all EasySkills symlinks / 清除所有映射 |
| `-h` `--help` | Show help / 显示帮助 |

### Chat with Your Agent / 用自然语言管理

Once EasySkills is loaded as a skill, you can manage everything through chat:

EasySkills 加载为技能后，可以通过对话管理一切：

| Task / 任务 | Prompt / 提示词 |
|---|---|
| Initialize | *"Run EasySkills and initialize my skills sync"* / *"运行 EasySkills 初始化同步"* |
| Add custom path | *"Map EasySkills to `/path/to/agent/skills`"* / *"映射技能到 `/path/to/agent/skills`"* |
| View mappings | *"Show all active EasySkills mappings"* / *"显示所有 EasySkills 映射状态"* |
| Remove path | *"Remove `/path/to/agent/skills` from EasySkills"* / *"从 EasySkills 移除该路径"* |

---

## Supported Agents / 支持的 Agent 列表

24 agents are pre-configured out of the box. Custom paths can be added at any time.

开箱即用支持 24 个 Agent，可随时添加自定义路径。

| # | Agent | macOS Path | Windows Path |
|:-:|:---|:---|:---|
| 1 | **Antigravity (Gemini)** | `~/.gemini/config/skills` | `%USERPROFILE%\.gemini\config\skills` |
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

> Trae and Trae CN also map to `~/Library/Application Support/Trae[‑CN]/skills` (macOS) and `%APPDATA%\Trae[‑CN]\skills` (Windows).

> Trae 和 Trae CN 同时映射到 `~/Library/Application Support/Trae[-CN]/skills`（macOS）和 `%APPDATA%\Trae[-CN]\skills`（Windows）。

---

## Project Structure / 项目结构

```
EasySkills/
├── README.md                  # This file
├── SKILL.md                   # AI Agent skill interface
├── LICENSE                    # MIT License
├── .gitignore
├── install_mac.command        # macOS double-click installer
├── install_windows.bat        # Windows double-click installer
├── uninstall_mac.command      # macOS uninstaller
├── uninstall_windows.bat      # Windows uninstaller
├── _maintenance/              # Core engine (auto-excluded from skill mapping)
│   ├── deploy.sh              # macOS mapping & CLI tool
│   ├── deploy.ps1             # Windows mapping & CLI tool
│   ├── watch.sh               # macOS watcher installer (launchd)
│   ├── watch.ps1              # Windows watcher installer (startup shortcut)
│   ├── watcher-service.ps1    # Windows FileSystemWatcher service
│   ├── watcher-launcher.vbs   # Windows silent launcher
│   ├── unwatch.sh             # macOS watcher uninstaller
│   ├── unwatch.ps1            # Windows watcher uninstaller
│   └── .version               # Version tracker
└── [YourSkills]/              # Drop your custom skills here!
```

---

## How It Works / 工作原理

```
┌─────────────────────────────────────────────────────┐
│                  ~/EasySkills/                       │
│                                                     │
│  _maintenance/    SkillA/    SkillB/    SkillC/     │
│  (engine)                                           │
└──────────┬──────────────────────────────────────────┘
           │  symlink / junction
           ▼
┌──────────────────────────────────────────────────────┐
│  ~/.claude/skills/SkillA  ──→  ~/EasySkills/SkillA  │
│  ~/.cursor/skills/SkillA  ──→  ~/EasySkills/SkillA  │
│  ~/.gemini/config/skills/SkillA ──→  ...            │
│  ~/.codex/skills/SkillA   ──→  ...                  │
│  ... (all 24 agents)                                │
└──────────────────────────────────────────────────────┘
```

1. **Install** — Engine copies to `~/EasySkills/_maintenance/`, scans for installed agents, creates symlinks/junctions
2. **Watch** — Background daemon monitors `~/EasySkills/` top-level for folder additions/removals
3. **Sync** — On change, re-maps all skills to all detected agents. Existing real folders are never touched.

---

1. **安装** — 引擎复制到 `~/EasySkills/_maintenance/`，扫描已安装 Agent，创建软链/联结
2. **监听** — 后台守护进程监听 `~/EasySkills/` 顶层目录的文件夹增删
3. **同步** — 变化发生时，重新映射所有技能到所有 Agent。已有的真实文件夹不受影响。

---

## Notes / 注意事项

**Windows Defender**: The `.vbs` silent launcher may trigger a false positive. The project is fully open-source and safe. The installer can automatically add a Defender exclusion via UAC prompt, or you can manually whitelist `%USERPROFILE%\EasySkills` in Windows Security settings.

**Windows Defender 误报**：`.vbs` 静默启动器可能触发误报。项目完全开源安全。安装器可通过 UAC 弹窗自动添加 Defender 白名单，也可手动在 Windows 安全中心将 `%USERPROFILE%\EasySkills` 加入排除项。

**Watcher Scope**: The watcher monitors only the **top-level** of `~/EasySkills` (folder additions/removals/renames). It does not watch inside subdirectories — since skills are symlinked, internal file changes are instantly reflected everywhere without re-syncing.

**监听范围**：监听服务只监控 `~/EasySkills` **顶层目录**的变化。不监听子目录内部——因为技能是通过软链映射的，内部文件修改会即时反映到所有 Agent，无需重新同步。

---

## Contributing / 贡献

To add support for a new agent:

1. Add the default skills path to the `TARGETS` array in both `_maintenance/deploy.sh` and `_maintenance/deploy.ps1`
2. Add the agent name mapping in the `get_agent_name` / `Get-AgentName` function in both files
3. Update the agent table in this README and in `SKILL.md`
4. Submit a pull request

添加新 Agent 支持：在两个 deploy 脚本的 `TARGETS` 数组中添加路径，在 `get_agent_name` / `Get-AgentName` 中添加名称映射，更新 README 和 SKILL.md 的 Agent 表格，提交 PR。

---

## License / 许可证

[MIT](LICENSE) &copy; 2026 Runhua Huang

---

<div align="center">

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=RunhuaHuang/EasySkills&type=Date)](https://star-history.com/#RunhuaHuang/EasySkills&Date)

</div>
