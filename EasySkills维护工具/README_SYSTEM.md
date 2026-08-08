# EasySkills — System & Operations Reference

> **Version:** 4.0.0 · **Homepage:** https://github.com/RunhuaHuang/EasySkills

EasySkills is a cross-platform skills, rules, and MCP manager for macOS, Linux, and Windows. It establishes a centralized folder (`~/EasySkills`) and delivers capabilities through three channels:
- **Channel 01 / Skills (Symlinks)**: Dynamically maps top-level folders inside `~/EasySkills` into every installed agent's skills directory using native symlinks (macOS/Linux) or directory junctions (Windows).
- **Channel 02 / Agent Rules (Managed Blocks)**: Compiles all Markdown files from `~/EasySkills/instructions/` and injects them as a single concatenated prompt rule block (enclosed in `<!-- EasySkills:begin/end -->` comments) into agent global instruction files (e.g. `CLAUDE.md`, `AGENTS.md`).
- **Channel 03 / MCP Gateway (stdio)**: Each Agent connects to one EasySkills MCP process. The Go Gateway reads `~/EasySkills/mcp/servers.json`, connects to all selected downstream MCP servers, and publishes their tools under collision-free `server__tool` names.

This document is operational reference material for the installed system. It is **not** an agent skill and is not mapped into any agent's skills directory.

