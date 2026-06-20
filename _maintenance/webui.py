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
        except OSError:
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
            DISABLED_TARGETS_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
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
    except OSError:
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
            DISABLED_TARGETS_FILE.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
        except OSError:
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
    try:
        if TOKEN_FILE.exists():
            token = TOKEN_FILE.read_text(encoding="utf-8").strip()
            if len(token) >= 16:
                return token
    except OSError:
        pass
    token = secrets.token_urlsafe(32)
    try:
        # Atomic create — fails if another process created it first
        fd = os.open(str(TOKEN_FILE), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.write(fd, token.encode("utf-8"))
        finally:
            os.close(fd)
    except FileExistsError:
        # Another process won the race — retry reading up to 3 times
        for _ in range(3):
            try:
                candidate = TOKEN_FILE.read_text(encoding="utf-8").strip()
                if len(candidate) >= 16:
                    return candidate
            except OSError:
                pass
            import time
            time.sleep(0.05)
        # Both processes failed to write a valid token; surface as an error
        raise RuntimeError(
            f"Token file {TOKEN_FILE} exists but could not be read after 3 retries."
        )
    except OSError:
        pass
    return token

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
    ]

DEFAULT_AGENTS = _load_default_agents()

# Ensure ~/.qoder-cn/skills exists — unlike other agents whose directories are
# created by their respective tools, Qoder CN relies on EasySkills to create
# the path if it does not already exist.
_qoder_cn_skills = Path.home() / ".qoder-cn" / "skills"
if not _qoder_cn_skills.exists():
    _qoder_cn_skills.mkdir(parents=True, exist_ok=True)

EXCLUDE_NAMES = {"_maintenance", ".git", "node_modules", "dist", "docs"}

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
# GitHub API response could otherwise point urlretrieve() at an arbitrary server.
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
                skills.append({
                    "name": item.name,
                    "path": str(item),
                    "has_skill_md": (item / "SKILL.md").exists() or (item / "README_SYSTEM.md").exists(),
                })
    return skills


