#!/usr/bin/env python3
# ==============================================================================
# Script: webui.py (macOS/Linux)
# Description: EasySkills WebUI backend — Python 3 stdlib only, zero pip deps.
# Usage: python3 _maintenance/webui.py
#        or: bash _maintenance/deploy.sh --webui
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

import hashlib
import http.server
import logging
import signal
import socketserver
import base64
import binascii
import functools
import fcntl
import hmac
import json
import os
import platform
import secrets
import shutil
import subprocess
import tarfile
import tempfile
import threading
import urllib.parse
import urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
CENTRAL_DIR = SCRIPT_DIR.parent

# Dynamically resolve to official home directory installation if it exists.
# An explicit EASYSKILLS_CENTRAL_DIR env var wins over any heuristic so
# multi-instance setups (repo clone + home install) behave predictably.
HOME_CENTRAL_DIR = Path.home() / "EasySkills"
_env_central = os.environ.get("EASYSKILLS_CENTRAL_DIR")
if _env_central:
    _env_path = Path(_env_central).expanduser().resolve()
    if _env_path.is_dir() and (_env_path / "_maintenance").is_dir():
        CENTRAL_DIR = _env_path
        SCRIPT_DIR = _env_path / "_maintenance"
elif (HOME_CENTRAL_DIR.exists() and HOME_CENTRAL_DIR.is_dir()
      and not (CENTRAL_DIR / ".git").exists()
      and (HOME_CENTRAL_DIR / "_maintenance" / ".version").exists()):
    CENTRAL_DIR = HOME_CENTRAL_DIR
    SCRIPT_DIR = HOME_CENTRAL_DIR / "_maintenance"

CUSTOM_TARGETS_FILE = SCRIPT_DIR / "custom-targets.txt"
DISABLED_TARGETS_FILE = SCRIPT_DIR / "disabled-targets.txt"
AGENT_PATH_CONFIG_FILE = CENTRAL_DIR / ".easyskills-agent-paths.json"

def _add_to_disabled_targets(path_str: str):
    if not path_str or not path_str.strip():
        return
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
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
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
            pass

def _remove_from_disabled_targets(path_str: str):
    if not path_str or not path_str.strip() or not DISABLED_TARGETS_FILE.exists():
        return
    path_str = path_str.strip()
    try:
        norm_path = str(Path(path_str).expanduser().resolve())
    except Exception:
        norm_path = str(Path(path_str).expanduser())

    lines = []
    try:
        lines = DISABLED_TARGETS_FILE.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return

    new_lines = []
    updated = False
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
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
            pass

def _get_disabled_targets() -> set[str]:
    disabled = set()
    if DISABLED_TARGETS_FILE.exists():
        try:
            for line in DISABLED_TARGETS_FILE.read_text(encoding="utf-8").splitlines():
                stripped = line.strip()
                if stripped and not stripped.startswith("#"):
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
    WEBUI_DIR = Path(__file__).parent.resolve() / "webui"

# --- Instruction-rule library (AGENTS.md / CLAUDE.md management) ---
# Modular rule files live here; "write to all agents" concatenates them into a
# single managed block injected into each agent's global instruction file.
INSTRUCTIONS_DIR = CENTRAL_DIR / "instructions"
INSTRUCTION_SYNC_STATE_FILE = CENTRAL_DIR / ".easyskills-instruction-state.json"
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
        return env_token
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
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)

WEBUI_TOKEN = _load_or_create_token()

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
        ("MiniMax Code",                   Path.home() / ".mavis/skills"),
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
if not _qoder_cn_skills.exists():
    _qoder_cn_skills.mkdir(parents=True, exist_ok=True)

EXCLUDE_NAMES = {"_maintenance", ".git", "node_modules", "dist", "docs", "instructions"}

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

def _is_github_download_url(url: str) -> bool:
    """True only for https URLs whose host is a known GitHub delivery host."""
    try:
        parsed = urllib.parse.urlparse(url)
    except ValueError:
        return False
    return parsed.scheme == "https" and (parsed.hostname or "") in _GITHUB_TARBALL_HOSTS

