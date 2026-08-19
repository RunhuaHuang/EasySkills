## EasySkills 4.1.2

Release focused on the Windows PowerShell 5.1 install/self-update path and on
making WebUI skill-import failures actionable instead of opaque. All 187
security/contract tests pass; install.ps1 and webui.ps1 parse cleanly under
the real PowerShell parser.

### Windows installer & self-update (install.ps1 / webui.ps1)

- **Fixed install/self-update abort on Windows PowerShell 5.1**: the zip
  validator cast the signed Int32 `Entry.ExternalAttributes` (negative for
  every regular file/symlink mode such as `0x81818000`) to `[uint64]`, which
  throws on .NET Framework. Both copies now use a sign-extending `[int64]`
  arithmetic shift; the mode-nibble result is identical on every PowerShell
  version.
- Download errors are no longer misattributed to the network: download /
  validate / extract run as separate stages and the final error lists
  `stage | source | cause` for every mirror attempt (temp paths redacted).
- The installer is immune to profile-defined functions that override
  `Remove-Item` (common security wrappers reject pipeline input):
  filesystem-mutating cmdlets are module-qualified and stale expansion
  directories are removed by `-LiteralPath` instead of through a pipeline.
- README / WebUI / script header now recommend downloading the installer and
  running it in a clean `-NoProfile -File` process; `irm | iex` remains
  available as the advanced one-liner.

### WebUI skill import (webui.py / webui.ps1 / webui/index.html)

- `Invalid file path in upload` now names the offending file and the rule it
  broke (reserved Windows device name, forbidden character, trailing dot,
  absolute path, …) on both backends.
- Frontend pre-validates every path before base64-encoding and reports up to
  10 problems plus the total count, so a rejected folder is diagnosed before
  any upload.
- Shared portability limits (1000 files / 32 depth / 255 component /
  200 total path) plus a 7 MB pre-flight raw-bytes cap are enforced
  identically by Python, PowerShell, and the frontend.
- Python validates raw path segments before `pathlib` folds them away, so
  `a//b` and `a/./b` are rejected consistently with the PowerShell backend;
  duplicate detection is case- and NFC-insensitive on both backends.
- Non-ASCII skill/file names no longer arrive as mojibake on Windows: the
  frontend declares `charset=utf-8` and the PowerShell backend decodes JSON
  as UTF-8 per RFC 8259 when no charset is given. Windows PowerShell 5.1
  imports larger than the 2 MB `ConvertFrom-Json` limit now work via a
  JavaScriptSerializer fallback.
- HTTP errors (400/404/411/413) carry JSON bodies on both backends and the
  frontend parses responses defensively, so an oversized import shows a real
  size error instead of "Network offline / backend unreachable".
- Error toasts persist until dismissed and gain a copy-diagnostics button.

## EasySkills 4.1.1

A stability release: a full cross-platform code audit fixed launcher, uninstall,
encoding, and hot-reload regressions plus a batch of WebUI correctness issues.
All 182 Python security/contract tests and all Go unit and routing tests pass.

### Platform fixes (scripts)

- macOS launchers (`启动`/`关闭`) now resolve symlinks explicitly, so the
  user-facing entries in `EasySkills维护工具/macOS/` work when double-clicked
  (previously they failed to locate `deploy.sh`; the shutdown launcher could
  silently fail to stop both WebUI and watcher).
- Windows uninstallers stop the watcher **before** running cleanup, preventing
  the file watcher from rebuilding junctions in the gap and leaving dead links.
  The engine launcher uninstaller also gained the multi-directory ambiguity
  check.
- `deploy.ps1` reads `custom-targets.txt` / `disabled-targets.txt` /
  `agents.json` with explicit UTF-8 encoding, fixing silently dropped
  non-ASCII custom target paths on Windows PowerShell 5.1.
- `webui-service.ps1` sets `UseShellExecute=$false` before touching
  `EnvironmentVariables`, avoiding dropped env vars on newer .NET runtimes.
- Block-inner `::` comments in batch uninstallers converted to `REM` for
  reliable cmd parsing.

### WebUI backend (webui.py / webui.ps1)

- Named custom-target rows whose name matches no default agent no longer
  vanish from the agent list after editing.
- `map` now reports a real file/dir name collision as a conflict instead of
  silently skipping it (user data is never overwritten).
