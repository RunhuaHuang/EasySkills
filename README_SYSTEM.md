# EasySkills — System & Operations Reference

> **Version:** 2.1.0 · **Homepage:** https://github.com/RunhuaHuang/EasySkills

EasySkills is a cross-platform automated skills manager for macOS, Linux, and
Windows. It creates one centralized skills directory (`~/EasySkills`), registers
a background file watcher, and maps your custom skill folders — via native
symlinks (macOS/Linux) or directory junctions (Windows) — into every installed
agent's skills directory.

This document is operational reference material for the installed system. It is
**not** an agent skill and is not mapped into any agent's skills directory;
EasySkills installs as a standalone tool (CLI + local WebUI), not as a skill.

> 🌐 **WebUI Dashboard:** EasySkills ships with a visual manager running locally
> on port **6633** — [http://127.0.0.1:6633](http://127.0.0.1:6633). Import/delete
> skills, connect/disconnect agents, register custom paths, sync, prune broken
> links, and check for updates, all from one page.

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

**Double-click install:** clone or download the repo, then double-click
`install_mac.command` (macOS) or `install_windows.bat` (Windows).

The installer creates `~/EasySkills`, detects supported agents, maps shared
skills, starts the background watcher, and launches the WebUI. User config
(`custom-targets.txt`, `disabled-targets.txt`) and the WebUI token are preserved
across upgrades.

### Windows Defender note

If Windows Defender flags `~/EasySkills`, add an exclusion (a standard UAC prompt
appears — click "Yes"):

```powershell
Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -Command `"Add-MpPreference -ExclusionPath '$env:USERPROFILE\EasySkills'; Write-Host 'Windows Defender exclusion added successfully.'; Start-Sleep -Seconds 2`""
```

You can also add the exclusion manually later via Windows Security settings.

---

## Operating the installed system

`watch.sh` / `watch.ps1` internally run the initial sync and then register the
background watcher — running the watch script alone handles everything. Run the
commands below from the `~/EasySkills` root directory.

### macOS / Linux

```bash
bash ./_maintenance/watch.sh                       # install watcher + initial sync
bash ./_maintenance/watch.sh "/path/to/agent/skills"  # also map a custom path
bash ./_maintenance/deploy.sh --status             # health check
bash ./_maintenance/deploy.sh --webui              # open the WebUI manager
```

### Windows

```powershell
powershell -ExecutionPolicy Bypass -File .\_maintenance\watch.ps1
powershell -ExecutionPolicy Bypass -File .\_maintenance\watch.ps1 -CustomPath "C:\path\to\agent\skills"
powershell -ExecutionPolicy Bypass -File .\_maintenance\deploy.ps1 -Status
powershell -ExecutionPolicy Bypass -File .\_maintenance\deploy.ps1 -WebUI
```

### Adding custom agent paths

If an agent lives in a non-standard location, register its skills folder via the
WebUI **Agents** tab, or with `deploy.sh --add` / `deploy.ps1 -Add`. Custom paths
persist in `_maintenance/custom-targets.txt`. The agent target list itself is
defined in `_maintenance/agents.json` (the single source of truth).

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
