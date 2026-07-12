#!/usr/bin/env bash

# ==============================================================================
# Script: webui-service.sh (macOS / Linux)
# Description: Supervises the EasySkills WebUI backend (port 6633). Mirrors the
#              Windows webui-service.ps1 supervisor: ensures the backend stays
#              up, restarts it after a crash, and throttles restart storms.
#              Designed to run under launchd (KeepAlive) or systemd as a
#              long-lived supervisor; the supervised webui.py is the actual
#              HTTP server.
# ==============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEBUI_SCRIPT="$SCRIPT_DIR/webui.py"
# Must match webui.py:PORT (single source of truth).
PORT=6633
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/webui-service.log"

# Under launchd/systemd the PATH is minimal (often just /usr/bin:/bin). Worse,
# /usr/bin/python3 may be an OLDER system Python that can't run webui.py (which
# uses PEP 604 `X | None` syntax requiring Python 3.10+). PREPEND the common
# Homebrew/3rd-party interpreter locations so a modern python3 wins over the
# stale /usr/bin/python3.
# Preserve priority order even if some paths already exist later in PATH.
_PATH_PREFIX=""
for _p in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.pyenv/shims"; do
  [ -d "$_p" ] || continue
  _PATH_PREFIX="${_PATH_PREFIX}${_PATH_PREFIX:+:}$_p"
done
PATH="${_PATH_PREFIX}${_PATH_PREFIX:+:}${PATH:-}"
unset _PATH_PREFIX
export PATH
PYTHON_BIN="$(command -v python3 2>/dev/null || true)"
# The supervisor owns browser-opening policy. Backend restarts must not spawn a
# new browser tab/window every time webui.py is relaunched.
export EASYSKILLS_NO_BROWSER=1

mkdir -p "$LOG_DIR" 2>/dev/null || true

log() {
  printf '%s [pid=%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# --- preflight ---------------------------------------------------------------
if [ -z "$PYTHON_BIN" ]; then
  log "python3 not found; supervisor cannot start. Exiting."
  exit 1
fi
if [ ! -f "$WEBUI_SCRIPT" ]; then
  log "webui.py not found at $WEBUI_SCRIPT. Exiting."
  exit 1
fi

# --- single-instance guard (mkdir-based, atomic) -----------------------------
LOCK_DIR="$SCRIPT_DIR/.webui-service.lock.d"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  # A stale lock from a crashed supervisor: reclaim if the holder is dead.
  old_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -z "$old_pid" ] || ! kill -0 "$old_pid" 2>/dev/null; then
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || { log "Could not acquire supervisor lock."; exit 1; }
  else
    log "Another supervisor is already running (PID $old_pid); exiting."
    exit 0
  fi
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

# --- helpers -----------------------------------------------------------------
port_is_open() {
  # Try a TCP connect to the WebUI port; returns 0 if something is listening.
  if command -v nc >/dev/null 2>&1; then
    nc -z -w1 127.0.0.1 "$PORT" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then
    "$PYTHON_BIN" - "$PORT" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.socket()
s.settimeout(1)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
    sys.exit(0)
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
  else
    return 1
  fi
}

own_webui_pid() {
  # Find a webui.py process launched from our SCRIPT_DIR. We anchor on the
  # literal webui.py PATH (unique enough), NOT on the interpreter prefix —
  # because PYTHON_BIN may be an absolute path (e.g. /opt/homebrew/bin/python3
  # or /usr/bin/python3), so requiring the literal "python3" prefix would fail
  # to match and cause the supervisor to restart a healthy backend in a loop.
  local pattern
  pattern="${SCRIPT_DIR}/webui.py"
  local match
  # Match any process whose command line contains our webui.py path.
  match=$(pgrep -f "${pattern}" 2>/dev/null | head -1)
  # Defense in depth: confirm the candidate is a PYTHON interpreter running our
  # script. A bare substring check would match editors/greps that happen to have
  # the path on their command line (VS Code, vim, grep, ripgrep, a language
  # server...) — and we would then SIGKILL them, destroying unsaved work.
  # ps -o comm= gives the executable basename (e.g. "python3", "python3.11").
  if [ -n "$match" ]; then
    local comm base
    comm=$(ps -p "$match" -o comm= 2>/dev/null || true)
    base="${comm##*/}"
    case "$base" in
      python|python[0-9]*) echo "$match" ;;
    esac
  fi
}

kill_stale_webui() {
  local pid
  pid="$(own_webui_pid)"
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    # give it a moment to release the port
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.3
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
}