# Serializes all WebUI write operations within this process (the deploy.sh
# mkdir-lock is a separate cross-process lock; this guards against concurrent
# ThreadingMixIn requests racing on CENTRAL_DIR mutations).
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
# Data helpers
# ──────────────────────────────────────────────────────────────

def get_agent_root(target: Path) -> Path:
    home = Path.home()
    lib_app = home / "Library" / "Application Support"
    if str(target).startswith(str(lib_app)):
        rel = target.relative_to(lib_app)
        return lib_app / rel.parts[0]
    if str(target).startswith(str(home)):
        rel = target.relative_to(home)
        if len(rel.parts) > 1 and rel.parts[0] == ".config":
            return home / ".config" / rel.parts[1]
        return home / rel.parts[0]
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
        return True
        
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
        if "=" in line:
            name, path = line.split("=", 1)
            name = name.strip()
            path = _normalize_local_path(path)
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
    for name, default_path in DEFAULT_AGENTS:
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

    # 2. Add Custom Agents (that don't match any default name override)
    for name, path_str in custom_list:
        path_key = _normalize_local_path(path_str)
        if path_key in seen:
            continue
        seen.add(path_key)
        p = Path(path_str)
        active = p.exists() or p.parent.exists()
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
    name = name.strip()
    if not name:
        return False, "Rule name cannot be empty"
    if "/" in name or "\\" in name or "\x00" in name or name in (".", ".."):
        return False, "Invalid rule name"
    if not name.endswith(".md"):
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


def _inject_managed_block(existing: str, block: str) -> str:
    """Insert or replace the managed block inside an instruction file's content.

    - No existing content  → block alone.
    - Has managed block    → replace the old block with the new one.
    - No managed block     → append block (separated by a blank line).
    """
    existing_begin = next((marker for marker in EASY_SKILLS_BEGIN_ALIASES if marker in existing), None)
    if existing_begin and EASY_SKILLS_END in existing:
        import re
        pattern = re.compile(
            re.escape(existing_begin) + r".*?" + re.escape(EASY_SKILLS_END),
            re.DOTALL,
        )
        return pattern.sub(lambda m: block, existing, count=1)
    if existing.strip():
        return existing.rstrip() + "\n\n" + block + "\n"
    return block + "\n"


def _strip_managed_block(content: str) -> str:
    """Remove the managed block from content, returning the remainder."""
    existing_begin = next((marker for marker in EASY_SKILLS_BEGIN_ALIASES if marker in content), None)
    if not existing_begin or EASY_SKILLS_END not in content:
        return content
    import re
    pattern = re.compile(
        re.escape(existing_begin) + r".*?" + re.escape(EASY_SKILLS_END) + r"\n?",
        re.DOTALL,
    )
    return pattern.sub("", content, count=1)


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
            if item.is_file() and item.suffix == ".md" and (requested is None or item.name in requested):
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
            if item.is_file() and item.suffix == ".md":
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


@_writes_locked
def save_instruction(name: str, content: str) -> dict:
    """Create or overwrite a single rule file in the instructions library."""
    valid, clean = _validate_instruction_name(name)
    if not valid:
        return {"success": False, "message": clean}
    if not isinstance(content, str):
        return {"success": False, "message": "Rule content must be text"}
    try:
        INSTRUCTIONS_DIR.mkdir(parents=True, exist_ok=True)
        _atomic_write_text(INSTRUCTIONS_DIR / clean, content)
    except OSError as e:
        return {"success": False, "message": f"Save failed: {e}"}
    return {"success": True, "message": f"Saved rule: {clean}", "name": clean}


@_writes_locked
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
        if path.exists():
            shutil.copystat(path, temp_path)
        os.replace(temp_path, path)
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
        previous_state = _instruction_state_entry(path)
        _set_instruction_state(path, current, legacy)
        try:
            _atomic_write_text(path, _inject_managed_block(existing, block))
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
        if remaining.strip():
            _atomic_write_text(path, remaining.rstrip() + "\n")
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
            updated = _inject_managed_block(existing, _build_managed_block(current, legacy))
            previous_state = _instruction_state_entry(path)
            _set_instruction_state(path, current, legacy)
        else:
            updated = _strip_managed_block(existing)
            previous_state = _instruction_state_entry(path)
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