- Empty central library no longer reports every agent as "mapped", keeping
  dashboard stats honest.
- Self-update downloads the release tarball once instead of twice (the old
  double-download added bandwidth and lock-hold time without real integrity
  gains); safe extraction still rejects tampered archives.
- `fcntl` import is conditional so the module parses on Windows; atomic writes
  no longer follow symlinked backups; 500 responses no longer echo internal
  paths.

### WebUI frontend

- The MCP list and diagnostics panel skip no-op re-renders, fixing the
  two-click delete confirmation being interrupted by the 5-second poll and
  preserving diagnostics scroll position.
- Removed the full-document language re-apply after every button request
  (~thousands of DOM operations per action).
- Rules page now filters Proma workspace agents like every other page.
- Version check no longer compares against a hardcoded fallback; unknown
  versions show a "version unknown" badge instead.
- Removed dead code (`updateMCPTransportFields` reference,
  `toggleSearchInput`).

### MCP Gateway (Go)

- Hot reload keeps the previous working session and tool routes when an
  optional downstream fails, instead of aborting the whole reload (and now
  matches the startup-time tolerance); required servers still fail hard.
- Config-reload retries back off exponentially (2s → 30s cap) and abort
  immediately on shutdown, ending the 2-second retry loop that respawned
  downstream processes.
- Connection-error redaction no longer masks command/args, restoring useful
  troubleshooting output; secrets (env/headers) stay redacted.
- `DefaultPath()` fails loudly instead of falling back to a CWD-relative
  path; dead `boolPtr` helper removed.

### Misc

- Removed the stale, unsynced `mcp/servers.json.bak`.
- Default install version bumped to `v4.1.1`.

---

## 目录结构重构（推广准备）

为降低用户认知负担，对安装目录结构做了如下调整：

- `_maintenance` → `EasySkills维护工具/.engine`：程序本体目录改用点前缀 + 中文名。点前缀使其在 **macOS Finder 中默认隐藏**（注：Windows 资源管理器不隐藏点前缀目录，Windows 用户仍会看到 `EasySkills维护工具/.engine/`），避免 macOS 用户被大量脚本文件干扰；同时点前缀保留了原有"以 `_`/`.` 开头的目录不参与 skill 扫描"的启发式，防止维护工具被误当成技能同步给各 AI Agent。
- `_maintenance.bak` → `.maintenance-bak`、`_runtime` → `.runtime`：升级备份目录和 MCP 二进制目录同样改用点前缀（macOS 默认隐藏）。
- 启动/关闭/卸载脚本统一收纳进 `EasySkills维护工具/.engine/launchers/`（隐藏引擎目录）；同时在 `EasySkills维护工具/` 下生成可见的 `macOS/`、`Windows/` 入口文件夹（符号链接/复制到 `.engine/launchers/`），这是用户唯一需要直接操作的入口。
- Windows 批处理脚本（`install_windows.bat`、卸载脚本）开头新增 `chcp 65001`；全部 PowerShell 脚本转为 **UTF-8 with BOM** 编码，确保含中文的目录路径在非中文区域设置的 Windows（PowerShell 5.1）上也能正确解析。
- 安装器现在会**自动迁移并清理旧版 `_maintenance/`、`_runtime/` 目录**，升级过程不再残留旧目录，也不会丢失已配置的自定义路径与 WebUI token。

> 说明：`release_notes.md` 中更早版本里出现的 `_maintenance`、`_maintenance.bak` 等旧目录名属于历史变更记录，保留原文以便追溯。

---

## EasySkills 4.1.0

A directory-structure release: the `_maintenance/` engine folder is renamed to
`EasySkills维护工具/.engine/`, with a hardened install/upgrade pipeline,
explicit opt-in mainland-China mirror support, and a batch of Windows correctness fixes found
in a full code audit. All 180 Python security/contract tests and all Go unit
and routing tests pass.

### Directory restructure

- `_maintenance/` → `EasySkills维护工具/.engine/` (two-level layout). Visible
  user entry folders `EasySkills维护工具/macOS/` and `Windows/` link back into
  the hidden `.engine/launchers/` directory.
- Backup/runtime dirs renamed: `_maintenance.bak` → `.maintenance-bak`,
  `_runtime` → `.runtime`.

### Install / upgrade hardening (bug fixes)

