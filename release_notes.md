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
