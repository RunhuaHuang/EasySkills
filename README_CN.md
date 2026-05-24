<div align="center">

# EasySkills

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Windows-brightgreen.svg)](#-安装方式)
[![Agents](https://img.shields.io/badge/支持Agent-25+-orange.svg)](#-支持的-agent-列表)
[![Version](https://img.shields.io/badge/版本-1.1.3-purple.svg)](https://github.com/RunhuaHuang/EasySkills/releases)

**一个技能目录，统治所有 Agent。**

[**English**](README.md)

</div>

---

## 痛点

你电脑上装了 Claude Code。还有 Cursor。可能还有 Gemini CLI、Copilot、Windsurf、Trae、Codex……

你找到了一个好用的自定义技能——或者你自己写了一个。然后呢？

你把它复制到 `~/.claude/skills/`。再复制到 `~/.cursor/skills/`。再到 `~/.gemini/config/skills/`。然后你想起来还有 Copilot。还有 Codex。还有上周刚装的那个新 Agent。

**一周后**，你改进了这个技能。现在你得回忆每个复制过的文件夹，逐一更新。漏了一个。那个 Agent 跑的还是旧版本。你明明修过的 bug，又咬了你一口。

**一个月后**，6 个 Agent，同一个技能散落了 4 个不同版本。有些 Agent 有某些技能，有些没有。你已经记不清谁有什么了。

这就是多 Agent 时代的现实：**每个 AI 编程助手各自为政，技能目录互相隔离**，而你就是那个被迫手动同步一切的人。

---

## 解决方案

**EasySkills** 彻底消灭了这个问题。

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
│ ... 25 个 Agent，全部同步，始终一致         │
└─────────────────────────────────────────────┘
```

**一个目录，一份文件，所有 Agent。** 修改一个技能文件，所有 Agent 立刻看到——因为从头到尾只有一份真实文件，通过软链接（macOS）或 NTFS 目录联结（Windows）挂载到各个 Agent 目录。

后台监听服务检测到你添加或删除了技能文件夹，自动重新同步。空闲时 CPU 占用为零。

---

## 为什么选 EasySkills？

| 场景 | 没有 EasySkills | 有了 EasySkills |
|:---|:---|:---|
| 添加新技能 | 手动复制到 N 个 Agent 文件夹 | 放进一个文件夹，结束 |
| 更新技能 | 逐一找到每份副本，手动更新 | 改一份，所有 Agent 同步看到 |
| 装了新 Agent | 手动把所有技能搬过去 | 下次同步自动完成 |
| 删除技能 | 从 N 个文件夹逐一删除 | 从一个文件夹删除 |
| 版本漂移 | 不可避免 | 不可能——始终只有一份 |

---

## 核心特性

### Windows 免提权映射
Windows 创建软链接需要管理员权限或开发者模式。EasySkills 使用 **NTFS 目录联结（Junction）**——原生 NTFS 特性，普通用户权限即可创建，兼容性 100%。不会弹 UAC，不会导致 Agent 终端崩溃。

### 静默后台守护
| | macOS | Windows |
|---|---|---|
| **机制** | `launchd` + `WatchPaths`（内核 FSEvents） | 启动快捷方式 `.lnk` → `FileSystemWatcher` |
| **空闲 CPU** | 0% | 0% |
| **开机自启** | LaunchAgent plist | 启动文件夹快捷方式 |
| **控制台窗口** | 无（守护进程） | 隐藏（`WindowStyle=0`） |

### 智能 Agent 检测
引擎在创建目录前会检查 Agent 是否实际安装。它会检查 Agent 的根配置目录（例如 `~/.claude/`）——如果不存在，直接跳过。不会在你的主目录下生成无用的空文件夹。

### 本地优先保护
如果 Agent 的技能目录中已有同名的**真实文件夹**（非软链接），引擎会跳过并发出警告。你的本地技能永远不会被覆盖或删除。

### 并发安全
macOS 使用 PID 文件锁，Windows 使用系统命名互斥锁（`Global\EasySkillsDeploy`），防止后台监听与手动同步同时触发时产生竞态。

### 双击安装与卸载
原生 `.command`（macOS）和 `.bat`（Windows）脚本，不需要打开终端、不需要包管理器、不需要环境配置。卸载器会停止守护进程、清除所有软链接、删除目录——100% 绿色无残留。

---

## 安装方式

### 方案 A：一行命令安装（推荐）

**macOS / Linux：**
```bash
curl -fsSL https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.sh | bash
```

**Windows（PowerShell）：**
```powershell
irm https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.ps1 | iex
```

一行命令搞定。自动下载 EasySkills、安装引擎到 `~/EasySkills`、映射所有已安装 Agent、启动后台监听。

### 方案 B：双击安装

克隆或下载本仓库，然后：

| | 安装 | 卸载 |
|---|---|---|
| **macOS** | 双击 `install_mac.command` | 双击 `uninstall_mac.command` |
| **Windows** | 双击 `install_windows.bat` | 双击 `uninstall_windows.bat` |

安装器将引擎复制到 `~/EasySkills`，扫描已安装的 Agent，映射所有技能，启动后台监听。之后可以删除下载的仓库。

### 方案 C：让 AI Agent 自动安装

如果你的 Agent 支持技能加载，直接说：

> *"帮我运行 EasySkills 初始化"*

Agent 会读取 [SKILL.md](SKILL.md)，检测操作系统，执行安装脚本，并主动询问你是否有自定义 Agent 路径需要添加。全程自主。

---

## 使用方法

### 添加技能

将任意技能文件夹放入 `~/EasySkills`。后台监听服务会在几秒内检测到并映射到所有已安装的 Agent。

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

开箱即用支持 25 个 Agent，可随时通过命令行或对话添加自定义路径。

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
├── _maintenance/              # 核心引擎（不会被映射为技能）
│   ├── deploy.sh / deploy.ps1 # 映射与命令行工具
│   ├── watch.sh / watch.ps1   # 监听安装器
│   ├── unwatch.sh / unwatch.ps1 # 监听卸载器
│   ├── watcher-service.ps1    # Windows FileSystemWatcher 服务
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

<div align="center">

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=RunhuaHuang/EasySkills&type=Date)](https://star-history.com/#RunhuaHuang/EasySkills&Date)

</div>