- **[security]** `.gitignore` rules now match the real `.engine` location, so
  the per-machine WebUI auth token (`.easyskills-token`) is correctly ignored
  and can no longer be accidentally committed.
- **[windows]** All three `.bat` scripts (install / uninstall / launcher
  uninstall) used a `".EasySkills*"` wildcard (leading dot) that never matched
  the real `EasySkills维护工具` directory — installation and uninstallation
  silently no-op'd. Fixed the wildcard and the two-level `.engine` resolution.
- **[windows]** `install_windows.bat` swap step used `ren <tmp>
  EasySkills维护工具/.engine` — cmd's `ren` rejects a path in the new-name
  argument. Restructured the swap to use a same-parent rename + cross-dir
  `move`.
- **[windows]** `install.ps1` used `Rename-Item` for the `.engine →
  .maintenance-bak` rotation, but `Rename-Item` cannot relocate across
  directories — the backup landed in the wrong place and rollback was
  unreachable. Switched to `Move-Item` to match the bash `mv` semantics.
- **[windows]** The WebUI self-update and rollback paths had the same
  cross-directory `Rename-Item -NewName` mistake in a later code path. They now
  use explicit `Move-Item -Destination` operations for the root backup and
  same-parent leaf renames for `.engine`, with regression contracts covering
  both directions.
- **[security]** PowerShell ZIP validation now treats a single Windows
  backslash as an absolute-path/link boundary and validates the complete
  symbolic-link graph before extraction. The Unix WebUI supervisor also uses
  literal process-command matching instead of a path regex, preventing an
  installation path from matching an unrelated Python process.
- **[gateway]** Connection failures redact configured endpoint query strings,
  environment values, and HTTP header values before they reach logs, status
  JSON, or WebUI test output.
- **[windows]** **Critical:** `deploy.ps1`, `webui.ps1`, `watcher-service.ps1`,
  `install-gateway.ps1`, and `watch.ps1` all computed the central/root
  directory as `ScriptDir`'s parent (one level up = `EasySkills维护工具/`),
  but the skill folders live two levels up. This made Windows skill-sync find
  nothing, the FileSystemWatcher monitor the wrong directory, and the Gateway
  binary land in a mismatched `.runtime`. Fixed all five scripts to go up two
  parents, matching `deploy.sh`'s `$SCRIPT_DIR/../..`.
- **[macos]** `install_mac.command` referenced the deprecated `A-程序控制/`
  launcher folder (real name is `launchers/`) and was missing the visible
  `macOS/` + `Windows/` entry-folder creation that `install.sh` has. Fixed both.

### Explicit mainland-China mirror support

- The installers (`install.sh` / `install.ps1`) and Gateway downloaders use
  GitHub by default. A third-party mirror is used only when the user explicitly
  selects an HTTPS prefix via `EASYSKILLS_MIRROR`; installers never silently
  change the source trust boundary after a GitHub failure.

### Docs

- README (zh + en) documents the mirror-prefixed install commands for users
  behind the GFW.
- The README Agent tables are checked against `agents.json`, including Windows
  path separators, so documentation cannot silently drift from runtime paths.

---

## EasySkills 4.0.3

A polish release hardening the MCP Gateway, the Windows WebUI backend, and
the contract test suite. All changes are backward-compatible. All 120 Python
security/contract tests and all Go unit and end-to-end routing tests pass.

### MCP Gateway: Config Hot-Reload

- The `serve` command now polls the config file for changes every 2 seconds
  using a SHA-256 content hash and calls the new `Router.Reload` API on
  change, updating downstream connections and tool registrations without
  restarting the process.

### MCP Gateway: Core Improvements

- **`Router.Reload` API.** Adds, removes, and reconfigures downstream servers
  in-place while the gateway is running. Servers whose config has not changed
  are reused unchanged; removed servers are cleanly shut down.
- **Tool-name deduplication.** `resolveToolName` resolves the clean original
  name first and falls back to a namespaced `server__tool` form only on
  collision, then appends a counter for further collisions. Previously all
  names were namespaced unconditionally.
- **Rollback on discover error.** Partially registered tools are removed from
  the routing table when `ListTools` pagination fails mid-stream, preventing
  phantom tool routes.
- **Input/output schema validation.** `validateToolDefinition` rejects tools
  whose `inputSchema` or `outputSchema` is not a JSON object, preventing
  routing of tools that downstream clients cannot safely introspect.
