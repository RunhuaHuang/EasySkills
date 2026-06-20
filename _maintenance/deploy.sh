#!/usr/bin/env bash

# ==============================================================================
# Script: deploy.sh (macOS / Linux)
# Description: Active skills mapping and persistence CLI tool.
#              Reads agent targets from agents.json with hardcoded fallback.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CENTRAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CUSTOM_TARGETS_FILE="$SCRIPT_DIR/custom-targets.txt"
LOCK_FILE="$SCRIPT_DIR/.deploy.lock"

# When invoked under launchd/systemd the PATH is minimal and /usr/bin/python3
# may be a stale system Python that can't run webui.py (uses `X | None` syntax,
# needs 3.10+). Prepend common modern-interpreter locations so Homebrew's et al.
# python3 wins. Affects start_webui's fallback path and the supervisor it spawns.
# Preserve priority order even if some paths already exist later in PATH.
_PATH_PREFIX=""
for _p in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.pyenv/shims"; do
  [ -d "$_p" ] || continue
  _PATH_PREFIX="${_PATH_PREFIX}${_PATH_PREFIX:+:}$_p"
done
PATH="${_PATH_PREFIX}${_PATH_PREFIX:+:}${PATH:-}"
unset _PATH_PREFIX
export PATH

# --- One-time migration: move custom-targets.txt from legacy root location ---
LEGACY_ROOT_TARGETS="$CENTRAL_DIR/custom-targets.txt"
if [ -f "$LEGACY_ROOT_TARGETS" ]; then
  if grep -q -v -E '^\s*(#|$)' "$LEGACY_ROOT_TARGETS" 2>/dev/null; then
    touch "$CUSTOM_TARGETS_FILE"
    grep -v -E '^\s*(#|$)' "$LEGACY_ROOT_TARGETS" | while IFS= read -r line; do
      if ! grep -Fxq "$line" "$CUSTOM_TARGETS_FILE" 2>/dev/null; then
        echo "$line" >> "$CUSTOM_TARGETS_FILE"
      fi
    done
  fi
  rm -f "$LEGACY_ROOT_TARGETS"
fi

# --- One-time cleanup: remove stale files from root (older-install leftovers) ---
# Only run in installed location (~/EasySkills), skip if inside a git repo
if [ ! -d "$CENTRAL_DIR/.git" ]; then
  for _stale in README.md README_EN.md README_CN.md LICENSE install.sh install.ps1 \
                install_mac.command install_windows.bat \
                uninstall_mac.command uninstall_windows.bat; do
    rm -f "$CENTRAL_DIR/$_stale" 2>/dev/null
  done
fi

# ---- Load agent targets from agents.json (single source of truth) ----
AGENTS_JSON="$SCRIPT_DIR/agents.json"
declare -a AGENT_NAMES=()

