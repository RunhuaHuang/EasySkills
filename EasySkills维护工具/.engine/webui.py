#!/usr/bin/env python3
# ==============================================================================
# Script: webui.py (macOS/Linux)
# Description: EasySkills WebUI backend — Python 3 stdlib only, zero pip deps.
# Usage: python3 EasySkills维护工具/.engine/webui.py
#        or: bash EasySkills维护工具/.engine/deploy.sh --webui
# ==============================================================================

# --- Python version guard -----------------------------------------------------
# MUST run before any code uses `X | None` type syntax (PEP 604, Python 3.10+).
# On older interpreters (e.g. a stale /usr/bin/python3 under launchd) this gives
# a clear, actionable error instead of a confusing parse-time TypeError that
# would make the supervisor restart-loop the backend forever.
import sys as _sys

if _sys.version_info < (3, 10):
    _sys.stderr.write(
        "EasySkills WebUI requires Python 3.10 or newer, but "
        f"Python {_sys.version.split()[0]} was found at "
        f"{_sys.executable}.\n"
        "Install a recent Python 3 (e.g. via https://www.python.org/downloads/ "
        "or Homebrew: `brew install python`) and ensure it is on PATH.\n"
    )
    _sys.exit(1)

_DOCTOR_MODE = "--doctor" in _sys.argv

import hashlib
import html as html_lib
import http.server
import logging
import signal
import socketserver
import base64
import binascii
import contextlib

try:
    import fcntl
except ImportError:  # Windows: locking falls back to no-op below
    fcntl = None
import errno
import functools
import hmac
import json
import os
import platform
import posixpath
import re
import secrets
import shutil
import subprocess
import tarfile
import tempfile
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.absolute()
# The engine lives at EasySkills维护工具/.engine (two levels under the
# repo/install root), so the central directory that holds mcp/, instructions/,
# and the skill folders is TWO parents up — same as deploy.sh's "$SCRIPT_DIR/../.."
# and deploy.ps1's double Split-Path.
CENTRAL_DIR = SCRIPT_DIR.parent.parent

# Dynamically resolve to official home directory installation if it exists.
# An explicit EASYSKILLS_CENTRAL_DIR env var wins over any heuristic so
# multi-instance setups (repo clone + home install) behave predictably.
HOME_CENTRAL_DIR = Path.home() / "EasySkills"
_env_central = os.environ.get("EASYSKILLS_CENTRAL_DIR")
if _env_central:
    _env_path = Path(_env_central).expanduser().resolve()
    if _env_path.is_dir() and (_env_path / "EasySkills维护工具/.engine").is_dir():
        CENTRAL_DIR = _env_path
        SCRIPT_DIR = _env_path / "EasySkills维护工具/.engine"
elif (HOME_CENTRAL_DIR.exists() and HOME_CENTRAL_DIR.is_dir()
      and not (CENTRAL_DIR / ".git").exists()
      and (HOME_CENTRAL_DIR / "EasySkills维护工具/.engine" / ".version").exists()):
    CENTRAL_DIR = HOME_CENTRAL_DIR
    SCRIPT_DIR = HOME_CENTRAL_DIR / "EasySkills维护工具/.engine"

CUSTOM_TARGETS_FILE = SCRIPT_DIR / "custom-targets.txt"
DISABLED_TARGETS_FILE = SCRIPT_DIR / "disabled-targets.txt"
AGENT_PATH_CONFIG_FILE = CENTRAL_DIR / ".easyskills-agent-paths.json"

def _target_line_parts(line: str) -> tuple[str, str]:
    """Split a persisted target line without truncating paths that contain '='.

    Named entries use ``Agent name=/absolute/path``.  Plain paths are also
    supported, and ``=`` is a legal filename character on both Unix and
    Windows.  Treat an equals sign as a delimiter only when the right-hand
    side has an unambiguous path shape; otherwise preserve the entire line as
    a plain path.
    """
    stripped = str(line or "").strip()
    if not stripped or stripped.startswith("#"):
        return "", ""
    if "=" in stripped:
        prefix, candidate = (part.strip() for part in stripped.split("=", 1))
        candidate_looks_like_path = (
            candidate.startswith(("/", "\\", "~", "."))
            or "/" in candidate
            or "\\" in candidate
            or re.match(r"^[A-Za-z]:[\\/]", candidate) is not None
        )
        prefix_looks_like_path = (
            prefix.startswith(("/", "\\", "~", "."))
            or "/" in prefix
            or "\\" in prefix
            or re.match(r"^[A-Za-z]:[\\/]", prefix) is not None
        )
        if prefix and candidate_looks_like_path and not prefix_looks_like_path:
            return prefix, candidate
    return "", stripped


def _target_path_from_line(line: str) -> str:
    """Extract a path from either a plain or labelled persisted target line."""
    return _target_line_parts(line)[1]


def _add_to_disabled_targets(path_str: str) -> bool:
    if not path_str or not path_str.strip():
        return False
    path_str = path_str.strip()
    try:
        norm_path = str(Path(path_str).expanduser().resolve())
    except Exception:
        norm_path = str(Path(path_str).expanduser())

    lines = []
    if DISABLED_TARGETS_FILE.exists():
        try:
            lines = DISABLED_TARGETS_FILE.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError):
            pass

    exists = False
    for line in lines:
        stripped = _target_path_from_line(line)
        if not stripped:
            continue
        try:
            line_path = str(Path(stripped).expanduser().resolve())
        except Exception:
            line_path = str(Path(stripped).expanduser())
        if line_path == norm_path:
            exists = True
            break

    if not exists:
        lines.append(norm_path)
        try:
            _atomic_write_text(DISABLED_TARGETS_FILE, "\n".join(lines) + "\n")
        except OSError:
            return False
    return True

def _remove_from_disabled_targets(path_str: str) -> bool:
    if not path_str or not path_str.strip() or not DISABLED_TARGETS_FILE.exists():
        return True
    path_str = path_str.strip()
    try:
        norm_path = str(Path(path_str).expanduser().resolve())
    except Exception:
        norm_path = str(Path(path_str).expanduser())

    lines = []
    try:
        lines = DISABLED_TARGETS_FILE.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return False

    new_lines = []
    updated = False
    for line in lines:
        stripped = _target_path_from_line(line)
        if not stripped:
            new_lines.append(line)
            continue
        try:
            line_path = str(Path(stripped).expanduser().resolve())
        except Exception:
            line_path = str(Path(stripped).expanduser())
        if line_path == norm_path:
            updated = True
        else:
            new_lines.append(line)
    
    if updated:
        try:
            _atomic_write_text(DISABLED_TARGETS_FILE, "\n".join(new_lines) + "\n")
        except (OSError, UnicodeError):
            return False
    return True

def _get_disabled_targets() -> set[str]:
    disabled = set()
    if DISABLED_TARGETS_FILE.exists():
        try:
            for line in DISABLED_TARGETS_FILE.read_text(encoding="utf-8").splitlines():
                stripped = _target_path_from_line(line)
                if stripped:
                    try:
                        norm = str(Path(stripped).expanduser().resolve())
                    except Exception:
                        norm = str(Path(stripped).expanduser())
                    disabled.add(norm)
        except OSError:
            pass
    return disabled
AGENTS_JSON_FILE = SCRIPT_DIR / "agents.json"
WEBUI_DIR = SCRIPT_DIR / "webui"
if not WEBUI_DIR.exists():
    WEBUI_DIR = Path(__file__).parent.absolute() / "webui"

# --- Instruction-rule library (AGENTS.md / CLAUDE.md management) ---
# Modular rule files live here; "write to all agents" concatenates them into a
# single managed block injected into each agent's global instruction file.
INSTRUCTIONS_DIR = CENTRAL_DIR / "instructions"
INSTRUCTION_SYNC_STATE_FILE = CENTRAL_DIR / ".easyskills-instruction-state.json"
MCP_DIR = CENTRAL_DIR / "mcp"
MCP_CONFIG_FILE = MCP_DIR / "servers.json"
MCP_CONFIG_BACKUP_FILE = MCP_DIR / "servers.json.bak"
MCP_TEMPLATE_FILE = SCRIPT_DIR / "mcp-servers.template.json"
MCP_GATEWAY_BINARY = CENTRAL_DIR / ".runtime" / ("easyskills-mcp.exe" if os.name == "nt" else "easyskills-mcp")
EASY_SKILLS_BEGIN = "<!-- EasySkills:begin -->"
EASY_SKILLS_BEGIN_ALIASES = (
    EASY_SKILLS_BEGIN,
    "<!-- EasySkills:begin (managed block — do not edit manually) -->",
    "<!-- EasySkills:begin (managed block - do not edit manually) -->",
)
EASY_SKILLS_END = "<!-- EasySkills:end -->"
# WebUI listen port — SINGLE SOURCE OF TRUTH. Mirror any change in webui.ps1
# ($Port) and webui-service.ps1 ($Port); display strings referencing 6633 in the
# installers/scripts also need updating.
PORT = 6633
ALLOWED_ORIGINS = {f"http://localhost:{PORT}", f"http://127.0.0.1:{PORT}"}
WATCHER_LAUNCHD_LABEL = "com.easyskills.watcher"

# ---- Persistent token (survives restarts) ----
# Stored under SCRIPT_DIR (not bare home) so it stays with the installation
# and is not visible to unrelated home-dir processes.
TOKEN_FILE = SCRIPT_DIR / ".easyskills-token"