- **`downstream.cfg` field.** Each active session now stores its originating
  `ServerConfig` so `Reload` can detect unchanged servers and skip
  reconnection.
- **Process resource cleanup (Windows).** `Test-MCPGateway` in `webui.ps1`
  now wraps the helper process in a `finally` block that calls `Dispose()`,
  preventing handle leaks.

### Windows WebUI (`webui.ps1`)

- **MCP version integer check.** `Test-MCPConfig` previously accepted
  floating-point `version` values (e.g. `1.0`) as valid. The check now
  requires a strict `[int]` or `[long]`, matching the JSON schema intent.
- **Historical-target cleanup.** `Remove-InstructionsFromOne` falls back to
  the instruction state file for custom Agent paths that were removed from the
  current configuration after EasySkills wrote instructions to them, ensuring
  bulk cleanup reaches all previously managed targets.

### Validation

- 2 new Python contract tests cover the PowerShell MCP version integer check
  and the historical-target cleanup path in `Remove-InstructionsFromOne`.
- 2 new Go unit tests cover `resolveToolName` collision semantics and
  `validateToolDefinition` schema rejection.
- 1 new Go integration test (`TestGatewayReload`) exercises the full
  `Router.Reload` lifecycle: config-unchanged fast-path, tool-timeout change,
  server addition, and server removal.

## EasySkills 4.0.0

EasySkills now has a third capability channel: a cross-platform MCP Gateway.
Each Agent connects to EasySkills once, while all downstream MCP servers,
credentials, profiles, and tool filters are managed centrally in one JSON file
and the local WebUI.

### MCP Gateway

- Added a static Go Gateway binary for macOS, Linux, and Windows on amd64 and
  arm64. End users do not need Go installed when a release asset is available.
- Exposes downstream MCP tools directly using their clean, original tool names.
- Supports stdio, MCP Streamable HTTP, and legacy SSE downstream transports.
- Supports optional/required servers, connection and call timeouts, profiles,
  and per-server/profile glob allow/deny filters.
- Keeps the initial scope intentionally tool-only; Resources, Prompts,
  Sampling, and Elicitation are not proxied in v1.

### Central JSON and WebUI

- Added `~/EasySkills/mcp/servers.json` as the single source of truth, with
  schema validation, atomic saves, owner-only Unix permissions, and one backup.
- API keys, tokens, headers, and environment values are intentionally stored
  as plaintext JSON strings and can be edited directly in the WebUI.
- Added modular MCP rows with structured add/edit forms, per-module enable,
  disable, test, and delete controls, Gateway status, and one-click Agent
  configuration copy actions for Claude/Cursor/Kiro, VS Code, and Codex.
- Installers initialize the config only when absent, preserve it on upgrade,
  and treat Gateway installation failure as non-fatal for Skills and Rules.

### Validation

- 118 Python security/contract tests pass.
- Go unit and end-to-end routing tests, `go vet`, Python compilation, shell
  syntax, frontend JavaScript parsing, and macOS/Linux/Windows cross-builds pass.

## EasySkills 3.2.1

A patch release completing the post-3.2.0 audit with additional data-safety,
concurrency, update, and failure-path hardening across macOS, Linux, and
Windows. All changes are backward-compatible. All 115 contract tests pass.

### Link and User-Data Safety

- Agent links that point to a central skill which is itself an external
  symlink/junction are now consistently recognized as EasySkills-owned by
  status, unmap, cleanup, and delete operations.
- Mapping preserves same-name foreign links instead of silently replacing
  user-managed symlinks or junctions.
- Windows central external-link skills are deleted non-recursively, preventing
  PowerShell 5.1 from traversing into and deleting the real external target.
- Every bundled uninstaller now uses Trash/Recycle Bin and refuses to remove
  the installation when link cleanup fails.

### Concurrency and Failure Reporting

- Explicit `add`, `remove`, and `cleanup` operations wait for an in-flight
  deploy lock and fail safely on timeout; only duplicate background syncs may
  be skipped as success.
- Cleanup failures now propagate through shell/PowerShell exit codes so
  uninstallers cannot mistake an incomplete cleanup for success.
- `deploy.sh --add` / `--remove` reject missing path arguments instead of
  entering a non-advancing argument loop.
- Disabled-target updates and WebUI token creation are atomic; token creation
  also uses a cross-process lock and enforces owner-only permissions.

