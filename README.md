<div align="center">

# EasySkills

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Windows-brightgreen.svg)](#-installation)
[![Agents](https://img.shields.io/badge/Supported%20Agents-25+-orange.svg)](#-supported-agents)
[![Version](https://img.shields.io/badge/Version-1.1.1-purple.svg)](https://github.com/RunhuaHuang/EasySkills/releases)

**One skills directory to rule them all.**

[**中文文档**](README_CN.md)

</div>

---

## The Problem

You have Claude Code on your machine. And Cursor. And maybe Gemini CLI, Copilot, Windsurf, Trae, Codex...

You find an amazing custom skill — or you build one yourself. Now what?

You copy it into `~/.claude/skills/`. Then into `~/.cursor/skills/`. Then `~/.gemini/config/skills/`. Then you remember Copilot. And Codex. And that new agent you installed last week.

**A week later**, you improve the skill. Now you have to remember every folder you copied it to and update them all. You miss one. That agent runs the stale version. A bug you already fixed bites you again.

**A month later**, you've got 6 agents with 4 different versions of the same skill scattered across your home directory. Some folders have skills the others don't. You can't remember which agent has what.

This is the reality of the multi-agent era: **every AI coding agent reinvents its own skills silo**, and you're the one stuck manually keeping them in sync.

---

## The Solution

**EasySkills** eliminates this problem entirely.

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
│ ... 25 agents, all in sync, all the time    │
└─────────────────────────────────────────────┘
```

**One directory. One copy. Every agent.** Changes to a skill file are instantly reflected everywhere — because there's only one real copy, linked into all agent directories via symlinks (macOS) or NTFS junctions (Windows).

A background watcher detects when you add or remove skill folders and re-syncs automatically. It uses zero CPU when idle.

---

## Why EasySkills?

| Pain Point | Without EasySkills | With EasySkills |
|:---|:---|:---|
| Adding a new skill | Copy to N agent folders manually | Drop into one folder. Done. |
| Updating a skill | Hunt down every copy, update each | Edit the one copy. All agents see it. |
| New agent installed | Manually copy all skills over | Runs automatically on next sync |
| Removing a skill | Delete from N folders | Remove from one folder |
| Version drift | Inevitable | Impossible — there's only one copy |

---

## Features

### Zero-Privilege on Windows
Windows symbolic links require admin privileges or Developer Mode. EasySkills uses **NTFS Directory Junctions** — a native NTFS feature that works under standard user permissions with full compatibility. No UAC prompts, no elevated terminals crashing your agents.

### Silent Background Daemon
| | macOS | Windows |
|---|---|---|
| **Mechanism** | `launchd` + `WatchPaths` (kernel FSEvents) | Startup `.lnk` → `FileSystemWatcher` |
| **Idle CPU** | 0% | 0% |
| **Auto-start** | LaunchAgent plist | Startup folder shortcut |
| **Console window** | None (daemon) | Hidden (`WindowStyle=0`) |

### Smart Agent Detection
The engine checks whether an agent is actually installed before creating any directories. It looks for the agent's root config folder (e.g., `~/.claude/` for Claude Code) — if it doesn't exist, that agent is skipped. No phantom empty folders cluttering your home directory.

### Local-First Safety
If a skill with the same name already exists as a **real directory** (not a symlink) in an agent's skills folder, the engine skips it with a warning. Your local skills are never overwritten or deleted.

### Concurrency Protection
PID-based file lock (macOS) and named system mutex (Windows) prevent race conditions when the watcher and a manual sync trigger simultaneously.

### Double-Click Install & Uninstall
Native `.command` (macOS) and `.bat` (Windows) scripts. No terminal commands, no package managers, no environment setup. The uninstaller stops daemons, removes all symlinks, and deletes the directory — 100% clean removal.

---

## Installation

### Method A: One-Line Install (Recommended)

**macOS / Linux:**
```bash
curl -fsSL https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.sh | bash
```

**Windows (PowerShell):**
```powershell
irm https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.ps1 | iex
```

That's it. One command downloads EasySkills, installs the engine to `~/EasySkills`, maps all detected agents, and starts the background watcher.

### Method B: Double-Click

Clone or download this repo, then:

| | Install | Uninstall |
|---|---|---|
| **macOS** | Double-click `install_mac.command` | Double-click `uninstall_mac.command` |
| **Windows** | Double-click `install_windows.bat` | Double-click `uninstall_windows.bat` |

The installer copies the engine to `~/EasySkills`, scans for installed agents, maps all skills, and starts the background watcher. You can safely delete the downloaded repo afterward.

### Method C: Let Your AI Agent Do It

If your agent supports skill loading, just say:

> *"Help me initialize EasySkills"*

The agent reads [SKILL.md](SKILL.md), detects your OS, runs the script, and asks if you have custom agent paths to add. Fully autonomous.

---

## Usage

### Adding Skills

Drop any skill folder into `~/EasySkills`. The background watcher picks it up and maps it to all detected agents within seconds.

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

25 agents are pre-configured. Custom paths can be added at any time via CLI or chat.

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
├── _maintenance/              # Core engine (excluded from skill mapping)
│   ├── deploy.sh / deploy.ps1 # Mapping & CLI tool
│   ├── watch.sh / watch.ps1   # Watcher installer
│   ├── unwatch.sh / unwatch.ps1 # Watcher uninstaller
│   ├── watcher-service.ps1    # Windows FileSystemWatcher service
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

<div align="center">

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=RunhuaHuang/EasySkills&type=Date)](https://star-history.com/#RunhuaHuang/EasySkills&Date)

</div>