def _load_or_create_token() -> str:
    env_token = os.environ.get("EASYSKILLS_WEBUI_TOKEN")
    if env_token:
        # Enforce the same minimum strength as the file-backed path below: a
        # mistyped or placeholder env value must not silently become a weak token.
        if len(env_token) >= 16:
            return env_token
        print(f"ignoring EASYSKILLS_WEBUI_TOKEN: too short ({len(env_token)} < 16 chars); "
              "generating a file-backed token instead", file=_sys.stderr)
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    lock_path = TOKEN_FILE.with_name(TOKEN_FILE.name + ".lock")
    lock_fd = os.open(str(lock_path), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        os.fchmod(lock_fd, 0o600)
    except OSError:
        os.close(lock_fd)
        raise
    with os.fdopen(lock_fd, "a+") as lock_handle:
        # A stable companion lock prevents two manually-started backends from
        # both reclaiming a corrupt token and ending up with different in-memory
        # tokens. Locking TOKEN_FILE itself is insufficient because os.replace
        # changes its inode.
        if fcntl is not None:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        try:
            if TOKEN_FILE.is_file():
                try:
                    token = TOKEN_FILE.read_text(encoding="utf-8").strip()
                    if len(token) >= 16:
                        os.chmod(TOKEN_FILE, 0o600)
                        return token
                except (OSError, UnicodeError):
                    pass

            token = secrets.token_urlsafe(32)
            fd, temp_name = tempfile.mkstemp(
                prefix=f".{TOKEN_FILE.name}.", suffix=".tmp", dir=str(TOKEN_FILE.parent)
            )
            temp_path = Path(temp_name)
            try:
                os.fchmod(fd, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
                    handle.write(token)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(temp_path, TOKEN_FILE)
            finally:
                try:
                    temp_path.unlink()
                except FileNotFoundError:
                    pass
            return token
        finally:
            if fcntl is not None:
                fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)

# Doctor mode is a strictly read-only diagnostic path. Avoid creating the
# persistent browser token (or its lock file) when the backend is only being
# used to print a support report.
WEBUI_TOKEN = "" if _DOCTOR_MODE else _load_or_create_token()

# ---- Load agents from agents.json (single source of truth) ----
def _load_default_agents() -> list[tuple[str, Path]]:
    """Load agent list from agents.json, with hardcoded fallback."""
    try:
        if AGENTS_JSON_FILE.exists():
            with open(AGENTS_JSON_FILE, encoding="utf-8") as f:
                data = json.load(f)
            def _expand(p: str) -> str:
                p = (p or "").strip()
                # Only a leading '~' is the home shortcut; never touch later ones.
                if p == "~" or p.startswith("~/"):
                    return str(Path.home()) + p[1:]
                return p
            agents = []
            for a in data.get("agents", []):
                name = a.get("name", "")
                mac = _expand(a.get("mac_path", ""))
                if mac:
                    agents.append((name, Path(mac)))
                extra = _expand(a.get("mac_extra_path", ""))
                if extra:
                    agents.append((name, Path(extra)))
            if agents:
                return agents
    except Exception:
        pass
    # Fallback: hardcoded defaults (kept in sync with agents.json)
    return [
        ("Antigravity CLI",                Path.home() / ".gemini/config/skills"),
        ("Antigravity IDE",                Path.home() / ".gemini/antigravity/skills"),
        ("Codex",                          Path.home() / ".codex/skills"),
        ("Claude Code",                    Path.home() / ".claude/skills"),
        ("GitHub Copilot",                 Path.home() / ".copilot/skills"),
        ("Pi",                             Path.home() / ".pi/agent/skills"),
        ("OpenCode",                       Path.home() / ".config/opencode/skills"),
        ("Kimi Code",                      Path.home() / ".kimi/skills"),
        ("ZCode",                          Path.home() / ".zcode/skills"),
        ("Trae (Global)",                  Path.home() / ".trae/skills"),
        ("Trae (Global)",                  Path.home() / "Library/Application Support/Trae/skills"),
        ("Trae CN",                        Path.home() / ".trae-cn/skills"),
        ("Trae CN",                        Path.home() / "Library/Application Support/Trae-CN/skills"),
        ("OpenClaw",                       Path.home() / ".openclaw/skills"),
        ("Hermes Agent",                   Path.home() / ".hermes/skills"),
        ("Proma",                          Path.home() / ".proma/default-skills"),
        ("Cursor",                         Path.home() / ".cursor/skills"),
        ("Kiro Agent",                     Path.home() / ".kiro/skills"),
        ("Junie (JetBrains)",              Path.home() / ".junie/skills"),
        ("Cline",                          Path.home() / ".cline/skills"),
        ("Roo Code",                       Path.home() / ".roo/skills"),
        ("Run",                            Path.home() / ".run" / "global-skills" / "skills"),
        ("Warp",                           Path.home() / ".warp/skills"),
        ("Windsurf",                       Path.home() / ".codeium/windsurf/skills"),
        ("Firebender",                     Path.home() / ".firebender/skills"),
        ("Augment",                        Path.home() / ".augment/skills"),
        ("Continue",                       Path.home() / ".continue/skills"),
        ("Goose",                          Path.home() / ".config/goose/skills"),
        ("Agents (Standard)",              Path.home() / ".agents/skills"),
        ("Qoder",                          Path.home() / ".qoder/skills"),
        ("Qwen Code",                      Path.home() / ".qwen/skills"),
        ("CodeBuddy",                      Path.home() / ".codebuddy/skills"),
        ("Amp",                            Path.home() / ".config/agents/skills"),
        ("OpenHands",                      Path.home() / ".openhands/skills"),
        ("Kilo Code",                      Path.home() / ".kilocode/skills"),
        ("Zencoder",                       Path.home() / ".zencoder/skills"),
        ("iFlow CLI",                      Path.home() / ".iflow/skills"),
        ("Droid",                          Path.home() / ".factory/skills"),
        ("Devin for Terminal",             Path.home() / ".config/devin/skills"),
        ("WorkBuddy",                      Path.home() / ".workbuddy/skills"),
        ("QClaw",                          Path.home() / ".qclaw/skills"),
        ("CodeWhale",                      Path.home() / ".codewhale/skills"),
        ("QoderWork CN",                   Path.home() / ".qoderworkcn/skills"),
        ("Qoder CN",                       Path.home() / ".qoder-cn/skills"),
        ("MiniMax Code",                   Path.home() / ".mavis/agents/mavis/skills"),
    ]

DEFAULT_AGENTS = _load_default_agents()


def _load_default_instruction_paths() -> dict[str, str]:
    """Load the platform-specific default global instruction file per Agent."""
    result: dict[str, str] = {}
    try:
        data = json.loads(AGENTS_JSON_FILE.read_text(encoding="utf-8"))
        for agent in data.get("agents", []):
            name = str(agent.get("name", "")).strip()
            raw = str(agent.get("mac_instructions_file", "")).strip()
            if not name or not raw or name in result:
                continue
            expanded = str(Path.home()) + raw[1:] if raw == "~" or raw.startswith("~/") else raw
            result[name] = str(Path(expanded).expanduser())
    except (OSError, ValueError, TypeError):
        pass
    return result


DEFAULT_INSTRUCTION_PATHS = _load_default_instruction_paths()

# Ensure ~/.qoder-cn/skills exists — unlike other agents whose directories are
# created by their respective tools, Qoder CN relies on EasySkills to create
# the path if it does not already exist.
_qoder_cn_skills = Path.home() / ".qoder-cn" / "skills"
if not _DOCTOR_MODE and not _qoder_cn_skills.exists():
    _qoder_cn_skills.mkdir(parents=True, exist_ok=True)

EXCLUDE_NAMES = {"EasySkills维护工具", ".git", "node_modules", "dist", "docs", "instructions", "mcp", ".runtime", ".maintenance-bak"}

# Module-level constant: built once, not re-allocated on every get_agent_name() call.
_AGENT_PREFIX_MAP: list[tuple[str, str]] = [
    (".gemini/antigravity/", "Antigravity IDE"),
    (".gemini/",            "Antigravity CLI"),
    (".codex/",             "Codex"),
    (".claude/",            "Claude Code"),
    (".copilot/",           "GitHub Copilot"),
    (".pi/",                "Pi"),
    (".config/opencode/",   "OpenCode"),
    (".kimi/",              "Kimi Code"),
    (".zcode/",             "ZCode"),
    (".trae-cn/",           "Trae CN"),
    (".trae/",              "Trae (Global)"),
    (".openclaw/",          "OpenClaw"),
    (".hermes/",            "Hermes Agent"),
    (".proma/",             "Proma"),
    (".cursor/",            "Cursor"),
    (".kiro/",              "Kiro Agent"),
    (".junie/",             "Junie (JetBrains)"),
    (".cline/",             "Cline"),
    (".roo/",               "Roo Code"),
    (".warp/",              "Warp"),
    (".codeium/windsurf/",  "Windsurf"),
    (".firebender/",        "Firebender"),
    (".augment/",           "Augment"),
    (".continue/",          "Continue"),
    (".config/goose/",      "Goose"),
    (".qoder/",             "Qoder"),
    (".qwen/",              "Qwen Code"),
    (".codebuddy/",         "CodeBuddy"),
    (".config/agents/",     "Amp"),
    (".openhands/",         "OpenHands"),
    (".kilocode/",          "Kilo Code"),
    (".zencoder/",          "Zencoder"),
    (".iflow/",             "iFlow CLI"),
    (".factory/",           "Droid"),
    (".config/devin/",      "Devin for Terminal"),
    (".workbuddy/",         "WorkBuddy"),
    (".qclaw/",             "QClaw"),
    (".codewhale/",         "CodeWhale"),
    (".qoderworkcn/",       "QoderWork CN"),
    (".qoder-cn/",          "Qoder CN"),
    (".mavis/",             "MiniMax Code"),
    (".agents/",            "Agents (Standard)"),
    (".run/",               "Run"),
    ("Trae-CN/",            "Trae CN"),
    ("Trae/",               "Trae (Global)"),
]

GITHUB_REPO = "RunhuaHuang/EasySkills"
GITHUB_API_LATEST_RELEASE = f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest"
GITHUB_LATEST_RELEASE = f"https://github.com/{GITHUB_REPO}/releases/latest"
GITHUB_RELEASE_TAG_PREFIX = f"https://github.com/{GITHUB_REPO}/releases/tag/"

# Hosts permitted when fetching release artifacts during self-update. A tampered
# GitHub API response could otherwise point the downloader at an arbitrary server.
# GitHub's Releases API normally returns api.github.com tarball URLs which then
# redirect to codeload.github.com; all listed hosts are GitHub-owned delivery
# endpoints.
_GITHUB_TARBALL_HOSTS = {"api.github.com", "github.com", "codeload.github.com", "objects.githubusercontent.com"}
_WINDOWS_RESERVED_FILENAMES = {
    "CON", "PRN", "AUX", "NUL",
    *(f"COM{i}" for i in range(1, 10)),
    *(f"LPT{i}" for i in range(1, 10)),
}


def _is_portable_filename(name: str) -> bool:
    """Return whether *name* is a safe single component on Unix and Windows."""
    if not name or name.endswith((" ", ".")):
        return False
    if any(ord(char) < 32 or char in '<>:"/\\|?*' for char in name):
        return False
    return name.split(".", 1)[0].upper() not in _WINDOWS_RESERVED_FILENAMES

def _is_github_download_url(url: str) -> bool:
    """True only for https URLs whose host is a known GitHub delivery host."""
    try:
        parsed = urllib.parse.urlparse(url)
        # Userinfo and non-default ports change the trust boundary even when
        # the textual hostname still looks like github.com.  Release URLs are
        # ordinary HTTPS URLs and never need either form.
        port = parsed.port
    except ValueError:
        return False
    return (
        parsed.scheme.lower() == "https"
        and (parsed.hostname or "").lower() in _GITHUB_TARBALL_HOSTS
        and parsed.username is None
        and parsed.password is None
        and port in (None, 443)
    )

# Serializes all WebUI write operations within this process. Combined with the
# cross-process deploy lock below, this closes the WebUI-vs-launchd race: a
# launchd-triggered deploy.sh run_sync and a WebUI do_map no longer mutate the
# same agent-target symlinks concurrently.
_webui_write_lock = threading.RLock()


def _writes_locked(func):
    """Decorator: hold the process-wide write lock for the duration of *func*.

    Prevents concurrent ThreadingMixIn requests from racing on CENTRAL_DIR /
    config mutations (e.g. do_map iterating while delete_skill rmtree's a dir).
    """
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        with _webui_write_lock:
            return func(*args, **kwargs)

    return wrapper


# ──────────────────────────────────────────────────────────────
# Cross-process deploy lock — mirrors deploy.sh's mkdir-based .deploy.lock.d
# ──────────────────────────────────────────────────────────────
# WebUI write operations (do_map / do_unmap / delete_skill / import_skill_folder)
# mutate the SAME agent-target symlink trees that launchd/systemd-triggered
# deploy.sh run_sync walks. Previously these two code paths held unrelated locks
# (a Python RLock vs bash's .deploy.lock.d), so they could interleave on one
# target path and produce ENOENT/EEXIST races. Operations that touch agent
# targets directly (not via run_deploy, which already takes the bash lock) now
# acquire THIS lock so they exclude an in-flight watcher sync.

_DEPLOY_LOCK_TIMEOUT = 10.0  # seconds; bounded so a WebUI request never hangs
_deploy_lock_state = threading.local()


def _inherited_deploy_lock_held(lock_dir: Path) -> bool:
    """Return whether this child process is intentionally running under a parent lock.

    A locked WebUI operation may invoke ``deploy.sh``/``webui.py --sync-rules``.
    Those children must participate in the parent's critical section instead of
    waiting on the same on-disk lock.  The marker is accepted only when the lock
    directory still records the advertised live parent PID; a stray environment
    variable therefore cannot bypass a missing or unrelated lock.
    """
    if os.environ.get("EASYSKILLS_DEPLOY_LOCK_HELD") != "1":
        return False
    owner = os.environ.get("EASYSKILLS_DEPLOY_LOCK_PID", "").strip()
    if not owner.isdigit() or owner == str(os.getpid()):
        return False
    try:
        recorded = (lock_dir / "pid").read_text(encoding="utf-8").strip()
        os.kill(int(owner), 0)
    except (OSError, ValueError):
        return False
    return recorded == owner


@contextlib.contextmanager
def _cross_process_deploy_lock(timeout: float = _DEPLOY_LOCK_TIMEOUT):
    """Acquire deploy.sh's cross-process lock from within the WebUI process.

    Uses the same mkdir-atomic ``.deploy.lock.d`` directory and PID stamping as
    deploy.sh, including stale-lock reclamation via atomic rename. On Windows,
    deploy.ps1 uses a named mutex instead of this dir lock, so the interop only
    applies on POSIX (webui.py is the macOS/Linux backend); on Windows the
    webui.ps1 backend owns its own synchronization.
    """
    lock_base = SCRIPT_DIR / ".deploy.lock"
    lock_dir = Path(str(lock_base) + ".d")
    pid_file = lock_dir / "pid"

    # A single request can legitimately compose several locked helpers (for
    # example add_mcp_server -> save_mcp_config or update_agent_paths ->
    # do_map).  The on-disk lock is process-wide, so treat nested acquisition
    # on the same thread as re-entrant instead of waiting on our own PID until
    # the timeout expires.  The outermost context remains responsible for the
    # actual directory cleanup.
    if (
        getattr(_deploy_lock_state, "depth", 0) > 0
        and getattr(_deploy_lock_state, "lock_dir", "") == str(lock_dir)
    ):
        _deploy_lock_state.depth += 1
        try:
            yield True
        finally:
            _deploy_lock_state.depth -= 1
        return

    # A child deploy/webui process inherits the parent's lock marker. Treat the
    # parent-owned lock as already held, but never trust the marker without
    # matching the on-disk PID stamp and a live owner check.
    if _inherited_deploy_lock_held(lock_dir):
        yield True
        return

    deadline = time.monotonic() + timeout
    acquired = False
    poll = 0.1

    def _stamp_pid() -> None:
        try:
            pid_file.write_text(str(os.getpid()), encoding="utf-8")
        except OSError:
            pass

    def _pid_alive(pid: str) -> bool:
        pid = pid.strip()
        if not pid:
            return False
        try:
            os.kill(int(pid), 0)
        except (OSError, ValueError):
            return False
        return True

    try:
        while True:
            try:
                os.mkdir(lock_dir)  # atomic on POSIX and Windows
                _stamp_pid()
                acquired = True
                break
            except OSError as exc:
                if exc.errno != errno.EEXIST:
                    raise
                # Lock exists — is the holder alive?
                try:
                    holder = pid_file.read_text(encoding="utf-8")
                except (OSError, ValueError):
                    holder = ""
                if not holder:
                    # Creator may still be writing the PID; give it a moment.
                    time.sleep(0.1)
                    try:
                        holder = pid_file.read_text(encoding="utf-8")
                    except (OSError, ValueError):
                        holder = ""
                if holder and not _pid_alive(holder):
                    # Stale lock. Atomically rename it away (only the current
                    # owner of the live dir can win this race), then mkdir.
                    # Mirrors deploy.sh's reclaim logic.
                    stale = Path(str(lock_dir) + f".stale.{os.getpid()}")
                    try:
                        os.replace(lock_dir, stale)
                        shutil.rmtree(stale, ignore_errors=True)
                    except OSError:
                        pass
                    continue
                if time.monotonic() >= deadline:
                    break
                time.sleep(poll)
        if acquired:
            _deploy_lock_state.lock_dir = str(lock_dir)
            _deploy_lock_state.depth = 1
        yield acquired
    finally:
        if acquired:
            # Only remove the dir we created. Another process may have reclaimed
            # a stale lock in the meantime; verify the PID stamp is still ours.
            try:
                current = pid_file.read_text(encoding="utf-8").strip()
            except (OSError, ValueError):
                current = ""
            if current == str(os.getpid()):
                shutil.rmtree(lock_dir, ignore_errors=True)
            _deploy_lock_state.depth = 0
            _deploy_lock_state.lock_dir = ""


def _writes_locked_proc(func):
    """Decorator: hold BOTH the in-process write lock and the cross-process
    deploy lock. Use for operations that mutate agent-target symlink trees
    directly (do_map / do_unmap / delete_skill). A timed-out lock is a hard
    failure: proceeding anyway would reintroduce the exact watcher/WebUI race
    this lock is meant to prevent."""
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        with _webui_write_lock, _cross_process_deploy_lock() as held:
            if not held:
                return {
                    "success": False,
                    "message": "Another EasySkills synchronization is still running. Please retry shortly.",
                }
            return func(*args, **kwargs)
    return wrapper


# ──────────────────────────────────────────────────────────────
# Data helpers
# ──────────────────────────────────────────────────────────────

def get_agent_root(target: Path) -> Path:
    home = Path.home()
    lib_app = home / "Library" / "Application Support"
    try:
        rel = target.relative_to(lib_app)
        if not rel.parts:
            return lib_app
        return lib_app / rel.parts[0]
    except ValueError:
        pass
    try:
        rel = target.relative_to(home)
        if not rel.parts:
            return home
        if len(rel.parts) > 1 and rel.parts[0] == ".config":
            return home / ".config" / rel.parts[1]
        return home / rel.parts[0]
    except ValueError:
        pass
    return target.parent


def get_skills():
    skills = []
    if CENTRAL_DIR.exists():
        for item in sorted(CENTRAL_DIR.iterdir()):
            if (item.is_dir()
                    and not item.name.startswith(("_", "."))
                    and item.name not in EXCLUDE_NAMES):
                # An external-link skill is a symlink (Path.is_symlink()) whose
                # target still exists — is_dir() follows the link and is True,
                # so it is still listed and forwarded normally. The flag lets
                # the UI mark it fragile. (Dangling symlinks have is_dir()==False
                # and are excluded here, mirroring the old behaviour; run_sync
                # prunes them server-side.)
                skills.append({
                    "name": item.name,
                    "path": str(item),
                    "has_skill_md": (item / "SKILL.md").exists() or (item / "README_SYSTEM.md").exists(),
                    "is_external_link": item.is_symlink(),
                })
    return skills


def get_central_dir_warnings() -> dict:
    """Count link-health issues in the central dir for /api/status.

    Read-only status probe mirroring run_sync's PART A.5 detection so the
    dashboard can surface problems without a sync. Dangling links (target gone)
    are auto-pruned by run_sync; external links (valid symlink) are forwarded
    but fragile. See run_sync in deploy.sh for the authoritative pruning logic.
    """
    dangling = 0
    external = 0
    if CENTRAL_DIR.exists():
        try:
            for item in CENTRAL_DIR.iterdir():
                if item.name.startswith(("_", ".")) or item.name in EXCLUDE_NAMES:
                    continue
                if not item.is_symlink():
                    continue
                # exists() follows the symlink: False => dangling, True => external
                if item.exists():
                    external += 1
                else:
                    dangling += 1
        except OSError:
            pass
    return {"dangling_count": dangling, "external_link_count": external}


def get_custom_targets():
    if not CUSTOM_TARGETS_FILE.exists():
        return []
    lines = []
    try:
        content = CUSTOM_TARGETS_FILE.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return []
    for line in content.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            lines.append(line)
    return lines


def _normalize_local_path(path_str: str) -> str:
    raw = str(path_str or "").strip()
    if not raw:
        return ""
    path = Path(raw).expanduser()
    try:
        return str(path.resolve())
    except (OSError, ValueError):
        return str(path)


def _validate_mapping_target(path_str: str, *, require_existing: bool = False) -> tuple[Path | None, str]:
    """Validate an Agent skills directory without changing filesystem state."""
    if not isinstance(path_str, str) or not path_str.strip():
        return None, "Target path cannot be empty"
    target = Path(_normalize_local_path(path_str))
    if require_existing and not target.exists():
        return None, "Path does not exist"
    if target.is_symlink() and not target.exists():
        return None, "Target path must be a directory"
    if target.exists() and not target.is_dir():
        return None, "Target path must be a directory"
    try:
        central_resolved = CENTRAL_DIR.resolve()
        target_resolved = target.resolve()
    except (OSError, RuntimeError) as exc:
        return None, f"Invalid target path: {exc}"
    if target_resolved == central_resolved or central_resolved in target_resolved.parents:
        return None, "Target path cannot be the EasySkills library or one of its subdirectories"
    return target, ""


def _load_agent_path_configs() -> list[dict]:
    try:
        data = json.loads(AGENT_PATH_CONFIG_FILE.read_text(encoding="utf-8"))
        entries = data.get("agents", [])
        if isinstance(entries, list):
            return [entry for entry in entries if isinstance(entry, dict)]
    except (OSError, ValueError, TypeError):
        pass
    return []


def _save_agent_path_configs(entries: list[dict]) -> None:
    payload = {"version": 1, "agents": entries}
    _atomic_write_text(
        AGENT_PATH_CONFIG_FILE,
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
    )


def _instruction_path_for_agent(name: str, skills_path: str, configs: list[dict]) -> str:
    normalized_skills = _normalize_local_path(skills_path)
    for entry in configs:
        if _normalize_local_path(str(entry.get("skills_path", ""))) != normalized_skills:
            continue
        configured = str(entry.get("instructions_path", "")).strip()
        if configured:
            return _normalize_local_path(configured)
    default_path = DEFAULT_INSTRUCTION_PATHS.get(name, "")
    return _normalize_local_path(default_path) if default_path else ""


def is_mapped(target_path: str, disabled_set: set[str], has_skills: bool) -> bool:
    try:
        norm_path = str(Path(target_path).expanduser().resolve())
    except Exception:
        norm_path = str(Path(target_path).expanduser())
        
    if norm_path in disabled_set:
        return False
        
    target = Path(target_path)
    if not target.exists() or not target.is_dir():
        return False
        
    if not has_skills:
        # No skills => no links can exist; reporting "mapped" would inflate
        # the dashboard. The disabled/exists checks above still apply.
        return False
        
    try:
        central_resolved = CENTRAL_DIR.resolve()
        for item in target.iterdir():
            if item.is_symlink() and _link_points_into_central(item, central_resolved):
                return True
    except Exception:
        pass
    return False


def _link_points_into_central(link: Path, central_resolved: Path | None = None) -> bool:
    """Return whether *link* lexically targets this EasySkills library.

    Deliberately do not call ``resolve()`` on the final link target. A supported
    central skill may itself be a symlink to an external folder; fully resolving
    the Agent-side link would jump through that second link and incorrectly
    classify it as foreign, making mapped status, unmap, and delete disagree.
    """
    try:
        raw_target = Path(os.readlink(str(link)))
        target = raw_target if raw_target.is_absolute() else link.parent / raw_target
        # Resolve only the parent to normalize ``..`` without following the
        # final central skill symlink.
        lexical_target = target.parent.resolve() / target.name
        central = central_resolved or CENTRAL_DIR.resolve()
        return lexical_target == central or central in lexical_target.parents
    except (OSError, RuntimeError, ValueError):
        return False


def is_proma_workspace_target(path: str) -> bool:
    normalized = path.replace("\\", "/").lower()
    return "/.proma/agent-workspaces/" in normalized


def get_agent_name(path: str) -> str:
    home = str(Path.home())
    lib_app = str(Path.home() / "Library" / "Application Support")
    rel = path
    if path.startswith(lib_app + os.sep):
        rel = path[len(lib_app) + 1:]
    elif path.startswith(home + os.sep):
        rel = path[len(home) + 1:]
    rel_lower = rel.lower()
    for prefix, name in _AGENT_PREFIX_MAP:
        if rel_lower.startswith(prefix):
            return name
    return "Custom Agent"


def get_agents():
    custom_targets = get_custom_targets()
    custom_overrides = {}
    custom_list = []
    
    for line in custom_targets:
        name, raw_path = _target_line_parts(line)
        if name:
            path = _normalize_local_path(raw_path)
            if not path:
                continue
            if is_proma_workspace_target(path):
                continue
            custom_overrides[name] = path
        else:
            path = _normalize_local_path(line)
            if not path:
                continue
            if is_proma_workspace_target(path):
                continue
            name = get_agent_name(path)
            custom_list.append((name, path))

    seen: set[str] = set()
    agents = []
    disabled_set = _get_disabled_targets()
    has_skills = len(get_skills()) > 0
    path_configs = _load_agent_path_configs()

    # 1. Add Default Agents (checking for overrides)
    matched_override_names: set[str] = set()
    for name, default_path in DEFAULT_AGENTS:
        if name in custom_overrides:
            matched_override_names.add(name)
        path_str = custom_overrides.get(name, str(default_path))
        path_key = _normalize_local_path(path_str)
        if path_key in seen:
            continue
        seen.add(path_key)
        p = Path(path_str)
        agent_root = get_agent_root(p)
        active = agent_root.exists()
        instructions_path = _instruction_path_for_agent(name, path_str, path_configs)
        
        agents.append({
            "name": name,
            "path": path_str,
            "instructions_path": instructions_path,
            "instructions_exists": bool(instructions_path and Path(instructions_path).is_file()),
            "active": active,
            "mapped": is_mapped(path_str, disabled_set, has_skills),
            "custom": name in custom_overrides,
        })

    # Named custom-target rows whose name matched no default agent must stay
    # visible, otherwise a user-edited override would silently disappear.
    for name, path_str in custom_overrides.items():
        if name not in matched_override_names:
            custom_list.append((name, path_str))

    # 2. Add Custom Agents (that don't match any default name override)
    for name, path_str in custom_list:
        path_key = _normalize_local_path(path_str)
        if path_key in seen:
            continue
        seen.add(path_key)
        p = Path(path_str)
        active = get_agent_root(p).exists()
        instructions_path = _instruction_path_for_agent(name, path_str, path_configs)

        agents.append({
            "name": name,
            "path": path_str,
            "instructions_path": instructions_path,
            "instructions_exists": bool(instructions_path and Path(instructions_path).is_file()),
            "active": active,
            "mapped": is_mapped(path_str, disabled_set, has_skills),
            "custom": True,
        })

    return agents


def is_proma_workspace_agent(agent: dict) -> bool:
    name = str(agent.get("name", ""))
    path = str(agent.get("path", ""))
    return name.startswith("Proma Workspace") or is_proma_workspace_target(path)


def get_visible_agents():
    return [agent for agent in get_agents() if not is_proma_workspace_agent(agent)]


def get_version():
    version_file = SCRIPT_DIR / ".version"
    if version_file.exists():
        return version_file.read_text(encoding="utf-8").strip()
    return "unknown"


# ──────────────────────────────────────────────────────────────
# Instruction-rule library: modular AGENTS.md / CLAUDE.md management
# ──────────────────────────────────────────────────────────────

def _load_instruction_targets() -> list[tuple[str, Path]]:
    """Return configured instruction files for visible Agents, de-duplicated."""
    targets: list[tuple[str, Path]] = []
    seen: set[str] = set()
    for agent in get_visible_agents():
        raw = str(agent.get("instructions_path", "")).strip()
        if not raw:
            continue
        path = Path(raw).expanduser()
        resolved = _normalize_local_path(raw)
        if resolved in seen:
            continue
        seen.add(resolved)
        targets.append((str(agent.get("name", "")), path))
    return targets


def _instruction_target_activity() -> dict[str, bool]:
    """Return instruction-file activity, folding aliases that share one file."""
    activity: dict[str, bool] = {}
    for agent in get_visible_agents():
        raw = str(agent.get("instructions_path", "")).strip()
        if not raw:
            continue
        key = _normalize_local_path(raw)
        activity[key] = activity.get(key, False) or bool(agent.get("active"))
    return activity


def _detected_instruction_targets() -> list[tuple[str, Path]]:
    """Return de-duplicated instruction targets belonging to detected agents."""
    activity = _instruction_target_activity()
    return [
        (name, path)
        for name, path in _load_instruction_targets()
        if activity.get(str(path.resolve()), False)
    ]


def _validate_instruction_name(name: str) -> tuple[bool, str]:
    """Validate a rule filename (must be safe, end with .md)."""
    if not isinstance(name, str):
        return False, "Rule name must be text"
    if name != name.strip():
        return False, "Invalid rule name"
    if not name:
        return False, "Rule name cannot be empty"
    if "/" in name or "\\" in name or "\x00" in name:
        return False, "Invalid rule name"
    if name in (".", "..") or not _is_portable_filename(name):
        return False, "Invalid rule name"
    if name.lower().endswith(".md"):
        name = name[:-3] + ".md"
    else:
        name = name + ".md"
    return True, name


def _build_managed_block(rules: dict[str, str], legacy_text: str = "") -> str:
    """Build a context-minimal block with only the outer begin/end markers."""
    parts = [rules[name].strip() for name in sorted(rules, key=str.casefold)]
    if legacy_text.strip():
        parts.append(legacy_text.strip())
    return f"{EASY_SKILLS_BEGIN}\n" + "\n\n".join(parts) + f"\n{EASY_SKILLS_END}"


def _managed_body(rules: dict[str, str], legacy_text: str = "") -> str:
    """Return the exact marker-free body emitted by _build_managed_block."""
    block = _build_managed_block(rules, legacy_text)
    return block[len(EASY_SKILLS_BEGIN) + 1:-(len(EASY_SKILLS_END) + 1)]


def _instruction_state_key(path: Path) -> str:
    return str(path.expanduser().resolve())


def _load_instruction_sync_state() -> dict:
    try:
        data = json.loads(INSTRUCTION_SYNC_STATE_FILE.read_text(encoding="utf-8"))
        if isinstance(data, dict) and isinstance(data.get("targets"), list):
            return data
    except (OSError, ValueError, TypeError):
        pass
    return {"version": 1, "targets": []}


def _save_instruction_sync_state(state: dict) -> None:
    payload = json.dumps(state, ensure_ascii=False, indent=2) + "\n"
    _atomic_write_text(INSTRUCTION_SYNC_STATE_FILE, payload)


def _instruction_state_entry(path: Path) -> dict | None:
    key = _instruction_state_key(path)
    for entry in _load_instruction_sync_state().get("targets", []):
        if isinstance(entry, dict) and entry.get("path") == key:
            return entry
    return None


def _set_instruction_state(path: Path, rules: dict[str, str], legacy_text: str = "") -> None:
    state = _load_instruction_sync_state()
    key = _instruction_state_key(path)
    body = _managed_body(rules, legacy_text)
    entry = {
        "path": key,
        "rules": [
            {"name": name, "content": rules[name]}
            for name in sorted(rules, key=str.casefold)
        ],
        "legacy": legacy_text,
        "body_sha256": hashlib.sha256(body.strip().encode("utf-8")).hexdigest(),
    }
    targets = [
        item for item in state.get("targets", [])
        if not isinstance(item, dict) or item.get("path") != key
    ]
    targets.append(entry)
    state["version"] = 1
    state["targets"] = targets
    _save_instruction_sync_state(state)


def _remove_instruction_state(path: Path) -> None:
    state = _load_instruction_sync_state()
    key = _instruction_state_key(path)
    targets = [
        item for item in state.get("targets", [])
        if not isinstance(item, dict) or item.get("path") != key
    ]
    if len(targets) == len(state.get("targets", [])):
        return
    state["targets"] = targets
    if targets:
        _save_instruction_sync_state(state)
    else:
        try:
            INSTRUCTION_SYNC_STATE_FILE.unlink()
        except FileNotFoundError:
            pass


def _purge_all_managed_markers(text: str) -> str:
    """Remove EVERY managed block AND every orphan begin/end marker from text.

    A file should never carry more than one begin/end pair. Repeated pairs can
    arise when a user copy-pastes a block, or when an older begin-marker alias
    (e.g. an em-dash variant decoded with the wrong code page) stops matching,
    leaving the previous block behind while a new one is appended. Without this
    purge, the count=1 substitution below would only ever touch the first block
    and leave the rest as permanent, unmanageable residue.

    Markers are paired with a stack (each ``end`` matches the nearest preceding
    unmatched ``begin``). Only matched spans are dropped as managed blocks, so
    plain text sitting between an orphan ``begin`` and the real block is kept —
    a naive ``begin.*?end`` regex would instead swallow that user content.
    Unmatched ``begin``/``end`` markers are removed afterwards as orphans.

    begin/end aliases are tolerated on read; only the canonical markers are
    ever written.
    """
    # 1) Collect every begin (any alias) and end marker position.
    markers: list[tuple[int, str, int]] = []
    for alias in EASY_SKILLS_BEGIN_ALIASES:
        start = 0
        while True:
            idx = text.find(alias, start)
            if idx == -1:
                break
            markers.append((idx, "begin", len(alias)))
            start = idx + len(alias)
    start = 0
    while True:
        idx = text.find(EASY_SKILLS_END, start)
        if idx == -1:
            break
        markers.append((idx, "end", len(EASY_SKILLS_END)))
        start = idx + len(EASY_SKILLS_END)
    markers.sort()

    # 2) Stack-pair: each end closes the nearest open begin.
    spans: list[tuple[int, int]] = []  # (begin_start, end_pos_after_marker)
    stack: list[tuple[int, int]] = []
    for idx, kind, length in markers:
        if kind == "begin":
            stack.append((idx, length))
        else:  # end
            if stack:
                b_idx, _b_len = stack.pop()
                spans.append((b_idx, idx + length))
            # an end with no open begin is an orphan, handled in step 4.

    # 3) Drop matched spans (trailing newline/CRLF absorbed), back-to-front.
    for b_idx, end_pos in sorted(spans, reverse=True):
        absorb = end_pos
        if absorb < len(text) and text[absorb] == "\n":
            absorb += 1
        elif absorb + 1 <= len(text) and text[absorb:absorb + 2] == "\r\n":
            absorb += 2
        text = text[:b_idx] + text[absorb:]

    # 4) Remove any remaining orphan begin/end markers.
    for alias in EASY_SKILLS_BEGIN_ALIASES:
        text = text.replace(alias, "")
    text = text.replace(EASY_SKILLS_END, "")
    return text


def _inject_managed_block(existing: str, block: str) -> str:
    """Insert or replace the managed block inside an instruction file's content.

    - No existing content  → block alone.
    - Has managed block    → replace the old block with the new one.
    - No managed block     → append block (separated by a blank line).

    Any duplicate/orphan markers from copy-paste or legacy aliases are purged
    first so the file is left with at most one clean block.
    """
    has_block = EASY_SKILLS_END in existing and any(
        marker in existing for marker in EASY_SKILLS_BEGIN_ALIASES
    )
    if has_block:
        # Purge ALL prior blocks/markers, then re-inject a single fresh block.
        user_content = _purge_all_managed_markers(existing)
        if user_content.strip():
            return user_content.rstrip() + "\n\n" + block + "\n"
        return block + "\n"
    if existing.strip():
        return existing.rstrip() + "\n\n" + block + "\n"
    return block + "\n"


def _strip_managed_block(content: str) -> str:
    """Remove the managed block from content, returning the remainder.

    Purges every block and every orphan marker (not just the first), so
    duplicate blocks pasted by the user cannot linger, and an orphan begin
    marker cannot cause the user's own content to be eaten.
    """
    if EASY_SKILLS_END not in content and not any(
        marker in content for marker in EASY_SKILLS_BEGIN_ALIASES
    ):
        return content
    return _purge_all_managed_markers(content)


def _rule_library(rule_names: list[str] | None = None) -> tuple[dict[str, str], str | None]:
    """Load an explicit rule selection, returning a useful validation error."""
    if rule_names is not None and (
        not isinstance(rule_names, list)
        or any(not isinstance(name, str) for name in rule_names)
    ):
        return {}, "Rules must be a list of rule names."
    if rule_names is not None and not rule_names:
        return {}, "Select at least one rule."
    requested = None
    if rule_names is not None:
        requested = set()
        for name in rule_names:
            valid, clean = _validate_instruction_name(name)
            if not valid:
                return {}, clean
            requested.add(clean)

    rules: dict[str, str] = {}
    if INSTRUCTIONS_DIR.exists():
        for item in sorted(INSTRUCTIONS_DIR.iterdir()):
            if (
                item.is_file()
                and item.suffix == ".md"
                and not item.name.startswith(".")
                and (requested is None or item.name in requested)
            ):
                try:
                    rules[item.name] = item.read_text(encoding="utf-8").strip()
                except (OSError, UnicodeError) as exc:
                    return {}, f"Could not read rule {item.name}: {exc}"
    if requested is not None:
        missing = sorted(requested - set(rules))
        if missing:
            return {}, f"Rule(s) not found: {', '.join(missing)}"
    return rules, None


def _managed_rules(content: str, path: Path | None = None) -> tuple[dict[str, str], str]:
    """Read state-backed or historical managed rules and preserve unknown content."""
    import re
    from urllib.parse import unquote

    begin_pattern = "(?:" + "|".join(re.escape(marker) for marker in EASY_SKILLS_BEGIN_ALIASES) + ")"
    outer = re.search(
        begin_pattern + r"\r?\n?(.*?)\r?\n?" + re.escape(EASY_SKILLS_END),
        content,
        re.DOTALL,
    )
    if not outer:
        return {}, ""

    body = outer.group(1)
    rules: dict[str, str] = {}

    # Previous compact format: one label per rule. It remains readable so the
    # next write can migrate it to the marker-free, state-backed format.
    compact_marker = re.compile(
        r"<!-- EasySkills:(rule ([^\r\n]+?)|legacy) -->\r?\n?"
    )
    compact_matches = list(compact_marker.finditer(body))
    if compact_matches:
        unmatched = []
        prefix = body[:compact_matches[0].start()].strip()
        if prefix:
            unmatched.append(prefix)
        for index, match in enumerate(compact_matches):
            segment_end = (
                compact_matches[index + 1].start()
                if index + 1 < len(compact_matches)
                else len(body)
            )
            segment = body[match.end():segment_end].strip()
            if match.group(1) == "legacy":
                if segment:
                    unmatched.append(segment)
            else:
                rules[unquote(match.group(2))] = segment
        return rules, "\n\n".join(unmatched)

    # Historical verbose format.
    verbose_marker = re.compile(
        r"<!-- EasySkills:rule:begin ([^\r\n]+?) -->\r?\n?(.*?)\r?\n?<!-- EasySkills:rule:end -->",
        re.DOTALL,
    )
    unmatched = []
    cursor = 0
    for match in verbose_marker.finditer(body):
        gap = body[cursor:match.start()].strip()
        if gap:
            unmatched.append(gap)
        rules[unquote(match.group(1))] = match.group(2).strip()
        cursor = match.end()
    tail = body[cursor:].strip()
    if tail:
        unmatched.append(tail)

    legacy = "\n\n".join(unmatched)

    # Current marker-free format: rule identities and snapshots live in a
    # hidden EasySkills state file instead of consuming Agent context tokens.
    if not rules and path is not None:
        entry = _instruction_state_entry(path)
        if entry:
            expected_hash = entry.get("body_sha256", "")
            actual_hash = hashlib.sha256(body.strip().encode("utf-8")).hexdigest()
            state_rules = entry.get("rules", [])
            if expected_hash == actual_hash and isinstance(state_rules, list):
                restored: dict[str, str] = {}
                valid = True
                for item in state_rules:
                    if not isinstance(item, dict) or not isinstance(item.get("name"), str) or not isinstance(item.get("content"), str):
                        valid = False
                        break
                    restored[item["name"]] = item["content"]
                if valid:
                    return restored, entry.get("legacy", "") if isinstance(entry.get("legacy", ""), str) else ""

    if legacy and not rules:
        # Recover rule identities from the old "---" concatenation whenever
        # the content still matches files in the current library.
        library, _ = _rule_library()
        by_content: dict[str, list[str]] = {}
        for name, rule_content in library.items():
            by_content.setdefault(rule_content.strip(), []).append(name)
        unresolved = []
        for part in legacy.split("\n\n---\n\n"):
            candidates = by_content.get(part.strip(), [])
            name = next((n for n in candidates if n not in rules), None)
            if name:
                rules[name] = part.strip()
            elif part.strip():
                unresolved.append(part.strip())
        legacy = "\n\n---\n\n".join(unresolved)
    return rules, legacy


def _managed_rule_count(content: str, path: Path | None = None) -> int:
    """Count both labelled rules and unresolved rules from the legacy format."""
    rules, legacy = _managed_rules(content, path)
    legacy_parts = [part for part in legacy.replace("\r\n", "\n").split("\n\n---\n\n") if part.strip()]
    return len(rules) + len(legacy_parts)


def get_instructions() -> dict:
    """List rule files in the instructions library + per-agent write status."""
    rules = []
    if INSTRUCTIONS_DIR.exists():
        for item in sorted(INSTRUCTIONS_DIR.iterdir()):
            if item.is_file() and item.suffix == ".md" and not item.name.startswith("."):
                read_error = ""
                try:
                    content = item.read_text(encoding="utf-8")
                except (OSError, UnicodeError) as exc:
                    content = ""
                    read_error = str(exc)
                rules.append({
                    "name": item.name,
                    "preview": content[:200],
                    "size": len(content),
                    "read_error": read_error,
                })

    targets = _load_instruction_targets()
    target_activity = _instruction_target_activity()
    agents_status = []
    for name, path in targets:
        has_block = False
        managed_rules = []
        managed_rule_count = 0
        exists = path.is_file()
        if exists:
            try:
                text = path.read_text(encoding="utf-8")
                has_block = any(marker in text for marker in EASY_SKILLS_BEGIN_ALIASES)
                if has_block:
                    managed_rules = list(_managed_rules(text, path)[0])
                    managed_rule_count = _managed_rule_count(text, path)
            except (OSError, UnicodeError):
                pass
        agents_status.append({
            "name": name,
            "path": str(path),
            "exists": exists,
            "active": target_activity.get(str(path.resolve()), False),
            "has_managed_block": has_block,
            "managed_rules": managed_rules,
            "managed_rule_count": managed_rule_count,
        })

    return {
        "success": True,
        "rules": rules,
        "agents": agents_status,
    }


@_writes_locked_proc
def save_instruction(name: str, content: str) -> dict:
    """Create or overwrite a single rule file in the instructions library."""
    valid, clean = _validate_instruction_name(name)
    if not valid:
        return {"success": False, "message": clean}
    if not isinstance(content, str):
        return {"success": False, "message": "Rule content must be text"}
    try:
        INSTRUCTIONS_DIR.mkdir(parents=True, exist_ok=True)
        collision = _casefold_child(INSTRUCTIONS_DIR, clean)
        if collision is not None and collision.name != clean:
            return {"success": False, "message": f"Rule name conflicts case-insensitively with: {collision.name}"}
        _atomic_write_text(INSTRUCTIONS_DIR / clean, content)
    except OSError as e:
        return {"success": False, "message": f"Save failed: {e}"}
    return {"success": True, "message": f"Saved rule: {clean}", "name": clean}


@_writes_locked_proc
def delete_instruction(name: str) -> dict:
    """Delete a single rule file from the instructions library."""
    valid, clean = _validate_instruction_name(name)
    if not valid:
        return {"success": False, "message": clean}
    target = INSTRUCTIONS_DIR / clean
    if not target.exists():
        return {"success": False, "message": f"Rule not found: {clean}"}
    try:
        target.unlink()
    except OSError as e:
        return {"success": False, "message": f"Delete failed: {e}"}
    return {"success": True, "message": f"Deleted rule: {clean}", "name": clean}


@_writes_locked
def get_instruction_content(name: str) -> dict:
    """Read the full content of a single rule file (for the editor)."""
    valid, clean = _validate_instruction_name(name)
    if not valid:
        return {"success": False, "message": clean}
    target = INSTRUCTIONS_DIR / clean
    if not target.exists():
        return {"success": False, "message": f"Rule not found: {clean}"}
    try:
        content = target.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return {"success": False, "message": f"Read failed: {exc}"}
    return {"success": True, "name": clean, "content": content}


def _atomic_write_text(path: Path, content: str) -> None:
    """Replace a UTF-8 text file atomically without exposing partial content."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=str(path.parent),
    )
    temp_path = Path(temp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        if path.exists() and not path.is_symlink():
            shutil.copystat(path, temp_path)
        os.replace(temp_path, path)
    finally:
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass


def _atomic_copy_file(source: Path, destination: Path) -> None:
    """Copy a file without following a pre-existing destination symlink."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(
        prefix=f".{destination.name}.",
        suffix=".tmp",
        dir=str(destination.parent),
    )
    temp_path = Path(temp_name)
    try:
        with source.open("rb") as source_handle, os.fdopen(fd, "wb") as destination_handle:
            shutil.copyfileobj(source_handle, destination_handle)
            destination_handle.flush()
            os.fsync(destination_handle.fileno())
        os.chmod(temp_path, 0o600)
        os.replace(temp_path, destination)
    finally:
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass


def _write_to_one(path: Path, rules: dict[str, str], *, replace: bool = False) -> bool:
    """Add or refresh named rules in one instruction file."""
    try:
        path = path.resolve()
        path.parent.mkdir(parents=True, exist_ok=True)
        existing = path.read_text(encoding="utf-8") if path.exists() else ""
        current, legacy = _managed_rules(existing, path)
        state_entry = _instruction_state_entry(path)
        state_matches = bool(
            state_entry
            and state_entry.get("body_sha256")
            == hashlib.sha256(legacy.strip().encode("utf-8")).hexdigest()
        )
        if (
            not replace
            and
            EASY_SKILLS_BEGIN in existing
            and "EasySkills:rule" not in existing
            and legacy.strip()
            and not current
            and not state_matches
        ):
            return False
        if replace:
            current, legacy = {}, ""
        current.update(rules)
        block = _build_managed_block(current, legacy)
        new_content = _inject_managed_block(existing, block)
        body = _managed_body(current, legacy)
        new_entry = {
            "path": _instruction_state_key(path),
            "rules": [
                {"name": name, "content": current[name]}
                for name in sorted(current, key=str.casefold)
            ],
            "legacy": legacy,
            "body_sha256": hashlib.sha256(body.strip().encode("utf-8")).hexdigest(),
        }
        if existing == new_content and state_entry == new_entry:
            return True
        previous_state = _instruction_state_entry(path)
        _set_instruction_state(path, current, legacy)
        try:
            _atomic_write_text(path, new_content)
        except Exception:
            if previous_state is None:
                _remove_instruction_state(path)
            else:
                state = _load_instruction_sync_state()
                key = _instruction_state_key(path)
                state["targets"] = [
                    item for item in state.get("targets", [])
                    if not isinstance(item, dict) or item.get("path") != key
                ] + [previous_state]
                _save_instruction_sync_state(state)
            raise
        return True
    except (OSError, UnicodeError):
        return False


