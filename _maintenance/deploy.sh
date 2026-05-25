#!/usr/bin/env bash

# ==============================================================================
# Script: deploy.sh (macOS)
# Description: Active skills mapping and persistence CLI tool for macOS.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CENTRAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CUSTOM_TARGETS_FILE="$SCRIPT_DIR/custom-targets.txt"
LOCK_FILE="$SCRIPT_DIR/.deploy.lock"

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

# Default target skills directories
TARGETS=(
  "$HOME/.gemini/config/skills"
  "$HOME/.gemini/antigravity/skills"
  "$HOME/.codex/skills"
  "$HOME/.claude/skills"
  "$HOME/.copilot/skills"
  "$HOME/.pi/agent/skills"
  "$HOME/.config/opencode/skills"
  "$HOME/.kimi/skills"
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
  "$HOME/.warp/skills"
  "$HOME/.codeium/windsurf/skills"
  "$HOME/.firebender/skills"
  "$HOME/.augment/skills"
  "$HOME/.continue/skills"
  "$HOME/.config/goose/skills"
  "$HOME/.agents/skills"
  "$HOME/.run/global-skills/skills"
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
)

# ---- Concurrency lock (PID-based, stale-safe) ----
acquire_lock() {
  if [ -f "$LOCK_FILE" ]; then
    local old_pid
    old_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      echo "Another deploy is already running (PID: $old_pid), skipping."
      exit 0
    fi
    rm -f "$LOCK_FILE"
  fi
  echo $$ > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"' EXIT
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
    echo "$HOME/$first"
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

get_agent_name() {
  local path="$1"
  if [[ "$path" == *".gemini"*"antigravity"* ]]; then echo "Antigravity IDE"; return; fi
  if [[ "$path" == *".gemini"* ]]; then echo "Antigravity CLI"; return; fi
  if [[ "$path" == *".codex"* ]]; then echo "Codex"; return; fi
  if [[ "$path" == *".claude"* ]]; then echo "Claude Code"; return; fi
  if [[ "$path" == *".copilot"* ]]; then echo "GitHub Copilot"; return; fi
  if [[ "$path" == *".pi"* ]]; then echo "Pi"; return; fi
  if [[ "$path" == *".config/opencode"* ]]; then echo "OpenCode"; return; fi
  if [[ "$path" == *".kimi"* ]]; then echo "Kimi Code"; return; fi
  if [[ "$path" == *".trae-cn"* || "$path" == *"/Trae-CN/"* ]]; then echo "Trae CN"; return; fi
  if [[ "$path" == *".trae"* || "$path" == *"/Trae/"* ]]; then echo "Trae (Global)"; return; fi
  if [[ "$path" == *".openclaw"* ]]; then echo "OpenClaw"; return; fi
  if [[ "$path" == *".hermes"* ]]; then echo "Hermes Agent"; return; fi
  if [[ "$path" == *".proma/agent-workspaces/"* ]]; then
    local rel="${path#*/.proma/agent-workspaces/}"
    local ws_id="${rel%%/*}"
    echo "Proma Workspace ($ws_id)"
    return
  fi
  if [[ "$path" == *".proma"* ]]; then echo "Proma"; return; fi
  if [[ "$path" == *".cursor"* ]]; then echo "Cursor"; return; fi
  if [[ "$path" == *".kiro"* ]]; then echo "Kiro Agent"; return; fi
  if [[ "$path" == *".junie"* ]]; then echo "Junie (JetBrains)"; return; fi
  if [[ "$path" == *".cline"* ]]; then echo "Cline"; return; fi
  if [[ "$path" == *".roo"* ]]; then echo "Roo Code"; return; fi
  if [[ "$path" == *".warp"* ]]; then echo "Warp"; return; fi
  if [[ "$path" == *".codeium/windsurf"* ]]; then echo "Windsurf"; return; fi
  if [[ "$path" == *".firebender"* ]]; then echo "Firebender"; return; fi
  if [[ "$path" == *".augment"* ]]; then echo "Augment"; return; fi
  if [[ "$path" == *".continue"* ]]; then echo "Continue"; return; fi
  if [[ "$path" == *".config/goose"* ]]; then echo "Goose"; return; fi
  if [[ "$path" == *".qoder"* ]]; then echo "Qoder"; return; fi
  if [[ "$path" == *".qwen"* ]]; then echo "Qwen Code"; return; fi
  if [[ "$path" == *".codebuddy"* ]]; then echo "CodeBuddy"; return; fi
  if [[ "$path" == *".config/agents"* ]]; then echo "Amp"; return; fi
  if [[ "$path" == *".openhands"* ]]; then echo "OpenHands"; return; fi
  if [[ "$path" == *".kilocode"* ]]; then echo "Kilo Code"; return; fi
  if [[ "$path" == *".zencoder"* ]]; then echo "Zencoder"; return; fi
  if [[ "$path" == *".iflow"* ]]; then echo "iFlow CLI"; return; fi
  if [[ "$path" == *".factory"* ]]; then echo "Droid"; return; fi
  if [[ "$path" == *".config/devin"* ]]; then echo "Devin for Terminal"; return; fi
  if [[ "$path" == *".agents"* ]]; then echo "Agents (Standard)"; return; fi
  if [[ "$path" == *".run"* ]]; then echo "Run"; return; fi
  echo "Custom Agent"
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
  SUCCESSFUL_INJECTIONS=()
  echo "=========================================================="
  echo "Starting EasySkills Sync (macOS)..."
  echo "=========================================================="

  # PART A: Map EasySkills itself
  for target in "${TARGETS[@]}"; do
    agent_root=$(get_agent_root "$target")
    [ ! -d "$agent_root" ] && continue

    mkdir -p "$target"
    dest_path="$target/EasySkills"

    if [ -e "$dest_path" ] || [ -L "$dest_path" ]; then
      if [ -L "$dest_path" ]; then
        rm -f "$dest_path"
      else
        continue
      fi
    fi

    ln -s "$CENTRAL_DIR" "$dest_path"
    echo "   * Self-Mapped EasySkills -> $dest_path"
    injection_tracked "$target" || SUCCESSFUL_INJECTIONS+=("$target")
  done

  # PART B: Map each custom skill directory
  for skill_dir in "$CENTRAL_DIR"/*/; do
    [ -d "$skill_dir" ] || continue
    skill_name=$(basename "$skill_dir")

    [[ "$skill_name" == "node_modules" || "$skill_name" == ".git" || "$skill_name" == "dist" || "$skill_name" == "." || "$skill_name" == ".." || "$skill_name" == _* ]] && continue

    echo "   Found skill: $skill_name"

    for target in "${TARGETS[@]}"; do
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
  path="$1"
  if [ -z "$path" ] || [ ! -d "$path" ]; then
    echo "Error: Please specify a valid directory."
    exit 1
  fi
  abs_path=$(cd "$path" && pwd)
  touch "$CUSTOM_TARGETS_FILE"
  if grep -q "$abs_path" "$CUSTOM_TARGETS_FILE" 2>/dev/null; then
    echo "Path is already persisted: $abs_path"
  else
    echo "$abs_path" >> "$CUSTOM_TARGETS_FILE"
    echo "Successfully persisted custom target: $abs_path"
  fi
  run_sync
}

remove_target() {
  path="$1"
  if [ -z "$path" ]; then
    echo "Error: Please specify a path to remove."
    exit 1
  fi
  if [ -f "$CUSTOM_TARGETS_FILE" ]; then
    grep -v -F "$path" "$CUSTOM_TARGETS_FILE" > "${CUSTOM_TARGETS_FILE}.tmp"
    mv "${CUSTOM_TARGETS_FILE}.tmp" "$CUSTOM_TARGETS_FILE"
    echo "Successfully removed path: $path"
    run_sync
  else
    echo "No custom targets file found."
  fi
}

run_cleanup() {
  load_custom_targets
  local central_resolved
  central_resolved=$(cd "$CENTRAL_DIR" && pwd -P)
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
  watcher_pid=$(launchctl list 2>/dev/null | awk '$3 == "com.easyskills.watcher" { print $1; exit }')
  if [ -n "$watcher_pid" ]; then
    local pid
    pid="$watcher_pid"
    echo "   Watcher: ✅ Running (PID $pid)"
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

  if [ "$(uname -s)" = "Darwin" ] && command -v launchctl &>/dev/null; then
    local webui_label="com.easyskills.webui.manual"
    launchctl remove "$webui_label" 2>/dev/null || true
    if command -v lsof &>/dev/null; then
      local pid
      for pid in $(lsof -tiTCP:6633 -sTCP:LISTEN 2>/dev/null); do
        local cmdline
        cmdline=$(ps -p "$pid" -o command= 2>/dev/null || true)
        if [[ "$cmdline" == *"$SCRIPT_DIR/webui.py"* ]]; then
          kill "$pid" 2>/dev/null || true
        fi
      done
    fi
    if launchctl submit -l "$webui_label" -- "$python_bin" "$SCRIPT_DIR/webui.py" 2>/dev/null; then
      echo "WebUI launching on http://127.0.0.1:6633"
      return 0
    fi
  fi

  if command -v setsid &>/dev/null; then
    setsid "$python_bin" "$SCRIPT_DIR/webui.py" >/dev/null 2>&1 &
  else
    "$python_bin" "$SCRIPT_DIR/webui.py" >/dev/null 2>&1 &
  fi
  echo "WebUI launching on http://127.0.0.1:6633"
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
