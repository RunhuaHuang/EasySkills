# Adding a New Agent to EasySkills

When adding support for a new AI coding agent, update these locations:

## 1. `_maintenance/deploy.sh` (macOS)

- Add the skills path to the `TARGETS` array (~line 27)
- Add a pattern match in `get_agent_name()` (~line 101)

## 2. `_maintenance/deploy.ps1` (Windows)

- Add the skills path to the `$Targets` array (~line 37)
- Add a pattern match in `Get-AgentName` (~line 115)

## 3. `SKILL.md`

- Add the agent entry under "Supported Agent Target Paths" with macOS and Windows paths

## Path conventions

| Platform | Standard pattern | Example |
|----------|-----------------|---------|
| macOS | `$HOME/.<agent>/skills` | `$HOME/.claude/skills` |
| macOS (App Support) | `$HOME/Library/Application Support/<App>/skills` | Trae |
| Windows | `$Home\.<agent>\skills` | `$Home\.claude\skills` |
| Windows (AppData) | `$env:APPDATA\<App>\skills` | Trae |
