# Adding a New Agent to EasySkills

When adding support for a new AI coding agent, update **all** of these locations so the agent is detected on every platform and in every entry point. `agents.json` is the single source of truth that the scripts read at runtime; the hardcoded fallback lists exist only for when `agents.json` is missing/unreadable, so they must be kept in sync too.

## 1. `EasySkills维护工具/.engine/agents.json` (single source of truth)

- Append an object to the `agents` array with `name`, `mac_path`, and `win_path`.
- Use `mac_extra_path` / `win_extra_path` if the agent has a second skills location (e.g. Trae's App Support / AppData path).

## 2. `EasySkills维护工具/.engine/deploy.sh` (macOS / Linux)

- Add the skills path to the `TARGETS` array in the fallback section (search `# Fallback: hardcoded defaults`).
- Add a pattern match in the `get_agent_name()` `case` statement (search `.codewhale/*)` for the last entry).

## 3. `EasySkills维护工具/.engine/deploy.ps1` (Windows)

- Add the skills path to the `$script:Targets` array in the fallback section (search `# Fallback: hardcoded defaults`).
- Add a pattern match in `Get-AgentName`'s `switch -Wildcard` (search `.codewhale\*`).

## 4. `EasySkills维护工具/.engine/webui.py` (macOS / Linux WebUI)

- Add the agent to the hardcoded fallback list in `_load_default_agents()` (search `# Fallback: hardcoded defaults`).
- Add an entry to the module-level `_AGENT_PREFIX_MAP` list (used by `get_agent_name()`).

## 5. `EasySkills维护工具/.engine/webui.ps1` (Windows WebUI)

- Add the agent to the hardcoded fallback list in `Load-DefaultAgents` (search `# Fallback: hardcoded defaults`).
- Add a `if ($PathStr -like "*\.<agent>\*")` line in `Get-AgentNameFromPath`.

## 6. Documentation

- `README.md` and `README_EN.md`: add a numbered row to the supported-agents table.
- `README_SYSTEM.md`: add a `### N. Name` block with macOS and Windows paths under "Supported Agent Target Paths".

## Path conventions

| Platform | Standard pattern | Example |
|----------|-----------------|---------|
| macOS | `$HOME/.<agent>/skills` | `$HOME/.claude/skills` |
| macOS (App Support) | `$HOME/Library/Application Support/<App>/skills` | Trae |
| Windows | `$Home\.<agent>\skills` | `$Home\.claude\skills` |
| Windows (AppData) | `$env:APPDATA\<App>\skills` | Trae |

## How sync decides whether to create the skills folder

Each agent has a "root" directory derived from its skills path (e.g. `~/.codex` for `~/.codex/skills`, via `get_agent_root`). Sync **skips** an agent only if its root directory does not exist (meaning the user never installed that agent). When the root exists, the sync step automatically creates the `skills` subfolder (`mkdir -p` / `New-Item -ItemType Directory`). So most agents need no special "create directory" logic — just registering them above is enough.