### WebUI and Update Robustness

- Successful self-update/rollback now restarts the backend after delivering
  the API response, ensuring the newly installed Python/PowerShell code is
  actually loaded. Failed replacement launches keep the old backend alive and
  remain retryable.
- Release downloads validate both initial and final redirect hosts, enforce
  timeouts and compressed/extracted size limits, reject unsafe archive paths,
  and guard against archive bombs.
- Complete network failure in both the GitHub API and redirect fallback now
  returns a structured failure instead of HTTP 500.
- Oversized HTTP requests return 413 immediately and close the connection,
  preventing unread body bytes from contaminating a subsequent request.
- Linux watcher status now checks the persistent systemd path/timer units
  instead of the normally-inactive oneshot service.
- Empty optional rule libraries no longer produce contradictory failure and
  success messages during an otherwise successful skill sync.

### Validation

- 115 contract tests pass.
- Ruff static analysis, Python compilation, shell syntax checks, frontend
  JavaScript syntax validation, HTTP restart/oversize smoke tests, isolated
  sync-cleanup tests, and permission/lock failure injection tests all pass.

## EasySkills 3.2.0

A hardening release focused on robustness, data safety, and correctness across
the deploy engine, installers, background supervisors, and the WebUI — the
result of a full multi-round audit. No behaviour or API changes; all fixes are
drop-in. All 98 contract tests pass.

### Process Termination Safety (macOS / Linux)

Three sites matched a backend process purely by a `webui.py` path appearing on
its command line, then force-killed the match. That also matched **editors,
greps, and language servers** that had the file open — and `kill -9` would
destroy unsaved work.

- `own_webui_pid` / `stop_own_webui` (`deploy.sh`) and `own_webui_pid`
  (`webui-service.sh`) now require the matched process to be a **Python
  interpreter** (`ps -o comm=` basename check) before killing. The uninstaller
  (`uninstall_mac.command`) gained the same guard for both `bash`/`sh` and
  `python` backends.

### Concurrency (Windows)

- **Recover from an abandoned deploy mutex.** `deploy.ps1` `Acquire-Lock` now
  catches `AbandonedMutexException`. Previously, a single force-killed deploy
  (Task Manager, hard reboot mid-sync) left the named mutex abandoned, and every
  subsequent `deploy.ps1` invocation threw the unhandled exception, re-abandoned
  the mutex, and bricked all future deploys until a reboot. macOS/Linux already
  self-healed via PID-lock recovery; Windows now matches that behaviour.

### Data Safety

- **Atomic config writes (Windows).** `Write-Utf8NoBom` in `deploy.ps1` now
  writes to a temp file and atomically moves it over the target, mirroring
  `deploy.sh`'s temp+`mv` pattern. A direct `WriteAllText` truncated-then-wrote
  `custom-targets.txt` / `disabled-targets.txt`, so an interruption could leave
  them truncated and silently drop every persisted custom agent path.