@_writes_locked
def write_instructions_to_all() -> dict:
    """Write every library rule to every detected agent instruction file."""
    rules, error = _rule_library()
    if error or not rules:
        return {"success": False, "message": "No rules in the library. Add rules first."}
    targets = _detected_instruction_targets()
    if not targets:
        return {"success": False, "message": "No detected agent instruction targets found."}
    written, failed = [], []
    for name, path in targets:
        if _write_to_one(path, rules, replace=True):
            written.append(name)
        else:
            failed.append(f"{name} ({path})")
    msg = f"Wrote rules to {len(written)} agent(s)."
    if failed:
        msg += f" Failed: {', '.join(failed)}"
    return {"success": len(failed) == 0, "message": msg, "written": len(written), "failed": failed}


@_writes_locked
def remove_instructions_from_all() -> dict:
    """Remove the managed block from every detected agent instruction file."""
    targets = _detected_instruction_targets()
    if not targets:
        return {"success": False, "message": "No detected agent instruction targets found."}
    removed, failed = [], []
    for name, path in targets:
        if _remove_from_one(path):
            removed.append(name)
        else:
            failed.append(f"{name} ({path})")
    msg = f"Removed managed block from {len(removed)} agent(s)."
    if failed:
        msg += f" Failed: {', '.join(failed)}"
    return {"success": len(failed) == 0, "message": msg, "removed": len(removed), "failed": failed}


@_writes_locked
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


@_writes_locked
def remove_instructions_from_one(path_str: str) -> dict:
    """Remove the managed block from a single agent's instruction file."""
    path = _known_instruction_target(path_str)
    if path is None:
        return {"success": False, "message": "Unknown agent instruction target"}
    if _remove_from_one(path):
        return {"success": True, "message": f"Removed managed block from {path}"}
    return {"success": False, "message": f"Remove failed for {path}"}


@_writes_locked
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


@_writes_locked
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


# ──────────────────────────────────────────────────────────────
# Operations
# ──────────────────────────────────────────────────────────────

