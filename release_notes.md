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
  - macOS/Linux: `~/.mavis/skills`
  - Windows: `%USERPROFILE%\.mavis\skills`

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