launch_webui() {
  # Detach so the child outlives any transient shell state; suppress its stdio.
  # Echo the child PID so the caller can detect immediate exits (e.g. an
  # incompatible Python version fails at startup and the process dies in <1s).
  if command -v setsid >/dev/null 2>&1; then
    setsid "$PYTHON_BIN" "$WEBUI_SCRIPT" >/dev/null 2>&1 &
    echo $!
  else
    nohup "$PYTHON_BIN" "$WEBUI_SCRIPT" >/dev/null 2>&1 &
    echo $!
  fi
}

# --- supervisor loop ---------------------------------------------------------
log "Supervisor started. SCRIPT_DIR=$SCRIPT_DIR PORT=$PORT"

# Restart-storm throttle: count restarts within a rolling window.
RESTART_TIMES=()
THROTTLE_WINDOW=300   # 5 minutes
THROTTLE_MAX=12       # >=12 restarts in the window -> cool down

# Quick-fail detection: if webui.py dies within QUICK_FAIL_SECS of launch this
# many times in a row, the backend is fundamentally broken (wrong Python
# version, missing file, etc.) — stop hammering and surface the problem rather
# than restart-looping forever.
QUICK_FAIL_SECS=5
QUICK_FAIL_MAX=3
QUICK_FAIL_COUNT=0

while true; do
  pid="$(own_webui_pid)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && port_is_open; then
    # Healthy: backend alive and port responding. Reset quick-fail counter and idle.
    QUICK_FAIL_COUNT=0
    sleep 5
    continue
  fi

  if [ -z "$pid" ] && port_is_open; then
    # The port is occupied, but not by the webui.py process launched from this
    # EasySkills install. Do not repeatedly spawn a backend that can only fail
    # to bind; wait for the external owner to go away (or the user to change it).
    log "Port $PORT is already in use by a non-EasySkills process; waiting."
    sleep 5
    continue
  fi

  # Something is wrong (no process, dead process, or port not responding).
  # First, reap any half-dead backend so we don't fight over the port.
  kill_stale_webui

  # Throttle check: drop restarts older than the window, then count.
  now=$(date +%s)
  _kept=()
  # ${arr[@]:0} is the set -u-safe way to iterate a possibly-empty array on
  # bash 3.2 (macOS default), where "${arr[@]}" on an unset/empty array errors.
  for t in "${RESTART_TIMES[@]:0}"; do
    [ -n "$t" ] && [ $((now - t)) -le "$THROTTLE_WINDOW" ] && _kept+=("$t")
  done
  RESTART_TIMES=()
  for t in "${_kept[@]:0}"; do
    RESTART_TIMES+=("$t")
  done
  if [ "${#RESTART_TIMES[@]}" -ge "$THROTTLE_MAX" ]; then
    log "Restart storm (>=${THROTTLE_MAX} in ${THROTTLE_WINDOW}s); cooling down 30s."
    sleep 30
    continue
  fi

  log "Launching webui.py ..."
  child_pid="$(launch_webui)"
  RESTART_TIMES+=("$(date +%s)")

  # Wait up to 15s for OUR backend to come up, but bail early if the child died.
  ready=false
  for _ in $(seq 1 30); do
    launched_pid="$(own_webui_pid)"
    if [ -n "$launched_pid" ] && kill -0 "$launched_pid" 2>/dev/null && port_is_open; then
      ready=true
      break
    fi
    # If the launched child is gone and no webui.py is alive, it failed fast.
    if [ -n "$child_pid" ] && ! kill -0 "$child_pid" 2>/dev/null && [ -z "$(own_webui_pid)" ]; then
      break
    fi
    sleep 0.5
  done
  if [ "$ready" = true ]; then
    log "WebUI up on port $PORT."
    QUICK_FAIL_COUNT=0
  else
    # Distinguish a fast crash (child died quickly) from a slow/never-ready start.
    if [ -n "$child_pid" ] && ! kill -0 "$child_pid" 2>/dev/null && [ -z "$(own_webui_pid)" ]; then
      QUICK_FAIL_COUNT=$((QUICK_FAIL_COUNT + 1))
      log "webui.py exited quickly (attempt $QUICK_FAIL_COUNT/$QUICK_FAIL_MAX). Likely a Python-version or config problem — check that 'python3 $WEBUI_SCRIPT' runs manually."
      if [ "$QUICK_FAIL_COUNT" -ge "$QUICK_FAIL_MAX" ]; then
        log "Aborting: webui.py failed $QUICK_FAIL_MAX times in a row. Not restart-looping. Fix the underlying error (often: need Python 3.10+ on PATH) and re-run watch.sh."
        exit 1
      fi
    else
      log "WebUI did not come up within 15s; will retry."
    fi
  fi
  sleep 2
done
