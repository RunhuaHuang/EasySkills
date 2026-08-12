# EasySkills v5 Architecture and Migration Plan

Status: design baseline, no destructive migration is enabled in v4.1.x.

This document defines an evolutionary path from the current Bash, Python, and
PowerShell implementation to a single static Go core. The objective is to
remove duplicated business logic while preserving every existing skill,
instruction file, MCP configuration, Agent mapping, launcher, and rollback
path.

## 1. Decision summary

EasySkills v5 should use one cross-platform Go core for domain logic and keep
Bash and PowerShell only as thin bootstrap and operating-system integration
layers.

The migration must be:

- additive before subtractive;
- copy-and-verify before any path switch;
- dual-read during the compatibility window;
- journaled and reversible;
- safe for offline use;
- compatible with the v4 root layout until an explicit later deprecation.

The v4.1.x line remains the compatibility foundation. It must not silently move
or delete user-authored content.

## 2. Current-state constraints

The current product works, but several responsibilities are coupled:

- Python and PowerShell independently implement WebUI APIs, sync logic,
  configuration validation, update, rollback, and diagnostics.
- `~/EasySkills` mixes user-authored skills and rules with application code,
  machine state, secrets, logs, runtime binaries, and backups.
- installers and long-running services need knowledge of internal directory
  names such as `EasySkills维护工具/.engine`.
- root-directory scanning must maintain an exclusion list to distinguish skills
  from infrastructure folders.
- behavior parity is enforced mainly through source contracts because Windows
  and Unix backends do not share an executable core.

These are maintainability risks, not reasons for an immediate rewrite. v5
should replace one responsibility at a time behind compatible interfaces.

## 3. Target component model

```text
Thin installers and launchers
        |
        v
easyskills (static Go core)
  |- config and migration engine
  |- Agent catalog and path resolver
  |- skill link reconciler
  |- instruction managed-block engine
  |- MCP configuration and Gateway runtime
  |- doctor and support bundle generator
  |- update and rollback coordinator
  `- local HTTP API for the existing static WebUI
        |
        v
User content roots + OS-specific application state
```

### Ownership rule

The Go core owns all portable business rules. Shell and PowerShell may own only
operations that are genuinely OS-specific, such as registering launchd,
systemd, or Task Scheduler entries and opening a browser.

## 4. Proposed command surface

The v5 binary should expose stable, scriptable subcommands:

| Command | Responsibility |
|---|---|
| `easyskills sync` | Reconcile skill links and managed instruction blocks |
| `easyskills status [--json]` | Fast operational summary |
| `easyskills doctor [--json]` | Deep, credential-safe diagnostics |
| `easyskills watch install|start|stop|status` | Cross-platform watcher lifecycle |
| `easyskills agents list|set|remove` | Agent catalog and path overrides |
| `easyskills rules list|write|remove|validate` | Managed instruction blocks |
| `easyskills mcp init|validate|list|test|serve` | MCP configuration and Gateway |
| `easyskills webui serve` | Loopback-only HTTP API and static UI |
| `easyskills update check|apply` | Verified release update |
| `easyskills rollback` | Restore the prior engine release |
| `easyskills migrate plan|apply|status|rollback` | Explicit, journaled layout migration |

Human output may be localized. `--json` output must use a versioned schema and
stable field names so the WebUI, tests, and support tooling do not parse prose.

## 5. Target data layout

User-authored, portable content remains easy to find and back up:

```text
~/EasySkills/
  skills/
  instructions/
  config/
    mcp/servers.json
    agents.overrides.json
