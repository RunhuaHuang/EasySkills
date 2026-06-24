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