> 🌐 **WebUI Dashboard:** EasySkills ships with a visual manager running locally on port **6633** — [http://127.0.0.1:6633](http://127.0.0.1:6633). Import/delete skills, manage modular Agent rules and MCP modules, test each downstream MCP, check connected agent status, synchronize manually, prune invalid links, and trigger updates.

---

## Installation

**One-line install (recommended):**

```bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.sh | bash
```
```powershell
# Windows (PowerShell)
irm https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.ps1 | iex
```

**Double-click install:** clone or download the repo, then double-click `install_mac.command` (macOS) or `install_windows.bat` (Windows).

The installer creates `~/EasySkills`, detects supported agents, maps shared skills, compiles rules, initializes `mcp/servers.json`, installs the platform Gateway binary, starts the background watcher, and launches the WebUI. User config (including MCP JSON and plaintext credentials) is preserved across upgrades. Gateway download/build failure is non-fatal for the other two channels.

### Windows Defender note

If Windows Defender flags `~/EasySkills`, add an exclusion (a standard UAC prompt appears — click "Yes"):

```powershell
Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -Command `"Add-MpPreference -ExclusionPath '$env:USERPROFILE\EasySkills'; Write-Host 'Windows Defender exclusion added successfully.'; Start-Sleep -Seconds 2`""
```

You can also add the exclusion manually later via Windows Security settings.

---

## Operating the installed system

### 1. Opening the WebUI & Starting Services
EasySkills installs a background file watcher daemon (`launchd` on macOS, `systemd` on Linux, Task Scheduler on Windows) and a WebUI daemon on port 6633.

#### Double-click Launchers (Simplest)
Navigate to `~/EasySkills/EasySkills维护工具` and double-click the launcher inside the platform folder:
- **macOS**: `macOS/启动.command`
- **Windows**: `Windows/启动.bat`

#### Terminal Commands
Run these from the `~/EasySkills` root directory:
**macOS / Linux:**
```bash
bash ./EasySkills维护工具/.engine/deploy.sh --webui              # Launch WebUI
bash ./EasySkills维护工具/.engine/deploy.sh --watch              # Enable watcher
```
**Windows (PowerShell):**
```powershell
powershell -ExecutionPolicy Bypass -File .\EasySkills维护工具/.engine\deploy.ps1 -WebUI
powershell -ExecutionPolicy Bypass -File .\EasySkills维护工具/.engine\deploy.ps1 -Watch
```

### 2. Stopping & Restarting
If you only close the browser tab, the background watcher keeps running. To restart or fully stop the service:

**macOS / Linux:**
```bash
# Stop watcher
bash ./EasySkills维护工具/.engine/deploy.sh --unwatch
# Stop WebUI service
launchctl remove com.easyskills.webui 2>/dev/null || true
pkill -f '[E]asySkills/EasySkills维护工具/.engine/webui.py' 2>/dev/null || true
```
**Windows (PowerShell):**
```powershell
# Stop watcher & WebUI task
powershell -ExecutionPolicy Bypass -File .\EasySkills维护工具/.engine\deploy.ps1 -Unwatch
```

### 3. Adding custom agent paths
If an agent lives in a non-standard location, configure its folders via the WebUI **Agent Config** tab, or with `deploy.sh --add <path>` / `deploy.ps1 -Add <path>`. Custom paths persist in `EasySkills维护工具/.engine/custom-targets.txt`. The default agent list itself is defined in `EasySkills维护工具/.engine/agents.json` (the single source of truth).

### 4. MCP Gateway operations

Installed files:

- Config: `~/EasySkills/mcp/servers.json`
- Automatic backup: `~/EasySkills/mcp/servers.json.bak`
- macOS/Linux binary: `~/EasySkills/.runtime/easyskills-mcp`
- Windows binary: `%USERPROFILE%\EasySkills\.runtime\easyskills-mcp.exe`

The Agent-facing transport is stdio. Downstream servers may use `stdio`, `http` (MCP Streamable HTTP), `streamable-http`, or legacy `sse`. The initial Gateway intentionally proxies MCP tools only; Resources, Prompts, Sampling, and Elicitation are outside the v1 routing surface.

The Gateway does not run as a permanent background daemon. Each Agent starts
the configured stdio command on demand and owns that process for the lifetime
of its session. Closing an unrelated terminal window has no effect; a terminal
matters only when the Gateway was started manually inside it.

```bash
~/EasySkills/.runtime/easyskills-mcp validate
~/EasySkills/.runtime/easyskills-mcp list
~/EasySkills/.runtime/easyskills-mcp test --profile default
~/EasySkills/.runtime/easyskills-mcp connect --profile default
```

Core JSON fields:

| Scope | Field | Meaning |
|---|---|---|
| root | `version` | Schema version; currently `1` |
| root | `servers` | Object keyed by a stable server name |
| root | `profiles` | Named server/tool selections; `default` is used unless overridden |
| server | `enabled`, `required` | Enable a server; optionally fail Gateway startup when it cannot connect |
| server | `transport` | `stdio`, `http` / `streamable-http`, or `sse` |
| stdio server | `command`, `args`, `cwd`, `env` | Child process launch configuration |
| HTTP/SSE server | `url`, `headers` | Remote endpoint and request headers |
| server | `startup_timeout_seconds`, `tool_timeout_seconds` | Bounded connection/discovery and tool-call timeouts |
| server/profile | `enabled_tools`, `disabled_tools` | Glob allow/deny lists; profile patterns use `server.tool` |
| profile | `servers` | Server names or `"*"` |

Secrets are deliberately not encrypted: `env`, `headers`, API keys, and tokens round-trip as plain JSON strings so the WebUI remains simple and portable. On Unix, EasySkills enforces `0700` on the MCP directory and `0600` on the config/backup; saves are atomic. Never commit or share `servers.json`.

Agent configuration snippets are generated in the WebUI. Conceptually, all supported Agents launch the same command with `connect --config <servers.json> --profile default`; no Agent configuration changes are required when downstream servers change.

---

## Pre-configured Default Paths

The installer maps shared skills into these popular local coding agents whenever
their directory exists. Agents not installed on the machine are skipped.

### 1. Antigravity CLI (formerly Gemini CLI)
- **macOS**: `~/.gemini/config/skills`
- **Windows**: `%USERPROFILE%\.gemini\config\skills`

### 2. Antigravity IDE
- **macOS**: `~/.gemini/antigravity/skills`
- **Windows**: `%USERPROFILE%\.gemini\antigravity\skills`

### 3. Codex (OpenAI)
- **macOS**: `~/.codex/skills`
- **Windows**: `%USERPROFILE%\.codex\skills`

### 4. Claude Code (Anthropic CLI)
- **macOS**: `~/.claude/skills`
- **Windows**: `%USERPROFILE%\.claude\skills`

### 5. GitHub Copilot
- **macOS**: `~/.copilot/skills`
- **Windows**: `%USERPROFILE%\.copilot\skills`

### 6. Pi (Personal Assistant Client)
- **macOS**: `~/.pi/agent/skills`
- **Windows**: `%USERPROFILE%\.pi\agent\skills`

### 7. OpenCode
- **macOS**: `~/.config/opencode/skills`
- **Windows**: `%USERPROFILE%\.config\opencode\skills`

### 8. Trae (ByteDance Global)
- **macOS**: `~/.trae/skills` & `~/Library/Application Support/Trae/skills`
- **Windows**: `%USERPROFILE%\.trae\skills` & `%APPDATA%\Trae\skills`

### 9. Trae CN (ByteDance China)
- **macOS**: `~/.trae-cn/skills` & `~/Library/Application Support/Trae-CN/skills`
- **Windows**: `%USERPROFILE%\.trae-cn\skills` & `%APPDATA%\Trae-CN\skills`

### 10. Kimi Code (Moonshot)
- **macOS**: `~/.kimi/skills`
- **Windows**: `%USERPROFILE%\.kimi\skills`

### 11. ZCode
- **macOS**: `~/.zcode/skills`
- **Windows**: `%USERPROFILE%\.zcode\skills`

### 12. OpenClaw
- **macOS**: `~/.openclaw/skills`
- **Windows**: `%USERPROFILE%\.openclaw\skills`

### 13. Hermes Agent
- **macOS**: `~/.hermes/skills`
- **Windows**: `%USERPROFILE%\.hermes\skills`

### 14. Proma
- **macOS**: `~/.proma/default-skills`
- **Windows**: `%USERPROFILE%\.proma\default-skills`

### 15. Cursor
- **macOS**: `~/.cursor/skills`
- **Windows**: `%USERPROFILE%\.cursor\skills`

### 16. Kiro Agent (AWS)
- **macOS**: `~/.kiro/skills`
- **Windows**: `%USERPROFILE%\.kiro\skills`

### 17. Junie (JetBrains)
- **macOS**: `~/.junie/skills`
- **Windows**: `%USERPROFILE%\.junie\skills`

### 18. Cline
- **macOS**: `~/.cline/skills`
- **Windows**: `%USERPROFILE%\.cline\skills`

### 19. Roo Code
- **macOS**: `~/.roo/skills`
- **Windows**: `%USERPROFILE%\.roo\skills`

### 20. Warp
- **macOS**: `~/.warp/skills`
- **Windows**: `%USERPROFILE%\.warp\skills`

### 21. Windsurf
- **macOS**: `~/.codeium/windsurf/skills`
- **Windows**: `%USERPROFILE%\.codeium\windsurf\skills`

### 22. Firebender
- **macOS**: `~/.firebender/skills`
- **Windows**: `%USERPROFILE%\.firebender\skills`

### 23. Augment
- **macOS**: `~/.augment/skills`
- **Windows**: `%USERPROFILE%\.augment\skills`

### 24. Continue
- **macOS**: `~/.continue/skills`
- **Windows**: `%USERPROFILE%\.continue\skills`

### 25. Goose (Block/AAIF)
- **macOS**: `~/.config/goose/skills`
- **Windows**: `%USERPROFILE%\.config\goose\skills`

### 26. Agents (Cross-tool Standard)
- **macOS**: `~/.agents/skills`
- **Windows**: `%USERPROFILE%\.agents\skills`

### 27. Run
- **macOS**: `~/.run/global-skills/skills`
- **Windows**: `%USERPROFILE%\.run\global-skills\skills`

### 28. Qoder
- **macOS**: `~/.qoder/skills`
- **Windows**: `%USERPROFILE%\.qoder\skills`

### 29. Qwen Code
- **macOS**: `~/.qwen/skills`
- **Windows**: `%USERPROFILE%\.qwen\skills`

### 30. CodeBuddy
- **macOS**: `~/.codebuddy/skills`
- **Windows**: `%USERPROFILE%\.codebuddy\skills`

### 31. Amp
- **macOS**: `~/.config/agents/skills`
- **Windows**: `%USERPROFILE%\.config\agents\skills`

### 32. OpenHands
- **macOS**: `~/.openhands/skills`
- **Windows**: `%USERPROFILE%\.openhands\skills`

### 33. Kilo Code
- **macOS**: `~/.kilocode/skills`
- **Windows**: `%USERPROFILE%\.kilocode\skills`

### 34. Zencoder
- **macOS**: `~/.zencoder/skills`
- **Windows**: `%USERPROFILE%\.zencoder\skills`

### 35. iFlow CLI
- **macOS**: `~/.iflow/skills`
- **Windows**: `%USERPROFILE%\.iflow\skills`

### 36. Droid
- **macOS**: `~/.factory/skills`
- **Windows**: `%USERPROFILE%\.factory\skills`

### 37. Devin for Terminal
- **macOS**: `~/.config/devin/skills`
- **Windows**: `%USERPROFILE%\.config\devin\skills`

### 38. WorkBuddy
- **macOS**: `~/.workbuddy/skills`
- **Windows**: `%USERPROFILE%\.workbuddy\skills`

### 39. QClaw
- **macOS**: `~/.qclaw/skills`
- **Windows**: `%USERPROFILE%\.qclaw\skills`

### 40. CodeWhale
- **macOS**: `~/.codewhale/skills`
- **Windows**: `%USERPROFILE%\.codewhale\skills`

### 41. QoderWork CN
- **macOS**: `~/.qoderworkcn/skills`
- **Windows**: `%USERPROFILE%\.qoderworkcn\skills`

### 42. Qoder CN
- **macOS**: `~/.qoder-cn/skills`
- **Windows**: `%USERPROFILE%\.qoder-cn\skills`

### 43. MiniMax Code
- **macOS**: `~/.mavis/agents/mavis/skills`
- **Windows**: `%USERPROFILE%\.mavis\agents\mavis\skills`