```

Machine-owned state moves to the platform state root:

| Platform | State root |
|---|---|
| macOS | `~/Library/Application Support/EasySkills/` |
| Linux | `${XDG_STATE_HOME:-~/.local/state}/easyskills/` |
| Windows | `%LOCALAPPDATA%\EasySkills\` |

The state root contains `runtime/`, `state/`, `logs/`, `cache/`, `backups/`,
the WebUI token, locks, migration journals, and installed binaries. It is never
scanned as a skill library.

The default skill root changes only through the explicit migration command.
Until migration is applied, v5 must treat legacy top-level skill directories as
the authoritative source.

## 6. Compatibility contract

During the v5 compatibility window:

1. Existing `deploy.sh`, `deploy.ps1`, launchers, and port 6633 continue to work.
2. Existing Agent links remain valid; migration does not rewrite them until a
   verified sync is ready to commit.
3. Existing `instructions/`, `mcp/servers.json`, custom target files, disabled
   target files, instruction state, Agent path overrides, token, and backup are
   recognized.
4. MCP schema version 1 remains accepted, including literal values and
   `${env:VARIABLE}` references.
5. The WebUI initially keeps its current static HTML and calls a versioned
   `/api/v1` surface supplied by the Go core. A temporary `/api/*` compatibility
   adapter preserves older UI builds.
6. No migration step deletes the legacy source tree. Cleanup becomes a separate
   command available only after a successful migration and a retention period.

## 7. Migration algorithm

`easyskills migrate apply` should implement a transactional sequence:

1. Acquire the global EasySkills mutation lock.
2. Run doctor preflight and stop on errors.
3. Produce a migration plan containing source, destination, item counts, file
   sizes, and SHA-256 hashes for managed configuration files.
4. Create a timestamped journal in the state root.
5. Copy user content into a staging directory on the destination filesystem.
6. Verify counts, required files, hashes, JSON schemas, and path containment.
7. Atomically rename staging directories into their final locations.
8. Write a versioned active-layout pointer.
9. Run a dry reconciliation, then commit Agent link changes.
10. Run doctor again and mark the journal complete.

On any failure, the active-layout pointer and Agent links remain on the legacy
layout. A failed destination is preserved for inspection or removed only when
it is known to be a newly created staging directory.

`easyskills migrate rollback` switches the active-layout pointer back, restores
the prior link manifest, and reruns reconciliation. It does not delete the v5
copy.

## 8. Delivery phases

### Phase 0 — v4.1.x foundation

- Stable installer channel and version pinning.
- Environment-backed MCP credentials.
- Cross-platform CI, syntax checks, and contract tests.
- Read-only doctor CLI/API and WebUI health matrix.
- Rollback fault-injection tests.

Exit criterion: current behavior is observable and regression-tested.

### Phase 1 — Go read-only shadow core

- Add `status`, `doctor`, Agent catalog loading, path resolution, and config
  validation to the Go binary.
- Run Go and legacy reports side by side in CI fixtures.
- Do not mutate links or instruction files.

Exit criterion: normalized JSON reports match for all supported fixtures.

### Phase 2 — Go reconciliation engine, opt-in

- Implement skill-link and managed-rule planning in Go.
- Add dry-run manifests and deterministic diffs.
- Enable mutation only through an explicit preview flag or environment switch.
- Keep legacy execution as an immediate fallback.

Exit criterion: parity fixtures and real temporary-home integration tests pass
on macOS, Linux, and Windows.

### Phase 3 — Go WebUI API

- Serve the existing static UI from the Go core.
- Introduce `/api/v1` and retain the compatibility adapter.
- Move update, rollback, and support diagnostics behind the shared core.

Exit criterion: browser QA and API contract suites pass against one backend on
all platforms.

### Phase 4 — Explicit layout migration

- Ship `migrate plan`, `apply`, `status`, and `rollback`.
- Default to plan-only in the first release.
- Require an explicit apply action; never migrate during an ordinary update.

Exit criterion: interrupted-copy, permission-denied, disk-full, failed-rename,
and rollback simulations preserve the legacy installation.

### Phase 5 — Bootstrap simplification

- Install the Go binary into the platform state/bin location.
- Reduce Bash and PowerShell to download verification, service registration,
  and delegation to the core.
- Retain legacy path readers for at least one major release.

Exit criterion: no business-rule implementation remains duplicated in shell,
Python, and PowerShell.

## 9. Testing and release gates

Every phase must include:

- unit tests for path normalization, schema validation, managed-block merging,
  credential reference resolution, and redaction;
- temporary-home integration tests on all three operating systems;
- fault injection for permission failures, partial copies, failed renames,
  occupied ports, corrupt tokens, and unavailable Gateway servers;
- golden JSON fixtures for `status --json` and `doctor --json`;
- browser tests for wide, medium, and mobile layouts;
- installer tests proving stable-channel defaults and non-destructive rollback;
- reproducible release binaries with checksums and signed provenance when the
  release process supports it.

No phase may become the default until rollback has been exercised in CI.

## 10. Security requirements

- Bind the WebUI to loopback only and preserve host, origin, and token checks.
- Never include WebUI tokens or MCP values in logs, doctor reports, telemetry,
  or support bundles.
- Prefer environment references for sensitive MCP fields and report only
  aggregate credential posture.
- Store machine secrets and state with owner-only permissions where supported.
- Validate every archive path, extracted size, redirect host, and final binary
  checksum before replacing an installed version.
- Treat all migration paths as untrusted input and reject traversal or paths
  outside the declared roots.

## 11. Generated artifacts and single sources of truth

The Agent catalog remains the source for platform paths and instruction files.
A future generator should derive:

- Go embedded Agent metadata;
- legacy fallback arrays during the compatibility window;
- README Agent tables;
- WebUI labels and capability metadata;
- contract fixtures.

Generation must be deterministic and CI must fail when generated artifacts are
out of date. User overrides remain separate and are never regenerated.

## 12. Explicit non-goals for v4.1.x

- no automatic move from root-level skills into `skills/`;
- no deletion of the legacy engine, runtime, token, or backup locations;
- no replacement of both WebUI backends in one release;
- no silent change to Agent target paths;
- no requirement for users to install Go, Python packages, Node.js, or a
  database.

The immediate goal is safer evolution, not a visually or structurally complete
rewrite marketed as v5 before the migration and rollback guarantees exist.
