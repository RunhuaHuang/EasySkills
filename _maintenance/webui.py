#!/usr/bin/env python3
# ==============================================================================
# Script: webui.py (macOS/Linux)
# Description: EasySkills WebUI backend — Python 3 stdlib only, zero pip deps.
# Usage: python3 _maintenance/webui.py
#        or: bash _maintenance/deploy.sh --webui
# ==============================================================================

import http.server
import socketserver
import hmac
import json
import os
import platform
import secrets
import shutil
import subprocess
import tarfile
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
CENTRAL_DIR = SCRIPT_DIR.parent

# Dynamically resolve to official home directory installation if it exists
HOME_CENTRAL_DIR = Path.home() / "EasySkills"
if HOME_CENTRAL_DIR.exists() and HOME_CENTRAL_DIR.is_dir() and not (CENTRAL_DIR / ".git").exists():
    CENTRAL_DIR = HOME_CENTRAL_DIR
    SCRIPT_DIR = HOME_CENTRAL_DIR / "_maintenance"

CUSTOM_TARGETS_FILE = SCRIPT_DIR / "custom-targets.txt"
WEBUI_DIR = SCRIPT_DIR / "webui"
if not WEBUI_DIR.exists():
    WEBUI_DIR = Path(__file__).parent.resolve() / "webui"
PORT = 6633
WEBUI_TOKEN = os.environ.get("EASYSKILLS_WEBUI_TOKEN") or secrets.token_urlsafe(32)
ALLOWED_ORIGINS = {f"http://localhost:{PORT}", f"http://127.0.0.1:{PORT}"}

DEFAULT_AGENTS = [
    ("Antigravity CLI",                Path.home() / ".gemini/config/skills"),
    ("Antigravity IDE",                Path.home() / ".gemini/antigravity/skills"),
    ("Codex",                          Path.home() / ".codex/skills"),
    ("Claude Code",                    Path.home() / ".claude/skills"),
    ("GitHub Copilot",                 Path.home() / ".copilot/skills"),
    ("Pi",                             Path.home() / ".pi/skills"),
    ("OpenCode",                       Path.home() / ".opencode/skills"),
    ("Kimi Code",                      Path.home() / ".kimi/skills"),
    ("Trae (Global)",                  Path.home() / ".trae/skills"),
    ("Trae (Global, App)",             Path.home() / "Library/Application Support/Trae/skills"),
    ("Trae CN",                        Path.home() / ".trae-cn/skills"),
    ("Trae CN (App)",                  Path.home() / "Library/Application Support/Trae-CN/skills"),
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
    ("Windsurf",                       Path.home() / ".windsurf/skills"),
    ("Firebender",                     Path.home() / ".firebender/skills"),
    ("Augment",                        Path.home() / ".augment/skills"),
    ("Continue",                       Path.home() / ".continue/skills"),
    ("Goose",                          Path.home() / ".goose/skills"),
    ("Agents (Standard)",              Path.home() / ".agents/skills"),
]

EXCLUDE_NAMES = {"_maintenance", ".git", "node_modules", "dist"}


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
                    "has_skill_md": (item / "SKILL.md").exists(),
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


def is_mapped(target_path: str) -> bool:
    return (Path(target_path) / "EasySkills").is_symlink()


def is_proma_workspace_target(path: str) -> bool:
    normalized = path.replace("\\", "/").lower()
    return "/.proma/agent-workspaces/" in normalized