- **Verbatim custom-targets preservation (`install.sh`).** The installer no
  longer round-trips `custom-targets.txt` through a shell variable
  (`$(cat …)` + `echo "$VAR"`), which mangled paths containing backslashes,
  glob characters, or a leading `-`. It now copies the file verbatim (matching
  `disabled-targets.txt` and `webui.py`'s `do_self_update`).

### Status & Labelling Correctness

- **`deploy.sh --status` no longer false-reports a running watcher.**
  `launchctl list` prints `-` in the PID column for a job that is loaded but not
  running; that was reported as `✅ Running (PID -)`. Now treated as not-running,
  consistent with `get_watcher_status` in `webui.py`.
- **Trae/Trae-CN AppData paths labelled correctly in fallback mode (Windows).**
  In `deploy.ps1`'s prefix-based `Get-AgentName` fallback, `%APPDATA%\Trae\skills`
  was shadowed by the broader `$Home\` prefix and mislabelled "Custom Agent". The
  more specific `$env:APPDATA\` prefix is now tested first, with explicit
  `Trae\*` / `Trae-CN\*` branches.

### Uninstaller Safety (macOS)

- **Warn when symlink cleanup fails.** `uninstall_mac.command` now captures the
  exit code of `deploy.sh --cleanup`. On failure it prints a clear warning with
  a manual-cleanup command before trashing `~/EasySkills`, so a partial cleanup
  no longer leaves dangling symlinks scattered across every agent's skills
  directory with no indication.

### Installer Reporting (Windows)

- **Fix empty version reporting.** `install_windows.bat` read `OLD_VERSION` /
  `NEW_VERSION` with `%VAR%` inside the parenthesised install block, where CMD
  expands once at parse time — so every install printed an empty version and
  upgrades were undetectable. The version report is now emitted **after** the
  block, where the variables hold their real values.

### WebUI Supervisor (Windows)

- **Don't restart-storm when the port is held by a foreign process.**
  `webui-service.ps1` now mirrors `webui-service.sh`: when port 6633 responds but
  no `webui.ps1` from this install owns it, it waits instead of relaunching —
  preventing the supervisor from burning through its restart throttle with no
  chance of recovery.

### WebUI Frontend

- **Surface backend failures on read polls.** `apiCall` previously swallowed
  network/parse errors for GET routes (`/api/status`, `/api/skills`, …) with no
  toast, so a dead backend left the dashboard looking alive. GET failures now
  show a localised error toast, rate-limited to once per 15 s (with re-announce
  after recovery) so the 5 s poller can't spam.
- **Localise the agent-path-edit error.** `saveCustomModalEdit`'s catch no
  longer shows the raw browser error string; it shows a consistent localised
  message.
- **Harden the central XSS boundary.** `escapeHtml` now coerces `null` /
  `undefined` / non-strings to `''` (via `String(text)`), so a future optional
  backend field rendered without a `|| ''` guard can't throw and break the
  entire render loop.

### Validation

- All 98 contract tests pass (version/agent-count assertions derive from
  `_maintenance/.version` and `agents.json`, so they stay green on release).

## EasySkills 3.1.0

### Data Safety (Windows)

Two critical issues in `deploy.ps1` that could cause **permanent loss of the
central skill library** on Windows PowerShell 5.1 have been fixed.

- **Never delete link-target contents.** All four junction-removal sites
  previously used `Remove-Item -Recurse -Force`, which on a directory junction
  can traverse into and delete the **real contents** of the link target. Now
  every reparse point is removed with `[System.IO.Directory]::Delete(path,
  $false)` — the link itself only, never its target.
- **Detect and replace dangling junctions.** `Test-Path` follows reparse
  points, so a dangling junction (target removed) reported `False` and was
  skipped — then `New-Item` failed because the dead link still occupied the
  name, silently leaving that skill unmapped for that agent. Now uses
  `Get-Item -Force` (attributes), which sees the entry regardless of whether
  its target exists. This closes a cross-platform parity gap: `deploy.sh`
  already handled this correctly with `[ -e ] || [ -L ]`.

### Update & Rollback Atomicity (macOS + Windows)

The self-update and rollback rename rotations could, in a narrow failure
window, **destroy the currently-running version** or brick every subsequent
rollback. Both backends are now hardened.

- **Self-update rollback no longer destroys the current version.** When the
  second rename (`new → current`) failed after the first (`current → .bak`)
  succeeded, the old recovery code did `rmtree(_maintenance.bak)` — which at
  that point held the running version. The recovery now undoes the first
  rename (moves `.bak` back to current) and restores the pre-existing backup
  snapshot.
- **Rollback pre-cleans `.prev` and recovers from failure.** A stale
  `_maintenance.prev` left by a prior failed rollback made every subsequent
  rollback fail forever (POSIX `rename` refuses to overwrite an existing
  directory). Now `.prev` is pre-cleaned, and if the second rename fails the
  current version is restored from `.prev`.
- **Self-update validates the download host (Windows).** `webui.ps1`
  `Run-SelfUpdate` now rejects download URLs whose host is not a trusted
  GitHub delivery host, matching the `webui.py`
  `_is_github_download_url` guard that already existed on macOS/Linux.

### Robustness

- **`Run-DeployCommand` no longer deadlocks on large output (Windows).**
  Reading both stdout and stderr synchronously via `ReadToEnd()` deadlocks
  when the child fills the OS pipe buffer (~64 KiB) on one stream while we
  block on the other. Now uses `ReadToEndAsync()` so the 30 s timeout is
  effective and both buffers drain concurrently.
- **Token loader recovers from a corrupt token file (macOS/Linux).** A prior
  interrupted write could leave the token file existing-but-empty; the
  `O_CREAT | O_EXCL` path could never replace it, raising `RuntimeError` in a
  loop across restarts and bricking startup. A persistently-invalid file is
  now reclaimed (unlinked and recreated).

### Agent Support

- Add **MiniMax Code** as the 43rd supported agent target:
  - macOS/Linux: `~/.mavis/agents/mavis/skills`
  - Windows: `%USERPROFILE%\.mavis\agents\mavis\skills`

### Validation

- Agent-path and version assertions now derive from `agents.json` /
  `_maintenance/.version` (single sources of truth) so they never go stale on
  release — the root-cause fix for the stale-version-assertion bug seen in
  2.1.0.
- 8 new contract tests guard each fix above (reparse-point non-recursive
  delete, attribute-based dangling detection, download-host allowlist,
  self-update rollback undo, rollback `.prev` pre-clean + recovery, async
  stream reads, corrupt-token reclaim).
- All 66 tests pass.

## EasySkills 2.1.0

### Link-Health Diagnostics (new)

A broken (dangling) symlink in the central skill library — its target removed
by the user — used to be invisible to EasySkills and, worse, could be forwarded
into every agent's skills directory. Some agents (e.g. older Run builds) abort
their entire skill scan the moment they `stat` a dead link, silently dropping
every skill sorted after it. This release makes that whole failure mode visible
and self-healing.

- **Auto-prune dangling links on sync.** `deploy.sh` / `deploy.ps1` now scan the
  central directory before mapping and automatically remove any symlink whose
  target no longer exists, with a clear log line per pruned link and a summary
  count. Dangling links are dead data (their target is gone), so pruning is
  loss-free and stops the broken link from ever reaching an agent.
- **Flag external-link skills as fragile.** A skill that is itself a valid
  external symlink is still forwarded (backward compatible) but is now flagged
  with a warning and surfaced in the sync summary, nudging you to convert it to
  a real directory so a single target deletion can't cascade across agents.
- **`--status` link-health snapshot.** The status command now reports a read-only
  `Link health: N dangling (run sync to prune), M external` line, so problems
  can be previewed without running a sync.

### WebUI

- Skills that are external symlinks now show a `⚠ External Link` warning badge
  (amber accent) on the Skills tab, with the card border and icon recoloured.
- The dashboard shows a link-health advisory banner whenever the central library
  has dangling or external-link skills, with a one-line summary and a pointer to
  the Skills tab.

### API

- `GET /api/status` now includes `dangling_count` and `external_link_count`
  (both macOS/Linux and Windows backends).
- `GET /api/skills` now includes an `is_external_link` boolean per skill
  (both backends). The frontend degrades gracefully if an older backend omits it.

### Validation

- Add 5 new regression tests covering link-health semantics: external-link
  detection and dangling exclusion in `get_skills()`, dangling/external counting
  in `get_central_dir_warnings()`, missing-central-dir handling, cross-backend
  field-name contracts, and that the sync logic prunes dangling symlinks.

## EasySkills 2.0.1

### Security

- Protect all local WebUI `GET /api/*` endpoints with the same token gate used by write APIs, including macOS/Linux and Windows backends.
- Keep frontend reads compatible with the stricter API by sending `X-EasySkills-Token` for dashboard, skills, agents, and update-check requests.
- Preserve token-refresh retry behavior when the browser has a stale WebUI token.

### Fixes

- Fix `unwatch.sh` so non-standard installation paths are handled correctly when waiting for or terminating an in-flight `deploy.sh`.
- Ignore runtime `_maintenance.bak/` self-update backup directories in git.
- Avoid a full agent-link rebuild when deleting a single skill from the WebUI; only that skill's symlinks are removed.
- Add an explicit `EASYSKILLS_CENTRAL_DIR` override for predictable multi-install WebUI directory selection.

### Agent Support

- Add QoderWork CN target support:
  - macOS/Linux: `~/.qoderworkcn/skills`
  - Windows: `%USERPROFILE%\.qoderworkcn\skills`
- Add Qoder CN target support:
  - macOS/Linux: `~/.qoder-cn/skills`
  - Windows: `%USERPROFILE%\.qoder-cn\skills`
- Update the GitHub README and system reference to show all 42 built-in targets.

### Validation

- Expand the security contract suite to cover authenticated GET APIs, frontend token headers, dynamic `unwatch.sh` path handling, backup ignore rules, and the new agent paths.
