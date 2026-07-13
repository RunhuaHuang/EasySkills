<div align="center">

# EasySkills

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Windows-brightgreen.svg)](#安装方式)
[![Agents](https://img.shields.io/badge/支持Agent-43+-orange.svg)](#支持的-agent-列表)
[![Version](https://img.shields.io/badge/版本-3.2.1-purple.svg)](https://github.com/RunhuaHuang/EasySkills/releases)

**一个中央库、两条同步通道，统一管理所有 Agent。**

只需将技能或指令规则放入 `~/EasySkills`，
它就会通过原生链接与非破坏性标记，自动同步至 Claude Code、Codex、Cursor、Gemini、Copilot、Windsurf、Trae 等 43+ Agent 的运行环境中。

本地优先 &bull; 空闲零 CPU &bull; 自带 WebUI

[**English**](README_EN.md)

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

---

## 开启、关闭、重启与更新

安装部署请使用上方「快速开始」命令。部署完成后会安装后台监听服务，并自动启动本地 WebUI：`http://127.0.0.1:6633`。终端出现提示：

> 程序正在启动挂载中，完成后浏览器 WebUI 会自动打开。

### 开启 / 打开 WebUI

安装完成后 WebUI 会自动打开；以下命令用于之后手动重新打开：

```bash
# macOS / Linux
bash ~/EasySkills/_maintenance/deploy.sh --webui

# Windows PowerShell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" -WebUI
```

### 关闭

如果只是不用控制台，直接关闭浏览器标签页即可；后台同步仍会继续运行。

如果要停止后台监听与 WebUI 服务：

```bash
# macOS / Linux：停止后台监听
bash ~/EasySkills/_maintenance/deploy.sh --unwatch

# macOS：如需同时停止 WebUI 后端
launchctl remove com.easyskills.webui 2>/dev/null || true
launchctl remove com.easyskills.webui.manual 2>/dev/null || true
pkill -f '[E]asySkills/_maintenance/webui.py' 2>/dev/null || true
pkill -f '[E]asySkills/_maintenance/webui-service.sh' 2>/dev/null || true
```

```powershell
# Windows：停止后台监听与 WebUI 计划任务
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" -Unwatch
```

### 重启

```bash
# macOS / Linux
bash ~/EasySkills/_maintenance/deploy.sh --unwatch
bash ~/EasySkills/_maintenance/deploy.sh --watch
bash ~/EasySkills/_maintenance/deploy.sh --webui
```

```powershell
# Windows PowerShell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" -Unwatch
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" -Watch
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" -WebUI
```

### 更新

推荐：在 WebUI 中使用 **检查更新 / 立即更新**。更新会保留自定义 Agent 路径、已断开的连接目标和 WebUI token，并保留上一份 `_maintenance.bak` 以便回滚。

也可以重新运行安装器原地升级：

```bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.sh | bash
```

```powershell
# Windows PowerShell
irm https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.ps1 | iex
```

---

## 工作原理

EasySkills 提供两条同步通道，帮助您统一交付智能体的各项能力：

```
~/EasySkills/                           ← 您的中央管理目录
├── _maintenance/                       ← 引擎（对 Agent 不可见）
│
├── instructions/                       ← [通道二] 模块化 Agent 规则（.md 文件）
│   ├── rule1.md
│   └── rule2.md
│           │
│           ▼ 托管块安全合并写入（非破坏性）
│   ┌──────────────────────────────────────────────┐
│   │ ~/.claude/CLAUDE.md      ──→ <!-- Managed -->│
│   │ ~/.cursor/AGENTS.md      ──→ <!-- Managed -->│
│   └──────────────────────────────────────────────┘
│
├── MyAwesomeSkill/                     ← [通道一] 共享技能文件夹
└── DeployHelper/
            │
            ▼ 软链接 (macOS/Linux) / 目录联结 (Windows)
    ┌──────────────────────────────────────────────┐
    │ ~/.claude/skills/MyAwesomeSkill  ──→  ✓      │
    │ ~/.cursor/skills/MyAwesomeSkill  ──→  ✓      │
    │ ... 43+ 个目标，全部同步，始终一致           │
    └──────────────────────────────────────────────┘
```

* **通道一 (技能同步)** — 使用原生软链接（macOS/Linux）或目录联结（Windows）将共享技能映射到各个 AI 工具的技能目录中。修改一处，所有 Agent 即时生效，不破坏专属技能。
* **通道二 (规则同步)** — 自动编译合并 `instructions/` 目录下的所有 Markdown 规则文件，并通过 `<!-- EasySkills:begin -->` / `<!-- EasySkills:end -->` 托管块插入各 Agent 的全局指令规则文件（如 `CLAUDE.md`, `AGENTS.md`）。更新时只替换块内内容，块外您自定义的修改完全保留。

---

## WebUI 控制台

通过本地控制台 `http://127.0.0.1:6633` 管理一切。

提供技能库导入/删除、模块化 Agent 规则编辑、Agent 连接与路径管理、自定义路径注册、手动同步、无效链接清理和版本更新检查。

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
| **2** | **Agent 规则同步** | 支持非破坏性托管块（`<!-- EasySkills:begin/end -->`）安全写入全局指令规则文件，保留用户手写内容 |
| **3** | **Agent 自动检测** | 自动识别 43+ 主流 Agent，只为真实存在的路径建立连接 |
| **4** | **双通道静默监听** | 后台监听顶层技能增删并自动重写已连接 Agent 的指令规则 |
| **5** | **非侵入式** | 共享技能与 Agent 专属技能并列存在——原有 skills 不受影响 |
| **6** | **Windows 免提权** | 使用 NTFS 目录联结，无需管理员权限或开发者模式 |
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
| `--add <路径>` | 为默认未支持的 Agent 注册 skills 文件夹路径（添加并持久化自定义 Agent 路径） |
| `--remove <路径>` | 移除已持久化的自定义路径 |
| `--watch` | 安装后台监听 |
| `--unwatch` | 卸载后台监听 |
| `--webui` | 启动本地 WebUI（端口 6633） |
| `--cleanup` | 清除所有 EasySkills 软链接 |
| `--help` | 显示帮助 |

> **提示：** 也可以在 WebUI 的「智能体」页可视化完成添加 / 移除自定义路径，无需记忆命令。

---

## 支持的 Agent 列表

开箱即用支持 43+ 个 Agent 目标路径，可随时通过命令行、WebUI 或对话添加自定义路径。

<details>
<summary><b>查看完整列表</b></summary>

| # | Agent | macOS 路径 | Windows 路径 |
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
| 28 | **Qoder** | `~/.qoder/skills` | `%USERPROFILE%\.qoder\skills` |
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
| 43 | **MiniMax Code** | `~/.mavis/skills` | `%USERPROFILE%\.mavis\skills` |

> Trae 和 Trae CN 同时映射到 `~/Library/Application Support/Trae[-CN]/skills`（macOS）和 `%APPDATA%\Trae[-CN]\skills`（Windows）。

</details>

---

## 注意事项

**Windows Defender** — 安装器可通过 UAC 弹窗自动添加白名单。也可以手动在 Windows 安全中心将 `%USERPROFILE%\EasySkills` 加入排除项。

**监听范围** — 后台监听只监控 `~/EasySkills` **顶层目录**的文件夹增删。不监听子目录内部——因为技能是通过软链映射的，内部文件修改会即时反映到所有 Agent，无需重新同步。如果存在 `~/.proma`，EasySkills 会每 5 分钟轮询 Proma workspace 的 `skills` 目录，自动发现新工作区。

---

## 参与贡献

添加新 Agent 支持：

1. 在 `_maintenance/agents.json` 中添加条目（single source of truth）
2. 在 `deploy.sh` 和 `deploy.ps1` 的硬编码回退数组中添加对应路径
3. 更新 `README.md`、`README_EN.md` 和 `README_SYSTEM.md` 中的 Agent 表格
4. 运行测试：`python3 -m unittest _maintenance/tests/test_security_contracts.py`
5. 提交 Pull Request

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