def get_agent_name(path: str) -> str:
    path_lower = path.lower()
    if "antigravity" in path_lower and ".gemini" in path_lower: return "Antigravity IDE"
    if ".gemini" in path_lower: return "Antigravity CLI"
    if ".codex" in path_lower: return "Codex"
    if ".claude" in path_lower: return "Claude Code"
    if ".copilot" in path_lower: return "GitHub Copilot"
    if ".pi" in path_lower: return "Pi"
    if ".opencode" in path_lower: return "OpenCode"
    if ".kimi" in path_lower: return "Kimi Code"
    if ".trae-cn" in path_lower or "/trae-cn/" in path_lower: return "Trae CN"
    if ".trae" in path_lower or "/trae/" in path_lower: return "Trae (Global)"
    if ".openclaw" in path_lower: return "OpenClaw"
    if ".hermes" in path_lower: return "Hermes Agent"
    if ".proma" in path_lower: return "Proma"
    if ".cursor" in path_lower: return "Cursor"
    if ".kiro" in path_lower: return "Kiro Agent"
    if ".junie" in path_lower: return "Junie (JetBrains)"
    if ".cline" in path_lower: return "Cline"
    if ".roo" in path_lower: return "Roo Code"
    if ".warp" in path_lower: return "Warp"
    if ".windsurf" in path_lower: return "Windsurf"
    if ".firebender" in path_lower: return "Firebender"
    if ".augment" in path_lower: return "Augment"
    if ".continue" in path_lower: return "Continue"
    if ".goose" in path_lower: return "Goose"
    if ".agents" in path_lower: return "Agents (Standard)"
    if ".run" in path_lower: return "Run"
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
            "mapped": is_mapped(path_str) if p.exists() else False,
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
            "mapped": is_mapped(path_str) if p.exists() else False,
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


def get_watcher_status():
    try:
        if platform.system() == "Darwin":
            r = subprocess.run(
                ["launchctl", "list"],
                capture_output=True, text=True, timeout=5
            )
            for line in r.stdout.splitlines():
                if "easyskills" in line.lower():
                    pid = line.split()[0]
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


def do_map(target_path: str) -> dict:
    if not target_path or not target_path.strip():
        return {"success": False, "message": "Target path cannot be empty"}
    target_path = target_path.strip()
    target = Path(target_path)
    try:
        target.mkdir(parents=True, exist_ok=True)
        # EasySkills self-link
        self_link = target / "EasySkills"
        if self_link.is_symlink():
            self_link.unlink()
        if not self_link.exists():
            self_link.symlink_to(CENTRAL_DIR)
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


def do_unmap(target_path: str) -> dict:
    if not target_path or not target_path.strip():
        return {"success": False, "message": "Target path cannot be empty"}
    target_path = target_path.strip()
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
    do_map(new_path)

    return {"success": True, "message": f"Updated {name} to {new_path}"}


