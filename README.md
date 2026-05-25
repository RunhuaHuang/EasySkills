<div align="center">

# EasySkills

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Windows-brightgreen.svg)](#installation)
[![Agents](https://img.shields.io/badge/Supported%20Agents-25+-orange.svg)](#supported-agents)
[![Version](https://img.shields.io/badge/Version-1.2.1-purple.svg)](https://github.com/RunhuaHuang/EasySkills/releases)

**A local control plane for AI coding agent skills.**

Drop a skill once. EasySkills detects mainstream local agents and keeps Claude Code, Codex, Cursor, Gemini, Copilot, Windsurf, Trae, and 25+ agent targets in sync through native links.

Local-first. Zero idle CPU. WebUI included.

[**中文文档**](README_CN.md)

</div>

---

## Why EasySkills

AI coding agents are becoming a daily stack, but their skill systems still live in separate folders.

One skill might need to exist in Claude Code, Cursor, Codex, Gemini, Copilot, and whatever you install next. Copying works at first, then updates drift, old versions linger, and every agent becomes its own small maintenance project.

EasySkills keeps the convenience of each agent's native skills folder without forcing you to maintain copies. It detects supported agents already installed on your machine, maps shared skills into them, and leaves each agent's own private skills untouched.

| What you need | What EasySkills does |
|:---|:---|
| One skill library | Stores every skill in `~/EasySkills` |
| No version drift | Maps agents to the same real files instead of copying |
| Fast onboarding | Detects supported local agents and maps only paths that exist |
| Live updates | Watches top-level skill additions/removals and refreshes mappings automatically |
| Native-agent compatibility | Uses links, so each agent can keep its own dedicated skills alongside shared ones |
| Visual control | Ships a local WebUI for status, bridges, cleanup, and updates |
| Safe defaults | Skips real local folders, uses file locks, and stays localhost-only |

---

## Installation

### One-Line Install

**macOS / Linux:**
```bash
curl -fsSL https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.sh | bash
```

**Windows (PowerShell):**
```powershell
irm https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.ps1 | iex
```

The installer creates `~/EasySkills`, maps every detected agent, starts the watcher, and launches the local WebUI when the required runtime is available.

### Double-Click Install

Clone or download this repo, then:

| | Install | Uninstall |
|---|---|---|
| **macOS** | Double-click `install_mac.command` | Double-click `uninstall_mac.command` |
| **Windows** | Double-click `install_windows.bat` | Double-click `uninstall_windows.bat` |

You can delete the downloaded repo after installation; the runtime lives in `~/EasySkills`.

### Agent-Assisted Install

If your agent supports skill loading, just say:

> *"Help me initialize EasySkills."*

The agent reads [SKILL.md](SKILL.md), detects your OS, runs the installer, and asks about custom agent paths when needed.

---

## WebUI Dashboard

Manage EasySkills visually from a local-only dashboard. Monitor watcher status, sync on demand, connect agent bridges, edit paths, clean broken links, and check for updates.

```bash
# macOS / Linux
bash ~/EasySkills/_maintenance/deploy.sh --webui

# Windows (PowerShell)
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" -WebUI
```

<p align="center">
  <img src="docs/assets/webui-dashboard-macos.jpg" alt="EasySkills WebUI dashboard on macOS" width="100%">
</p>

<p align="center">
  <img src="docs/assets/webui-agents-macos.jpg" alt="EasySkills WebUI agent bridges on macOS" width="100%">
</p>

---

## How It Works

```
~/EasySkills/
├── _maintenance/        ← engine (invisible to agents)
├── MyAwesomeSkill/      ← drop it here once
├── CodeReviewSkill/     ← it appears everywhere
└── DeployHelper/        ← instantly, automatically
        │
        ▼ symlink / junction (not copy)
┌─────────────────────────────────────────────┐
│ ~/.claude/skills/MyAwesomeSkill  ──→  ✓     │
│ ~/.cursor/skills/MyAwesomeSkill  ──→  ✓     │
│ ~/.gemini/config/skills/MyAwesomeSkill ──→ ✓│
│ ~/.codex/skills/MyAwesomeSkill   ──→  ✓     │
│ ~/.copilot/skills/MyAwesomeSkill ──→  ✓     │
│ ... 25+ targets, all in sync, all the time  │
└─────────────────────────────────────────────┘
```

EasySkills maps each shared skill into agent-specific folders with symlinks on macOS/Linux and NTFS junctions on Windows. It does not replace the agent's skills directory and does not remove agent-owned skills. File edits are reflected immediately because every mapped agent points back to the same source. A lightweight watcher handles top-level skill additions and removals with zero CPU while idle.

---

## Core Capabilities

| Capability | Details |
|:---|:---|
| Local WebUI | Dashboard at `http://localhost:6633` for watcher status, skill registry, agent bridges, cleanup, and updates |
| Agent discovery | Detects mainstream local agents and only enables bridges for paths that actually exist |
| Live skill mapping | Updates mappings when shared skill folders are added or removed from `~/EasySkills` |
| Non-invasive links | Shared skills are mapped beside agent-specific skills, so private agent skills keep working |
| Zero-privilege Windows mapping | Uses NTFS directory junctions, so users do not need admin mode or Developer Mode |
| Silent watcher | `launchd` + `WatchPaths` on macOS, scheduled task + hidden `FileSystemWatcher` service on Windows |
| Local-first safety | Skips existing real folders and never overwrites local agent-owned skills |
| Concurrency protection | PID lock on macOS and named mutex on Windows prevent overlapping sync runs |

### Watcher Runtime
| | macOS | Windows |
|---|---|---|
| **Mechanism** | `launchd` + `WatchPaths` (kernel FSEvents) | Scheduled Task → `FileSystemWatcher` |
| **Idle CPU** | 0% | 0% |
| **Auto-start** | LaunchAgent plist | Scheduled Task (startup shortcut fallback) |
| **Console window** | None (daemon) | Hidden (`WindowStyle=0`) |

## Usage

Drop any shared skill folder into `~/EasySkills`. The watcher maps it to detected agents within seconds. Existing agent-specific skills stay in place, and edits inside a mapped skill folder do not require re-syncing because agents read the linked source directly.

### CLI Reference

```bash
# macOS
bash ~/EasySkills/_maintenance/deploy.sh [option]

# Windows (PowerShell)
powershell -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" [option]
```

| Option | Description |
|---|---|
| *(none)* / `--sync` | Sync all skills to all agents |
| `--list` | List all active mappings |
| `--add <path>` | Add & persist a custom agent path |
| `--remove <path>` | Remove a persisted custom path |
| `--watch` | Install background watcher |
| `--unwatch` | Uninstall background watcher |
| `--webui` | Start the local WebUI manager on port 6633 |
| `--cleanup` | Remove all EasySkills symlinks |
| `--help` | Show help |

### Agent Chat Commands

Once EasySkills is loaded as a skill, you can manage everything through natural language:

| Task | Prompt |
|---|---|
| Initialize | *"Run EasySkills and set up my skills sync"* |
| Add custom path | *"Map EasySkills to `/path/to/agent/skills`"* |
| View mappings | *"Show all active EasySkills mappings"* |
| Remove a path | *"Remove `/path/to/agent/skills` from EasySkills"* |

---

## Supported Agents

25+ agent targets are pre-configured. Custom paths can be added at any time via CLI or chat.

| # | Agent | macOS Path | Windows Path |
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

> Trae and Trae CN also map to `~/Library/Application Support/Trae[-CN]/skills` (macOS) and `%APPDATA%\Trae[-CN]\skills` (Windows).

---

## Project Structure

```
EasySkills/
├── README.md                  # English documentation (this file)
├── README_CN.md               # Chinese documentation
├── SKILL.md                   # AI Agent skill interface
├── LICENSE                    # MIT License
├── install.sh                 # macOS/Linux remote installer (curl)
├── install.ps1                # Windows remote installer (irm)
├── install_mac.command        # macOS double-click installer
├── install_windows.bat        # Windows double-click installer
├── uninstall_mac.command      # macOS uninstaller
├── uninstall_windows.bat      # Windows uninstaller
├── docs/assets/               # README screenshots
├── _maintenance/              # Core engine (excluded from skill mapping)
│   ├── deploy.sh / deploy.ps1 # Mapping & CLI tool
│   ├── webui.py / webui.ps1   # Local WebUI backend
│   ├── watch.sh / watch.ps1   # Watcher installer
│   ├── unwatch.sh / unwatch.ps1 # Watcher uninstaller
│   ├── register-tasks.ps1     # Windows Scheduled Task registration
│   ├── watcher-service.ps1    # Windows FileSystemWatcher supervisor
│   ├── webui-service.ps1      # Windows WebUI supervisor
│   └── .version               # Version tracker
└── [YourSkills]/              # Drop your custom skills here
```

---

## Notes

**Windows Defender** — The installer can automatically add a Defender exclusion via UAC prompt. You can also manually whitelist `%USERPROFILE%\EasySkills` in Windows Security settings.

**Watcher Scope** — The watcher monitors only the **top-level** of `~/EasySkills` (folder additions/removals). It does not watch inside subdirectories — since skills are symlinked, internal file changes are instantly reflected everywhere without re-syncing. If `~/.proma` exists, EasySkills also polls Proma workspace `skills` folders every 5 minutes so new workspaces are picked up automatically.

---

## Contributing

To add support for a new agent:

1. Add the default skills path to the `TARGETS` array in both `_maintenance/deploy.sh` and `_maintenance/deploy.ps1`
2. Add the agent name mapping in `get_agent_name` / `Get-AgentName` in both files
3. Update the agent table in `README.md`, `README_CN.md`, and `SKILL.md`
4. Submit a pull request

---

## License

[MIT](LICENSE) &copy; 2026 Runhua Huang

---

<details>
<summary>Star History</summary>

<div align="center">
[![Star History Chart](https://api.star-history.com/svg?repos=RunhuaHuang/EasySkills&type=Date)](https://star-history.com/#RunhuaHuang/EasySkills&Date)
</div>

</details>
