#!/usr/bin/env python3
import base64
import re
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def load_python_webui_module():
    import importlib.util

    spec = importlib.util.spec_from_file_location("easyskills_webui_test", ROOT / "_maintenance/webui.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class SecurityContractsTest(unittest.TestCase):
    def test_python_webui_binds_loopback_and_requires_token_for_posts(self):
        src = read("_maintenance/webui.py")
        self.assertIn('ThreadedServer(("127.0.0.1", PORT), Handler)', src)
        self.assertIn("WEBUI_TOKEN", src)
        self.assertIn("X-EasySkills-Token", src)
        self.assertIn("def _is_post_allowed", src)
        self.assertIn("self._reject_forbidden()", src)

    def test_windows_webui_requires_token_for_posts(self):
        src = read("_maintenance/webui.ps1")
        self.assertIn("$WebUIToken", src)
        self.assertIn("X-EasySkills-Token", src)
        self.assertIn("Test-PostAllowed", src)
        self.assertIn("Send-ForbiddenResponse", src)
        # Browser auto-open failure must not crash the listener
        self.assertIn("Browser open failed", src)

    def test_windows_webui_isolates_request_errors_from_listener_lifetime(self):
        src = read("_maintenance/webui.ps1")
        self.assertIn("function Invoke-WebUIRequest", src)
        self.assertIn("function Close-ResponseQuietly", src)
        self.assertIn("Request handler error", src)
        self.assertIn("GetContext transient error", src)

        # Outer retry loop ensures the listener is rebuilt if it dies.
        self.assertIn("function Start-WebUIListener", src)
        outer = re.search(
            r"while \(\$true\) \{(?P<body>.*?)\n\}\s*$",
            src,
            re.DOTALL,
        )
        self.assertIsNotNone(outer, "outermost while($true) loop not found in webui.ps1")
        body = outer.group("body")
        self.assertIn("Start-WebUIListener", body)
        self.assertIn("$Listener.IsListening", body)
        self.assertIn("$Listener.GetContext()", body)
        self.assertIn("Invoke-WebUIRequest $Context", body)

    def test_webui_hides_proma_workspace_targets_from_agent_list(self):
        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")
        html_src = read("_maintenance/webui/index.html")

        self.assertIn("def is_proma_workspace_target", py_src)
        self.assertIn("def get_visible_agents", py_src)
        self.assertIn("function Is-PromaWorkspaceTarget", ps_src)
        self.assertIn("$Normalized = $PathStr -replace '/', '\\'", ps_src)
        self.assertIn("function Get-VisibleAgentsData", ps_src)
        self.assertIn("function getVisibleAgents", html_src)
        self.assertIn("isPromaWorkspaceAgent", html_src)
        self.assertNotIn('return f"Proma Workspace', py_src)
        self.assertNotIn('return "Proma Workspace', ps_src)
        self.assertNotRegex(py_src, r"custom_list\.append\(\(get_agent_name\(str\(ws_skills\)\)")
        self.assertNotRegex(ps_src, r"CustomList \+= @\{ Name = \(Get-AgentNameFromPath \$WsSkills\.FullName\)")

    def test_double_click_installers_copy_skill_md_to_root(self):
        self.assertIn('cp "$CURRENT_DIR/SKILL.md" "$PERM_DIR/SKILL.md"', read("install_mac.command"))
        self.assertIn('copy /Y "%CURRENT_DIR%SKILL.md" "%PERM_DIR%\\SKILL.md" > nul', read("install_windows.bat"))

    def test_cleanup_only_matches_current_central_dir(self):
        for rel in ("_maintenance/deploy.sh", "_maintenance/deploy.ps1", "_maintenance/webui.py", "_maintenance/webui.ps1"):
            src = read(rel)
            self.assertNotIn("MyEasySkillsBackup", src)
            self.assertIsNone(re.search(r"EasySkills[\"'` ]?[*]", src), rel)
        self.assertIn("link_target_resolved", read("_maintenance/deploy.sh"))
        self.assertIn("CentralResolved", read("_maintenance/deploy.ps1"))

    def test_watch_plist_is_generated_with_plistlib(self):
        src = read("_maintenance/watch.sh")
        self.assertIn("plistlib", src)
        self.assertNotIn('echo "        <string>$arg</string>"', src)

    def test_dynamic_agent_buttons_do_not_use_inline_handlers(self):
        src = read("_maintenance/webui/index.html")
        self.assertNotIn("function escapeJsString", src)
        self.assertNotIn("onclick=\"startEditAgentPrompt", src)
        self.assertNotIn("onclick=\"apiCall('/api/agents/", src)
        self.assertIn("addEventListener('click'", src)

    def test_skills_tab_supports_folder_import_and_confirmed_delete(self):
        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")
        html_src = read("_maintenance/webui/index.html")

        self.assertIn("def import_skill_folder", py_src)
        self.assertIn("def delete_skill", py_src)
        self.assertIn('"/api/skills/import"', py_src)
        self.assertIn('"/api/skills/delete"', py_src)

        self.assertIn("function Import-SkillFolder", ps_src)
        self.assertIn("function Delete-Skill", ps_src)
        self.assertIn('"/api/skills/import"', ps_src)
        self.assertIn('"/api/skills/delete"', ps_src)

        self.assertIn("webkitdirectory", html_src)
        self.assertIn("id=\"skill-folder-input\"", html_src)
        self.assertIn("id=\"skill-delete-overlay\"", html_src)
        self.assertIn("skill-card-tools", html_src)
        self.assertIn("function importSkillFolder", html_src)
        self.assertIn("function confirmDeleteSkill", html_src)
        self.assertIn("addEventListener('pointerdown'", html_src)
        self.assertIn("input.showPicker", html_src)
        self.assertIn("skillDeleteOverlay.classList.add('active')", html_src)
        self.assertNotIn("confirm(", html_src)
        self.assertIn("fa-trash", html_src)
        self.assertIn("/api/skills/import", html_src)
        self.assertIn("/api/skills/delete", html_src)
        self.assertLess(html_src.index("</main>"), html_src.index('id="skill-delete-overlay"'))
        overlay_css = html_src.split(".skill-delete-overlay {", 1)[1].split("}", 1)[0]
        self.assertIn("left: 0;", overlay_css)
        self.assertNotIn("left: 280px;", overlay_css)

    def test_agents_and_guide_are_webui_first(self):
        html_src = read("_maintenance/webui/index.html")

        self.assertIn("agent-register-note", html_src)
        self.assertIn("t-agent-register-title", html_src)
        self.assertIn("t-agent-register-desc", html_src)
        self.assertIn("skills folder", html_src)

        self.assertIn("WebUI Quick Start", html_src)
        self.assertIn("WebUI Control Map", html_src)
        self.assertIn("Managing skills in the WebUI", html_src)
        self.assertIn("Connecting agents in the WebUI", html_src)
        self.assertIn("Advanced CLI fallback", html_src)
        self.assertIn("bash ~/EasySkills/_maintenance/deploy.sh --sync", html_src)
        self.assertIn('powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\\EasySkills\\_maintenance\\deploy.ps1" -Sync', html_src)
        self.assertIn('bash ~/EasySkills/_maintenance/deploy.sh --add "/absolute/path/to/agent/skills"', html_src)
        self.assertIn('powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\\EasySkills\\_maintenance\\deploy.ps1" -Add "C:\\Path\\To\\Agent\\skills"', html_src)
        self.assertNotIn("CLI Reference</span>", html_src)
        self.assertNotIn("Agent Chat Commands</span>", html_src)
        self.assertNotIn("\\\\'", html_src)

    def test_dashboard_explains_central_skill_library_drop_target(self):
        html_src = read("_maintenance/webui/index.html")

        self.assertIn("central-directory-panel", html_src)
        self.assertIn("central-directory-title", html_src)
        self.assertIn("t-central-dir-eyebrow", html_src)
        self.assertIn("Drop skills into the central skills folder", html_src)
        self.assertIn("EasySkills will sync them to every linked agent", html_src)
        self.assertIn("本机中央技能库目录", html_src)
        self.assertIn("将Skills拖入中央技能文件夹", html_src)
        self.assertIn("'t-central-dir-copy': ''", html_src)
        self.assertIn(".central-directory-copy:empty", html_src)
        dashboard_markup = html_src.split('<section id="dashboard"', 1)[1].split('<section id="skills"', 1)[0]
        self.assertNotIn("terminal-dots", dashboard_markup)

    def test_skills_and_agents_toolbars_use_shared_visual_system(self):
        html_src = read("_maintenance/webui/index.html")

        self.assertIn(".skills-import-copy", html_src)
        self.assertIn("class=\"skills-import-copy t-skill-import-hint\"", html_src)
        self.assertNotIn("terminal-text t-skill-import-hint", html_src)

        self.assertIn(".agent-list-header", html_src)
        self.assertIn(".agent-filter-control", html_src)
        self.assertIn("class=\"agent-filter-input\"", html_src)
        self.assertIn("Search agents or paths...", html_src)
        self.assertIn("搜索 Agent 或路径...", html_src)
        self.assertNotIn("class=\"search-widget\"", html_src)
        self.assertNotIn("placeholder=\"筛选...\"", html_src)

    def test_english_navigation_uses_user_facing_agent_language(self):
        html_src = read("_maintenance/webui/index.html")

        self.assertIn("'t-skills': 'Skills'", html_src)
        self.assertIn("'t-agents': 'Agents'", html_src)
        self.assertIn("'t-mapped-agents': 'Linked Agents'", html_src)
        self.assertIn("'t-central-dir': 'Central Skill Library'", html_src)
        self.assertIn("'t-map': 'Link Agent'", html_src)
        self.assertIn("'t-unmap': 'Disconnect Agent'", html_src)
        self.assertIn("central skill library", html_src)
        self.assertIn("Linked Agents", html_src)
        self.assertNotIn("'t-skills': 'Registry'", html_src)
        self.assertNotIn("'t-agents': 'Bridges'", html_src)
        self.assertNotIn("'t-mapped-agents': 'Linked Bridges'", html_src)
        self.assertNotIn("connect bridge", html_src)

    def test_readmes_are_webui_first_and_use_current_terms(self):
        readme_cn = read("README.md")
        readme_en = read("README_EN.md")

        self.assertIn("http://127.0.0.1:6633", readme_en)
        self.assertIn("skill library import/delete", readme_en)
        self.assertIn("linked agents", readme_en)
        self.assertIn("register unsupported agents by skills-folder path", readme_en)
        self.assertNotIn("http://localhost:6633", readme_en)
        self.assertNotIn("agent bridges", readme_en)
        self.assertNotIn("skill registry", readme_en)

        self.assertIn("http://127.0.0.1:6633", readme_cn)
        self.assertIn("技能库导入/删除", readme_cn)
        self.assertIn("Agent 连接", readme_cn)
        self.assertIn("默认未支持的 Agent 注册 skills 文件夹路径", readme_cn)
        self.assertNotIn("http://localhost:6633", readme_cn)

    def test_python_skill_import_and_delete_are_confined_to_central_dir(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            central = Path(tmp)
            files = [
                {
                    "path": "SKILL.md",
                    "data": base64.b64encode(b"---\nname: imported\n---\n").decode("ascii"),
                },
                {
                    "path": "scripts/run.sh",
                    "data": base64.b64encode(b"#!/usr/bin/env bash\n").decode("ascii"),
                },
            ]

            with mock.patch.object(webui, "CENTRAL_DIR", central), \
                 mock.patch.object(webui, "run_deploy", return_value={"success": True, "message": "synced"}):
                result = webui.import_skill_folder("ImportedSkill", files)
                self.assertTrue(result["success"], result)
                self.assertEqual((central / "ImportedSkill" / "SKILL.md").read_text(encoding="utf-8"), "---\nname: imported\n---\n")
                self.assertEqual((central / "ImportedSkill" / "scripts" / "run.sh").read_bytes(), b"#!/usr/bin/env bash\n")

                blocked = webui.import_skill_folder("../escape", files)
                self.assertFalse(blocked["success"])
                self.assertFalse((central.parent / "escape").exists())

                traversal = webui.import_skill_folder("BadSkill", [
                    {"path": "../outside.txt", "data": base64.b64encode(b"nope").decode("ascii")},
                    {"path": "SKILL.md", "data": base64.b64encode(b"ok").decode("ascii")},
                ])
                self.assertFalse(traversal["success"])
                self.assertFalse((central / "BadSkill").exists())

                deleted = webui.delete_skill("ImportedSkill")
                self.assertTrue(deleted["success"], deleted)
                self.assertFalse((central / "ImportedSkill").exists())

    def test_readme_version_and_agent_count_match_release(self):
        self.assertIn("Version-1.2.2", read("README_EN.md"))
        self.assertIn("版本-1.2.2", read("README.md"))
        self.assertIn("35+ agent targets are pre-configured", read("README_EN.md"))
        self.assertIn("开箱即用支持 35+ 个 Agent", read("README.md"))
        self.assertEqual("1.2.2", read("_maintenance/.version").strip())

    def test_default_agent_targets_include_requested_agents_and_corrected_paths(self):
        expected_paths = {
            "Qoder": {
                "mac": "$HOME/.qoder/skills",
                "win": "$Home\\.qoder\\skills",
                "py": 'Path.home() / ".qoder/skills"',
                "doc_mac": "~/.qoder/skills",
                "doc_win": "%USERPROFILE%\\.qoder\\skills",
            },
            "Qwen Code": {
                "mac": "$HOME/.qwen/skills",
                "win": "$Home\\.qwen\\skills",
                "py": 'Path.home() / ".qwen/skills"',
                "doc_mac": "~/.qwen/skills",
                "doc_win": "%USERPROFILE%\\.qwen\\skills",
            },
            "CodeBuddy": {
                "mac": "$HOME/.codebuddy/skills",
                "win": "$Home\\.codebuddy\\skills",
                "py": 'Path.home() / ".codebuddy/skills"',
                "doc_mac": "~/.codebuddy/skills",
                "doc_win": "%USERPROFILE%\\.codebuddy\\skills",
            },
            "Amp": {
                "mac": "$HOME/.config/agents/skills",
                "win": "$Home\\.config\\agents\\skills",
                "py": 'Path.home() / ".config/agents/skills"',
                "doc_mac": "~/.config/agents/skills",
                "doc_win": "%USERPROFILE%\\.config\\agents\\skills",
            },
            "OpenHands": {
                "mac": "$HOME/.openhands/skills",
                "win": "$Home\\.openhands\\skills",
                "py": 'Path.home() / ".openhands/skills"',
                "doc_mac": "~/.openhands/skills",
                "doc_win": "%USERPROFILE%\\.openhands\\skills",
            },
            "Kilo Code": {
                "mac": "$HOME/.kilocode/skills",
                "win": "$Home\\.kilocode\\skills",
                "py": 'Path.home() / ".kilocode/skills"',
                "doc_mac": "~/.kilocode/skills",
                "doc_win": "%USERPROFILE%\\.kilocode\\skills",
            },
            "Zencoder": {
                "mac": "$HOME/.zencoder/skills",
                "win": "$Home\\.zencoder\\skills",
                "py": 'Path.home() / ".zencoder/skills"',
                "doc_mac": "~/.zencoder/skills",
                "doc_win": "%USERPROFILE%\\.zencoder\\skills",
            },
            "iFlow CLI": {
                "mac": "$HOME/.iflow/skills",
                "win": "$Home\\.iflow\\skills",
                "py": 'Path.home() / ".iflow/skills"',
                "doc_mac": "~/.iflow/skills",
                "doc_win": "%USERPROFILE%\\.iflow\\skills",
            },
            "Droid": {
                "mac": "$HOME/.factory/skills",
                "win": "$Home\\.factory\\skills",
                "py": 'Path.home() / ".factory/skills"',
                "doc_mac": "~/.factory/skills",
                "doc_win": "%USERPROFILE%\\.factory\\skills",
            },
            "Devin for Terminal": {
                "mac": "$HOME/.config/devin/skills",
                "win": "$Home\\.config\\devin\\skills",
                "py": 'Path.home() / ".config/devin/skills"',
                "doc_mac": "~/.config/devin/skills",
                "doc_win": "%USERPROFILE%\\.config\\devin\\skills",
            },
            "OpenCode": {
                "mac": "$HOME/.config/opencode/skills",
                "win": "$Home\\.config\\opencode\\skills",
                "py": 'Path.home() / ".config/opencode/skills"',
                "doc_mac": "~/.config/opencode/skills",
                "doc_win": "%USERPROFILE%\\.config\\opencode\\skills",
            },
            "Goose": {
                "mac": "$HOME/.config/goose/skills",
                "win": "$Home\\.config\\goose\\skills",
                "py": 'Path.home() / ".config/goose/skills"',
                "doc_mac": "~/.config/goose/skills",
                "doc_win": "%USERPROFILE%\\.config\\goose\\skills",
            },
            "Windsurf": {
                "mac": "$HOME/.codeium/windsurf/skills",
                "win": "$Home\\.codeium\\windsurf\\skills",
                "py": 'Path.home() / ".codeium/windsurf/skills"',
                "doc_mac": "~/.codeium/windsurf/skills",
                "doc_win": "%USERPROFILE%\\.codeium\\windsurf\\skills",
            },
            "Pi": {
                "mac": "$HOME/.pi/agent/skills",
                "win": "$Home\\.pi\\agent\\skills",
                "py": 'Path.home() / ".pi/agent/skills"',
                "doc_mac": "~/.pi/agent/skills",
                "doc_win": "%USERPROFILE%\\.pi\\agent\\skills",
            },
        }

        deploy_sh = read("_maintenance/deploy.sh")
        deploy_ps = read("_maintenance/deploy.ps1")
        webui_py = read("_maintenance/webui.py")
        webui_ps = read("_maintenance/webui.ps1")
        docs = read("README.md") + read("README_EN.md") + read("SKILL.md")

        for name, paths in expected_paths.items():
            with self.subTest(agent=name):
                self.assertIn(paths["mac"], deploy_sh)
                self.assertIn(paths["win"], deploy_ps)
                self.assertIn(paths["py"], webui_py)
                self.assertIn(paths["win"], webui_ps)
                self.assertIn(paths["doc_mac"], docs)
                self.assertIn(paths["doc_win"], docs)

        for stale_path in (
            "$HOME/.opencode/skills",
            "$Home\\.opencode\\skills",
            'Path.home() / ".opencode/skills"',
            "$HOME/.goose/skills",
            "$Home\\.goose\\skills",
            'Path.home() / ".goose/skills"',
            "$HOME/.windsurf/skills",
            "$Home\\.windsurf\\skills",
            'Path.home() / ".windsurf/skills"',
            "$HOME/.pi/skills",
            "$Home\\.pi\\skills",
            'Path.home() / ".pi/skills"',
        ):
            self.assertNotIn(stale_path, deploy_sh + deploy_ps + webui_py + webui_ps)

    def test_update_checks_use_backend_release_proxy(self):
        """The About page must not depend on the browser reaching GitHub.

        The self-update path already fetches GitHub from the local backend with
        a User-Agent. The manual "Check for Updates" path should use the same
        backend boundary so CORS/ad blockers/browser-side GitHub failures do
        not make a real release look like "unknown".
        """
        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")
        html_src = read("_maintenance/webui/index.html")

        self.assertIn("def get_latest_release", py_src)
        self.assertIn('"/api/latest-release"', py_src)
        self.assertIn("function Get-LatestRelease", ps_src)
        self.assertIn('"/api/latest-release"', ps_src)
        self.assertIn("archive/refs/tags", py_src)
        self.assertIn("archive/refs/tags", ps_src)
        self.assertIn("fetchLatestRelease", html_src)
        self.assertIn("fetch('/api/latest-release')", html_src)
        self.assertNotIn("fetch('https://api.github.com/repos/RunhuaHuang/EasySkills/releases/latest')", html_src)

    # -------------------------------------------------------------------------
    # Windows background launching — Scheduled Tasks (S4U) + AV-safe launchers
    # -------------------------------------------------------------------------

    def test_windows_scripts_do_not_use_wscript_shell_run_pattern(self):
        """WScript.Shell.Run(cmd, 0, ...) inside a PowerShell script is a
        well-known AV heuristic flag (used by script-based malware). We use
        Scheduled Tasks for true persistence and plain Start-Process for
        background launches."""
        for rel in (
            "install.ps1",
            "_maintenance/watch.ps1",
            "_maintenance/deploy.ps1",
        ):
            src = read(rel)
            # CreateShortcut via WScript.Shell is OK (just makes a .lnk file).
            # We forbid .Run with hidden-window flag from PowerShell scripts.
            self.assertNotRegex(
                src,
                r"New-Object -ComObject WScript\.Shell[\s\S]{0,400}\.Run\(",
                rel,
            )

    def test_windows_persistence_uses_scheduled_tasks(self):
        """Persistence is provided by user-level Scheduled Tasks. LogonType
        is Interactive (Limited run level) — the simplest option that works
        without admin rights. Window hiding is handled at the action level
        via wscript.exe + run-hidden.vbs, not via LogonType."""
        reg = read("_maintenance/register-tasks.ps1")
        self.assertIn("Register-ScheduledTask", reg)
        self.assertIn("-LogonType Interactive", reg)
        self.assertIn("-RunLevel Limited", reg)
        self.assertIn("New-ScheduledTaskTrigger -AtLogOn", reg)
        self.assertIn("EasySkills WebUI", reg)
        self.assertIn("EasySkills Watcher", reg)
        # Restart-on-failure count is conservative (AV-friendly).
        self.assertRegex(reg, r"-RestartCount\s+\d{1,2}(?!\d)")
        # Must reap stale supervisor processes before re-registering so an old
        # supervisor's window doesn't linger after upgrade.
        self.assertIn("Stop-EasySkillsBackgroundProcesses", reg)
        # S4U is gone — most non-admin accounts lack SeBatchLogonRight, and
        # the attempted-then-fallback approach produced noisy warnings on
        # every install.
        self.assertNotIn("-LogonType S4U", reg)

        install = read("install.ps1")
        self.assertIn("register-tasks.ps1", install)
        watch = read("_maintenance/watch.ps1")
        self.assertIn("register-tasks.ps1", watch)

    def test_windows_task_action_uses_wscript_not_powershell_directly(self):
        """The Scheduled Task action MUST be wscript.exe pointing at
        run-hidden.vbs — NOT powershell.exe directly. powershell.exe is a
        console-subsystem app and creates a console window even with
        `-WindowStyle Hidden` under interactive Task Scheduler. wscript.exe
        is GUI-subsystem and never creates a console."""
        reg = read("_maintenance/register-tasks.ps1")
        self.assertIn("wscript.exe", reg)
        self.assertIn("run-hidden.vbs", reg)
        # The action's Execute must be wscript.exe (not powershell.exe).
        # The Argument string passes the .vbs and the .ps1 service path.
        self.assertRegex(
            reg,
            r"New-ScheduledTaskAction\s+-Execute\s+\$WscriptExe",
        )

    def test_windows_uninstaller_removes_scheduled_tasks(self):
        unwatch = read("_maintenance/unwatch.ps1")
        self.assertIn("Unregister-ScheduledTask", unwatch)
        self.assertIn("EasySkills WebUI", unwatch)
        self.assertIn("EasySkills Watcher", unwatch)
        # Legacy startup shortcuts (old install scheme) are also cleaned up.
        self.assertIn("EasySkillsWatcher.lnk", unwatch)
        self.assertIn("EasySkillsWebUI.lnk", unwatch)

    def test_windows_launcher_is_silent_vbs_not_visible_bat(self):
        """The user-facing 'Start' launcher must be a .vbs running under
        wscript.exe so it shows ZERO console window. The old .bat is gone."""
        from pathlib import Path
        vbs = ROOT / "_maintenance/Windows/Start — 启动.vbs"
        bat = ROOT / "_maintenance/Windows/Start — 启动.bat"
        self.assertTrue(vbs.exists(), "Start — 启动.vbs missing")
        self.assertFalse(bat.exists(), "Legacy Start — 启动.bat must be removed")

        src = vbs.read_text(encoding="utf-8")
        # Triggers the tasks via Task Scheduler COM (no schtasks.exe spawn).
        self.assertIn("Schedule.Service", src)
        self.assertIn('"EasySkills WebUI"', src)
        self.assertIn('"EasySkills Watcher"', src)
        self.assertIn("Shell.Application", src)
        # Fallback path goes through wscript.exe + run-hidden.vbs so no
        # console-subsystem process is launched directly.
        self.assertIn("run-hidden.vbs", src)
        self.assertIn("wscript.exe", src)

    def test_windows_run_hidden_vbs_launcher_exists(self):
        """run-hidden.vbs is the windowless bootstrap used by all Scheduled
        Task actions. wscript.exe is GUI-subsystem and never spawns a
        console; the .vbs in turn launches PowerShell with SW_HIDE."""
        from pathlib import Path
        vbs = ROOT / "_maintenance/run-hidden.vbs"
        self.assertTrue(vbs.exists(), "_maintenance/run-hidden.vbs missing")
        src = vbs.read_text(encoding="utf-8")
        self.assertIn("WScript.Arguments(0)", src)
        self.assertIn("powershell.exe", src)
        # Must hide the window: SW_HIDE (0), don't wait (False).
        self.assertRegex(src, r'\.Run\s+(?:cmd|"[^"]*").*,\s*0,\s*False')

    def test_windows_bat_files_auto_close_instead_of_blocking_on_pause(self):
        """Foreground .bat windows must auto-close (timeout) instead of
        waiting for a keypress (pause)."""
        for rel in (
            "install_windows.bat",
            "uninstall_windows.bat",
            "_maintenance/Windows/Uninstall — 卸载.bat",
        ):
            src = read(rel)
            self.assertNotIn("pause > nul", src, rel)
            self.assertIn("timeout /t", src, rel)

    def test_windows_supervisor_has_single_instance_mutex(self):
        """webui-service.ps1 and watcher-service.ps1 must guard against
        multiple concurrent instances via a named mutex (Local\\ scope —
        Global\\ would look like cross-session malware persistence to AV)."""
        webui_svc = read("_maintenance/webui-service.ps1")
        watcher_svc = read("_maintenance/watcher-service.ps1")
        for src in (webui_svc, watcher_svc):
            self.assertIn("System.Threading.Mutex", src)
            self.assertIn("Local\\EasySkills", src)
            self.assertNotIn("Global\\EasySkills", src)

    def test_windows_webui_uses_supervisor_service(self):
        service = read("_maintenance/webui-service.ps1")
        self.assertIn("function Test-WebUIPort", service)
        self.assertIn("while ($true)", service)
        self.assertIn("webui.ps1", service)
        self.assertIn("-NoBrowser", service)

        # The supervisor script is referenced directly by install/watch and
        # by the Scheduled Task registration helper. install_windows.bat
        # delegates to watch.ps1 instead of referencing the supervisor directly.
        for rel in (
            "install.ps1",
            "_maintenance/watch.ps1",
            "_maintenance/deploy.ps1",
            "_maintenance/register-tasks.ps1",
        ):
            self.assertIn("webui-service.ps1", read(rel), rel)
        # install_windows.bat must hand off to watch.ps1 (which then registers
        # the Scheduled Tasks that ultimately invoke webui-service.ps1).
        self.assertIn("watch.ps1", read("install_windows.bat"))

        webui = read("_maintenance/webui.ps1")
        self.assertIn("[switch]$NoBrowser", webui)
        # Browser auto-open must be skippable via either the -NoBrowser
        # switch (used by direct PS invocation) or the
        # EASYSKILLS_NO_BROWSER env var (used by the wscript launcher path
        # where passing a switch is awkward).
        self.assertIn("EASYSKILLS_NO_BROWSER", webui)
        self.assertRegex(webui, r"if \(-not \$SkipBrowser")

    def test_webui_stop_watcher_keeps_backend_running(self):
        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")
        deploy_ps = read("_maintenance/deploy.ps1")
        unwatch_ps = read("_maintenance/unwatch.ps1")

        # macOS still uses the deploy-script path (launchctl unload is light).
        self.assertIn('"/api/watcher/stop":         lambda: run_deploy("--unwatch")', py_src)

        # Windows uses dedicated narrow functions for start/stop so the
        # WebUI request handler is never killed by the very action it
        # spawned (which would surface as a "Network offline" flash).
        self.assertIn("function Start-WatcherTask", ps_src)
        self.assertIn("function Stop-WatcherTask", ps_src)
        self.assertRegex(ps_src, r'/api/watcher/start"\s*\)\s*\{\s*\n\s*Send-JsonResponse\s+\$Context\s+\(Start-WatcherTask\)')
        self.assertRegex(ps_src, r'/api/watcher/stop"\s*\)\s*\{\s*\n\s*Send-JsonResponse\s+\$Context\s+\(Stop-WatcherTask\)')
        # Watcher start must NOT route through Run-DeployCommand by default;
        # only via the fallback path when the task is missing.
        self.assertIn("Start-ScheduledTask -TaskName \"EasySkills Watcher\"", ps_src)
        self.assertIn("Disable-ScheduledTask -TaskName \"EasySkills Watcher\"", ps_src)
        self.assertIn("function Quote-ProcessArgument", ps_src)
        self.assertIn('Run-DeployCommand @("-Add", $BodyData["path"])', ps_src)
        self.assertIn('Run-DeployCommand @("-Remove", $BodyData["path"])', ps_src)
        self.assertNotIn('Run-DeployCommand @("-Add", "`"$($BodyData["path"])`"")', ps_src)

        # Legacy deploy/unwatch -KeepWebUI flag still wired up for the
        # fallback path and for the uninstaller.
        self.assertIn("[switch]$KeepWebUI", deploy_ps)
        self.assertIn("[switch]$KeepWebUI", unwatch_ps)
        self.assertIn("if (-not $KeepWebUI)", unwatch_ps)

    def test_frontend_refreshes_token_after_forbidden(self):
        src = read("_maintenance/webui/index.html")
        self.assertIn("refreshEasySkillsToken", src)
        self.assertIn("res.status === 403", src)
        self.assertIn("retryOnForbidden", src)

    def test_macos_webui_launches_through_launchctl_with_loopback_url(self):
        for rel in ("_maintenance/deploy.sh", "_maintenance/macOS/Start — 启动.command"):
            src = read(rel)
            self.assertIn("com.easyskills.webui.manual", src, rel)
            self.assertIn("launchctl submit", src, rel)
            self.assertIn("command -v python3", src, rel)
            self.assertIn("http://127.0.0.1:6633", src, rel)
            self.assertNotIn("nohup python3", src, rel)

        for rel in ("install.sh", "install_mac.command"):
            src = read(rel)
            self.assertIn('bash "$PERM_DIR/_maintenance/deploy.sh" --webui', src, rel)
            self.assertIn("http://127.0.0.1:6633", src, rel)
            self.assertNotIn('open "http://127.0.0.1:6633"', src, rel)
            self.assertNotIn('xdg-open "http://127.0.0.1:6633"', src, rel)
            self.assertNotIn("nohup python3", src, rel)
            self.assertNotIn("launchctl submit", src, rel)

        deploy_src = read("_maintenance/deploy.sh")
        start_src = read("_maintenance/macOS/Start — 启动.command")
        self.assertIn("EASYSKILLS_NO_BROWSER=1", start_src)
        self.assertIn("lsof -tiTCP:6633 -sTCP:LISTEN", deploy_src)
        self.assertIn('[[ "$cmdline" == *"$SCRIPT_DIR/webui.py"* ]]', deploy_src)

        webui_src = read("_maintenance/webui.py")
        self.assertIn('sp.Popen(["open", f"http://127.0.0.1:{PORT}"]', webui_src)
        self.assertIn("http://127.0.0.1:{PORT}", webui_src)

    def test_macos_watcher_status_ignores_webui_launchd_service(self):
        webui = load_python_webui_module()
        launchctl_output = "16125\t0\tcom.easyskills.webui.manual\n"

        with mock.patch.object(webui.platform, "system", return_value="Darwin"), \
             mock.patch.object(webui.subprocess, "run", return_value=SimpleNamespace(stdout=launchctl_output)):
            self.assertEqual({"running": False, "pid": None}, webui.get_watcher_status())

    def test_macos_watcher_status_matches_exact_watcher_launchd_label(self):
        webui = load_python_webui_module()
        launchctl_output = "-\t0\tcom.easyskills.webui.manual\n123\t0\tcom.easyskills.watcher\n"

        with mock.patch.object(webui.platform, "system", return_value="Darwin"), \
             mock.patch.object(webui.subprocess, "run", return_value=SimpleNamespace(stdout=launchctl_output)):
            self.assertEqual({"running": True, "pid": "123"}, webui.get_watcher_status())


if __name__ == "__main__":
    unittest.main()