def do_self_update() -> dict:
    try:
        req = urllib.request.Request(
            "https://api.github.com/repos/RunhuaHuang/EasySkills/releases/latest",
            headers={"Accept": "application/vnd.github+json", "User-Agent": "EasySkills-WebUI"},
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            release = json.loads(resp.read().decode())

        latest_tag = release.get("tag_name", "")
        if not latest_tag:
            return {"success": False, "message": "Could not determine latest version"}

        tarball_url = release.get("tarball_url", "")
        if not tarball_url:
            return {"success": False, "message": "No tarball URL in release"}

        with tempfile.TemporaryDirectory() as tmp:
            archive_path = os.path.join(tmp, "release.tar.gz")
            urllib.request.urlretrieve(tarball_url, archive_path)

            with tarfile.open(archive_path, "r:gz") as tf:
                try:
                    tf.extractall(tmp, filter="data")
                except TypeError:
                    tf.extractall(tmp)

            extracted = [d for d in os.listdir(tmp) if os.path.isdir(os.path.join(tmp, d))]
            if not extracted:
                return {"success": False, "message": "Empty archive"}
            src_root = Path(tmp) / extracted[0]

            custom_backup = None
            if CUSTOM_TARGETS_FILE.exists():
                custom_backup = CUSTOM_TARGETS_FILE.read_text(encoding="utf-8")

            src_maint = src_root / "_maintenance"
            if src_maint.is_dir():
                dest_maint = CENTRAL_DIR / "_maintenance"
                for item in src_maint.iterdir():
                    dest = dest_maint / item.name
                    if item.is_dir():
                        if dest.exists():
                            shutil.rmtree(dest)
                        shutil.copytree(item, dest)
                    else:
                        shutil.copy2(item, dest)

            src_skill = src_root / "SKILL.md"
            if src_skill.exists():
                shutil.copy2(src_skill, CENTRAL_DIR / "SKILL.md")

            if custom_backup is not None:
                CUSTOM_TARGETS_FILE.write_text(custom_backup, encoding="utf-8")

            for script in ("deploy.sh", "watch.sh", "unwatch.sh"):
                s = CENTRAL_DIR / "_maintenance" / script
                if s.exists():
                    s.chmod(0o755)

        run_deploy("--sync")

        new_version = get_version()
        return {
            "success": True,
            "message": f"Updated to {new_version}. All agents re-synced.",
            "version": new_version,
        }
    except Exception as e:
        return {"success": False, "message": f"Update failed: {e}"}


# ──────────────────────────────────────────────────────────────
# HTTP handler
# ──────────────────────────────────────────────────────────────

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # quiet

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

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, ValueError):
            return {}

    def _is_post_allowed(self) -> bool:
        origin = self.headers.get("Origin")
        if origin and origin not in ALLOWED_ORIGINS:
            return False
        token = self.headers.get("X-EasySkills-Token", "")
        return hmac.compare_digest(token, WEBUI_TOKEN)

    def _reject_forbidden(self):
        self._json({"success": False, "message": "Forbidden"}, status=403)

    def do_OPTIONS(self):
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
        path = urllib.parse.urlparse(self.path).path

        if path in ("/", "/index.html"):
            self._index()

        elif path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()

        elif path == "/api/status":
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
            })

        elif path == "/api/skills":
            self._json(get_skills())

        elif path == "/api/agents":
            self._json(get_visible_agents())

        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if not self._is_post_allowed():
            self._reject_forbidden()
            return
        path = urllib.parse.urlparse(self.path).path
        body = self._body()

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
            "/api/update":               lambda: do_self_update(),
        }

        handler = routes.get(path)
        if handler:
            self._json(handler())
        else:
            self.send_response(404)
            self.end_headers()


# ──────────────────────────────────────────────────────────────
# Entry point
# ──────────────────────────────────────────────────────────────

def main():
    print(f"\n  🚀 EasySkills WebUI")
    print(f"  ┌──────────────────────────────────────┐")
    print(f"  │   http://localhost:{PORT}               │")
    print(f"  │   Press Ctrl+C to stop               │")
    print(f"  └──────────────────────────────────────┘\n")

    # Auto-open browser (cross-platform)
    try:
        import subprocess as sp
        current_os = platform.system()
        if current_os == "Darwin":
            sp.Popen(["open", f"http://localhost:{PORT}"],
                     stdout=sp.DEVNULL, stderr=sp.DEVNULL)
        elif current_os == "Linux":
            sp.Popen(["xdg-open", f"http://localhost:{PORT}"],
                     stdout=sp.DEVNULL, stderr=sp.DEVNULL)
        # Windows is handled by webui.ps1, but just in case:
        elif current_os == "Windows":
            sp.Popen(["cmd", "/c", "start", f"http://localhost:{PORT}"],
                     stdout=sp.DEVNULL, stderr=sp.DEVNULL)
    except Exception:
        pass

    class ThreadedServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
        allow_reuse_address = True
        daemon_threads = True

    try:
        with ThreadedServer(("127.0.0.1", PORT), Handler) as httpd:
            httpd.serve_forever()
    except OSError as e:
        print(f"  ❌ Cannot bind to port {PORT}: {e}")
        print(f"     Is another instance already running?")
    except KeyboardInterrupt:
        print("\n  Shutting down WebUI...")


if __name__ == "__main__":
    main()
