<div align="center">

# EasySkills

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Windows-brightgreen.svg)](#quick-start)
[![Agents](https://img.shields.io/badge/Supported%20Agents-43+-orange.svg)](#supported-agents)
[![Version](https://img.shields.io/badge/Version-4.0.3-purple.svg)](https://github.com/RunhuaHuang/EasySkills/releases)

**One central library, three capability channels, every AI coding agent under control.**

Simply drop a skill or instruction rule into `~/EasySkills`, or configure downstream MCP servers in the WebUI. EasySkills automatically syncs these capabilities to Claude Code, Cursor, Windsurf, Trae, Copilot, Gemini, and 43+ other agent environments.

Local-first &bull; Zero idle CPU &bull; WebUI included

[**中文文档**](README.md)

</div>

---

## Quick Start

### 1. One-Line Installation

Please copy and run the command suitable for your system. The commands are split into two lines for improved readability and to ensure the copy buttons are fully visible in all views:

**macOS / Linux**
```bash
curl -fsSL \
  https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.sh | bash
```

**Windows (PowerShell)**
```powershell
irm `
  https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.ps1 | iex
```

> 💡 **Alternative Installation**: You can also clone this repository locally and double-click `install_mac.command` (macOS) or `install_windows.bat` (Windows).

The installer will automatically perform the following steps:
1. Create `~/EasySkills` in your user directory as the central management folder.
2. Auto-detect installed agents and establish shared skill mappings.
3. Install the single-file MCP Gateway binary.
4. Launch the background file watcher service (for real-time synchronization).
5. Open the local WebUI manager console (`http://127.0.0.1:6633`).

---

## Open, Stop, Restart, and Update

Once installed, the background daemon service keeps running and the WebUI automatically launches at `http://127.0.0.1:6633`.

### Open the WebUI Manually
If you need to open the WebUI console manually at a later time:
* **macOS / Linux**:
  ```bash
  bash ~/EasySkills/_maintenance/deploy.sh --webui
  ```
* **Windows (PowerShell)**:
  ```powershell
  powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" -WebUI
  ```

### Stop Services
Closing the browser tab only closes the dashboard; background watchers will continue sync operations. To stop them completely:
* **macOS / Linux**:
  ```bash
  bash ~/EasySkills/_maintenance/deploy.sh --unwatch
  launchctl remove com.easyskills.webui 2>/dev/null || true
  launchctl remove com.easyskills.webui.manual 2>/dev/null || true
  pkill -f '[E]asySkills/_maintenance/webui.py' 2>/dev/null || true
  pkill -f '[E]asySkills/_maintenance/webui-service.sh' 2>/dev/null || true
  ```
* **Windows (PowerShell)**:
  ```powershell
  powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" -Unwatch
  ```

### Restart Services
* **macOS / Linux**:
  ```bash
  bash ~/EasySkills/_maintenance/deploy.sh --unwatch
  bash ~/EasySkills/_maintenance/deploy.sh --watch
  bash ~/EasySkills/_maintenance/deploy.sh --webui
  ```
* **Windows (PowerShell)**:
  ```powershell
  powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" -Unwatch
  powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" -Watch
  powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" -WebUI
  ```

### Update
* **Recommended**: Click **Check for updates / Update now** inside the WebUI Dashboard to upgrade in place. This preserves your custom paths, tokens, and settings, while backing up the prior engine in `_maintenance.bak` for rollback.
* **CLI**: Re-run the Quick Start installation scripts to perform an in-place upgrade:

  **macOS / Linux**
  ```bash
  curl -fsSL \
    https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.sh | bash
  ```

  **Windows (PowerShell)**
  ```powershell
  irm `
    https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.ps1 | iex
  ```

---

## Core Features and Usage Guide

EasySkills organizes AI Agent capabilities into three distinct channels. Here is how to use them:

```
~/EasySkills/                           ← Your Central Directory
│
├── [Channel 1] Skills Sync
│   ├── MyAwesomeSkill/                 ← Your custom skill folder
│   └── DeployHelper/
│               │
│               ▼ Native Symlinks / Junctions Mapping
│       ┌──────────────────────────────────────────────┐
│       │ ~/.claude/skills/MyAwesomeSkill  ──→  ✓      │
│       │ ~/.cursor/skills/MyAwesomeSkill  ──→  ✓      │
│       └──────────────────────────────────────────────┘
│
├── [Channel 2] MCP Gateway
│   ├── mcp/servers.json                ← Central config for downstream MCPs
│   └── _runtime/easyskills-mcp         ← Single-file MCP Gateway Proxy
│               │
│               ▼ Connect Agent once; Gateway routes all downstream tools
│       (prismstudio / visionpower / ...)
│
└── [Channel 3] Agents.md Agent Rules Sync
    ├── instructions/                   ← Place your modular rule files (.md)
    │   ├── git-rules.md
    │   └── python-style.md
    │           │
    │           ▼ Non-Destructive Managed Block Injection
    │   ┌──────────────────────────────────────────────┐
    │   │ ~/.claude/CLAUDE.md      ──→ <!-- Managed -->│
    │   │ ~/.cursor/AGENTS.md      ──→ <!-- Managed -->│
    │   └──────────────────────────────────────────────┘
```

---

### 1. Skills Sync (Channel 1)

Distribute your custom agent skills (prompt templates, workflows, custom tools) to all installed coding agents at once.

#### How to Use
* **Via File Manager**: Create or place your skill folders (e.g., `MyAwesomeSkill/`) directly under the `~/EasySkills/` directory.
* **Via WebUI**: Go to the **Skills** tab in the WebUI and click "Import Skill Folder" to upload it.

#### Working Principle
The EasySkills background watcher monitors directory additions and deletions in `~/EasySkills/`. It maps these folders to the corresponding skill directories of all installed agents using native **symlinks (macOS/Linux)** or **directory junctions (Windows)**.
* **Instant Effect**: Since it uses symlinks, edits made within `~/EasySkills/MyAwesomeSkill/` are reflected across all agent environments immediately.
* **Coexistence**: EasySkills only maps your shared folders; agent-specific private skills remain untouched and operational.

---

### 2. MCP Gateway (Channel 2)

Eliminate the need to repeatedly configure the same downstream MCP services (like databases, web search, GitHub tools) across different AI editors. Connect each agent once to the EasySkills Gateway, and manage all downstream MCPs centrally.

#### How to Use
1. **Add Downstream MCPs**: In the WebUI **MCP** page, click "Add MCP" and fill out the structured form for your target MCP service (supports stdio, HTTP, and SSE transport protocols).
2. **Retrieve Agent Configuration**: In the "Connect an Agent once" panel, select the agent you are using (e.g., Claude Code, Cursor, VS Code, or Codex) and copy the generated connection snippet. If you do not know how to configure this on your Agent, you can also copy the command and provide it directly to your Agent, letting it help you configure MCP automatically, then restart the Agent to enable it.
3. **Configure the Agent**: Paste the copied configuration snippet into your agent's config file (e.g., `claude_desktop_config.json` or Cursor's MCP list).
4. **Centralized Operations**: To add a new tool, update an API token, or disable a service, simply perform the action in the EasySkills WebUI. All agents will immediately pick up the changes without requiring any config edits.

#### Key Features
* **Tool Filtering**: Apply a custom whitelist or blacklist to restrict which tools are exposed per MCP service.
* **Connection Testing**: Execute one-click connectivity checks for downstream MCPs directly from the WebUI.

---

### 3. Agents.md Agent Rules Sync (Channel 3)

Deploy your personal development guidelines (e.g., Git commit message format, coding style, formatting standards) across all coding agents.

#### How to Use
* Simply drop your Markdown rule files (e.g., `git-rules.md`, `python-style.md`) into the `~/EasySkills/instructions/` directory.

#### Working Principle
EasySkills compiles and concatenates all Markdown files in the `instructions/` folder and inserts them into the global system instruction files of your agents (e.g., `~/.claude/CLAUDE.md` for Claude Code, or `~/.cursor/AGENTS.md` for Cursor).
* **Non-Destructive Managed Block**: The injected contents are bounded by `<!-- EasySkills:begin -->` and `<!-- EasySkills:end -->` comment blocks. EasySkills only overwrites content inside these markers, preserving any custom guidelines you write outside of them.

---

## WebUI Dashboard

The local-only WebUI running at `http://127.0.0.1:6633` is the central interface for managing your setup.

* **Skills Management**: Import and delete shared skills, and monitor which agents are mapping them.
* **Rules Management**: Online Markdown editor to create and manage custom prompt rules.
* **MCP Management**: Graphical management of downstream MCP modules, testing connectivity, and copying agent-side connection configs.
* **Agent Status**: View install status and directory path maps for 43+ built-in agents, and register custom agent paths.

<p align="center">
  <img src="docs/assets/webui-dashboard-macos.jpg" alt="EasySkills WebUI dashboard on macOS" width="100%">
</p>

<p align="center">
  <img src="docs/assets/webui-agents-macos.jpg" alt="EasySkills WebUI linked agents on macOS" width="100%">
</p>

---

## Features

| | Feature | Details |
|:---:|:---|:---|
| **1** | **Skill Import/Delete** | Import and manage skill folders visually via WebUI with safe deletion prompts |
| **2** | **Agents.md Agent Rules Sync** | Safe, non-destructive managed block injection (`<!-- EasySkills:begin/end -->`) into global instructions |
| **3** | **Agent Auto-Detection** | Detects 43+ mainstream agents and creates links only for paths that actually exist |
| **4** | **Central MCP Gateway** | Connect each agent once; manage downstream MCPs, API keys, and tool filters in the WebUI |
| **5** | **Non-Invasive** | Shared skills reside alongside agent-specific skills — private skills continue to work |
| **6** | **Zero-Privilege Windows** | NTFS directory junctions — no admin shell or Developer Mode required |
| **7** | **Local-First Security** | Skips existing real folders, uses file locks, and listens strictly on `127.0.0.1` |
| **8** | **Concurrency Protection** | macOS PID lock / Windows named mutex protects against overlapping syncs |
| **9** | **Static Single Binary** | Go-based compiled binary covering amd64/arm64 on macOS, Windows, and Linux |

---

## CLI Reference

You can also run management scripts directly via terminal commands:

**macOS / Linux**
```bash
bash ~/EasySkills/_maintenance/deploy.sh [option]
```

**Windows (PowerShell)**
```powershell
powershell -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" [option]
```

| Option | Description |
|---|---|
| *(none)* / `--sync` | Trigger an immediate sync of skills and rule files to all target agents |
| `--list` | Output a list of all active skill mappings |
| `--add <path>` | Manually register a custom skills directory for an unsupported agent |
| `--remove <path>` | Remove a registered custom agent path |
| `--watch` | Install and start the background file watcher service |
| `--unwatch` | Stop and uninstall the background file watcher service |
| `--webui` | Start the local WebUI manager service on port 6633 |
| `--cleanup` | Delete all symlinks and junctions created by EasySkills (safe, keeps source directories) |
| `--help` | Show command line usage help |

---

## Supported Agents

EasySkills pre-configures mappings for 43+ agent target directories. Custom paths can be added via the WebUI or using `deploy.sh --add <path>`.

<details>
<summary><b>Click to expand the full agent list</b></summary>

| # | Agent | macOS Path | Windows Path |
|:-:|:---|:---|:---|
| 1 | **Antigravity CLI** | `~/.gemini/config/skills` | `%USERPROFILE%\.gemini\config\skills` |
| 2 | **Antigravity IDE** | `~/.gemini/antigravity/skills` | `%USERPROFILE%\.gemini\antigravity\skills` |
| 3 | **Codex (OpenAI)** | `~/.codex/skills` | `%USERPROFILE%\.codex\skills` |
| 4 | **Claude Code** | `~/.claude/skills` | `%USERPROFILE%\.claude\skills` |
| 5 | **GitHub Copilot** | `~/.copilot/skills` | `%USERPROFILE%\.copilot\skills` |
| 6 | **Pi** | `~/.pi/agent/skills` | `%USERPROFILE%\.pi\agent\skills` |
| 7 | **OpenCode** | `~/.config/opencode/skills` | `%USERPROFILE%\.config\opencode\skills` |
| 8 | **Trae (Global)** | `~/.trae/skills` | `%USERPROFILE%\.trae\skills` |
| 9 | **Trae CN** | `~/.trae-cn/skills` | `%USERPROFILE%\.trae-cn\skills` |
| 10 | **Kimi Code (Moonshot)** | `~/.kimi/skills` | `%USERPROFILE%\.kimi\skills` |
| 11 | **ZCode** | `~/.zcode/skills` | `%USERPROFILE%\.zcode\skills` |
| 12 | **OpenClaw** | `~/.openclaw/skills` | `%USERPROFILE%\.openclaw\skills` |
| 13 | **Hermes Agent** | `~/.hermes/skills` | `%USERPROFILE%\.hermes\skills` |
| 14 | **Proma** | `~/.proma/default-skills` | `%USERPROFILE%\.proma\default-skills` |
| 15 | **Cursor** | `~/.cursor/skills` | `%USERPROFILE%\.cursor\skills` |
| 16 | **Kiro Agent (AWS)** | `~/.kiro/skills` | `%USERPROFILE%\.kiro\skills` |
| 17 | **Junie (JetBrains)** | `~/.junie/skills` | `%USERPROFILE%\.junie\skills` |
| 18 | **Cline** | `~/.cline/skills` | `%USERPROFILE%\.cline\skills` |
| 19 | **Roo Code** | `~/.roo/skills` | `%USERPROFILE%\.roo\skills` |
| 20 | **Warp** | `~/.warp/skills` | `%USERPROFILE%\.warp\skills` |
| 21 | **Windsurf** | `~/.codeium/windsurf/skills` | `%USERPROFILE%\.codeium\windsurf\skills` |
| 22 | **Firebender** | `~/.firebender/skills` | `%USERPROFILE%\.firebender\skills` |
| 23 | **Augment** | `~/.augment/skills` | `%USERPROFILE%\.augment\skills` |
| 24 | **Continue** | `~/.continue/skills` | `%USERPROFILE%\.continue\skills` |
| 25 | **Goose (Block/AAIF)** | `~/.config/goose/skills` | `%USERPROFILE%\.config\goose\skills` |
| 26 | **Agents (Standard)** | `~/.agents/skills` | `%USERPROFILE%\.agents\skills` |
| 27 | **Run** | `~/.run/global-skills/skills` | `%USERPROFILE%\.run\global-skills\skills` |
| 28 | **Qoder** | `~/.qoder/skills` | `%USERPROFILE%\.qoder/skills` |
| 29 | **Qwen Code** | `~/.qwen/skills` | `%USERPROFILE%\.qwen\skills` |
| 30 | **CodeBuddy** | `~/.codebuddy/skills` | `%USERPROFILE%\.codebuddy\skills` |
| 31 | **Amp** | `~/.config/agents/skills` | `%USERPROFILE%\.config\agents\skills` |
| 32 | **OpenHands** | `~/.openhands/skills` | `%USERPROFILE%\.openhands\skills` |
| 33 | **Kilo Code** | `~/.kilocode/skills` | `%USERPROFILE%\.kilocode\skills` |
| 34 | **Zencoder** | `~/.zencoder/skills` | `%USERPROFILE%\.zencoder\skills` |
| 35 | **iFlow CLI** | `~/.iflow/skills` | `%USERPROFILE%\.iflow\skills` |
| 36 | **Droid** | `~/.factory/skills` | `%USERPROFILE%\.factory\skills` |
| 37 | **Devin for Terminal** | `~/.config/devin/skills` | `%USERPROFILE%\.config\devin\skills` |
| 38 | **WorkBuddy** | `~/.workbuddy/skills` | `%USERPROFILE%\.workbuddy\skills` |
| 39 | **QClaw** | `~/.qclaw/skills` | `%USERPROFILE%\.qclaw\skills` |
| 40 | **CodeWhale** | `~/.codewhale/skills` | `%USERPROFILE%\.codewhale\skills` |
| 41 | **QoderWork CN** | `~/.qoderworkcn/skills` | `%USERPROFILE%\.qoderworkcn\skills` |
| 42 | **Qoder CN** | `~/.qoder-cn/skills` | `%USERPROFILE%\.qoder-cn\skills` |
| 43 | **MiniMax Code** | `~/.mavis/agents/mavis/skills` | `%USERPROFILE%\.mavis\agents\mavis\skills` |

> *Note:* Trae and Trae CN also map to `~/Library/Application Support/Trae[-CN]/skills` (macOS) and `%APPDATA%\Trae[-CN]\skills` (Windows).

</details>

---

## Notes & Troubleshooting

* **Windows Defender**: On Windows, the installer tries to append a Defender exclusion for `~/EasySkills` via UAC shell execution. Agree to the prompts. Alternatively, you can add `%USERPROFILE%\EasySkills` to exclusions manually in Windows Security settings.
* **Watcher Operations**: The background watcher service only monitors the **top-level** of the `~/EasySkills/` directory for additions and removals of folders. Subfolders within skills do not require file monitoring, as symlinks/junctions propagate internal edits instantly. If `~/.proma` exists, EasySkills checks the Proma workspace skills directories every 5 minutes to auto-mount.

---

## Contributing

To contribute support for a new Agent:

1. Add your agent configuration object to `_maintenance/agents.json` (the primary data source).
2. Append the target path to the default silent arrays in `deploy.sh` and `deploy.ps1`.
3. Update agent lists in `README.md`, `README_EN.md`, and `README_SYSTEM.md`.
4. Run validation tests:
   ```bash
   python3 -m unittest _maintenance/tests/test_security_contracts.py
   ```
5. Submit a Pull Request!

---

## License

Distributed under the [MIT License](LICENSE).
&copy; 2026 Runhua Huang

---

<details>
<summary>Star History</summary>

<div align="center">

[![Star History Chart](https://api.star-history.com/svg?repos=RunhuaHuang/EasySkills&type=Date)](https://star-history.com/#RunhuaHuang/EasySkills&Date)

</div>

</details>