def get_custom_targets():
    if not CUSTOM_TARGETS_FILE.exists():
        return []
    lines = []
    for line in CUSTOM_TARGETS_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            lines.append(line)
    return lines


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
            if item.is_symlink():
                try:
                    link_target = Path(os.readlink(str(item)))
                    if not link_target.is_absolute():
                        link_target = item.parent / link_target
                    if link_target.resolve().parent == central_resolved:
                        return True
                except Exception:
                    pass
    except Exception:
        pass
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
            path = path.strip()
            if is_proma_workspace_target(path):
                continue
            custom_overrides[name] = path
        else:
            path = line.strip()
            if is_proma_workspace_target(path):
                continue
            name = get_agent_name(path)
            custom_list.append((name, path))

    seen: set[str] = set()
    agents = []
    disabled_set = _get_disabled_targets()
    has_skills = len(get_skills()) > 0

    # 1. Add Default Agents (checking for overrides)
    for name, default_path in DEFAULT_AGENTS:
        path_str = custom_overrides.get(name, str(default_path))
        if path_str in seen:
            continue
        seen.add(path_str)
        p = Path(path_str)
        agent_root = get_agent_root(p)
        active = agent_root.exists()
        
        agents.append({
            "name": name,
            "path": path_str,
            "active": active,
            "mapped": is_mapped(path_str, disabled_set, has_skills),
            "custom": name in custom_overrides,
        })

    # 2. Add Custom Agents (that don't match any default name override)
    for name, path_str in custom_list:
        if path_str in seen:
            continue
        seen.add(path_str)
        p = Path(path_str)
        active = p.exists() or p.parent.exists()

        agents.append({
            "name": name,
            "path": path_str,
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
        fallback = get_latest_release_via_redirect()
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
            r = subprocess.run(
                ["pgrep", "-f", "easyskills.*watcher"],
                capture_output=True, text=True, timeout=5
            )
            if r.returncode == 0 and r.stdout.strip():
                pid = r.stdout.strip().splitlines()[0]
                return {"running": True, "pid": pid}
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
    name = (name or "").strip()
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
    central_resolved = str(CENTRAL_DIR.resolve())
    for agent_dir in _iter_agent_skill_dirs():
        link = agent_dir / clean_name
        if link.is_symlink():
            try:
                link_target = Path(os.readlink(str(link)))
                if not link_target.is_absolute():
                    link_target = link.parent / link_target
                resolved = str(link_target.resolve())
                if resolved == central_resolved or resolved.startswith(central_resolved + os.sep):
                    link.unlink()
                    removed_count += 1
            except Exception:
                pass
    return {"success": True, "message": f"Deleted {clean_name} (removed {removed_count} symlinks)", "skill": clean_name}


@_writes_locked
def do_map(target_path: str) -> dict:
    if not target_path or not target_path.strip():
        return {"success": False, "message": "Target path cannot be empty"}
    target_path = target_path.strip()
    _remove_from_disabled_targets(target_path)
    target = Path(target_path)
    try:
        target.mkdir(parents=True, exist_ok=True)
        # Per-skill links
        for skill_dir in CENTRAL_DIR.iterdir():
            if not skill_dir.is_dir():
                continue
            if skill_dir.name.startswith(("_", ".")) or skill_dir.name in EXCLUDE_NAMES:
                continue
            dest = target / skill_dir.name
            if dest.is_symlink():
                dest.unlink()
            if not dest.exists():
                dest.symlink_to(skill_dir)
        return {"success": True, "message": f"Mapped to {target_path}"}
    except Exception as e:
        return {"success": False, "message": str(e)}


@_writes_locked
def do_unmap(target_path: str) -> dict:
    if not target_path or not target_path.strip():
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
                link_target_raw = os.readlink(str(item))
                # Resolve relative symlinks to absolute for reliable comparison
                try:
                    link_target = Path(link_target_raw)
                    if not link_target.is_absolute():
                        link_target = item.parent / link_target
                    link_target_resolved = str(link_target.resolve())
                except Exception:
                    link_target_resolved = link_target_raw
                if (link_target_resolved == central_resolved
                        or link_target_resolved.startswith(central_resolved + os.sep)):
                    item.unlink()
                    removed.append(item.name)
        except Exception as e:
            errors.append(f"{item.name}: {e}")
    msg = f"Removed {len(removed)} symlinks"
    if errors:
        msg += f" ({len(errors)} errors: {'; '.join(errors)})"
    return {"success": True, "message": msg, "removed": removed}


@_writes_locked
def update_agent_path(name: str, old_path: str, new_path: str) -> dict:
    if not new_path:
        return {"success": False, "message": "New path cannot be empty"}
    
    # Expand paths correctly
    try:
        new_path = str(Path(new_path).expanduser().resolve())
    except Exception:
        new_path = str(Path(new_path).expanduser())

    lines = []
    if CUSTOM_TARGETS_FILE.exists():
        lines = CUSTOM_TARGETS_FILE.read_text(encoding="utf-8").splitlines()

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

        if line_path == old_path or (line_name == name and name != "Custom Agent"):
            new_lines.append(f"{name}={new_path}")
            updated = True
        else:
            new_lines.append(line)

    if not updated:
        new_lines.append(f"{name}={new_path}")

    # Save to custom-targets.txt (must succeed before creating symlinks)
    try:
        CUSTOM_TARGETS_FILE.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
    except OSError as e:
        return {"success": False, "message": f"Failed to write config: {e}"}

    # Automatically symlink to the new configuration location
    _remove_from_disabled_targets(old_path)
    _remove_from_disabled_targets(new_path)
    do_map(new_path)

    return {"success": True, "message": f"Updated {name} to {new_path}"}


def _sha256_file(path: str) -> str:
    """Return the hex SHA-256 digest of the file at *path*."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _safe_extract_tar(tf: tarfile.TarFile, dest: str) -> None:
    """Extract *tf* into *dest* rejecting unsafe members.

    Guards against path traversal (absolute paths, ``..``) and links pointing
    outside *dest* — the vulnerabilities that bare ``extractall`` exposes on
    Python < 3.12 (where the ``filter="data`` argument is unavailable). Used for
    the self-update tarball so a crafted release cannot write outside the
    temporary directory.
    """
    dest_real = os.path.realpath(dest)
    for member in tf.getmembers():
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
            link_real = os.path.realpath(os.path.join(os.path.dirname(target), member.linkname))
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
            urllib.request.urlretrieve(tarball_url, archive_path)

            # --- Integrity check: re-download and compare SHA-256 ---
            # GitHub serves the tarball deterministically for a given tag, so
            # two independent downloads must produce the identical digest.
            verify_path = os.path.join(tmp, "release_verify.tar.gz")
            urllib.request.urlretrieve(tarball_url, verify_path)
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
                # Rollback: restore from backup_maint_new if available
                try:
                    if new_maint_tmp.exists():
                        shutil.rmtree(new_maint_tmp)
                    if backup_maint_new.exists():
                        if backup_maint.exists():
                            shutil.rmtree(backup_maint)
                        backup_maint_new.rename(backup_maint)
                    if not dest_maint.exists() and backup_maint.exists():
                        shutil.copytree(backup_maint, dest_maint)
                except Exception:
                    pass
                raise

        run_deploy("--sync")

        new_version = get_version()
        return {
            "success": True,
            "message": f"Updated to {new_version}. All agents re-synced. The UI will reload to pick up the new version.",
            "version": new_version,
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

        if dest_maint.exists():
            dest_maint.rename(CENTRAL_DIR / "_maintenance.prev")
        rollback_tmp.rename(dest_maint)
        # Remove the transient .prev directory
        prev = CENTRAL_DIR / "_maintenance.prev"
        if prev.exists():
            shutil.rmtree(prev)

        for script in ("deploy.sh", "watch.sh", "unwatch.sh"):
            s = dest_maint / script
            if s.exists():
                s.chmod(0o755)

        run_deploy("--sync")
        # Remove backup so a second rollback doesn’t restore stale state
        try:
            shutil.rmtree(backup_maint)
        except OSError:
            pass
        version = get_version()
        return {
            "success": True,
            "message": f"Rolled back to {version}. All agents re-synced. The UI will reload to pick up the rolled-back version.",
            "version": version,
            # Same rationale as do_self_update: the running process holds the
            # pre-rollback code until a reload/supervisor restart.
            "_restart": True,
        }
    except Exception as e:
        return {"success": False, "message": f"Rollback failed: {e}"}


# ──────────────────────────────────────────────────────────────
# HTTP handler
# ──────────────────────────────────────────────────────────────

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

    def _json(self, data, status: int = 200):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
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
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
            self.end_headers()
            self.wfile.write(data)
        except FileNotFoundError:
            self.send_response(404)
            self.end_headers()

    def _file(self, path: Path, content_type: str):
        try:
            data = path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
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
            return None  # Signal to caller: send 413
        try:
            return json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, ValueError):
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
            self._json({
                "watcher":       watcher,
                "central_dir":   str(CENTRAL_DIR),
                "skills_count":  len(skills),
                "agents_total":  len(agents),
                "agents_mapped": sum(1 for a in agents if a["mapped"]),
                "version":       get_version(),
                "has_backup":    (CENTRAL_DIR / "_maintenance.bak").is_dir(),
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
            "/api/agents/update":        lambda: update_agent_path(body.get("name", ""), body.get("old_path", ""), body.get("new_path", "")),
            "/api/agents/custom/add":    lambda: run_deploy("--add", body.get("path", "")),
            "/api/agents/custom/remove": lambda: run_deploy("--remove", body.get("path", "")),
            "/api/skills/import":        lambda: import_skill_folder(body.get("name", ""), body.get("files", [])),
            "/api/skills/delete":        lambda: delete_skill(body.get("name", "")),
            "/api/update":               lambda: do_self_update(),
            "/api/rollback":             lambda: do_rollback(),
        }

        handler = routes.get(path)
        if handler:
            self._json(handler())
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
    if _debug_enabled:
        logging.debug("Debug mode enabled (EASYSKILLS_DEBUG=1)")
        logging.debug("CENTRAL_DIR=%s SCRIPT_DIR=%s", CENTRAL_DIR, SCRIPT_DIR)

    print(f"\n  🚀 EasySkills WebUI")
    print(f"  ┌──────────────────────────────────────┐")
    print(f"  │   http://127.0.0.1:{PORT}              │")
    print(f"  │   Press Ctrl+C to stop               │")
    if _debug_enabled:
        print(f"  │   Debug mode: ON                     │")
    print(f"  └──────────────────────────────────────┘\n")

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
        print(f"     Is another instance already running?")
    finally:
        if httpd is not None:
            httpd.server_close()


if __name__ == "__main__":
    main()