load_agents() {
  if [ -f "$AGENTS_JSON" ] && command -v python3 &>/dev/null; then
    local json_output
    json_output=$(python3 -c "
import json, os, sys
def expand(p):
    p = p.strip()
    if p.startswith('~'): return os.path.expanduser('~') + p[1:]
    return p
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    targets = []
    names = []
    for a in data.get('agents', []):
        mac = expand(a.get('mac_path', ''))
        if mac:
            targets.append(mac)
            names.append(a.get('name', ''))
        extra = expand(a.get('mac_extra_path', ''))
        if extra:
            targets.append(extra)
            names.append(a.get('name', ''))
    if targets:
        print('TARGETS:' + '\t'.join(targets))
        print('NAMES:' + '\t'.join(names))
except Exception:
    pass
" "$AGENTS_JSON" 2>/dev/null)
    if [ -n "$json_output" ]; then
      local targets_line names_line
      targets_line=$(echo "$json_output" | grep '^TARGETS:' | head -1)
      names_line=$(echo "$json_output" | grep '^NAMES:' | head -1)
      if [ -n "$targets_line" ]; then
        IFS=$'\t' read -ra TARGETS <<< "${targets_line#TARGETS:}"
        IFS=$'\t' read -ra AGENT_NAMES <<< "${names_line#NAMES:}"
        return
      fi
    fi
  fi
  # Fallback: hardcoded defaults (kept in sync with agents.json)
  TARGETS=(
    "$HOME/.gemini/config/skills"
    "$HOME/.gemini/antigravity/skills"
    "$HOME/.codex/skills"
    "$HOME/.claude/skills"
    "$HOME/.copilot/skills"
    "$HOME/.pi/agent/skills"
    "$HOME/.config/opencode/skills"
    "$HOME/.kimi/skills"
    "$HOME/.zcode/skills"
    "$HOME/.trae/skills"
    "$HOME/Library/Application Support/Trae/skills"
    "$HOME/.trae-cn/skills"
    "$HOME/Library/Application Support/Trae-CN/skills"
    "$HOME/.openclaw/skills"
    "$HOME/.hermes/skills"
    "$HOME/.proma/default-skills"
    "$HOME/.cursor/skills"
    "$HOME/.kiro/skills"
    "$HOME/.junie/skills"
    "$HOME/.cline/skills"
    "$HOME/.roo/skills"
    "$HOME/.run/global-skills/skills"
    "$HOME/.warp/skills"
    "$HOME/.codeium/windsurf/skills"
    "$HOME/.firebender/skills"
    "$HOME/.augment/skills"
    "$HOME/.continue/skills"
    "$HOME/.config/goose/skills"
    "$HOME/.agents/skills"
    "$HOME/.qoder/skills"
    "$HOME/.qwen/skills"
    "$HOME/.codebuddy/skills"
    "$HOME/.config/agents/skills"
    "$HOME/.openhands/skills"
    "$HOME/.kilocode/skills"
    "$HOME/.zencoder/skills"
    "$HOME/.iflow/skills"
    "$HOME/.factory/skills"
    "$HOME/.config/devin/skills"
    "$HOME/.workbuddy/skills"
    "$HOME/.qclaw/skills"
    "$HOME/.codewhale/skills"
    "$HOME/.qoderworkcn/skills"
    "$HOME/.qoder-cn/skills"
  )
  AGENT_NAMES=()
}

load_agents

# We use linear lookup instead of associative arrays to support macOS Bash 3.2.
get_agent_name_from_json() {
  local search_target="$1"
  if [ ${#AGENT_NAMES[@]} -gt 0 ]; then
    for i in "${!TARGETS[@]}"; do
      if [ "${TARGETS[$i]}" = "$search_target" ] && [ -n "${AGENT_NAMES[$i]:-}" ]; then
        echo "${AGENT_NAMES[$i]}"
        return 0
      fi
    done
  fi
  return 1
}

# ---- Concurrency lock (mkdir-based, atomic) ----
# NOTE: the EXIT trap references LOCK_FILE (a module-level var that survives the
# function return), NOT the local lock_dir — a single-quoted trap evaluates its
# body at trigger time, by which point a local var is out of scope and would
# expand to empty, leaking the lock dir.
acquire_lock() {
  local lock_dir="${LOCK_FILE}.d"
  if mkdir "$lock_dir" 2>/dev/null; then
    echo $$ > "$lock_dir/pid"
    trap 'rm -rf "${LOCK_FILE}.d"' EXIT
    return
  fi
  # Lock exists — check if holder is still alive
  local old_pid
  old_pid=$(cat "$lock_dir/pid" 2>/dev/null)
  if [ -z "$old_pid" ]; then
    # Give the creator a short time (0.5s) to write the PID (mitigate TOCTOU race)
    for i in {1..5}; do
      sleep 0.1
      old_pid=$(cat "$lock_dir/pid" 2>/dev/null)
      [ -n "$old_pid" ] && break
    done
  fi
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "Another deploy is already running (PID: $old_pid), skipping."
    exit 0
  fi
  # Stale lock (holder is dead). Reclaim it without the TOCTOU window of
  # "rm -rf whole dir then mkdir" — another process could have legitimately
  # taken the lock between our kill -0 check and the rm. Instead: atomically
  # rename the stale dir to a unique name (only the current owner can win this
  # race since a live owner's dir is in use), then mkdir. Retry a few times in
  # case two reclaimers race each other.
  local reclaimed=false
  for i in 1 2 3; do
    # mv is atomic on the same filesystem; if it succeeds we own the stale dir.
    if mv "$lock_dir" "${lock_dir}.stale.$$" 2>/dev/null; then
      rm -rf "${lock_dir}.stale.$$"
      reclaimed=true
      break
    fi
    # mv failed: either another reclaimer moved it, or a live owner appeared.
    if mkdir "$lock_dir" 2>/dev/null; then
      echo $$ > "$lock_dir/pid"
      trap 'rm -rf "${LOCK_FILE}.d"' EXIT
      return
    fi
    sleep 0.1
  done
  if [ "$reclaimed" = true ]; then
    if ! mkdir "$lock_dir" 2>/dev/null; then
      echo "Error: Could not acquire lock after reclaiming stale lock."
      exit 1
    fi
    echo $$ > "$lock_dir/pid"
    trap 'rm -rf "${LOCK_FILE}.d"' EXIT
    return
  fi
  echo "Error: Could not acquire lock."
  exit 1
}

# Derive the agent's root config directory from a target skills path.
get_agent_root() {
  local target="$1"
  if [[ "$target" == "$HOME/Library/Application Support/"* ]]; then
    local after="${target#$HOME/Library/Application Support/}"
    local app_name="${after%%/*}"
    echo "$HOME/Library/Application Support/$app_name"
  elif [[ "$target" == "$HOME/"* ]]; then
    local rel="${target#$HOME/}"
    local first="${rel%%/*}"
    if [ "$first" = ".config" ]; then
      local second
      second=$(echo "$rel" | cut -d'/' -f2)
      if [ -n "$second" ] && [ "$second" != "$rel" ]; then
        echo "$HOME/.config/$second"
      else
        echo "$HOME/.config"
      fi
    else
      echo "$HOME/$first"
    fi
  else
    echo "$target"
  fi
}

append_target_once() {
  local candidate="$1"
  for target in "${TARGETS[@]}"; do
    [[ "$target" == "$candidate" ]] && return
  done
  TARGETS+=("$candidate")
}

# Load persisted custom targets if file exists
load_custom_targets() {
  if [ -f "$CUSTOM_TARGETS_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      local target_path="$line"
      if [[ "$line" == *"="* ]]; then
        target_path="${line#*=}"
        target_path="${target_path## }"
      fi
      if [ -d "$target_path" ]; then
        append_target_once "$target_path"
      fi
    done < "$CUSTOM_TARGETS_FILE"
  fi

  [ ! -d "$HOME/.proma" ] && return
  local proma_ws_dir="$HOME/.proma/agent-workspaces"
  [ ! -d "$proma_ws_dir" ] && return
  while IFS= read -r ws_skills; do
    append_target_once "$ws_skills"
  done < <(find "$proma_ws_dir" -type d -name skills -prune 2>/dev/null)
}

# Load disabled targets if file exists
DISABLED_TARGETS_FILE="$SCRIPT_DIR/disabled-targets.txt"
declare -a DISABLED_TARGETS_LIST

load_disabled_targets() {
  DISABLED_TARGETS_LIST=()
  if [ -f "$DISABLED_TARGETS_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      local target_path="$line"
      if [[ "$line" == *"="* ]]; then
        target_path="${line#*=}"
        target_path="${target_path## }"
      fi
      if [ -n "$target_path" ]; then
        if [[ "$target_path" == "~"* ]]; then
          target_path="${HOME}${target_path#\~}"
        fi
        local abs_path
        abs_path=$(cd "$target_path" 2>/dev/null && pwd -P) || abs_path="$target_path"
        DISABLED_TARGETS_LIST+=("$abs_path")
      fi
    done < "$DISABLED_TARGETS_FILE"
  fi
}

is_disabled_target() {
  local search_target="$1"
  for disabled in "${DISABLED_TARGETS_LIST[@]}"; do
    if [ "$disabled" = "$search_target" ]; then
      return 0
    fi
  done
  return 1
}

get_agent_name() {
  local path="$1"
  local json_name
  if json_name=$(get_agent_name_from_json "$path") && [ -n "$json_name" ]; then
    echo "$json_name"
    return
  fi
  # Dynamic Proma workspace detection
  if [[ "$path" == *".proma/agent-workspaces/"* ]]; then
    local rel="${path#*/.proma/agent-workspaces/}"
    local ws_id="${rel%%/*}"
    echo "Proma Workspace ($ws_id)"
    return
  fi
  # Fallback: prefix-based matching (precise, avoids substring false positives)
  local rel="${path#$HOME/}"
  case "$rel" in
    .gemini/antigravity/*) echo "Antigravity IDE" ;;
    .gemini/*)             echo "Antigravity CLI" ;;
    .codex/*)              echo "Codex" ;;
    .claude/*)             echo "Claude Code" ;;
    .copilot/*)            echo "GitHub Copilot" ;;
    .pi/*)                 echo "Pi" ;;
    .config/opencode/*)    echo "OpenCode" ;;
    .kimi/*)               echo "Kimi Code" ;;
    .zcode/*)              echo "ZCode" ;;
    .trae-cn/*)            echo "Trae CN" ;;
    .trae/*)               echo "Trae (Global)" ;;
    .openclaw/*)           echo "OpenClaw" ;;
    .hermes/*)             echo "Hermes Agent" ;;
    .proma/*)              echo "Proma" ;;
    .cursor/*)             echo "Cursor" ;;
    .kiro/*)               echo "Kiro Agent" ;;
    .junie/*)              echo "Junie (JetBrains)" ;;
    .cline/*)              echo "Cline" ;;
    .roo/*)                echo "Roo Code" ;;
    .warp/*)               echo "Warp" ;;
    .codeium/windsurf/*)   echo "Windsurf" ;;
    .firebender/*)         echo "Firebender" ;;
    .augment/*)            echo "Augment" ;;
    .continue/*)           echo "Continue" ;;
    .config/goose/*)       echo "Goose" ;;
    .qoder/*)              echo "Qoder" ;;
    .qwen/*)               echo "Qwen Code" ;;
    .codebuddy/*)          echo "CodeBuddy" ;;
    .config/agents/*)      echo "Amp" ;;
    .openhands/*)          echo "OpenHands" ;;
    .kilocode/*)           echo "Kilo Code" ;;
    .zencoder/*)           echo "Zencoder" ;;
    .iflow/*)              echo "iFlow CLI" ;;
    .factory/*)            echo "Droid" ;;
    .config/devin/*)       echo "Devin for Terminal" ;;
    .workbuddy/*)          echo "WorkBuddy" ;;
    .qclaw/*)              echo "QClaw" ;;
    .codewhale/*)          echo "CodeWhale" ;;
    .qoderworkcn/*)        echo "QoderWork CN" ;;
    .qoder-cn/*)           echo "Qoder CN" ;;
    .agents/*)             echo "Agents (Standard)" ;;
    .run/*)                echo "Run" ;;
    Library/Application\ Support/Trae-CN/*) echo "Trae CN" ;;
    Library/Application\ Support/Trae/*)    echo "Trae (Global)" ;;
    *)                     echo "Custom Agent" ;;
  esac
}

injection_tracked() {
  local val="$1"
  for existing in "${SUCCESSFUL_INJECTIONS[@]}"; do
    [[ "$existing" == "$val" ]] && return 0
  done
  return 1
}

# ---- Core sync ----
run_sync() {
  load_custom_targets
  load_disabled_targets
  SUCCESSFUL_INJECTIONS=()

  # Ensure ~/.qoder-cn exists — unlike other agents whose directories are
  # created by their respective tools, Qoder CN relies on EasySkills to
  # create the path if it does not already exist.
  mkdir -p "$HOME/.qoder-cn/skills"

  echo "=========================================================="
  echo "Starting EasySkills Sync (macOS)..."
  echo "=========================================================="

  # PART A: Legacy cleanup (Remove EasySkills self-mapping from previous versions)
  local central_resolved
  central_resolved=$(cd "$CENTRAL_DIR" 2>/dev/null && pwd -P) || {
    echo "Error: Cannot resolve CENTRAL_DIR ($CENTRAL_DIR). Aborting sync."
    return 1
  }
  for target in "${TARGETS[@]}"; do
    dest_path="$target/EasySkills"
    if [ -L "$dest_path" ]; then
      link_target=$(readlink "$dest_path")
      case "$link_target" in
        /*) link_target_abs="$link_target" ;;
        *) link_target_abs="$(dirname "$dest_path")/$link_target" ;;
      esac
      link_target_resolved=$(cd "$(dirname "$link_target_abs")" 2>/dev/null && pwd -P)/$(basename "$link_target_abs")
      if [[ "$link_target_resolved" == "$central_resolved" ]]; then
        rm -f "$dest_path"
        echo "   * Cleaned up legacy self-mapping -> $dest_path"
      fi
    fi
  done

  # PART B: Map each custom skill directory
  for skill_dir in "$CENTRAL_DIR"/*/; do
    [ -d "$skill_dir" ] || continue
    skill_name=$(basename "$skill_dir")

    [[ "$skill_name" == "node_modules" || "$skill_name" == ".git" || "$skill_name" == "dist" || "$skill_name" == "docs" || "$skill_name" == "." || "$skill_name" == ".." || "$skill_name" == _* ]] && continue

    echo "   Found skill: $skill_name"

    for target in "${TARGETS[@]}"; do
      local norm_target
      norm_target=$(cd "$target" 2>/dev/null && pwd -P) || norm_target="$target"
      if is_disabled_target "$norm_target"; then
        continue
      fi

      agent_root=$(get_agent_root "$target")
      [ ! -d "$agent_root" ] && continue

      mkdir -p "$target"
      dest_path="$target/$skill_name"

      if [ -e "$dest_path" ] || [ -L "$dest_path" ]; then
        if [ -L "$dest_path" ]; then
          rm -f "$dest_path"
        else
          echo "      Warning: [$skill_name] already exists as a real directory in $target. Skipped."
          continue
        fi
      fi

      ln -s "$skill_dir" "$dest_path"
      echo "      -> Mapped to: $dest_path"
      injection_tracked "$target" || SUCCESSFUL_INJECTIONS+=("$target")
    done
  done

  echo "=========================================================="
  echo "EasySkills Sync completed successfully!"
  echo "=========================================================="
  echo "Injection Summary:"
  echo "=========================================================="
  if [ ${#SUCCESSFUL_INJECTIONS[@]} -eq 0 ]; then
    echo "   No active target Agent directories mapped."
  else
    echo "Successfully injected into the following agents:"
    for injected in "${SUCCESSFUL_INJECTIONS[@]}"; do
      agent_name=$(get_agent_name "$injected")
      echo "   -> [$agent_name] $injected"
    done
  fi
  echo "=========================================================="
}

list_links() {
  load_custom_targets
  echo "=========================================================="
  echo "Current Mapped Targets:"
  echo "=========================================================="
  for target in "${TARGETS[@]}"; do
    if [ -d "$target" ]; then
      echo "Agent Path: $target"
      find "$target" -maxdepth 1 -type l -exec ls -la {} \; | sed 's/^/   Link: /'
    fi
  done
  echo "=========================================================="
}

add_target() {
  local path="$1"
  if [ -z "$path" ] || [ ! -d "$path" ]; then
    echo "Error: Please specify a valid directory."
    exit 1
  fi
  local abs_path
  abs_path=$(cd "$path" && pwd -P)
  touch "$CUSTOM_TARGETS_FILE"
  if grep -qFx "$abs_path" "$CUSTOM_TARGETS_FILE" 2>/dev/null; then
    echo "Path is already persisted: $abs_path"
  else
    echo "$abs_path" >> "$CUSTOM_TARGETS_FILE"
    echo "Successfully persisted custom target: $abs_path"
  fi
  if [ -f "$DISABLED_TARGETS_FILE" ]; then
    local tmp_file="${DISABLED_TARGETS_FILE}.tmp"
    awk -v p="$abs_path" '
      $0 == p { next }
      { idx = index($0, "="); if (idx > 0 && substr($0, idx+1) == p) next }
      { print }
    ' "$DISABLED_TARGETS_FILE" > "$tmp_file"
    mv "$tmp_file" "$DISABLED_TARGETS_FILE"
  fi
  run_sync
}

remove_target() {
  local path="$1"
  if [ -z "$path" ]; then
    echo "Error: Please specify a path to remove."
    exit 1
  fi
  if [ -f "$CUSTOM_TARGETS_FILE" ]; then
    local abs_path
    abs_path=$(cd "$path" 2>/dev/null && pwd -P) || abs_path="$path"
    awk -v p="$abs_path" '
      $0 == p { next }
      { idx = index($0, "="); if (idx > 0 && substr($0, idx+1) == p) next }
      { print }
    ' "$CUSTOM_TARGETS_FILE" > "${CUSTOM_TARGETS_FILE}.tmp"
    mv "${CUSTOM_TARGETS_FILE}.tmp" "$CUSTOM_TARGETS_FILE"
    if [ -f "$DISABLED_TARGETS_FILE" ]; then
      local tmp_file="${DISABLED_TARGETS_FILE}.tmp"
      awk -v p="$abs_path" '
        $0 == p { next }
        { idx = index($0, "="); if (idx > 0 && substr($0, idx+1) == p) next }
        { print }
      ' "$DISABLED_TARGETS_FILE" > "$tmp_file"
      mv "$tmp_file" "$DISABLED_TARGETS_FILE"
    fi
    echo "Successfully removed path: $abs_path"
    run_sync
  else
    echo "No custom targets file found."
  fi
}

run_cleanup() {
  load_custom_targets
  local central_resolved
  central_resolved=$(cd "$CENTRAL_DIR" 2>/dev/null && pwd -P) || {
    echo "Error: Cannot resolve CENTRAL_DIR ($CENTRAL_DIR). Aborting cleanup."
    return 1
  }
  echo "=========================================================="
  echo "Cleaning up all EasySkills symlinks from agent directories..."
  echo "=========================================================="
  for target in "${TARGETS[@]}"; do
    if [ -d "$target" ]; then
      find "$target" -maxdepth 1 -type l | while read -r link; do
        link_target=$(readlink "$link")
        case "$link_target" in
          /*) link_target_abs="$link_target" ;;
          *) link_target_abs="$(dirname "$link")/$link_target" ;;
        esac
        link_target_resolved=$(cd "$(dirname "$link_target_abs")" 2>/dev/null && pwd -P)/$(basename "$link_target_abs")
        if [[ "$link_target_resolved" == "$central_resolved" || "$link_target_resolved" == "$central_resolved/"* ]]; then
          rm -f "$link"
          echo "   Removed symlink: $link"
        fi
      done
    fi
  done
  echo "All EasySkills symlinks cleaned up."
  echo "=========================================================="
}

run_status() {
  load_custom_targets
  echo "=========================================================="
  echo "EasySkills Status"
  echo "=========================================================="

  # Watcher status
  local watcher_running=false
  local watcher_pid
  if [ "$(uname -s)" = "Darwin" ]; then
    watcher_pid=$(launchctl list 2>/dev/null | awk '$3 == "com.easyskills.watcher" { print $1; exit }')
  elif [ "$(uname -s)" = "Linux" ] && command -v systemctl &>/dev/null; then
    local svc_state
    svc_state=$(systemctl --user is-active easyskills-watcher.service 2>/dev/null)
    if [ "$svc_state" = "active" ]; then
      watcher_pid=$(systemctl --user show easyskills-watcher.service -p MainPID --value 2>/dev/null)
      [ "$watcher_pid" = "0" ] && watcher_pid=""
    else
      watcher_pid=""
    fi
  fi
  if [ -n "$watcher_pid" ]; then
    echo "   Watcher: ✅ Running (PID $watcher_pid)"
    watcher_running=true
  else
    echo "   Watcher: ❌ Not running"
  fi

  # Mapped agents
  local agent_count=0
  local skill_count=0
  for target in "${TARGETS[@]}"; do
    if [ -d "$target" ]; then
      local links
      links=$(find "$target" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')
      if [ "$links" -gt 0 ]; then
        agent_count=$((agent_count + 1))
        skill_count=$((skill_count + links))
        local agent_name
        agent_name=$(get_agent_name "$target")
        echo "   Agent: $agent_name ($links skills)"
      fi
    fi
  done

  echo "   ------------------------------------------"
  echo "   Total: $agent_count agents, $skill_count skill mappings"
  echo "=========================================================="
}

show_help() {
  echo "EasySkills CLI Management Tool"
  echo "Usage: ./deploy.sh [options]"
  echo "Options:"
  echo "  -s, --sync          Execute skills synchronization (default)"
  echo "  -l, --list          List all active mappings and symlinks"
  echo "  -a, --add [path]    Add and persist a new custom agent skills directory"
  echo "  -r, --remove [path] Remove a custom agent skills directory from persistence"
  echo "  -w, --watch         Install/Start the background watcher daemon"
  echo "  -u, --unwatch       Uninstall/Stop the background watcher daemon"
  echo "  -c, --cleanup       Remove all EasySkills symlinks from agent directories"
  echo "  --status            Show watcher and mapping health status"
  echo "  --webui             Start the local WebUI Manager on port 6633"
  echo "  -h, --help          Show this help documentation"
}

start_webui() {
  if ! command -v python3 &>/dev/null; then
    echo "Note: python3 not found — WebUI skipped. Install Python 3 to use the WebUI."
    return 1
  fi

  local python_bin
  python_bin="$(command -v python3)"

  webui_ready() {
    [ -n "$(own_webui_pid)" ] || return 1
    port_ready
  }

  port_ready() {
    if command -v nc >/dev/null 2>&1; then
      nc -z -w1 127.0.0.1 6633 >/dev/null 2>&1
    else
      "$python_bin" - <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.socket()
s.settimeout(1)
try:
    s.connect(("127.0.0.1", 6633))
    sys.exit(0)
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
    fi
  }

  wait_for_webui() {
    local _i
    for _i in $(seq 1 40); do
      webui_ready && return 0
      sleep 0.5
    done
    return 1
  }

  own_webui_pid() {
    pgrep -f "$SCRIPT_DIR/webui.py" 2>/dev/null | head -1
  }

  stop_own_webui() {
    local pid
    if command -v lsof &>/dev/null; then
      for pid in $(lsof -tiTCP:6633 -sTCP:LISTEN 2>/dev/null); do
        local cmdline
        cmdline=$(ps -p "$pid" -o command= 2>/dev/null || true)
        if [[ "$cmdline" == *"$SCRIPT_DIR/webui.py"* ]]; then
          kill "$pid" 2>/dev/null || true
        fi
      done
    fi
    for pid in $(pgrep -f "$SCRIPT_DIR/webui.py" 2>/dev/null || true); do
      kill "$pid" 2>/dev/null || true
    done
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ -z "$(own_webui_pid)" ] && ! port_ready && break
      sleep 0.2
    done
  }

  launch_webui_detached() {
    "$python_bin" - "$python_bin" "$SCRIPT_DIR/webui.py" <<'PY' >/dev/null 2>&1
import os
import subprocess
import sys

python_bin, webui_script = sys.argv[1], sys.argv[2]
env = os.environ.copy()
env["EASYSKILLS_NO_BROWSER"] = "1"
subprocess.Popen(
    [python_bin, webui_script],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    start_new_session=True,
    env=env,
)
PY
  }

  open_webui_once() {
    echo "程序正在启动挂载中，完成后浏览器 WebUI 会自动打开。"
    echo "Starting and mounting WebUI; the browser will open automatically when ready."
    if ! wait_for_webui; then
      echo "WebUI is still starting; open http://127.0.0.1:6633 in a few seconds."
      return 1
    fi
    if [ "$(uname -s)" = "Darwin" ] && command -v open &>/dev/null; then
      open "http://127.0.0.1:6633" >/dev/null 2>&1 || true
    elif [ "$(uname -s)" = "Linux" ] && command -v xdg-open &>/dev/null; then
      xdg-open "http://127.0.0.1:6633" >/dev/null 2>&1 || true
    fi
  }

  # Preferred path on macOS: launch webui.py as a fully detached session.
  # We deliberately avoid `launchctl submit` for the WebUI backend here: on
  # some macOS configurations a submitted Python backend stays alive but never
  # begins serving port 6633, which is exactly the post-install blank/failing
  # browser tab we need to avoid. A tiny Python launcher with start_new_session
  # avoids shell/terminal cleanup killing the backend after the installer exits.
  local supervisor="$SCRIPT_DIR/webui-service.sh"
  if [ "$(uname -s)" = "Darwin" ]; then
    launchctl remove "com.easyskills.webui" 2>/dev/null || true
    local webui_label="com.easyskills.webui.manual"
    launchctl remove "$webui_label" 2>/dev/null || true
    stop_own_webui
    launch_webui_detached
    if open_webui_once; then
      echo "WebUI launching on http://127.0.0.1:6633"
      return 0
    fi
    stop_own_webui
  fi

  # Fallback (Linux / no launchd / launchctl failure): run the supervisor directly if present,
  # otherwise start webui.py bare.
  if [ -f "$supervisor" ]; then
    if command -v setsid &>/dev/null; then
      setsid /bin/bash "$supervisor" >/dev/null 2>&1 &
    else
      nohup /bin/bash "$supervisor" >/dev/null 2>&1 &
    fi
    if open_webui_once; then
      echo "WebUI launching on http://127.0.0.1:6633"
      return 0
    fi
  elif command -v setsid &>/dev/null; then
    EASYSKILLS_NO_BROWSER=1 setsid "$python_bin" "$SCRIPT_DIR/webui.py" >/dev/null 2>&1 &
    if open_webui_once; then
      echo "WebUI launching on http://127.0.0.1:6633"
      return 0
    fi
  else
    EASYSKILLS_NO_BROWSER=1 "$python_bin" "$SCRIPT_DIR/webui.py" >/dev/null 2>&1 &
    if open_webui_once; then
      echo "WebUI launching on http://127.0.0.1:6633"
      return 0
    fi
  fi
  echo "Error: WebUI did not become ready on http://127.0.0.1:6633." >&2
  return 1
}

# Parse command line options
ACTION="sync"
ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--sync) ACTION="sync"; shift ;;
    -l|--list) ACTION="list"; shift ;;
    -a|--add) ACTION="add"; ARG="$2"; shift 2 ;;
    -r|--remove) ACTION="remove"; ARG="$2"; shift 2 ;;
    -w|--watch) ACTION="watch"; shift ;;
    -u|--unwatch) ACTION="unwatch"; shift ;;
    -c|--cleanup) ACTION="cleanup"; shift ;;
    --status) ACTION="status"; shift ;;
    --webui) ACTION="webui"; shift ;;
    -h|--help) ACTION="help"; shift ;;
    *)
       ACTION="sync"
       TARGETS+=("$1")
       shift
       ;;
  esac
done

# Acquire lock for actions that modify symlinks
case "$ACTION" in
  sync|add|remove|cleanup) acquire_lock ;;
esac

case "$ACTION" in
  sync) run_sync ;;
  list) list_links ;;
  add) add_target "$ARG" ;;
  remove) remove_target "$ARG" ;;
  watch) bash "$SCRIPT_DIR/watch.sh" ;;
  unwatch) bash "$SCRIPT_DIR/unwatch.sh" ;;
  cleanup) run_cleanup ;;
  status) run_status ;;
  webui) start_webui ;;
  help) show_help ;;
esac