def _remove_from_one(path: Path) -> bool:
    """Remove the managed block from a single instruction file."""
    try:
        path = path.resolve()
        if not path.exists():
            _remove_instruction_state(path)
            return True
        existing = path.read_text(encoding="utf-8")
        if not any(marker in existing for marker in EASY_SKILLS_BEGIN_ALIASES) or EASY_SKILLS_END not in existing:
            _remove_instruction_state(path)
            return True
        remaining = _strip_managed_block(existing)
        previous_state = _instruction_state_entry(path)
        if remaining.strip():
            new_content = remaining.rstrip() + "\n"
            if existing == new_content and previous_state is None:
                return True
            if existing != new_content:
                _atomic_write_text(path, new_content)
        else:
            path.unlink()
        _remove_instruction_state(path)
        return True
    except (OSError, UnicodeError):
        return False


def _remove_rules_from_one(path: Path, rule_names: list[str]) -> bool:
    """Remove only named rules while preserving other managed and handwritten content."""
    try:
        path = path.resolve()
        if not path.exists():
            _remove_instruction_state(path)
            return True
        existing = path.read_text(encoding="utf-8")
        if not any(marker in existing for marker in EASY_SKILLS_BEGIN_ALIASES) or EASY_SKILLS_END not in existing:
            _remove_instruction_state(path)
            return True
        current, legacy = _managed_rules(existing, path)
        state_entry = _instruction_state_entry(path)
        state_matches = bool(
            state_entry
            and state_entry.get("body_sha256")
            == hashlib.sha256(legacy.strip().encode("utf-8")).hexdigest()
        )
        if (
            EASY_SKILLS_BEGIN in existing
            and "EasySkills:rule" not in existing
            and legacy.strip()
            and not current
            and not state_matches
        ):
            return False
        for name in rule_names:
            current.pop(name, None)
        if current or legacy.strip():
            block = _build_managed_block(current, legacy)
            updated = _inject_managed_block(existing, block)
            body = _managed_body(current, legacy)
            new_entry = {
                "path": _instruction_state_key(path),
                "rules": [
                    {"name": name, "content": current[name]}
                    for name in sorted(current, key=str.casefold)
                ],
                "legacy": legacy,
                "body_sha256": hashlib.sha256(body.strip().encode("utf-8")).hexdigest(),
            }
            previous_state = _instruction_state_entry(path)
            if existing == updated and previous_state == new_entry:
                return True
            _set_instruction_state(path, current, legacy)
        else:
            updated = _strip_managed_block(existing)
            previous_state = _instruction_state_entry(path)
            if existing == updated and previous_state is None:
                return True
        if updated.strip():
            if not current and not legacy.strip():
                updated = updated.rstrip() + "\n"
            try:
                _atomic_write_text(path, updated)
            except Exception:
                if current or legacy.strip():
                    if previous_state is None:
                        _remove_instruction_state(path)
                    else:
                        state = _load_instruction_sync_state()
                        key = _instruction_state_key(path)
                        state["targets"] = [
                            item for item in state.get("targets", [])
                            if not isinstance(item, dict) or item.get("path") != key
                        ] + [previous_state]
                        _save_instruction_sync_state(state)
                raise
        else:
            path.unlink()
        if not current and not legacy.strip():
            _remove_instruction_state(path)
        return True
    except (OSError, UnicodeError):
        return False


def _known_instruction_target(path_str: str) -> Path | None:
    """Resolve an API path only when it belongs to a declared Agent target."""
    if not isinstance(path_str, str) or not path_str.strip():
        return None
    try:
        requested = str(Path(path_str).expanduser().resolve())
    except (OSError, ValueError):
        return None
    for _, candidate in _load_instruction_targets():
        try:
            if str(candidate.resolve()) == requested:
                return candidate
        except (OSError, ValueError):
            continue
    return None


@_writes_locked_proc
def write_instructions_to_all() -> dict:
    """Write every library rule to every detected agent instruction file."""
    rules, error = _rule_library()
    if error:
        return {"success": False, "message": error}
    targets = _detected_instruction_targets()
    all_targets = {}
    for name, path in targets:
        all_targets[str(path.resolve())] = (name, path)
    sync_state = _load_instruction_sync_state()
    for entry in sync_state.get("targets", []):
        if isinstance(entry, dict) and entry.get("path"):
            p = Path(entry["path"]).resolve()
            p_str = str(p)
            if p_str not in all_targets:
                all_targets[p_str] = (p.name, p)
    if not all_targets:
        return {"success": False, "message": "No detected or previously synced agent instruction targets found."}
    if not rules:
        removed, failed = [], []
        for name, path in all_targets.values():
            if _remove_from_one(path):
                removed.append(name)
            else:
                failed.append(f"{name} ({path})")
        msg = f"No rules in library. Cleared managed block from {len(removed)} agent(s)."
        if failed:
            msg += f" Failed: {', '.join(failed)}"
        return {"success": len(failed) == 0, "message": msg, "written": 0, "failed": failed}
    if not targets:
        removed = []
        for name, path in all_targets.values():
            _remove_from_one(path)
            removed.append(name)
        return {"success": False, "message": "No detected active agent instruction targets found. Cleared legacy block from previously synced targets."}
    written, failed = [], []
    for name, path in targets:
        if _write_to_one(path, rules, replace=True):
            written.append(name)
        else:
            failed.append(f"{name} ({path})")
    active_paths = {str(path.resolve()) for name, path in targets}
    for entry in sync_state.get("targets", []):
        if isinstance(entry, dict) and entry.get("path"):
            p = Path(entry["path"]).resolve()
            if str(p) not in active_paths:
                _remove_from_one(p)
    msg = f"Wrote rules to {len(written)} agent(s)."
    if failed:
        msg += f" Failed: {', '.join(failed)}"
    return {"success": len(failed) == 0, "message": msg, "written": len(written), "failed": failed}


@_writes_locked_proc
def remove_instructions_from_all() -> dict:
    """Remove the managed block from every detected or previously synced agent instruction file."""
    targets = _detected_instruction_targets()
    all_targets = {}
    for name, path in targets:
        all_targets[str(path.resolve())] = (name, path)
    sync_state = _load_instruction_sync_state()
    for entry in sync_state.get("targets", []):
        if isinstance(entry, dict) and entry.get("path"):
            p = Path(entry["path"]).resolve()
            p_str = str(p)
            if p_str not in all_targets:
                all_targets[p_str] = (p.name, p)
    if not all_targets:
        return {"success": False, "message": "No agent instruction targets found to clear."}
    removed, failed = [], []
    for name, path in all_targets.values():
        if _remove_from_one(path):
            removed.append(name)
        else:
            failed.append(f"{name} ({path})")
    msg = f"Removed managed block from {len(removed)} agent(s)."
    if failed:
        msg += f" Failed: {', '.join(failed)}"
    return {"success": len(failed) == 0, "message": msg, "removed": len(removed), "failed": failed}


@_writes_locked_proc
def write_instructions_to_one(path_str: str) -> dict:
    """Write the managed block into a single agent's instruction file."""
    path = _known_instruction_target(path_str)
    if path is None:
        return {"success": False, "message": "Unknown agent instruction target"}
    rules, error = _rule_library()
    if error or not rules:
        return {"success": False, "message": "No rules in the library. Add rules first."}
    if _write_to_one(path, rules, replace=True):
        return {"success": True, "message": f"Wrote rules to {path}"}
    return {"success": False, "message": f"Write failed for {path}"}


@_writes_locked_proc
def remove_instructions_from_one(path_str: str) -> dict:
    """Remove the managed block from a single agent's instruction file."""
    path = _known_instruction_target(path_str)
    if path is None:
        return {"success": False, "message": "Unknown agent instruction target"}
    if _remove_from_one(path):
        return {"success": True, "message": f"Removed managed block from {path}"}
    return {"success": False, "message": f"Remove failed for {path}"}


@_writes_locked_proc
def write_selected_instructions(rules: list[str] | None = None, agents: list[str] | None = None) -> dict:
    """Add or refresh exactly the selected rules on exactly the selected agents."""
    if (
        not isinstance(rules, list)
        or any(not isinstance(name, str) for name in rules)
        or not isinstance(agents, list)
        or any(not isinstance(path, str) for path in agents)
    ):
        return {"success": False, "message": "Rules and agents must be lists of names and paths."}
    if not rules or not agents:
        return {"success": False, "message": "Select at least one rule and one agent."}
    selected_rules, error = _rule_library(rules)
    if error or not selected_rules:
        return {"success": False, "message": error or "No selected rules found."}
    targets = _load_instruction_targets()
    if not targets:
        return {"success": False, "message": "No agent instruction targets found."}
    try:
        agents_set = {str(Path(a).expanduser().resolve()) for a in agents}
    except (OSError, ValueError):
        return {"success": False, "message": "One or more selected Agent paths are invalid."}
    targets = [(n, p) for n, p in targets if str(p.resolve()) in agents_set]
    if not targets:
        return {"success": False, "message": "No matching agent targets. Check the selected paths."}
    written, failed = [], []
    for name, path in targets:
        if _write_to_one(path, selected_rules):
            written.append(name)
        else:
            failed.append(f"{name} ({path})")
    msg = f"Wrote rules to {len(written)} agent(s)."
    if failed:
        msg += f" Failed: {', '.join(failed)}"
    return {"success": len(failed) == 0, "message": msg, "written": len(written), "failed": failed}


@_writes_locked_proc
def remove_selected_instructions(rules: list[str] | None = None, agents: list[str] | None = None) -> dict:
    """Remove exactly the selected rules from exactly the selected agents."""
    if (
        not isinstance(rules, list)
        or any(not isinstance(name, str) for name in rules)
        or not isinstance(agents, list)
        or any(not isinstance(path, str) for path in agents)
    ):
        return {"success": False, "message": "Rules and agents must be lists of names and paths."}
    if not rules or not agents:
        return {"success": False, "message": "Select at least one rule and one agent."}
    selected_rules, error = _rule_library(rules)
    if error or not selected_rules:
        return {"success": False, "message": error or "No selected rules found."}
    targets = _load_instruction_targets()
    if not targets:
        return {"success": False, "message": "No agent instruction targets found."}
    try:
        agents_set = {str(Path(a).expanduser().resolve()) for a in agents}
    except (OSError, ValueError):
        return {"success": False, "message": "One or more selected Agent paths are invalid."}
    targets = [(n, p) for n, p in targets if str(p.resolve()) in agents_set]
    if not targets:
        return {"success": False, "message": "No matching agent targets. Check the selected paths."}
    removed, failed = [], []
    for name, path in targets:
        if _remove_rules_from_one(path, list(selected_rules)):
            removed.append(name)
        else:
            failed.append(f"{name} ({path})")
    msg = f"Removed {len(selected_rules)} rule(s) from {len(removed)} agent(s)."
    if failed:
        msg += f" Failed: {', '.join(failed)}"
    return {"success": len(failed) == 0, "message": msg, "removed": len(removed), "failed": failed}


# ──────────────────────────────────────────────────────────────
# MCP Gateway JSON configuration
# ──────────────────────────────────────────────────────────────

_MCP_IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_MCP_SERVER_FIELDS = {
    "enabled", "required", "transport", "command", "args", "cwd", "env",
    "url", "headers", "startup_timeout_seconds", "tool_timeout_seconds",
    "enabled_tools", "disabled_tools",
}
_MCP_PROFILE_FIELDS = {"servers", "enabled_tools", "disabled_tools"}
_MCP_ENV_NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_MCP_HEADER_NAME_RE = re.compile(r"[!#$%&'*+\-.^_`|~0-9A-Za-z]+")


