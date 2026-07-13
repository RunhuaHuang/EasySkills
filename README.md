<div align="center">

# EasySkills

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Windows-brightgreen.svg)](#快速开始)
[![Agents](https://img.shields.io/badge/支持Agent-43+-orange.svg)](#支持的-agent-列表)
[![Version](https://img.shields.io/badge/版本-4.0.3-purple.svg)](https://github.com/RunhuaHuang/EasySkills/releases)

**一个中央库、三条能力通道，统一管理所有 AI Coding Agent 的技能与规则。**

只需将技能或规则文件放入 `~/EasySkills` 目录，或者通过 WebUI 统一管理下游 MCP 服务，它就会自动将各项能力同步至 Claude Code、Cursor、Windsurf、Trae、Copilot、Gemini 等 43+ 个 Agent 的运行环境中。

本地优先 &bull; 空闲零 CPU &bull; 自带 WebUI

[**English Version**](README_EN.md)

</div>

---

## 快速开始

### 1. 一键安装部署

请复制并运行适用于您系统的安装命令。为了防止命令过长导致复制按钮隐藏，已将命令拆分为两行：

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

> 💡 **其他安装方式**：您也可以克隆本仓库到本地，然后双击运行 `install_mac.command` (macOS) 或 `install_windows.bat` (Windows)。

安装器会自动执行以下操作：
1. 在您用户目录下创建 `~/EasySkills` 文件夹作为中央管理目录。
2. 自动检测已安装的 Agent，建立共享技能映射。
3. 安装单文件 MCP Gateway。
4. 启动后台监听服务（实现实时同步）。
5. 自动拉起本地管理控制台 WebUI（`http://127.0.0.1:6633`）。

---

## 开启、关闭、重启与更新

安装部署完成后，服务会在后台持续运行，并自动打开浏览器展示 WebUI 界面：`http://127.0.0.1:6633`。

### 开启 / 打开 WebUI
若之后需要手动重新打开 WebUI：
* **macOS / Linux**：
  ```bash
  bash ~/EasySkills/_maintenance/deploy.sh --webui
  ```
* **Windows (PowerShell)**：
  ```powershell
  powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" -WebUI
  ```

### 关闭服务
如果仅关闭浏览器标签页，后台监听同步服务仍会继续工作。如需彻底停止后台监听与 WebUI 后端：
* **macOS / Linux**：
  ```bash
  bash ~/EasySkills/_maintenance/deploy.sh --unwatch
  launchctl remove com.easyskills.webui 2>/dev/null || true
  launchctl remove com.easyskills.webui.manual 2>/dev/null || true
  pkill -f '[E]asySkills/_maintenance/webui.py' 2>/dev/null || true
  pkill -f '[E]asySkills/_maintenance/webui-service.sh' 2>/dev/null || true
  ```
* **Windows (PowerShell)**：
  ```powershell
  powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" -Unwatch
  ```

### 重启服务
* **macOS / Linux**：
  ```bash
  bash ~/EasySkills/_maintenance/deploy.sh --unwatch
  bash ~/EasySkills/_maintenance/deploy.sh --watch
  bash ~/EasySkills/_maintenance/deploy.sh --webui
  ```
* **Windows (PowerShell)**：
  ```powershell
  powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" -Unwatch
  powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" -Watch
  powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" -WebUI
  ```

### 更新升级
* **推荐方式**：直接在 WebUI 的 **检查更新 / 立即更新** 按钮一键升级。更新过程会自动保留您的自定义路径、配置及 WebUI token，并在 `_maintenance.bak` 中备份上一版本。
* **命令行方式**：重新运行快速开始中的一键安装命令，即可在原地无损覆盖升级：
  
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

## 核心功能与使用指南

EasySkills 将 AI Agent 的核心能力统一抽象为三条能力通道，以下为它们的使用指南：

```
~/EasySkills/                           ← 您的中央管理目录
│
├── [通道一] 技能同步 (Skills)
│   ├── MyAwesomeSkill/                 ← 您的自定义技能文件夹
│   └── DeployHelper/
│               │
│               ▼ 原生软链接/目录联结映射
│       ┌──────────────────────────────────────────────┐
│       │ ~/.claude/skills/MyAwesomeSkill  ──→  ✓      │
│       │ ~/.cursor/skills/MyAwesomeSkill  ──→  ✓      │
│       └──────────────────────────────────────────────┘
│
├── [通道二] MCP 中枢网关
│   ├── mcp/servers.json                ← 下游 MCP 的统一配置文件
│   └── _runtime/easyskills-mcp         ← 单文件 MCP Gateway 代理
│               │
│               ▼ 智能体只需连接一次 Gateway，即可自动路由所有下游工具
│       (prismstudio / visionpower / ...)
│
└── [通道三] Agents.md Agent规则同步 (Agent Rules)
    ├── instructions/                   ← 放置您的模块化规则文件 (.md)
    │   ├── git-rules.md
    │   └── python-style.md
    │           │
    │           ▼ 托管块安全合并写入（非破坏性）
    │   ┌──────────────────────────────────────────────┐
    │   │ ~/.claude/CLAUDE.md      ──→ <!-- Managed -->│
    │   │ ~/.cursor/AGENTS.md      ──→ <!-- Managed -->│
    │   └──────────────────────────────────────────────┘
```

---

### 一、 技能同步 (Skills Sync)

将您的自定义技能（如提示词模板、工具配置、工作流）一次性分发给所有 Agent。

#### 1. 如何使用
* **通过文件管理器**：直接在 `~/EasySkills/` 根目录下创建或放入您的技能文件夹（例如：`MyAwesomeSkill/`）。
* **通过 WebUI 界面**：在 WebUI 的 **Skills** 页面点击“导入技能文件夹”上传即可。

#### 2. 工作原理
EasySkills 监听服务会捕捉到 `~/EasySkills/` 根目录下的文件夹变动，自动在所有已安装的 Agent（如 Claude Code, Cursor）对应的技能目录中创建原生**软链接 (macOS/Linux)** 或 **目录联结 (Windows)**。
* **即时生效**：因为是软链接，您只需修改 `~/EasySkills/MyAwesomeSkill/` 下的任何文件，所有 Agent 都会实时读取到最新内容。
* **安全共存**：EasySkills 只会映射您放入的共享文件夹，不会影响 Agent 原本自有的专属技能。

---

### 二、 MCP 中枢网关 (MCP Gateway)

解决不同 AI 工具需要重复配置下游 MCP 服务的痛点。您的 Agent 只需要连接一次 EasySkills MCP Gateway，即可由 Gateway 统一分发和路由所有下游 MCP 服务。

#### 1. 如何使用
1. **添加下游 MCP 服务**：在 WebUI 的 **MCP** 页面，点击 “添加 MCP”，通过表单可视化填写您的下游 MCP 服务配置（例如数据库连接、GitHub 工具等）。支持标准 stdio、HTTP、SSE 传输协议。
2. **连接 AI 智能体**：在 WebUI 的 “只连接一次 Agent” 区域，选择您正在使用的 Agent（例如 Claude Code、Cursor、VS Code 或 Codex），复制生成的连接命令或 JSON 配置。如果你不知道如何在你的agent完成配置，也可以复制下来命令之后，把命令提供给你的 Agent，让他帮助你完成 MCP 配置，然后重启 Agent 即可启用。
3. **完成配置**：将配置粘贴进 Agent 对应的配置文件中（例如 `claude_desktop_config.json` 或 Cursor 的 MCP 列表）。
4. **统一控制**：后续当您想新增 MCP、停用某项工具或修改 API Key 时，**无需**再去每个 Agent 里修改，直接在 EasySkills 的 WebUI 里开关或修改即可，所有 Agent 自动同步最新工具。

#### 2. 特性
* **白名单/黑名单**：在 WebUI 中可针对单个 MCP 配置工具白名单或黑名单，按需分发。
* **测试与测试连通**：在 WebUI 中可对任何下游 MCP 服务进行一键连通性测试。

---

### 三、 Agents.md Agent规则同步 (Agent Rules Sync)

将您个人的开发风格规范（如 Git 提交格式规范、代码缩进风格、注释要求）统一写入各个 Agent 的全局说明规则中。

#### 1. 如何使用
* 直接在 `~/EasySkills/instructions/` 目录下放置您的 Markdown 规则文件（例如：`git-rules.md`、`python-style.md`）。

#### 2. 工作原理
EasySkills 会自动扫描 `instructions/` 目录下的所有 Markdown 文件，将它们的内容整合成一段完整的提示词，并**非破坏性**地写入各个 Agent 的全局规则文件中（如 Claude Code 对应的 `~/.claude/CLAUDE.md`，Cursor 对应的 `~/.cursor/AGENTS.md` ）。
* **非破坏性托管块**：EasySkills 写入的内容会被包裹在 `<!-- EasySkills:begin -->` 和 `<!-- EasySkills:end -->` 注释标记中。每次同步只会覆盖更新这一块区域的内容，您在此区域外手动编写的其他特定规则绝对**不会被覆盖或破坏**。

---

## WebUI 控制台

本地控制台服务默认运行在 `http://127.0.0.1:6633`，是管理 EasySkills 的核心图形界面。

* **技能管理**：导入、删除共享技能，查看当前有哪些 Agent 已挂载了该技能。
* **规则管理**：在线编辑规则 Markdown 文件，管理多份定制规则。
* **MCP 网关管理**：可视化表单增删改查下游 MCP 模块，测试工具可用性，复制 Agent 连接配置。
* **智能体管理**：查看 43+ 个内置 Agent 的安装与连接状态；对于非标准路径安装的 Agent，可在本页手动添加其专属技能文件夹路径。

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
| **1** | **技能库导入/删除** | 通过 WebUI 导入技能文件夹；删除时弹窗确认，保证操作安全 |
| **2** | **Agents.md Agent规则同步** | 支持非破坏性托管块（`<!-- EasySkills:begin/end -->`）安全写入全局指令规则文件，保留用户手写内容 |
| **3** | **Agent 自动检测** | 自动识别 43+ 主流 Agent，只为真实存在的路径建立连接，保持轻量 |
| **4** | **MCP 中枢管理** | Agent 只连接一次；在 WebUI 中以独立模块管理所有下游 MCP、凭证与工具过滤 |
| **5** | **非侵入式** | 共享技能与 Agent 专属技能并列存在，原有 skills 文件夹不受任何影响 |
| **6** | **Windows 免提权** | 使用 NTFS 目录联结建立映射，无需管理员权限，无需开启开发者模式 |
| **7** | **本地优先与安全** | 跳过已有真实目录，使用文件锁，仅监听 `127.0.0.1` 确保本地安全 |
| **8** | **并发安全保护** | macOS PID 锁 / Windows 命名互斥锁，防止同步重入导致文件冲突 |
| **9** | **静态单文件 Gateway** | 采用 Go 静态编译二进制网关，覆盖 amd64/arm64 平台，用户无需自行安装 Go 环境 |

---

## 命令行工具

除了 WebUI 界面，您也可以通过本地脚本执行维护操作：

**macOS / Linux**
```bash
bash ~/EasySkills/_maintenance/deploy.sh [选项]
```

**Windows (PowerShell)**
```powershell
powershell -File "$env:USERPROFILE\EasySkills\_maintenance\deploy.ps1" [选项]
```

| 选项 | 说明 |
|---|---|
| *（无参数）* / `--sync` | 手动触发一次全局技能与规则的同步 |
| `--list` | 列出当前所有活跃的技能映射路径 |
| `--add <路径>` | 注册一个非标准路径安装的 Agent（添加并持久化自定义路径） |
| `--remove <路径>` | 移除已持久化的自定义 Agent 路径 |
| `--watch` | 安装并启动后台文件监听服务 |
| `--unwatch` | 卸载并停止后台文件监听服务 |
| `--webui` | 启动本地 WebUI 后端服务（默认端口 6633） |
| `--cleanup` | 清除当前所有 EasySkills 创建的软链接/目录联结（不伤及源文件） |
| `--help` | 显示命令行帮助信息 |

---

## 支持的 Agent 列表

EasySkills 开箱即用支持以下 43+ 个 Agent 目标路径。您可通过 WebUI 的「智能体」页或命令行 `--add` 参数随时注册您的自定义路径。

<details>
<summary><b>点击展开查看完整支持列表</b></summary>

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
| 43 | **MiniMax Code** | `~/.mavis/skills` | `%USERPROFILE%\.mavis\skills` |

> *注：*对于 Trae 和 Trae CN，另外会映射到其 AppData 路径：`~/Library/Application Support/Trae[-CN]/skills` (macOS) 和 `%APPDATA%\Trae[-CN]\skills` (Windows)。

</details>

---

## 注意事项

* **Windows Defender 提示**：在 Windows 系统上，EasySkills 安装器会自动尝试通过 UAC 弹窗为 `~/EasySkills` 目录添加 Defender 白名单排除项，请在弹窗时选择“是”。您也可以手动前往 Windows 安全中心进行排除配置。
* **监听限制说明**：后台文件监听器（Watcher）默认只监控 `~/EasySkills/` **顶层目录**的文件夹新增与删除。不需要也不推荐监听技能子目录内部的变化，因为技能是通过软链接同步映射的，内部任何文件修改均会立即可见。对于 `~/.proma` 的工作空间，EasySkills 会以每 5 分钟轮询一次的机制自动检测并挂载新工作区。

---

## 参与贡献

如果您想为 EasySkills 增加对新 Agent 的支持，请按照以下步骤：

1. 在 `_maintenance/agents.json` 配置文件中添加对应 Agent 条目（项目核心数据源）。
2. 在 `deploy.sh` 与 `deploy.ps1` 脚本的备用映射数组中添加对应的静默初始化路径。
3. 更新 `README.md`、`README_EN.md` 和 `README_SYSTEM.md` 文档中的支持列表。
4. 运行本地自动化测试进行校验：
   ```bash
   python3 -m unittest _maintenance/tests/test_security_contracts.py
   ```
5. 提交 Pull Request！

---

## 许可证

基于 [MIT 许可证](LICENSE) 分发。
&copy; 2026 Runhua Huang

---

<details>
<summary>Star History</summary>

<div align="center">

[![Star History Chart](https://api.star-history.com/svg?repos=RunhuaHuang/EasySkills&type=Date)](https://star-history.com/#RunhuaHuang/EasySkills&Date)

</div>

</details>