def run_deploy(*args: str) -> dict:
    deploy = SCRIPT_DIR / "deploy.sh"
    try:
        r = subprocess.run(
            ["bash", str(deploy), *args],
            capture_output=True, text=True, timeout=30,
            cwd=str(SCRIPT_DIR),
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
    name = name.strip()
    if not name:
        return False, "Skill name cannot be empty"
    if name.startswith(("_", ".")) or name in EXCLUDE_NAMES:
        return False, "Reserved skill name"
    if "/" in name or "\\" in name or "\x00" in name or name in (".", ".."):
        return False, "Invalid skill name"
    return True, name


def _safe_relative_path(path: str) -> Path | None:
    if not path or "\x00" in path:
        return None
    rel = Path(path.replace("\\", "/"))
    if rel.is_absolute() or any(part in ("", ".", "..") for part in rel.parts):
        return None
    return rel


@_writes_locked
def import_skill_folder(name: str, files: list[dict]) -> dict:
    valid, clean_name = _validate_skill_name(name)
    if not valid:
        return {"success": False, "message": clean_name}
    if not isinstance(files, list) or not files:
        return {"success": False, "message": "No files were provided"}

    CENTRAL_DIR.mkdir(parents=True, exist_ok=True)
    target = CENTRAL_DIR / clean_name
    if target.exists() or target.is_symlink():
        return {"success": False, "message": f"Skill already exists: {clean_name}"}

    prepared: list[tuple[Path, bytes]] = []
    has_skill_md = False
    for item in files:
        if not isinstance(item, dict):
            return {"success": False, "message": "Invalid file payload"}
        rel = _safe_relative_path(str(item.get("path", "")))
        if rel is None:
            return {"success": False, "message": "Invalid file path in upload"}
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
    return {"success": True, "message": msg, "skill": clean_name}


@_writes_locked
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
    for agent_dir in _iter_agent_skill_dirs():
        link = agent_dir / clean_name
        if link.is_symlink() and _link_points_into_central(link, CENTRAL_DIR.resolve()):
            try:
                link.unlink()
                removed_count += 1
            except Exception:
                pass
    return {"success": True, "message": f"Deleted {clean_name} (removed {removed_count} symlinks)", "skill": clean_name}


@_writes_locked
def do_map(target_path: str) -> dict:
    if not isinstance(target_path, str) or not target_path.strip():
        return {"success": False, "message": "Target path cannot be empty"}
    target_path = target_path.strip()
    _remove_from_disabled_targets(target_path)
    target = Path(target_path)
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
            if not dest.exists():
                dest.symlink_to(skill_dir)
        message = f"Mapped to {target_path}"
        if conflicts:
            message += f" (preserved {len(conflicts)} foreign link conflict(s): {', '.join(conflicts)})"
        return {"success": True, "message": message, "conflicts": conflicts}
    except Exception as e:
        return {"success": False, "message": str(e)}


@_writes_locked
def do_unmap(target_path: str) -> dict:
    if not isinstance(target_path, str) or not target_path.strip():
        return {"success": False, "message": "Target path cannot be empty"}
    target_path = target_path.strip()
    _add_to_disabled_targets(target_path)
    target = Path(target_path)
    if not target.exists():
        return {"success": False, "message": "Path does not exist"}
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
    return {"success": True, "message": msg, "removed": removed}


@_writes_locked
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
        if "=" in stripped:
            line_name, line_path = stripped.split("=", 1)
            line_name = line_name.strip()
            line_path = line_path.strip()
        else:
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
    _remove_from_disabled_targets(old_path)
    if bool((current or {}).get("mapped")):
        _remove_from_disabled_targets(new_path)
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
            _remove_from_disabled_targets(old_path)
            if not cleanup_result.get("success"):
                cleanup_warning = (
                    f" Warning: old skills links at {old_path} could not be fully removed: "
                    f"{cleanup_result.get('message', 'unknown cleanup error')}."
                )
    else:
        _add_to_disabled_targets(new_path)
        cleanup_warning = ""

    return {
        "success": True,
        "message": f"Updated {name} skills and instructions paths.{cleanup_warning}",
        "skills_path": new_path,
        "instructions_path": new_instructions_path,
    }


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


@_writes_locked
def register_custom_agent(skills_path: str, instructions_path: str) -> dict:
    """Register a custom Agent with both skill and instruction channels."""
    skills_path = _normalize_local_path(skills_path)
    instructions_path = _normalize_local_path(instructions_path)
    if not skills_path:
        return {"success": False, "message": "Skills path cannot be empty"}
    if not instructions_path:
        return {"success": False, "message": "Instructions file path cannot be empty"}
    instruction_target = Path(instructions_path)
    if instruction_target.exists() and instruction_target.is_dir():
        return {"success": False, "message": "Instructions path must point to a file, not a directory"}

    was_registered = any(
        _normalize_local_path(line.split("=", 1)[-1].strip()) == skills_path
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


@_writes_locked
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
    dest_real = os.path.realpath(dest)
    members = tf.getmembers()
    if len(members) > max_members:
        raise ValueError(f"Release archive contains too many entries ({len(members)} > {max_members})")
    total_size = sum(member.size for member in members if member.isfile())
    if total_size > max_total_size:
        raise ValueError("Release archive exceeds the 512 MB extracted-size safety limit")

    for member in members:
        if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
            raise ValueError(f"Refusing to extract unsupported tar member type: {member.name!r}")
        target = os.path.realpath(os.path.join(dest, member.name))
        # Reject absolute members, and any member whose resolved path escapes
        # dest (covers "../" traversal). The explicit grouping avoids the
        # `and`-binds-tighter-than-`or` precedence trap.
        escapes_dest = (
            target != dest_real
            and os.path.commonpath([target, dest_real]) != dest_real
        )
        if os.path.isabs(member.name) or escapes_dest:
            raise ValueError(f"Refusing to extract unsafe path: {member.name!r}")
        # Reject symlinks/hardlinks whose link target escapes dest.
        if member.issym() or member.islnk():
            if os.path.isabs(member.linkname):
                raise ValueError(f"Refusing to extract unsafe link: {member.name!r}")
            # Symbolic links are relative to the link's directory; tar hardlink
            # targets are archive-root-relative.
            link_base = os.path.dirname(target) if member.issym() else dest_real
            link_real = os.path.realpath(os.path.join(link_base, member.linkname))
            link_escapes = (
                link_real != dest_real
                and os.path.commonpath([link_real, dest_real]) != dest_real
            )
            if link_escapes:
                raise ValueError(f"Refusing to extract unsafe link: {member.name!r}")
        tf.extract(member, dest)


@_writes_locked
def do_self_update() -> dict:
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

            # --- Integrity check: re-download and compare SHA-256 ---
            # GitHub serves the tarball deterministically for a given tag, so
            # two independent downloads must produce the identical digest.
            verify_path = os.path.join(tmp, "release_verify.tar.gz")
            _download_github_file(tarball_url, verify_path)
            digest1 = _sha256_file(archive_path)
            digest2 = _sha256_file(verify_path)
            if not hmac.compare_digest(digest1, digest2):
                return {
                    "success": False,
                    "message": "Integrity check failed: download digest mismatch. Aborting update.",
                }
            os.unlink(verify_path)

            with tarfile.open(archive_path, "r:gz") as tf:
                # Safe extraction rejects absolute paths, ../ traversal, and
                # links escaping the dest dir — works on all Python versions
                # (the filter="data" arg is 3.12+ only).
                _safe_extract_tar(tf, tmp)

            extracted = [d for d in os.listdir(tmp) if os.path.isdir(os.path.join(tmp, d))]
            if not extracted:
                return {"success": False, "message": "Empty archive"}
            src_root = Path(tmp) / extracted[0]

            # Preserve user runtime files (not shipped in the release tarball)
            custom_backup = None
            if CUSTOM_TARGETS_FILE.exists():
                custom_backup = CUSTOM_TARGETS_FILE.read_text(encoding="utf-8")
            disabled_backup = None
            if DISABLED_TARGETS_FILE.exists():
                disabled_backup = DISABLED_TARGETS_FILE.read_text(encoding="utf-8")

            # --- Backup current _maintenance for rollback (atomic via temp rename) ---
            dest_maint = CENTRAL_DIR / "_maintenance"
            backup_maint = CENTRAL_DIR / "_maintenance.bak"
            backup_maint_new = CENTRAL_DIR / "_maintenance.bak.new"

            src_maint = src_root / "_maintenance"
            if not src_maint.is_dir():
                return {"success": False, "message": "Archive does not contain _maintenance/"}

            # Build new _maintenance in a temp dir, then rename atomically
            new_maint_tmp = CENTRAL_DIR / "_maintenance.new"
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

            # Copy README_SYSTEM.md / SKILL.md into the new tree if needed
            src_readme = src_root / "README_SYSTEM.md"
            if src_readme.exists():
                shutil.copy2(src_readme, CENTRAL_DIR / "README_SYSTEM.md")
            else:
                src_old = src_root / "SKILL.md"
                if src_old.exists():
                    shutil.copy2(src_old, CENTRAL_DIR / "README_SYSTEM.md")

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

                # Clean up the interim backup snapshot
                if backup_maint_new.exists():
                    shutil.rmtree(backup_maint_new)

                # Ensure shell scripts are executable
                for script in ("deploy.sh", "watch.sh", "unwatch.sh"):
                    s = dest_maint / script
                    if s.exists():
                        s.chmod(0o755)

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

        sync_result = run_deploy("--sync")

        new_version = get_version()
        sync_ok = bool(sync_result.get("success"))
        message = f"Updated to {new_version}."
        if sync_ok:
            message += " All agents re-synced."
        else:
            message += f" Update succeeded, but agent re-sync failed: {sync_result.get('message', 'unknown error')}"
        message += " The UI will reload to pick up the new version."
        return {
            "success": True,
            "message": message,
            "version": new_version,
            "sync_success": sync_ok,
            # Signal the frontend to reload: the running Python process still
            # holds the pre-update code, so a page reload (or a supervisor
            # restart) is needed to serve the new logic.
            "_restart": True,
        }
    except Exception as e:
        return {"success": False, "message": f"Update failed: {e}"}


@_writes_locked
def do_rollback() -> dict:
    backup_maint = CENTRAL_DIR / "_maintenance.bak"
    dest_maint = CENTRAL_DIR / "_maintenance"
    if not backup_maint.exists():
        return {"success": False, "message": "No backup found. Nothing to roll back."}
    try:
        # Preserve the user's CURRENT runtime files across the rollback
        custom_backup = None
        if CUSTOM_TARGETS_FILE.exists():
            custom_backup = CUSTOM_TARGETS_FILE.read_text(encoding="utf-8")
        disabled_backup = None
        if DISABLED_TARGETS_FILE.exists():
            disabled_backup = DISABLED_TARGETS_FILE.read_text(encoding="utf-8")

        # Atomic rollback: copy backup to a temp name, then rotate via rename
        rollback_tmp = CENTRAL_DIR / "_maintenance.rollback"
        if rollback_tmp.exists():
            shutil.rmtree(rollback_tmp)
        shutil.copytree(backup_maint, rollback_tmp)

        # Carry runtime files into the tree that will become _maintenance
        if custom_backup is not None:
            (rollback_tmp / "custom-targets.txt").write_text(custom_backup, encoding="utf-8")
        if disabled_backup is not None:
            (rollback_tmp / "disabled-targets.txt").write_text(disabled_backup, encoding="utf-8")
        if TOKEN_FILE.exists():
            try:
                shutil.copy2(TOKEN_FILE, rollback_tmp / TOKEN_FILE.name)
            except OSError:
                pass

        # Pre-clean _maintenance.prev: a stale .prev left by a prior failed
        # rollback would make the rename below fail (POSIX rename refuses to
        # overwrite an existing directory), dooming every subsequent rollback.
        prev = CENTRAL_DIR / "_maintenance.prev"
        if prev.exists():
            shutil.rmtree(prev)

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
        message += " The UI will reload to pick up the rolled-back version."
        return {
            "success": True,
            "message": message,
            "version": version,
            "sync_success": sync_ok,
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
                    str(CENTRAL_DIR / "_maintenance" / "webui.py"),
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
            html = (WEBUI_DIR / "index.html").read_text(encoding="utf-8")
            html = html.replace("__EASYSKILLS_TOKEN__", WEBUI_TOKEN)
            data = html.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self._send_security_headers()
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
            self.end_headers()
            self.wfile.write(data)
        except FileNotFoundError:
            self.send_response(404)
            self.end_headers()

    def _body(self) -> dict | None:
        """Parse the JSON request body.

        Returns:
            dict  – on success
            None  – when the body is too large (caller must send 413 and return)
            {}    – on missing / empty / malformed body (safe to proceed)
        """
        try:
            length = int(self.headers.get("Content-Length", 0))
        except (ValueError, TypeError):
            return {}
        if not length:
            return {}
        if length > 10 * 1024 * 1024:  # 10 MB cap
            # Do not block while draining an untrusted oversized body. Close
            # this keep-alive connection after the 413 so unread bytes can
            # never be parsed as a subsequent request.
            self.close_connection = True
            return None  # Signal to caller: send 413
        if length < 0:
            return {}
        try:
            parsed = json.loads(self.rfile.read(length))
            return parsed if isinstance(parsed, dict) else {}
        except (json.JSONDecodeError, OSError, UnicodeError, ValueError):
            return {}

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
                "version":       get_version(),
                "has_backup":    (CENTRAL_DIR / "_maintenance.bak").is_dir(),
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
                self._json({"success": False, "message": f"Request failed: {exc}"}, status=500)
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
                    p = line.split("=", 1)[-1].strip() if "=" in line else line
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