def _default_mcp_config() -> dict:
    try:
        data = json.loads(MCP_TEMPLATE_FILE.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            return data
    except (OSError, json.JSONDecodeError, UnicodeError):
        pass
    return {"version": 1, "servers": {}, "profiles": {"default": {"servers": ["*"]}}}


def _validate_string_list(value, field: str, problems: list[str]) -> None:
    if value is not None and (
        not isinstance(value, list) or any(not isinstance(item, str) for item in value)
    ):
        problems.append(f"{field} must be an array of strings")


def _valid_mcp_runtime_value_syntax(value: str) -> bool:
    """Mirror the Gateway's ${env:NAME} syntax validation at save time."""
    offset = 0
    while offset < len(value):
        if value.startswith("$${env:", offset):
            offset += len("$${env:")
            continue
        if not value.startswith("${env:", offset):
            offset += 1
            continue
        closing = value.find("}", offset)
        if closing < 0:
            return False
        name = value[offset + len("${env:"):closing]
        if _MCP_ENV_NAME_RE.fullmatch(name) is None:
            return False
        offset = closing + 1
    return True


def _valid_mcp_tool_pattern_syntax(pattern: str) -> bool:
    """Validate the glob syntax accepted by Go's path.Match."""
    index = 0
    while index < len(pattern):
        char = pattern[index]
        if char == "\\":
            if index + 1 >= len(pattern):
                return False
            index += 2
            continue
        if char != "[":
            index += 1
            continue

        index += 1
        if index < len(pattern) and pattern[index] == "^":
            index += 1
        ranges = 0
        while True:
            if index < len(pattern) and pattern[index] == "]" and ranges > 0:
                index += 1
                break
            if index >= len(pattern) or pattern[index] in "-]":
                return False
            if pattern[index] == "\\":
                index += 1
                if index >= len(pattern):
                    return False
            index += 1
            if index >= len(pattern):
                return False
            if pattern[index] == "-":
                index += 1
                if index >= len(pattern) or pattern[index] in "-]":
                    return False
                if pattern[index] == "\\":
                    index += 1
                    if index >= len(pattern):
                        return False
                index += 1
                if index >= len(pattern):
                    return False
            ranges += 1
    return True


def _valid_mcp_http_url(value: str) -> bool:
    """Validate an HTTP MCP endpoint before it reaches the Gateway."""
    # Keep this deliberately stricter than urllib.parse: a URL that contains
    # whitespace or a backslash can be interpreted differently by browsers,
    # proxies, Go's net/url, and .NET's System.Uri. All three runtimes share
    # this portable subset so a configuration cannot validate on one backend
    # and fail (or be redirected) on another.
    if (
        value != value.strip()
        or any(char.isspace() for char in value)
        or any(ord(char) < 32 for char in value)
        or "\\" in value
    ):
        return False
    try:
        parsed = urllib.parse.urlparse(value)
        port = parsed.port
    except ValueError:
        return False
    return (
        parsed.scheme.lower() in {"http", "https"}
        and bool(parsed.netloc)
        and parsed.hostname is not None
        and parsed.username is None
        and parsed.password is None
        and not parsed.netloc.endswith(":")
        and (port is None or 1 <= port <= 65535)
    )


def _validate_mcp_config(config_data) -> tuple[bool, str]:
    if not isinstance(config_data, dict):
        return False, "MCP configuration must be a JSON object."
    unknown_top = set(config_data) - {"version", "servers", "profiles"}
    if unknown_top:
        return False, f"Unknown top-level fields: {', '.join(sorted(unknown_top))}"
    version = config_data.get("version")
    if isinstance(version, bool) or not isinstance(version, int) or version != 1:
        return False, "version must be 1."
    servers = config_data.get("servers")
    profiles = config_data.get("profiles", {})
    if not isinstance(servers, dict):
        return False, "servers must be a JSON object."
    if not isinstance(profiles, dict):
        return False, "profiles must be a JSON object."
    problems: list[str] = []
    for name, server in servers.items():
        prefix = f"server {name!r}"
        if not isinstance(name, str) or not _MCP_IDENTIFIER_RE.fullmatch(name):
            problems.append(f"{prefix} has an invalid name")
            continue
        if not isinstance(server, dict):
            problems.append(f"{prefix} must be an object")
            continue
        unknown = set(server) - _MCP_SERVER_FIELDS
        if unknown:
            problems.append(f"{prefix} has unknown fields: {', '.join(sorted(unknown))}")
        if "enabled" in server and not isinstance(server["enabled"], bool):
            problems.append(f"{prefix}.enabled must be boolean")
        if "required" in server and not isinstance(server["required"], bool):
            problems.append(f"{prefix}.required must be boolean")
        if "cwd" in server and not isinstance(server["cwd"], str):
            problems.append(f"{prefix}.cwd must be a string")
        if "transport" in server and not isinstance(server["transport"], str):
            problems.append(f"{prefix}.transport must be a string")
        if "command" in server and not isinstance(server["command"], str):
            problems.append(f"{prefix}.command must be a string")
        if "url" in server and not isinstance(server["url"], str):
            problems.append(f"{prefix}.url must be a string")

        for scalar_field in ("command", "cwd", "url"):
            scalar_value = server.get(scalar_field)
            if isinstance(scalar_value, str) and "\x00" in scalar_value:
                problems.append(f"{prefix}.{scalar_field} must not contain NUL")

        transport = str(server.get("transport", "")).strip().lower().replace("_", "-")
        if transport == "streamable-http":
            transport = "http"
        if transport == "stdio":
            if not isinstance(server.get("command"), str) or not server.get("command", "").strip():
                problems.append(f"{prefix}.command is required for stdio")
        elif transport in {"http", "sse"}:
            url = server.get("url")
            if not isinstance(url, str) or not _valid_mcp_http_url(url):
                problems.append(f"{prefix}.url must be a valid http(s) URL")
        else:
            problems.append(f"{prefix}.transport must be stdio, http, streamable-http, or sse")
        _validate_string_list(server.get("args"), f"{prefix}.args", problems)
        if isinstance(server.get("args"), list):
            for index, argument in enumerate(server["args"]):
                if isinstance(argument, str) and "\x00" in argument:
                    problems.append(f"{prefix}.args[{index}] must not contain NUL")
        for map_field in ("env", "headers"):
            value = server.get(map_field)
            if value is not None and (
                not isinstance(value, dict)
                or any(not isinstance(k, str) or not isinstance(v, str) for k, v in value.items())
            ):
                problems.append(f"{prefix}.{map_field} must be an object of string values")
            elif isinstance(value, dict):
                for key, runtime_value in value.items():
                    if map_field == "env" and (not key or "=" in key or "\x00" in key):
                        problems.append(f"{prefix}.env[{key!r}] has an invalid variable name")
                    if map_field == "headers" and _MCP_HEADER_NAME_RE.fullmatch(key) is None:
                        problems.append(f"{prefix}.headers[{key!r}] has an invalid HTTP field name")
                    if "\x00" in runtime_value or (map_field == "headers" and any(c in runtime_value for c in "\r\n")):
                        problems.append(f"{prefix}.{map_field}[{key!r}] contains invalid control characters")
                    if not _valid_mcp_runtime_value_syntax(runtime_value):
                        problems.append(
                            f"{prefix}.{map_field}[{key!r}] has an invalid environment reference; "
                            "expected ${env:NAME}"
                        )
        for list_field in ("enabled_tools", "disabled_tools"):
            _validate_string_list(server.get(list_field), f"{prefix}.{list_field}", problems)
            patterns = server.get(list_field)
            if isinstance(patterns, list):
                for pattern in patterns:
                    if isinstance(pattern, str) and not _valid_mcp_tool_pattern_syntax(pattern):
                        problems.append(f"{prefix}.{list_field} contains invalid pattern {pattern!r}")
        for number_field, maximum in (("startup_timeout_seconds", 600), ("tool_timeout_seconds", 3600)):
            if number_field in server:
                value = server[number_field]
            else:
                value = None
            if number_field in server and (
                isinstance(value, bool) or not isinstance(value, int) or value < 0 or value > maximum
            ):
                problems.append(f"{prefix}.{number_field} must be an integer from 0 to {maximum}")
    for name, profile in profiles.items():
        prefix = f"profile {name!r}"
        if not isinstance(name, str) or not _MCP_IDENTIFIER_RE.fullmatch(name):
            problems.append(f"{prefix} has an invalid name")
            continue
        if not isinstance(profile, dict):
            problems.append(f"{prefix} must be an object")
            continue
        unknown = set(profile) - _MCP_PROFILE_FIELDS
        if unknown:
            problems.append(f"{prefix} has unknown fields: {', '.join(sorted(unknown))}")
        for list_field in _MCP_PROFILE_FIELDS:
            _validate_string_list(profile.get(list_field), f"{prefix}.{list_field}", problems)
            if list_field != "servers" and isinstance(profile.get(list_field), list):
                for pattern in profile[list_field]:
                    if isinstance(pattern, str) and not _valid_mcp_tool_pattern_syntax(pattern):
                        problems.append(f"{prefix}.{list_field} contains invalid pattern {pattern!r}")
        selected = profile.get("servers", [])
        if isinstance(selected, list):
            for server_name in selected:
                if isinstance(server_name, str) and server_name != "*" and server_name not in servers:
                    problems.append(f"{prefix} references unknown server {server_name!r}")
    if problems:
        return False, "; ".join(sorted(problems))
    return True, ""


def _read_mcp_config() -> tuple[dict | None, str | None]:
    if not MCP_CONFIG_FILE.exists():
        return _default_mcp_config(), None
    try:
        if MCP_CONFIG_FILE.stat().st_size > 1024 * 1024:
            return None, "MCP configuration exceeds the 1 MB limit."
        data = json.loads(MCP_CONFIG_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeError) as exc:
        return None, f"Could not read MCP config: {exc}"
    valid, message = _validate_mcp_config(data)
    return (data, None) if valid else (None, message)


def _gateway_info() -> dict:
    binary = MCP_GATEWAY_BINARY
    if not binary.is_file():
        found = shutil.which("easyskills-mcp")
        binary = Path(found) if found else binary
    expected_version = get_version()
    info = {
        "installed": binary.is_file(),
        "path": str(binary),
        "version": "",
        "version_number": "",
        "expected_version": expected_version,
        "version_matches": None,
    }
    if info["installed"]:
        try:
            result = subprocess.run(
                [str(binary), "version"], capture_output=True, text=True, timeout=5, check=False,
            )
            if result.returncode == 0:
                info["version"] = result.stdout.strip()
                match = re.match(r"^easyskills-mcp\s+(\S+)\s+\(", info["version"])
                if match:
                    info["version_number"] = match.group(1)
                    if expected_version != "unknown":
                        info["version_matches"] = match.group(1) == expected_version
        except (OSError, subprocess.SubprocessError):
            pass
    return info


def _install_gateway_for_engine(engine_dir: Path, source_dir: Path | None = None) -> dict:
    """Best-effort install of the Gateway version paired with *engine_dir*."""
    installer = engine_dir / "install-gateway.sh"
    if not installer.is_file():
        return {"attempted": False, "success": True, "message": ""}
    env = os.environ.copy()
    if source_dir is not None and source_dir.is_dir():
        env["EASYSKILLS_GATEWAY_SOURCE"] = str(source_dir)
    try:
        result = subprocess.run(
            ["bash", str(installer)],
            capture_output=True,
            text=True,
            timeout=240,
            check=False,
            cwd=str(engine_dir),
            env=env,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return {"attempted": True, "success": False, "message": str(exc)}
    output = (result.stdout + result.stderr).strip()
    return {
        "attempted": True,
        "success": result.returncode == 0,
        "message": output[-4000:],
    }


def get_mcp_config() -> dict:
    config_data, error = _read_mcp_config()
    return {
        "success": error is None,
        "path": str(MCP_CONFIG_FILE),
        "exists": MCP_CONFIG_FILE.is_file(),
        "config": config_data,
        "error": error or "",
        "gateway": _gateway_info(),
    }


@_writes_locked_proc
def save_mcp_config(config_data) -> dict:
    valid, message = _validate_mcp_config(config_data)
    if not valid:
        return {"success": False, "message": message}
    payload = json.dumps(config_data, ensure_ascii=False, indent=2) + "\n"
    if len(payload.encode("utf-8")) > 1024 * 1024:
        return {"success": False, "message": "MCP configuration exceeds the 1 MB limit."}
    try:
        MCP_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            MCP_DIR.chmod(0o700)
        except OSError:
            pass
        if MCP_CONFIG_FILE.is_file():
            _atomic_copy_file(MCP_CONFIG_FILE, MCP_CONFIG_BACKUP_FILE)
            try:
                MCP_CONFIG_BACKUP_FILE.chmod(0o600)
            except OSError:
                pass
        _atomic_write_text(MCP_CONFIG_FILE, payload)
        try:
            MCP_CONFIG_FILE.chmod(0o600)
        except OSError:
            pass
        return {"success": True, "message": "MCP configuration saved.", "config": config_data}
    except OSError as exc:
        return {"success": False, "message": f"Could not save MCP configuration: {exc}"}


@_writes_locked_proc
def add_mcp_server(name: str, server_data) -> dict:
    clean = (name or "").strip()
    if not _MCP_IDENTIFIER_RE.fullmatch(clean):
        return {"success": False, "message": "Server name must use letters, numbers, dot, underscore, or hyphen."}
    current, error = _read_mcp_config()
    if error:
        return {"success": False, "message": error}
    if clean in current["servers"]:
        return {"success": False, "message": f"MCP server {clean!r} already exists."}
    current["servers"][clean] = server_data
    return save_mcp_config(current)


@_writes_locked_proc
def update_mcp_server(name: str, server_data) -> dict:
    clean = (name or "").strip()
    current, error = _read_mcp_config()
    if error:
        return {"success": False, "message": error}
    if clean not in current["servers"]:
        return {"success": False, "message": f"MCP server {clean!r} does not exist."}
    current["servers"][clean] = server_data
    return save_mcp_config(current)


@_writes_locked_proc
def delete_mcp_server(name: str) -> dict:
    clean = (name or "").strip()
    current, error = _read_mcp_config()
    if error:
        return {"success": False, "message": error}
    if clean not in current["servers"]:
        return {"success": False, "message": f"MCP server {clean!r} does not exist."}
    del current["servers"][clean]
    for profile in current.get("profiles", {}).values():
        if isinstance(profile, dict) and isinstance(profile.get("servers"), list):
            profile["servers"] = [item for item in profile["servers"] if item != clean]
    return save_mcp_config(current)


def test_mcp_gateway(profile: str = "default", server_name: str = "") -> dict:
    gateway = _gateway_info()
    if not gateway["installed"]:
        return {"success": False, "message": "EasySkills MCP Gateway binary is not installed."}
    if not MCP_CONFIG_FILE.is_file():
        return {"success": False, "message": "Save the MCP configuration before testing."}
    clean_profile = (profile or "default").strip()
    if not _MCP_IDENTIFIER_RE.fullmatch(clean_profile):
        return {"success": False, "message": "Invalid profile name."}
    clean_server = (server_name or "").strip()
    if clean_server and not _MCP_IDENTIFIER_RE.fullmatch(clean_server):
        return {"success": False, "message": "Invalid MCP server name."}
    try:
        command = [
            gateway["path"], "test", "--config", str(MCP_CONFIG_FILE),
            "--profile", clean_profile,
        ]
        if clean_server:
            command.extend(["--server", clean_server])
        result = subprocess.run(
            command,
            capture_output=True, text=True, timeout=45, check=False,
        )
    except subprocess.TimeoutExpired:
        return {"success": False, "message": "MCP Gateway test timed out after 45 seconds."}
    except OSError as exc:
        return {"success": False, "message": f"Could not run MCP Gateway: {exc}"}
    if result.returncode != 0:
        message = (result.stderr or result.stdout or "Gateway test failed.").strip()
        return {"success": False, "message": message[-4000:]}
    try:
        summary = json.loads(result.stdout)
    except json.JSONDecodeError:
        summary = {"output": result.stdout.strip()}
    return {"success": True, "message": "MCP Gateway test completed.", "summary": summary}


def get_latest_release() -> dict:
    def release_from_tag(tag: str, name: str = "") -> dict:
        return {
            "success": True,
            "tag_name": tag,
            "name": name or tag,
            "html_url": f"https://github.com/{GITHUB_REPO}/releases/tag/{tag}",
            "published_at": "",
            "tarball_url": f"https://github.com/{GITHUB_REPO}/archive/refs/tags/{tag}.tar.gz",
            "zipball_url": f"https://github.com/{GITHUB_REPO}/archive/refs/tags/{tag}.zip",
            "draft": False,
            "prerelease": False,
        }

    def get_latest_release_via_redirect() -> dict:
        req = urllib.request.Request(
            GITHUB_LATEST_RELEASE,
            headers={"User-Agent": "EasySkills-WebUI"},
            method="HEAD",
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            final_url = resp.geturl()
        if not final_url.startswith(GITHUB_RELEASE_TAG_PREFIX):
            return {"success": False, "message": "Could not determine latest version"}
        tag = urllib.parse.unquote(final_url.removeprefix(GITHUB_RELEASE_TAG_PREFIX)).strip("/")
        if not tag:
            return {"success": False, "message": "Could not determine latest version"}
        return release_from_tag(tag)

    try:
        req = urllib.request.Request(
            GITHUB_API_LATEST_RELEASE,
            headers={"Accept": "application/vnd.github+json", "User-Agent": "EasySkills-WebUI"},
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            release = json.loads(resp.read().decode())

        latest_tag = release.get("tag_name", "")
        if not latest_tag:
            return {"success": False, "message": "Could not determine latest version"}

        return {
            "success": True,
            "tag_name": latest_tag,
            "name": release.get("name", ""),
            "html_url": release.get("html_url", ""),
            "published_at": release.get("published_at", ""),
            "tarball_url": release.get("tarball_url", ""),
            "zipball_url": release.get("zipball_url", ""),
            "draft": bool(release.get("draft", False)),
            "prerelease": bool(release.get("prerelease", False)),
        }
    except Exception as e:
        try:
            fallback = get_latest_release_via_redirect()
        except Exception as fallback_error:
            return {
                "success": False,
                "message": f"Failed to fetch release info: API error: {e}; fallback error: {fallback_error}",
            }
        if fallback.get("success"):
            fallback["message"] = f"GitHub API unavailable; used release redirect fallback ({e})"
            return fallback
        return {"success": False, "message": f"Failed to fetch release info: {e}"}


def get_watcher_status():
    try:
        if platform.system() == "Darwin":
            r = subprocess.run(
                ["launchctl", "list"],
                capture_output=True, text=True, timeout=5
            )
            for line in r.stdout.splitlines():
                parts = line.split(None, 2)
                if len(parts) >= 3 and parts[2] == WATCHER_LAUNCHD_LABEL:
                    pid = parts[0]
                    return {"running": True, "pid": None if pid == "-" else pid}
        elif platform.system() == "Linux":
            # The watcher is driven by persistent systemd path/timer units;
            # easyskills-watcher.service is Type=oneshot and is normally
            # inactive immediately after a successful sync, so neither pgrep
            # nor the service's active state represents watcher health.
            for unit in ("easyskills-watcher.path", "easyskills-watcher.timer"):
                r = subprocess.run(
                    ["systemctl", "--user", "is-active", unit],
                    capture_output=True, text=True, timeout=5,
                )
                if r.returncode == 0 and r.stdout.strip() == "active":
                    return {"running": True, "pid": None}
        return {"running": False, "pid": None}
    except Exception:
        return {"running": False, "pid": None}


_MCP_ENV_REFERENCE_RE = re.compile(r"(?<!\$)\$\{env:[A-Za-z_][A-Za-z0-9_]*\}")
_MCP_SENSITIVE_KEY_RE = re.compile(
    r"(?:^|[_-])(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|"
    r"password|passwd|credential|authorization|auth|cookie)(?:[_-]|$)",
    re.IGNORECASE,
)


def _is_sensitive_mcp_value(field: str, key: str) -> bool:
    """Conservatively identify credential-bearing env/header entries."""
    normalized = key.strip().lower()
    if field == "headers" and normalized in {
        "authorization", "proxy-authorization", "x-api-key", "api-key",
        "cookie", "set-cookie",
    }:
        return True
    return bool(_MCP_SENSITIVE_KEY_RE.search(normalized))


def _display_path(path: Path) -> str:
    """Return a support-safe path without exposing the user's home directory."""
    try:
        relative = path.expanduser().resolve().relative_to(Path.home().resolve())
        return str(Path("~") / relative)
    except (OSError, ValueError):
        return str(path)


def _mcp_credential_posture(config_data: dict | None) -> dict:
    references = 0
    literals = 0
    if not isinstance(config_data, dict):
        return {"environment_references": 0, "literal_values": 0}
    servers = config_data.get("servers", {})
    if not isinstance(servers, dict):
        return {"environment_references": 0, "literal_values": 0}
    for server in servers.values():
        if not isinstance(server, dict):
            continue
        for field in ("env", "headers"):
            values = server.get(field, {})
            if not isinstance(values, dict):
                continue
            for key, value in values.items():
                if not isinstance(value, str) or not value:
                    continue
                if not _is_sensitive_mcp_value(field, str(key)):
                    continue
                if _MCP_ENV_REFERENCE_RE.search(value):
                    references += 1
                else:
                    literals += 1
    return {"environment_references": references, "literal_values": literals}


def get_doctor_report() -> dict:
    """Build a read-only, credential-safe health report for support and UI use."""
    skills = get_skills()
    agents = get_visible_agents()
    detected_agents = [agent for agent in agents if agent.get("active")]
    mapped_agents = [agent for agent in detected_agents if agent.get("mapped")]
    instructions = get_instructions()
    instruction_agents = instructions.get("agents", []) if isinstance(instructions, dict) else []
    detected_instruction_agents = [agent for agent in instruction_agents if agent.get("active")]
    managed_instruction_agents = [
        agent for agent in detected_instruction_agents
        if int(agent.get("managed_rule_count", 0) or 0) > 0
    ]
    rules = instructions.get("rules", []) if isinstance(instructions, dict) else []
    link_warnings = get_central_dir_warnings()
    watcher = get_watcher_status()
    mcp_data = get_mcp_config()
    mcp_config = mcp_data.get("config") if mcp_data.get("success") else None
    mcp_servers = mcp_config.get("servers", {}) if isinstance(mcp_config, dict) else {}
    enabled_mcp_servers = [
        server for server in mcp_servers.values()
        if isinstance(server, dict) and server.get("enabled", True)
    ]
    credential_posture = _mcp_credential_posture(mcp_config)
    gateway = mcp_data.get("gateway", {}) if isinstance(mcp_data, dict) else {}

    checks: list[dict] = []

    def add_check(check_id: str, status: str, message: str, action: str = "") -> None:
        checks.append({"id": check_id, "status": status, "message": message, "action": action})

    if CENTRAL_DIR.is_dir():
        add_check("central-directory", "ok", "Central EasySkills directory is available.")
    else:
        add_check("central-directory", "error", "Central EasySkills directory is missing.", "Reinstall EasySkills or restore the directory from backup.")

    if watcher.get("running"):
        add_check("watcher", "ok", "Background synchronization watcher is running.")
    else:
        add_check("watcher", "warning", "Background synchronization watcher is stopped.", "Start the watcher from the dashboard or run deploy.sh --watch.")

    dangling = int(link_warnings.get("dangling_count", 0) or 0)
    external = int(link_warnings.get("external_link_count", 0) or 0)
    if dangling:
        add_check("link-health", "warning", f"{dangling} dangling central skill link(s) detected.", "Run a full sync to prune dangling links.")
    elif external:
        add_check("link-health", "warning", f"{external} externally linked skill folder(s) detected.", "Keep external targets available or import them into the central library.")
    else:
        add_check("link-health", "ok", "No dangling or external central skill links detected.")

    if skills and mapped_agents:
        add_check("skills-channel", "ok", f"{len(skills)} skill(s) are connected to {len(mapped_agents)} detected Agent(s).")
    elif skills:
        add_check("skills-channel", "warning", f"{len(skills)} skill(s) exist but no detected Agent is connected.", "Connect an Agent target or run a full sync.")
    else:
        add_check("skills-channel", "info", "The central skill library is empty.", "Import a skill when you are ready.")

    if rules and managed_instruction_agents:
        add_check("rules-channel", "ok", f"{len(rules)} rule(s) are written to {len(managed_instruction_agents)} detected Agent target(s).")
    elif rules:
        add_check("rules-channel", "warning", f"{len(rules)} rule(s) exist but none are written to a detected Agent target.", "Select rules and Agent targets, then write the managed blocks.")
    else:
        add_check("rules-channel", "info", "The modular Agent rules library is empty.")

    if not mcp_data.get("success"):
        add_check("mcp-config", "error", "The MCP configuration is invalid or unreadable.", "Open the MCP page and correct the configuration error.")
    elif gateway.get("installed") and gateway.get("version_matches") is False:
        add_check(
            "mcp-channel",
            "warning",
            f"Gateway version {gateway.get('version_number') or 'unknown'} does not match EasySkills {gateway.get('expected_version') or 'unknown'}.",
            "Reinstall the Gateway from this EasySkills version before using MCP tools.",
        )
    elif mcp_servers and gateway.get("installed"):
        add_check("mcp-channel", "ok", f"Gateway installed with {len(enabled_mcp_servers)} enabled server(s).")
    elif mcp_servers:
        add_check("mcp-channel", "warning", f"{len(mcp_servers)} MCP server(s) are configured but the Gateway binary is missing.", "Retry the Gateway installation from EasySkills.")
    elif gateway.get("installed"):
        add_check("mcp-channel", "info", "Gateway is installed; no downstream MCP server is configured yet.")
    else:
        add_check("mcp-channel", "info", "MCP Gateway is not installed and no downstream server is configured.")

    if credential_posture["literal_values"]:
        add_check(
            "credential-posture",
            "warning",
            f"{credential_posture['literal_values']} MCP credential value(s) are stored literally.",
            "Replace literal secrets with ${env:VARIABLE} references where possible.",
        )
    elif credential_posture["environment_references"]:
        add_check("credential-posture", "ok", f"{credential_posture['environment_references']} MCP credential value(s) use environment references.")
    else:
        add_check("credential-posture", "info", "No MCP environment or header credentials are configured.")

    summary = {
        "ok": sum(1 for check in checks if check["status"] == "ok"),
        "info": sum(1 for check in checks if check["status"] == "info"),
        "warnings": sum(1 for check in checks if check["status"] == "warning"),
        "errors": sum(1 for check in checks if check["status"] == "error"),
    }
    return {
        "schema_version": 1,
        "success": summary["errors"] == 0,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "version": get_version(),
        "platform": platform.system(),
        "runtime": {"python": platform.python_version()},
        "paths": {"central": _display_path(CENTRAL_DIR), "engine": _display_path(SCRIPT_DIR)},
        "summary": summary,
        "metrics": {
            "skills": len(skills),
            "agents_detected": len(detected_agents),
            "agents_mapped": len(mapped_agents),
            "rules": len(rules),
            "rule_targets_detected": len(detected_instruction_agents),
            "rule_targets_managed": len(managed_instruction_agents),
            "mcp_servers": len(mcp_servers),
            "mcp_servers_enabled": len(enabled_mcp_servers),
            "credential_posture": credential_posture,
            "dangling_links": dangling,
            "external_links": external,
        },
        "checks": checks,
    }


# ──────────────────────────────────────────────────────────────
# Operations
# ──────────────────────────────────────────────────────────────

def run_deploy(*args: str) -> dict:
    deploy = SCRIPT_DIR / "deploy.sh"
    try:
        env = os.environ.copy()
        if getattr(_deploy_lock_state, "depth", 0) > 0:
            env["EASYSKILLS_DEPLOY_LOCK_HELD"] = "1"
            env["EASYSKILLS_DEPLOY_LOCK_PID"] = str(os.getpid())
        r = subprocess.run(
            ["bash", str(deploy), *args],
            capture_output=True, text=True, timeout=30,
            cwd=str(SCRIPT_DIR),
            env=env,
        )
        combined = (r.stdout + r.stderr).strip()
        return {
            "success": r.returncode == 0,
            "output": combined,
            "message": combined if combined else
                       ("Command completed successfully" if r.returncode == 0 else "Command failed"),
        }
    except Exception as e:
        return {"success": False, "output": str(e), "message": str(e)}


def _validate_skill_name(name: str) -> tuple[bool, str]:
    if not isinstance(name, str):
        return False, "Skill name must be text"
    if name != name.strip():
        return False, "Invalid skill name"
    if not name:
        return False, "Skill name cannot be empty"
    if name.startswith(("_", ".")) or name in EXCLUDE_NAMES:
        return False, "Reserved skill name"
    if name in (".", "..") or not _is_portable_filename(name):
        return False, "Invalid skill name"
    return True, name


def _casefold_child(directory: Path, name: str) -> Path | None:
    """Find a child whose name collides case-insensitively with *name*.

    The Unix backend runs on a case-sensitive filesystem, but the same library
    may later be copied to Windows. Rejecting ambiguous names at creation time
    keeps the central library portable instead of allowing two entries that
    would collapse into one junction target on a case-insensitive volume.
    """
    try:
        folded = name.casefold()
        for entry in directory.iterdir():
            if entry.name.casefold() == folded:
                return entry
    except OSError:
        pass
    return None


def _safe_relative_path(path: str) -> Path | None:
    if not path or "\x00" in path:
        return None
    rel = Path(path.replace("\\", "/"))
    if rel.is_absolute() or any(part in ("", ".", "..") for part in rel.parts):
        return None
    # Every uploaded component must be valid on both POSIX and Windows.  The
    # central skill library is portable data and may later be mapped to a
    # Windows junction; accepting names such as ``CON`` or ``guide. `` here
    # would create an archive that imports successfully on Unix but cannot be
    # materialized safely on Windows.
    if any(not _is_portable_filename(part) for part in rel.parts):
        return None
    return rel


@_writes_locked_proc
def import_skill_folder(name: str, files: list[dict]) -> dict:
    valid, clean_name = _validate_skill_name(name)
    if not valid:
        return {"success": False, "message": clean_name}
    if not isinstance(files, list) or not files:
        return {"success": False, "message": "No files were provided"}

    prepared: list[tuple[Path, bytes]] = []
    seen_paths: set[str] = set()
    has_skill_md = False
    for item in files:
        if not isinstance(item, dict):
            return {"success": False, "message": "Invalid file payload"}
        rel = _safe_relative_path(str(item.get("path", "")))
        if rel is None:
            return {"success": False, "message": "Invalid file path in upload"}
        folded = rel.as_posix().casefold()
        if folded in seen_paths:
            return {"success": False, "message": f"Duplicate file path in upload: {rel}"}
        seen_paths.add(folded)
        data = item.get("data", "")
        if not isinstance(data, str):
            return {"success": False, "message": f"Invalid file data: {rel}"}
        try:
            content = base64.b64decode(data.encode("ascii"), validate=True)
        except (binascii.Error, UnicodeEncodeError, ValueError):
            return {"success": False, "message": f"Invalid base64 data: {rel}"}
        if rel.as_posix() == "SKILL.md":
            has_skill_md = True
        prepared.append((rel, content))

    if not has_skill_md:
        return {"success": False, "message": "Selected folder must contain SKILL.md at its root"}

    # The outer _writes_locked_proc decorator keeps the atomic library mutation
    # and its follow-up sync in one shared critical section. run_deploy inherits
    # that lock marker, so the child cannot race a watcher or deadlock itself.
    CENTRAL_DIR.mkdir(parents=True, exist_ok=True)
    target = CENTRAL_DIR / clean_name
    if target.exists() or target.is_symlink():
        return {"success": False, "message": f"Skill already exists: {clean_name}"}
    collision = _casefold_child(CENTRAL_DIR, clean_name)
    if collision is not None:
        return {"success": False, "message": f"Skill name conflicts case-insensitively with: {collision.name}"}

    tmp_dir = Path(tempfile.mkdtemp(prefix=".import-", dir=str(CENTRAL_DIR)))
    try:
        for rel, content in prepared:
            dest = tmp_dir / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(content)
        tmp_dir.rename(target)
    except Exception as e:
        shutil.rmtree(tmp_dir, ignore_errors=True)
        return {"success": False, "message": f"Import failed: {e}"}

    sync = run_deploy("--sync")
    msg = f"Imported {clean_name}"
    if sync.get("message"):
        msg += f"\n{sync['message']}"
    result = {
        # The folder import itself is complete at this point. Report sync as a
        # separate outcome so a transient deploy failure does not prompt the UI
        # to retry the import and hit a misleading "already exists" error.
        "success": True,
        "message": msg,
        "skill": clean_name,
        "sync_success": bool(sync.get("success")),
    }
    if not sync.get("success"):
        result["partial"] = True
    return result


@_writes_locked_proc
def delete_skill(name: str) -> dict:
    valid, clean_name = _validate_skill_name(name)
    if not valid:
        return {"success": False, "message": clean_name}

    target = CENTRAL_DIR / clean_name
    if not target.exists() and not target.is_symlink():
        return {"success": False, "message": f"Skill not found: {clean_name}"}

    try:
        if target.is_symlink():
            target.unlink()
        else:
            shutil.rmtree(target)
    except Exception as e:
        return {"success": False, "message": f"Delete failed: {e}"}

    # Remove only the symlinks for this specific skill from all agent targets,
    # instead of a full cleanup+sync cycle.
    removed_count = 0
    failed_links: list[str] = []
    for agent_dir in _iter_agent_skill_dirs():
        link = agent_dir / clean_name
        if link.is_symlink() and _link_points_into_central(link, CENTRAL_DIR.resolve()):
            try:
                link.unlink()
                removed_count += 1
            except Exception as exc:
                failed_links.append(f"{link}: {exc}")
    message = f"Deleted {clean_name} (removed {removed_count} symlinks)"
    if failed_links:
        message += f"; {len(failed_links)} symlink(s) could not be removed: {'; '.join(failed_links)}"
    result = {"success": True, "message": message, "skill": clean_name}
    if failed_links:
        result["partial"] = True
        result["failed_links"] = failed_links
    return result


@_writes_locked_proc
def do_map(target_path: str) -> dict:
    if not isinstance(target_path, str) or not target_path.strip():
        return {"success": False, "message": "Target path cannot be empty"}
    target_path = target_path.strip()
    target, validation_error = _validate_mapping_target(target_path)
    if target is None:
        return {"success": False, "message": validation_error}
    try:
        target.mkdir(parents=True, exist_ok=True)
        # Per-skill links
        conflicts = []
        central_resolved = CENTRAL_DIR.resolve()
        for skill_dir in CENTRAL_DIR.iterdir():
            if not skill_dir.is_dir():
                continue
            if skill_dir.name.startswith(("_", ".")) or skill_dir.name in EXCLUDE_NAMES:
                continue
            dest = target / skill_dir.name
            if dest.is_symlink():
                if _link_points_into_central(dest, central_resolved):
                    dest.unlink()
                else:
                    conflicts.append(skill_dir.name)
                    continue
            if dest.exists():
                # A real file/dir (not one of our links) already occupies the
                # name — never overwrite user data, report it as a conflict.
                conflicts.append(skill_dir.name)
                continue
            dest.symlink_to(skill_dir)
        if not _remove_from_disabled_targets(str(target)):
            return {
                "success": False,
                "message": "Skills were mapped, but the disabled-target state could not be updated; please retry",
                "partial": True,
                "conflicts": conflicts,
            }
        message = f"Mapped to {target_path}"
        if conflicts:
            message += f" (preserved {len(conflicts)} foreign link conflict(s): {', '.join(conflicts)})"
        return {"success": True, "message": message, "conflicts": conflicts}
    except Exception as e:
        return {"success": False, "message": str(e)}


@_writes_locked_proc
def do_unmap(target_path: str) -> dict:
    if not isinstance(target_path, str) or not target_path.strip():
        return {"success": False, "message": "Target path cannot be empty"}
    target_path = target_path.strip()
    target, validation_error = _validate_mapping_target(target_path, require_existing=True)
    if target is None:
        return {"success": False, "message": validation_error}
    if not _add_to_disabled_targets(str(target)):
        return {"success": False, "message": "Could not persist the disabled-target state; no links were removed"}
    removed = []
    errors = []
    central_resolved = str(CENTRAL_DIR.resolve())
    try:
        items = list(target.iterdir())
    except Exception as e:
        return {"success": False, "message": str(e)}
    for item in items:
        try:
            if item.is_symlink():
                if _link_points_into_central(item, Path(central_resolved)):
                    item.unlink()
                    removed.append(item.name)
        except Exception as e:
            errors.append(f"{item.name}: {e}")
    msg = f"Removed {len(removed)} symlinks"
    if errors:
        msg += f" ({len(errors)} errors: {'; '.join(errors)})"
    result = {"success": True, "message": msg, "removed": removed}
    if errors:
        # The disabled-target marker is already persisted, but one or more
        # links remain.  Keep success=true for backward compatibility while
        # exposing a machine-readable degraded outcome to callers/UI.
        result["partial"] = True
        result["errors"] = errors
    return result


@_writes_locked_proc
def update_agent_paths(
    name: str,
    old_skills_path: str,
    skills_path: str,
    instructions_path: str,
) -> dict:
    if not skills_path:
        return {"success": False, "message": "Skills path cannot be empty"}
    normalized_old = _normalize_local_path(old_skills_path)
    current = next(
        (
            agent for agent in get_visible_agents()
            if _normalize_local_path(str(agent.get("path", ""))) == normalized_old
        ),
        None,
    )
    if not instructions_path:
        instructions_path = str((current or {}).get("instructions_path", "")).strip()
        if not instructions_path:
            return {"success": False, "message": "Instructions file path cannot be empty"}

    # Expand paths correctly
    new_path = _normalize_local_path(skills_path)
    new_instructions_path = _normalize_local_path(instructions_path)
    instructions_target = Path(new_instructions_path)
    if instructions_target.exists() and instructions_target.is_dir():
        return {"success": False, "message": "Instructions path must point to a file, not a directory"}

    # Normalize old_path the same way new_path and stored lines are normalized,
    # otherwise a `~`-form or dotted old_path silently fails to match the stored
    # absolute path, leaving a stale/duplicate entry behind.
    old_path = _normalize_local_path(old_skills_path)
    validated_new_path, mapping_error = _validate_mapping_target(skills_path)
    if validated_new_path is None:
        return {"success": False, "message": mapping_error}
    new_path = str(validated_new_path)

    lines = []
    if CUSTOM_TARGETS_FILE.exists():
        lines = CUSTOM_TARGETS_FILE.read_text(encoding="utf-8").splitlines()
    original_custom_content = "\n".join(lines) + ("\n" if lines else "")

    updated = False
    new_lines = []
    
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            new_lines.append(line)
            continue
        
        # Parse line
        line_name, line_path = "", ""
        line_name, line_path = _target_line_parts(stripped)
        if not line_name:
            line_path = stripped
            line_name = get_agent_name(line_path)

        line_path_normalized = _normalize_local_path(line_path)
        if line_path_normalized == old_path:
            if not updated:
                new_lines.append(f"{name}={new_path}")
            updated = True
        else:
            new_lines.append(line)

    if not updated and new_path != old_path:
        new_lines.append(f"{name}={new_path}")

    # Save to custom-targets.txt (must succeed before creating symlinks)
    try:
        _atomic_write_text(CUSTOM_TARGETS_FILE, "\n".join(new_lines) + "\n")
    except OSError as e:
        return {"success": False, "message": f"Failed to write config: {e}"}

    path_configs = _load_agent_path_configs()
    updated_configs = []
    for entry in path_configs:
        entry_path = _normalize_local_path(str(entry.get("skills_path", "")))
        if entry_path in {old_path, new_path}:
            continue
        updated_configs.append(entry)
    updated_configs.append({
        "name": name,
        "skills_path": new_path,
        "instructions_path": new_instructions_path,
    })
    try:
        _save_agent_path_configs(updated_configs)
    except OSError as e:
        try:
            _atomic_write_text(CUSTOM_TARGETS_FILE, original_custom_content)
        except OSError:
            pass
        return {"success": False, "message": f"Failed to write Agent path config: {e}"}

    # Preserve the Agent's connection state while moving its skills path.
    # Do not silently ignore disabled-target persistence failures: a failed
    # write can make the UI report a mapped target as disabled (or vice versa)
    # after the path metadata has already been committed.
    if bool((current or {}).get("mapped")):
        cleanup_warning = ""
        if new_path != old_path:
            map_result = do_map(new_path)
            if not map_result.get("success"):
                return {
                    "success": False,
                    "message": (
                        f"Agent paths were saved, but the new skills path could not be mapped: "
                        f"{map_result.get('message', 'unknown mapping error')}. "
                        "The old skills links were preserved."
                    ),
                    "skills_path": new_path,
                    "instructions_path": new_instructions_path,
                    "partial": True,
                }
            cleanup_result = do_unmap(old_path)
            if not cleanup_result.get("success") or cleanup_result.get("partial"):
                cleanup_warning = (
                    f" Warning: old skills links at {old_path} could not be fully removed: "
                    f"{cleanup_result.get('message', 'unknown cleanup error')}."
                )
            elif not _remove_from_disabled_targets(old_path):
                cleanup_warning = (
                    f" Warning: old skills links were removed, but the disabled-target state "
                    f"for {old_path} could not be cleared."
                )
        elif not _remove_from_disabled_targets(new_path):
            cleanup_warning = (
                f" Warning: the Agent is mapped, but the disabled-target state for {new_path} "
                "could not be cleared."
            )
    else:
        if not _add_to_disabled_targets(new_path):
            return {
                "success": False,
                "message": (
                    f"Agent paths were saved, but the disabled-target state for {new_path} "
                    "could not be persisted."
                ),
                "skills_path": new_path,
                "instructions_path": new_instructions_path,
                "partial": True,
            }
        cleanup_warning = ""

    result = {
        "success": True,
        "message": f"Updated {name} skills and instructions paths.{cleanup_warning}",
        "skills_path": new_path,
        "instructions_path": new_instructions_path,
    }
    if cleanup_warning:
        result["partial"] = True
    return result


def update_agent_path(name: str, old_path: str, new_path: str) -> dict:
    """Backward-compatible single-path wrapper used by older callers."""
    normalized_old = _normalize_local_path(old_path)
    current = next(
        (
            agent for agent in get_visible_agents()
            if _normalize_local_path(str(agent.get("path", ""))) == normalized_old
        ),
        None,
    )
    instructions_path = str((current or {}).get("instructions_path", "")).strip()
    if not instructions_path:
        instructions_path = str(Path(new_path).expanduser().parent / "AGENTS.md")
    return update_agent_paths(name, old_path, new_path, instructions_path)


@_writes_locked_proc
def register_custom_agent(skills_path: str, instructions_path: str) -> dict:
    """Register a custom Agent with both skill and instruction channels."""
    validated_skills_path, mapping_error = _validate_mapping_target(skills_path)
    if validated_skills_path is None:
        return {"success": False, "message": mapping_error}
    skills_path = str(validated_skills_path)
    instructions_path = _normalize_local_path(instructions_path)
    if not instructions_path:
        return {"success": False, "message": "Instructions file path cannot be empty"}
    instruction_target = Path(instructions_path)
    if instruction_target.exists() and instruction_target.is_dir():
        return {"success": False, "message": "Instructions path must point to a file, not a directory"}

    was_registered = any(
        _normalize_local_path(_target_path_from_line(line)) == skills_path
        for line in get_custom_targets()
    )
    deploy_result = run_deploy("--add", skills_path)
    if not deploy_result.get("success"):
        return deploy_result

    entries = [
        entry for entry in _load_agent_path_configs()
        if _normalize_local_path(str(entry.get("skills_path", ""))) != skills_path
    ]
    entries.append({
        "name": get_agent_name(skills_path),
        "skills_path": skills_path,
        "instructions_path": instructions_path,
    })
    try:
        _save_agent_path_configs(entries)
    except OSError as exc:
        if not was_registered:
            run_deploy("--remove", skills_path)
        return {"success": False, "message": f"Failed to save Agent paths: {exc}"}

    return {
        "success": True,
        "message": f"Registered Agent skills and instructions channels\n{deploy_result.get('message', '')}".strip(),
        "skills_path": skills_path,
        "instructions_path": instructions_path,
    }


@_writes_locked_proc
def remove_custom_agent(skills_path: str) -> dict:
    skills_path = _normalize_local_path(skills_path)
    result = run_deploy("--remove", skills_path)
    if not result.get("success"):
        return result
    entries = [
        entry for entry in _load_agent_path_configs()
        if _normalize_local_path(str(entry.get("skills_path", ""))) != skills_path
    ]
    try:
        _save_agent_path_configs(entries)
    except OSError as exc:
        return {
            "success": True,
            "message": f"{result.get('message', '')}\nWarning: stale Agent path metadata could not be removed: {exc}".strip(),
        }
    return result


def _sha256_file(path: str) -> str:
    """Return the hex SHA-256 digest of the file at *path*."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _download_github_file(url: str, destination: str, *, max_bytes: int = 100 * 1024 * 1024) -> None:
    """Download a bounded release artifact and validate the final redirect."""
    if not _is_github_download_url(url):
        raise ValueError(f"Untrusted GitHub download URL: {url}")
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/vnd.github+json", "User-Agent": "EasySkills-WebUI"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        final_url = response.geturl()
        if not _is_github_download_url(final_url):
            raise ValueError(f"Download redirected to an untrusted host: {final_url}")
        raw_length = response.headers.get("Content-Length")
        if raw_length:
            try:
                declared_length = int(raw_length)
            except ValueError as exc:
                raise ValueError(f"Invalid release Content-Length: {raw_length!r}") from exc
            if declared_length < 0 or declared_length > max_bytes:
                raise ValueError("Release archive exceeds the 100 MB safety limit")

        written = 0
        with open(destination, "wb") as output:
            while True:
                chunk = response.read(64 * 1024)
                if not chunk:
                    break
                written += len(chunk)
                if written > max_bytes:
                    raise ValueError("Release archive exceeds the 100 MB safety limit")
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())


def _safe_extract_tar(
    tf: tarfile.TarFile,
    dest: str,
    *,
    max_members: int = 10_000,
    max_total_size: int = 512 * 1024 * 1024,
) -> None:
    """Extract *tf* into *dest* rejecting unsafe members.

    Guards against path traversal (absolute paths, ``..``) and links pointing
    outside *dest* — the vulnerabilities that bare ``extractall`` exposes on
    Python < 3.12 (where the ``filter="data`` argument is unavailable). Used for
    the self-update tarball so a crafted release cannot write outside the
    temporary directory.
    """
    members = tf.getmembers()
    if len(members) > max_members:
        raise ValueError(f"Release archive contains too many entries ({len(members)} > {max_members})")
    total_size = sum(member.size for member in members if member.isfile())
    if total_size > max_total_size:
        raise ValueError("Release archive exceeds the 512 MB extracted-size safety limit")

    seen: set[str] = set()
    links: dict[str, tuple[str, bool]] = {}

    def normalize_name(name: str) -> str:
        if not name or "\x00" in name or "\\" in name:
            raise ValueError(f"Refusing to extract invalid path: {name!r}")
        normalized = posixpath.normpath(name)
        if normalized in ("", "."):
            return ""
        if normalized == ".." or normalized.startswith("../") or normalized.startswith("/"):
            raise ValueError(f"Refusing to extract unsafe path: {name!r}")
        return normalized

    for member in members:
        if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
            raise ValueError(f"Refusing to extract unsupported tar member type: {member.name!r}")
        normalized = normalize_name(member.name)
        if not normalized or normalized in seen:
            raise ValueError(f"Refusing to extract duplicate path: {member.name!r}")
        seen.add(normalized)
        if member.issym() or member.islnk():
            if not member.linkname or "\x00" in member.linkname or os.path.isabs(member.linkname):
                raise ValueError(f"Refusing to extract unsafe link: {member.name!r}")
            links[normalized] = (member.linkname, member.issym())

    def resolve_virtual(path: str, follow_final: bool = True) -> str:
        """Resolve archive-internal links without touching the host filesystem."""
        current = normalize_name(path)
        visited: set[str] = set()
        for _ in range(64):
            parts = current.split("/") if current else []
            replaced = False
            for index in range(1, len(parts) + 1):
                prefix = "/".join(parts[:index])
                if prefix not in links or (index == len(parts) and not follow_final):
                    continue
                if prefix in visited:
                    raise ValueError(f"Refusing to extract cyclic link: {prefix!r}")
                linkname, is_symlink = links[prefix]
                if is_symlink:
                    base = posixpath.dirname(prefix)
                    replacement = posixpath.normpath(posixpath.join(base, linkname))
                else:
                    replacement = posixpath.normpath(linkname)
                if replacement == ".." or replacement.startswith("../") or replacement.startswith("/"):
                    raise ValueError(f"Refusing to extract unsafe link: {prefix!r}")
                rest = "/".join(parts[index:])
                current = normalize_name(posixpath.join(replacement, rest))
                visited.add(prefix)
                replaced = True
                break
            if not replaced:
                return current
        raise ValueError("Refusing to extract an excessively deep link chain")

    # Resolve every member through the virtual archive graph before extracting
    # anything. This prevents a safe-looking path from escaping via a symlink
    # declared elsewhere in the same archive.
    for normalized in seen:
        resolve_virtual(normalized)

    for member in members:
        try:
            tf.extract(member, dest, filter="data")
        except TypeError:
            # Python < 3.12 has no filter parameter; the complete virtual-link
            # validation above remains the compatibility safety barrier.
            tf.extract(member, dest)


def _find_release_root(extract_dir: Path) -> Path:
    """Return the one extracted root that contains the EasySkills engine.

    Release archives normally contain a single top-level directory, but using
    the first directory returned by the filesystem makes the selected source
    nondeterministic when an archive contains extra roots.  Reject both an
    incomplete archive and an ambiguous one before any live files are touched.
    """
    candidates = sorted(
        (
            entry
            for entry in extract_dir.iterdir()
            if entry.is_dir() and (entry / "EasySkills维护工具/.engine").is_dir()
        ),
        key=lambda entry: entry.name,
    )
    if not candidates:
        raise ValueError("Archive does not contain EasySkills维护工具/.engine/")
    if len(candidates) != 1:
        names = ", ".join(candidate.name for candidate in candidates)
        raise ValueError(f"Archive contains multiple EasySkills source roots: {names}")
    return candidates[0]


@_writes_locked_proc
def do_self_update() -> dict:
    gateway_result = {"attempted": False, "success": True, "message": ""}
    update_warning = ""
    try:
        release = get_latest_release()
        if not release.get("success"):
            return release
        latest_tag = release.get("tag_name", "")
        if not latest_tag:
            return {"success": False, "message": "Could not determine latest version"}

        tarball_url = release.get("tarball_url", "")
        if not tarball_url:
            return {"success": False, "message": "No tarball URL in release"}
        # Defense against a tampered API response redirecting the update to an
        # arbitrary host. Only known GitHub delivery hosts are allowed.
        if not _is_github_download_url(tarball_url):
            return {
                "success": False,
                "message": f"Update rejected: tarball URL host is not a trusted GitHub host ({tarball_url}).",
            }

        with tempfile.TemporaryDirectory() as tmp:
            archive_path = os.path.join(tmp, "release.tar.gz")
            _download_github_file(tarball_url, archive_path)

            # Corruption check: the tarball must parse cleanly end-to-end.
            # (A second download would only catch random transport corruption
            # at double the bandwidth and lock-hold time; safe extraction
            # below already rejects truncated/tampered archives.)
            archive_digest = _sha256_file(archive_path)
            logging.info("Self-update archive sha256=%s", archive_digest)

            with tarfile.open(archive_path, "r:gz") as tf:
                # Safe extraction rejects absolute paths, ../ traversal, and
                # links escaping the dest dir — works on all Python versions
                # (the filter="data" arg is 3.12+ only).
                _safe_extract_tar(tf, tmp)

            src_root = _find_release_root(Path(tmp))

            # Preserve user runtime files (not shipped in the release tarball)
            custom_backup = None
            if CUSTOM_TARGETS_FILE.exists():
                custom_backup = CUSTOM_TARGETS_FILE.read_text(encoding="utf-8")
            disabled_backup = None
            if DISABLED_TARGETS_FILE.exists():
                disabled_backup = DISABLED_TARGETS_FILE.read_text(encoding="utf-8")

            # --- Backup current engine dir for rollback (atomic via temp rename) ---
            dest_maint = CENTRAL_DIR / "EasySkills维护工具/.engine"
            backup_maint = CENTRAL_DIR / ".maintenance-bak"
            backup_maint_new = CENTRAL_DIR / ".maintenance-bak.new"

            src_maint = src_root / "EasySkills维护工具/.engine"
            expected_version = latest_tag[1:] if latest_tag.startswith("v") else latest_tag
            source_version_file = src_maint / ".version"
            try:
                source_version = source_version_file.read_text(encoding="utf-8").strip()
            except OSError as exc:
                return {"success": False, "message": f"Archive version could not be read: {exc}"}
            if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?", expected_version):
                return {"success": False, "message": f"Release tag has an invalid version: {latest_tag}"}
            if source_version != expected_version:
                return {
                    "success": False,
                    "message": f"Archive version {source_version!r} does not match release tag {latest_tag!r}.",
                }

            # Reconcile an interrupted prior update before starting a new one.
            # When .bak is absent, .bak.new may be the only remaining rollback
            # snapshot and must be promoted rather than overwritten/deleted.
            if backup_maint_new.exists():
                if backup_maint.exists():
                    shutil.rmtree(backup_maint_new)
                else:
                    try:
                        backup_maint_new.rename(backup_maint)
                    except OSError as exc:
                        return {
                            "success": False,
                            "message": f"Could not reconcile the preserved rollback snapshot: {exc}",
                        }

            # Build new engine in a temp dir, then rename atomically
            new_maint_tmp = CENTRAL_DIR / "EasySkills维护工具/.engine.new"
            if new_maint_tmp.exists():
                shutil.rmtree(new_maint_tmp)
            shutil.copytree(src_maint, new_maint_tmp)

            # Carry user runtime files INTO the new tree so they survive the
            # rename rotation below (the tarball does not contain them).
            if custom_backup is not None:
                (new_maint_tmp / "custom-targets.txt").write_text(custom_backup, encoding="utf-8")
            if disabled_backup is not None:
                (new_maint_tmp / "disabled-targets.txt").write_text(disabled_backup, encoding="utf-8")
            # Preserve the auth token (copy2 keeps the 0600 mode) so existing
            # browser sessions stay valid if the service restarts post-update.
            if TOKEN_FILE.exists():
                try:
                    shutil.copy2(TOKEN_FILE, new_maint_tmp / TOKEN_FILE.name)
                except OSError:
                    pass

            # Prepare executable modes while the new engine is still staged.
            # A permission failure must happen before the live directory moves.
            for script in ("deploy.sh", "watch.sh", "unwatch.sh"):
                staged_script = new_maint_tmp / script
                if staged_script.exists():
                    staged_script.chmod(0o755)

            # Select the documentation source now, but update the live README
            # only after the engine swap succeeds.
            src_readme = src_root / "EasySkills维护工具/README_SYSTEM.md"
            src_old = src_root / "SKILL.md"
            readme_source = src_readme if src_readme.is_file() else (src_old if src_old.is_file() else None)

            # Snapshot existing backup (so we can revert even the backup on failure)
            if backup_maint.exists():
                if backup_maint_new.exists():
                    shutil.rmtree(backup_maint_new)
                shutil.copytree(backup_maint, backup_maint_new)

            try:
                # Rotate: current -> .bak, new -> current  (two renames, fast)
                if dest_maint.exists():
                    if backup_maint.exists():
                        shutil.rmtree(backup_maint)
                    dest_maint.rename(backup_maint)

                new_maint_tmp.rename(dest_maint)

                # The live swap is complete. Failure to remove the redundant
                # prior-backup snapshot is non-fatal; the next update will
                # reconcile it safely.
                if backup_maint_new.exists():
                    try:
                        shutil.rmtree(backup_maint_new)
                    except OSError as exc:
                        update_warning += f" Old backup snapshot cleanup failed: {exc}."

                gateway_result = _install_gateway_for_engine(dest_maint, src_root / "gateway")

            except Exception:
                # Rollback. Two renames happened above; the dangerous case is
                # when the FIRST (current -> .bak) succeeded but the SECOND
                # (new -> current) failed: the running version now lives in
                # backup_maint and dest_maint is gone. The correct recovery is
                # to UNDO the first rename (move .bak back to current), NOT to
                # delete backup_maint — that would destroy the current version.
                try:
                    if new_maint_tmp.exists():
                        shutil.rmtree(new_maint_tmp)
                    # Undo the current->.bak rotation so the live version is
                    # restored to its original place.
                    if not dest_maint.exists() and backup_maint.exists():
                        backup_maint.rename(dest_maint)
                    # Restore the pre-existing .bak snapshot (we overwrote it).
                    if backup_maint_new.exists() and not backup_maint.exists():
                        backup_maint_new.rename(backup_maint)
                except Exception:
                    pass
                raise

            if readme_source is not None:
                readme_dest = CENTRAL_DIR / "EasySkills维护工具/README_SYSTEM.md"
                readme_staged = readme_dest.with_name(".README_SYSTEM.md.new")
                try:
                    shutil.copy2(readme_source, readme_staged)
                    os.replace(readme_staged, readme_dest)
                except OSError as exc:
                    update_warning += f" Documentation refresh failed: {exc}."
                    try:
                        readme_staged.unlink(missing_ok=True)
                    except OSError:
                        pass

        sync_result = run_deploy("--sync")

        new_version = get_version()
        sync_ok = bool(sync_result.get("success"))
        message = f"Updated to {new_version}."
        if sync_ok:
            message += " All agents re-synced."
        else:
            message += f" Update succeeded, but agent re-sync failed: {sync_result.get('message', 'unknown error')}"
        if gateway_result.get("attempted") and not gateway_result.get("success"):
            message += " Gateway update failed; the previous binary was preserved. Run Doctor and retry the Gateway installation."
        message += update_warning
        message += " The UI will reload to pick up the new version."
        return {
            "success": True,
            "message": message,
            "version": new_version,
            "sync_success": sync_ok,
            "gateway_success": bool(gateway_result.get("success")),
            # Signal the frontend to reload: the running Python process still
            # holds the pre-update code, so a page reload (or a supervisor
            # restart) is needed to serve the new logic.
            "_restart": True,
        }
    except Exception as e:
        return {"success": False, "message": f"Update failed: {e}"}


@_writes_locked_proc
def do_rollback() -> dict:
    backup_maint = CENTRAL_DIR / ".maintenance-bak"
    dest_maint = CENTRAL_DIR / "EasySkills维护工具/.engine"
    if not backup_maint.exists():
        return {"success": False, "message": "No backup found. Nothing to roll back."}
    try:
        # Recover a current engine stranded in .engine.prev by an interrupted
        # prior rollback. Never delete .prev when the normal live path is
        # missing: it may be the only runnable copy left.
        prev = CENTRAL_DIR / "EasySkills维护工具/.engine.prev"
        if prev.exists():
            if dest_maint.exists():
                shutil.rmtree(prev)
            else:
                try:
                    prev.rename(dest_maint)
                except OSError as exc:
                    return {
                        "success": False,
                        "message": f"Rollback recovery snapshot is preserved at {prev}, but could not be restored: {exc}",
                    }

        # Preserve the user's CURRENT runtime files across the rollback
        custom_backup = None
        if CUSTOM_TARGETS_FILE.exists():
            custom_backup = CUSTOM_TARGETS_FILE.read_text(encoding="utf-8")
        disabled_backup = None
        if DISABLED_TARGETS_FILE.exists():
            disabled_backup = DISABLED_TARGETS_FILE.read_text(encoding="utf-8")

        # Atomic rollback: copy backup to a temp name, then rotate via rename
        rollback_tmp = CENTRAL_DIR / "EasySkills维护工具/.engine.rollback"
        if rollback_tmp.exists():
            shutil.rmtree(rollback_tmp)
        shutil.copytree(backup_maint, rollback_tmp)

        # Carry runtime files into the tree that will become the new engine
        if custom_backup is not None:
            (rollback_tmp / "custom-targets.txt").write_text(custom_backup, encoding="utf-8")
        if disabled_backup is not None:
            (rollback_tmp / "disabled-targets.txt").write_text(disabled_backup, encoding="utf-8")
        if TOKEN_FILE.exists():
            try:
                shutil.copy2(TOKEN_FILE, rollback_tmp / TOKEN_FILE.name)
            except OSError:
                pass

        try:
            # Rotate: current -> .prev, rollback-tmp -> current (two renames).
            if dest_maint.exists():
                dest_maint.rename(prev)
            rollback_tmp.rename(dest_maint)
        except Exception:
            # If the second rename failed after the first succeeded, the
            # current version is stranded in .prev — restore it.
            try:
                if not dest_maint.exists() and prev.exists():
                    prev.rename(dest_maint)
                if rollback_tmp.exists():
                    shutil.rmtree(rollback_tmp)
            except Exception:
                pass
            raise

        # Remove the transient .prev directory now that the rotation succeeded.
        if prev.exists():
            shutil.rmtree(prev)

        for script in ("deploy.sh", "watch.sh", "unwatch.sh"):
            s = dest_maint / script
            if s.exists():
                s.chmod(0o755)

        gateway_result = _install_gateway_for_engine(dest_maint)

        sync_result = run_deploy("--sync")
        # Remove backup so a second rollback doesn’t restore stale state
        try:
            shutil.rmtree(backup_maint)
        except OSError:
            pass
        version = get_version()
        sync_ok = bool(sync_result.get("success"))
        message = f"Rolled back to {version}."
        if sync_ok:
            message += " All agents re-synced."
        else:
            message += f" Rollback succeeded, but agent re-sync failed: {sync_result.get('message', 'unknown error')}"
        if gateway_result.get("attempted") and not gateway_result.get("success"):
            message += " Gateway rollback failed; the existing binary was preserved. Run Doctor and retry the Gateway installation."
        message += " The UI will reload to pick up the rolled-back version."
        return {
            "success": True,
            "message": message,
            "version": version,
            "sync_success": sync_ok,
            "gateway_success": bool(gateway_result.get("success")),
            # Same rationale as do_self_update: the running process holds the
            # pre-rollback code until a reload/supervisor restart.
            "_restart": True,
        }
    except Exception as e:
        return {"success": False, "message": f"Rollback failed: {e}"}


# ──────────────────────────────────────────────────────────────
# HTTP handler
# ──────────────────────────────────────────────────────────────

_backend_restart_scheduled = threading.Event()
_INVALID_REQUEST_BODY = object()
_MISSING_CONTENT_LENGTH = object()


def _schedule_backend_restart(server) -> None:
    """Stop this backend after its response and ensure new disk code starts."""
    if _backend_restart_scheduled.is_set():
        return
    _backend_restart_scheduled.set()

    try:
        if os.environ.get("EASYSKILLS_SUPERVISED") != "1":
            # Manual macOS/Linux launches have no supervisor. Start a detached
            # helper that waits for this PID to disappear, then launches the newly
            # installed backend. Under a supervisor we only exit and let it restart
            # us, avoiding a duplicate-process race.
            helper = r"""
import os, socket, subprocess, sys, time
old_pid, python_bin, webui_script, port = int(sys.argv[1]), sys.argv[2], sys.argv[3], int(sys.argv[4])
# After the self-update swap, this process still holds the OLD pid, and
# EasySkills维护工具/.engine/ now contains the NEW code. Wait for the old pid to exit,
# then probe the port: if a new backend is already listening (a supervisor
# restarted us in the meantime), don't double-launch. Only start the new
# backend from the freshly installed tree if nothing is listening yet.
for _ in range(200):
    try:
        os.kill(old_pid, 0)
    except ProcessLookupError:
        break
    except PermissionError:
        break
    time.sleep(0.05)
else:
    raise SystemExit(1)
sock = socket.socket()
sock.settimeout(0.2)
try:
    if sock.connect_ex(("127.0.0.1", port)) == 0:
        raise SystemExit(0)
finally:
    sock.close()
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
"""
            env = os.environ.copy()
            env["EASYSKILLS_NO_BROWSER"] = "1"
            subprocess.Popen(
                [
                    _sys.executable,
                    "-c",
                    helper,
                    str(os.getpid()),
                    _sys.executable,
                    str(CENTRAL_DIR / "EasySkills维护工具/.engine" / "webui.py"),
                    str(PORT),
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
                env=env,
            )
    except Exception:
        # Keep the old backend alive and allow a later retry if the detached
        # replacement helper could not be created.
        _backend_restart_scheduled.clear()
        raise

    # TCPServer.shutdown must run from a different thread than serve_forever.
    threading.Thread(target=server.shutdown, daemon=True).start()


def _render_index_template(template: str, token: str, nonce: str | None = None) -> tuple[str, str]:
    """Inject the CSP nonce and escaped token into the static index template."""
    nonce = nonce or secrets.token_urlsafe(18)
    # Replace the nonce first, then inject an attribute-escaped token. This
    # prevents an environment-supplied token containing the nonce placeholder
    # from acquiring permission to execute script.
    page = template.replace("__EASYSKILLS_NONCE__", nonce)
    page = page.replace("__EASYSKILLS_TOKEN__", html_lib.escape(token, quote=True))
    return page, nonce


class Handler(http.server.BaseHTTPRequestHandler):
    # Per-connection socket timeout: a slow/idle client (or a slowloris-style
    # drip) gets dropped after this many seconds rather than pinning a server
    # thread indefinitely. Local-only tool, so a generous value is fine.
    timeout = 60

    def log_message(self, fmt, *args):
        if _debug_enabled:
            logging.debug("%s - %s", self.client_address[0], fmt % args)

    def _is_token_valid(self) -> bool:
        """Check the X-EasySkills-Token header (used for both GET and POST API auth)."""
        token = self.headers.get("X-EasySkills-Token", "")
        return hmac.compare_digest(token, WEBUI_TOKEN)

    def _is_host_allowed(self) -> bool:
        host = self.headers.get("Host", "")
        allowed = {f"localhost:{PORT}", f"127.0.0.1:{PORT}"}
        return host in allowed

    def _cors_origin(self):
        origin = self.headers.get("Origin", "")
        if origin in ALLOWED_ORIGINS:
            return origin
        return None

    def _send_security_headers(self):
        # Defense-in-depth: prevent MIME sniffing and clickjacking. The page
        # embeds the auth token in a <meta> tag, so it must not be framable by
        # any other (even loopback) origin.
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")

    def _json(self, data, status: int = 200):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._send_security_headers()
        cors_origin = self._cors_origin()
        if cors_origin:
            self.send_header("Access-Control-Allow-Origin", cors_origin)
        self.end_headers()
        self.wfile.write(body)

    def _index(self):
        try:
            page = (WEBUI_DIR / "index.html").read_text(encoding="utf-8")
            page, nonce = _render_index_template(page, WEBUI_TOKEN)
            data = page.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self._send_security_headers()
            self.send_header(
                "Content-Security-Policy",
                "default-src 'none'; "
                f"script-src 'nonce-{nonce}'; script-src-attr 'none'; "
                "style-src 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; "
                "font-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
            )
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
            self.end_headers()
            self.wfile.write(data)
        except FileNotFoundError:
            self.send_response(404)
            self.end_headers()

    def _body(self) -> dict | None | object:
        """Parse the JSON request body.

        Returns:
            dict  – on success
            None  – when the body is too large (caller must send 413 and return)
            _INVALID_REQUEST_BODY – on malformed framing or JSON (send 400)
            {}    – on an explicitly empty body (Content-Length: 0)
            _MISSING_CONTENT_LENGTH – when request framing omits Content-Length
        """
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            # The backend intentionally does not implement chunked request
            # decoding.  Reject an unframed POST instead of treating it as an
            # empty request while leaving bytes unread on a keep-alive socket.
            self.close_connection = True
            return _MISSING_CONTENT_LENGTH
        try:
            length = int(raw_length)
        except (ValueError, TypeError):
            self.close_connection = True
            return _INVALID_REQUEST_BODY
        if not length:
            return {}
        if length > 10 * 1024 * 1024:  # 10 MB cap
            # Do not block while draining an untrusted oversized body. Close
            # this keep-alive connection after the 413 so unread bytes can
            # never be parsed as a subsequent request.
            self.close_connection = True
            return None  # Signal to caller: send 413
        if length < 0:
            self.close_connection = True
            return _INVALID_REQUEST_BODY
        try:
            raw = self.rfile.read(length)
            if len(raw) != length:
                self.close_connection = True
                return _INVALID_REQUEST_BODY
            parsed = json.loads(raw)
            if not isinstance(parsed, dict):
                self.close_connection = True
                return _INVALID_REQUEST_BODY
            return parsed
        except (json.JSONDecodeError, OSError, UnicodeError, ValueError):
            self.close_connection = True
            return _INVALID_REQUEST_BODY

    def _is_post_allowed(self) -> bool:
        origin = self.headers.get("Origin")
        if origin and origin not in ALLOWED_ORIGINS:
            return False
        return self._is_token_valid()

    def _reject_forbidden(self):
        self._json({"success": False, "message": "Forbidden"}, status=403)

    def do_OPTIONS(self):
        if not self._is_host_allowed():
            self.send_response(400)
            self.end_headers()
            return
        cors_origin = self._cors_origin()
        if not cors_origin:
            self.send_response(403)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", cors_origin)
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-EasySkills-Token")
        self.end_headers()

    def do_GET(self):
        if not self._is_host_allowed():
            self.send_response(400)
            self.end_headers()
            return
        path = urllib.parse.urlparse(self.path).path

        if path in ("/", "/index.html"):
            self._index()

        elif path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()

        elif path == "/api/status":
            if not self._is_token_valid():
                self._reject_forbidden()
                return
            watcher = get_watcher_status()
            agents  = get_visible_agents()
            skills  = get_skills()
            instructions = get_instructions()
            instruction_agents = instructions.get("agents", [])
            detected_instruction_agents = [
                agent for agent in instruction_agents if agent.get("active")
            ]
            link_warnings = get_central_dir_warnings()
            mcp_data = get_mcp_config()
            mcp_config = mcp_data.get("config") if mcp_data.get("success") else None
            mcp_servers = mcp_config.get("servers", {}) if isinstance(mcp_config, dict) else {}
            self._json({
                "watcher":       watcher,
                "central_dir":   str(CENTRAL_DIR),
                "skills_count":  len(skills),
                "agents_total":  len(agents),
                "agents_detected": sum(1 for agent in agents if agent.get("active")),
                "agents_mapped": sum(1 for a in agents if a["mapped"]),
                "agent_instruction_paths_configured": sum(
                    1 for agent in agents if agent.get("instructions_path")
                ),
                "agent_instruction_files_existing": sum(
                    1 for agent in agents if agent.get("instructions_exists")
                ),
                "instruction_targets_total": len(instruction_agents),
                "instruction_target_files_existing": sum(
                    1 for agent in instruction_agents if agent.get("exists")
                ),
                "rules_count": len(instructions.get("rules", [])),
                "instruction_agents_detected": len(detected_instruction_agents),
                "instruction_agents_managed": sum(
                    1 for agent in detected_instruction_agents
                    if agent.get("managed_rule_count", 0) > 0
                ),
                "managed_rule_instances": sum(
                    int(agent.get("managed_rule_count", 0) or 0)
                    for agent in detected_instruction_agents
                ),
                "mcp_servers_count": len(mcp_servers),
                "mcp_servers_enabled": sum(
                    1 for server in mcp_servers.values()
                    if isinstance(server, dict) and server.get("enabled", True)
                ),
                "mcp_gateway_installed": bool(mcp_data.get("gateway", {}).get("installed")),
                "version":       get_version(),
                "has_backup":    (CENTRAL_DIR / ".maintenance-bak").is_dir(),
                # Link health: dangling links will be auto-pruned on next sync;
                # external links are valid-but-fragile symlinks.
                "dangling_count":   link_warnings["dangling_count"],
                "external_link_count": link_warnings["external_link_count"],
            })

        elif path == "/api/skills":
            if not self._is_token_valid():
                self._reject_forbidden()
                return
            self._json(get_skills())

        elif path == "/api/agents":
            if not self._is_token_valid():
                self._reject_forbidden()
                return
            self._json(get_visible_agents())

        elif path == "/api/latest-release":
            if not self._is_token_valid():
                self._reject_forbidden()
                return
            self._json(get_latest_release())

        elif path == "/api/instructions":
            if not self._is_token_valid():
                self._reject_forbidden()
                return
            self._json(get_instructions())

        elif path == "/api/mcp":
            if not self._is_token_valid():
                self._reject_forbidden()
                return
            self._json(get_mcp_config())

        elif path == "/api/doctor":
            if not self._is_token_valid():
                self._reject_forbidden()
                return
            self._json(get_doctor_report())

        elif path.startswith("/api/instructions/content/"):
            if not self._is_token_valid():
                self._reject_forbidden()
                return
            rule_name = urllib.parse.unquote(path[len("/api/instructions/content/"):])
            self._json(get_instruction_content(rule_name))

        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if not self._is_host_allowed():
            self.send_response(400)
            self.end_headers()
            return
        if not self._is_post_allowed():
            self._reject_forbidden()
            return
        path = urllib.parse.urlparse(self.path).path
        body = self._body()
        if body is None:  # body too large
            self.send_response(413)  # Request Entity Too Large
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if body is _MISSING_CONTENT_LENGTH:
            self.send_response(411)  # Length Required
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if body is _INVALID_REQUEST_BODY:
            self._json({"success": False, "message": "Invalid JSON request body"}, status=400)
            return

        routes = {
            "/api/sync":                 lambda: run_deploy("--sync"),
            "/api/cleanup":              lambda: run_deploy("--cleanup"),
            "/api/watcher/start":        lambda: run_deploy("--watch"),
            "/api/watcher/stop":         lambda: run_deploy("--unwatch"),
            "/api/agents/map":           lambda: do_map(body.get("path", "")),
            "/api/agents/unmap":         lambda: do_unmap(body.get("path", "")),
            "/api/agents/update":        lambda: update_agent_paths(
                body.get("name", ""),
                body.get("old_skills_path", body.get("old_path", "")),
                body.get("skills_path", body.get("new_path", "")),
                body.get("instructions_path", ""),
            ),
            "/api/agents/custom/add":    lambda: register_custom_agent(
                body.get("skills_path", body.get("path", "")),
                body.get("instructions_path", ""),
            ),
            "/api/agents/custom/remove": lambda: remove_custom_agent(body.get("path", "")),
            "/api/skills/import":        lambda: import_skill_folder(body.get("name", ""), body.get("files", [])),
            "/api/skills/delete":        lambda: delete_skill(body.get("name", "")),
            "/api/instructions/save":    lambda: save_instruction(body.get("name", ""), body.get("content", "")),
            "/api/instructions/delete":  lambda: delete_instruction(body.get("name", "")),
            "/api/instructions/write-all":    lambda: write_instructions_to_all(),
            "/api/instructions/remove-all":   lambda: remove_instructions_from_all(),
            "/api/instructions/write-one":    lambda: write_instructions_to_one(body.get("path", "")),
            "/api/instructions/remove-one":   lambda: remove_instructions_from_one(body.get("path", "")),
            "/api/instructions/write-selected":   lambda: write_selected_instructions(body.get("rules"), body.get("agents")),
            "/api/instructions/remove-selected":  lambda: remove_selected_instructions(body.get("rules"), body.get("agents")),
            "/api/mcp/save":                lambda: save_mcp_config(body.get("config")),
            "/api/mcp/server/add":          lambda: add_mcp_server(body.get("name", ""), body.get("server")),
            "/api/mcp/server/update":       lambda: update_mcp_server(body.get("name", ""), body.get("server")),
            "/api/mcp/server/delete":       lambda: delete_mcp_server(body.get("name", "")),
            "/api/mcp/test":                lambda: test_mcp_gateway(body.get("profile", "default"), body.get("server", "")),
            "/api/update":               lambda: do_self_update(),
            "/api/rollback":             lambda: do_rollback(),
        }

        handler = routes.get(path)
        if handler:
            try:
                result = handler()
                restart = bool(
                    isinstance(result, dict)
                    and result.get("success")
                    and result.get("_restart")
                )
                try:
                    self._json(result)
                finally:
                    if restart:
                        try:
                            _schedule_backend_restart(self.server)
                        except Exception as restart_error:
                            # The success response has already been emitted; do
                            # not attempt a second HTTP response. The scheduler
                            # cleared its flag and deliberately kept this old
                            # backend alive so the user can retry safely.
                            logging.error("Backend restart scheduling failed: %s", restart_error)
            except Exception as exc:
                if _debug_enabled:
                    logging.exception("Unhandled API error for %s", path)
                logging.error("Unhandled API error for %s: %s", path, exc)
                self._json(
                    {"success": False, "message": "Request failed due to an internal error; see the service log for details."},
                    status=500,
                )
        else:
            self.send_response(404)
            self.end_headers()


# ──────────────────────────────────────────────────────────────
# Debug logging
# ──────────────────────────────────────────────────────────────

_debug_enabled = os.environ.get("EASYSKILLS_DEBUG", "").lower() in ("1", "true", "yes")
if _debug_enabled:
    logging.basicConfig(
        level=logging.DEBUG,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

# ──────────────────────────────────────────────────────────────
# Per-skill symlink cleanup helper
# ──────────────────────────────────────────────────────────────

def _iter_agent_skill_dirs():
    """Yield all existing agent skill directories (for targeted symlink removal).

    Deduplicates paths to avoid redundant syscall overhead when a custom
    target overlaps with a DEFAULT_AGENTS entry.
    """
    seen: set[str] = set()
    for _, agent_path in DEFAULT_AGENTS:
        if agent_path.is_dir():
            key = str(agent_path)
            if key not in seen:
                seen.add(key)
                yield agent_path
    # Also include custom targets
    try:
        if CUSTOM_TARGETS_FILE.exists():
            for line in CUSTOM_TARGETS_FILE.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if line and not line.startswith("#"):
                    p = _target_path_from_line(line)
                    tp = Path(p).expanduser()
                    if tp.is_dir():
                        key = str(tp)
                        if key not in seen:
                            seen.add(key)
                            yield tp
    except OSError:
        pass


# ──────────────────────────────────────────────────────────────
# Entry point
# ──────────────────────────────────────────────────────────────

def main():
    if "--doctor" in _sys.argv:
        report = get_doctor_report()
        print(json.dumps(report, ensure_ascii=False, indent=2))
        _sys.exit(0 if report["success"] else 1)

    if "--sync-rules" in _sys.argv:
        res = write_instructions_to_all()
        print(f"Rules Sync: {'Success' if res['success'] else 'Failed'} - {res['message']}")
        _sys.exit(0 if res['success'] else 1)

    if _debug_enabled:
        logging.debug("Debug mode enabled (EASYSKILLS_DEBUG=1)")
        logging.debug("CENTRAL_DIR=%s SCRIPT_DIR=%s", CENTRAL_DIR, SCRIPT_DIR)

    print("\n  🚀 EasySkills WebUI")
    print("  ┌──────────────────────────────────────┐")
    print(f"  │   http://127.0.0.1:{PORT}              │")
    print("  │   Press Ctrl+C to stop               │")
    if _debug_enabled:
        print("  │   Debug mode: ON                     │")
    print("  └──────────────────────────────────────┘\n")

    # Auto-open browser (cross-platform), unless suppressed by caller
    if os.environ.get("EASYSKILLS_NO_BROWSER") != "1":
        try:
            import subprocess as sp
            current_os = platform.system()
            if current_os == "Darwin":
                sp.Popen(["open", f"http://127.0.0.1:{PORT}"],
                         stdout=sp.DEVNULL, stderr=sp.DEVNULL)
            elif current_os == "Linux":
                sp.Popen(["xdg-open", f"http://127.0.0.1:{PORT}"],
                         stdout=sp.DEVNULL, stderr=sp.DEVNULL)
            # Windows is handled by webui.ps1, but just in case:
            elif current_os == "Windows":
                sp.Popen(["cmd", "/c", "start", f"http://127.0.0.1:{PORT}"],
                         stdout=sp.DEVNULL, stderr=sp.DEVNULL)
        except Exception:
            pass

    class ThreadedServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
        allow_reuse_address = True
        daemon_threads = True
        # Cap the backlog of not-yet-accepted connections. Combined with the
        # per-handler timeout above, this bounds resource use under a burst of
        # connections (local-only, so a modest cap is plenty).
        request_queue_size = 16

    httpd = None

    def _graceful_shutdown(signum, frame):
        """Handle SIGTERM/SIGINT for graceful shutdown."""
        if _debug_enabled:
            logging.debug("Received signal %s, shutting down gracefully...", signum)
        if httpd is not None:
            threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _graceful_shutdown)
    signal.signal(signal.SIGINT, _graceful_shutdown)

    try:
        httpd = ThreadedServer(("127.0.0.1", PORT), Handler)
        httpd.serve_forever()
        if _debug_enabled:
            logging.debug("Server shut down cleanly.")
    except OSError as e:
        print(f"  ❌ Cannot bind to port {PORT}: {e}")
        print("     Is another instance already running?")
    finally:
        if httpd is not None:
            httpd.server_close()


if __name__ == "__main__":
    main()
