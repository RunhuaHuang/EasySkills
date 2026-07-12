#!/usr/bin/env python3
import base64
import json
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

    def test_api_gets_require_token_and_frontend_sends_it(self):
        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")
        html_src = read("_maintenance/webui/index.html")

        for endpoint in ("/api/status", "/api/skills", "/api/agents", "/api/latest-release"):
            with self.subTest(endpoint=endpoint):
                self.assertIn(f'path == "{endpoint}"', py_src)
                self.assertIn(f'$UrlPath -eq "{endpoint}"', ps_src)

        self.assertGreaterEqual(py_src.count("if not self._is_token_valid():"), 4)
        self.assertIn("function Test-TokenValid", ps_src)
        self.assertGreaterEqual(ps_src.count("Test-TokenValid $Request"), 5)
        self.assertIn("'X-EasySkills-Token': easySkillsToken", html_src)
        self.assertIn("fetch('/api/latest-release', { headers })", html_src)
        self.assertNotIn("fetch('/api/latest-release')", html_src)

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
        self.assertIn('cp "$CURRENT_DIR/README_SYSTEM.md" "$PERM_DIR/README_SYSTEM.md"', read("install_mac.command"))
        self.assertIn('copy /Y "%CURRENT_DIR%README_SYSTEM.md" "%PERM_DIR%\\README_SYSTEM.md" > nul', read("install_windows.bat"))

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
        # agents.json is the single source of truth for the agent count, and
        # _maintenance/.version is the single source of truth for the version.
        # Deriving both expected values from those files (instead of hardcoding
        # them here) means this test never goes red just because a release
        # bumped the version but forgot to update the assertions.
        agent_count = len(json.loads(read("_maintenance/agents.json"))["agents"])
        version = read("_maintenance/.version").strip()

        self.assertIn(f"Version-{version}", read("README_EN.md"))
        self.assertIn(f"版本-{version}", read("README.md"))
        self.assertIn(f"{agent_count}+ agent targets are pre-configured", read("README_EN.md"))
        self.assertIn(f"开箱即用支持 {agent_count}+ 个 Agent", read("README.md"))

    def test_default_agent_targets_include_requested_agents_and_corrected_paths(self):
        # Driven by agents.json (the single source of truth): every agent entry
        # is checked across all five runtime surfaces so a new agent can never
        # silently land in only some files. Path forms are derived mechanically
        # from the canonical mac_path/win_path in agents.json.
        agents = json.loads(read("_maintenance/agents.json"))["agents"]

        deploy_sh = read("_maintenance/deploy.sh")
        deploy_ps = read("_maintenance/deploy.ps1")
        webui_py = read("_maintenance/webui.py")
        webui_ps = read("_maintenance/webui.ps1")
        docs = read("README.md") + read("README_EN.md") + read("README_SYSTEM.md")

        for agent in agents:
            name = agent["name"]
            mac_tilde = agent["mac_path"]                       # ~/.xxx/skills
            win_env = agent["win_path"]                         # %USERPROFILE%\.xxx\skills

            mac_home = "$HOME/" + mac_tilde[2:]                 # deploy.sh form
            win_ps = "$Home\\" + win_env[len("%USERPROFILE%\\"):]  # .ps1 form
            py_tail = mac_tilde[2:]                             # webui.py string-literal tail

            with self.subTest(agent=name):
                self.assertIn(mac_home, deploy_sh,
                              f"{name}: deploy.sh missing {mac_home}")
                self.assertIn(win_ps, deploy_ps,
                              f"{name}: deploy.ps1 missing {win_ps}")
                # webui.py uses the mac_path tail as a single string literal
                # (e.g. Path.home() / ".codex/skills"). Match the tail; one
                # legacy entry (Run) splits the segments, so fall back to the
                # final path component for that case.
                if py_tail not in webui_py:
                    self.assertIn(py_tail.rsplit("/", 1)[-1], webui_py,
                                  f"{name}: webui.py missing path tail for {mac_tilde}")
                self.assertIn(win_ps, webui_ps,
                              f"{name}: webui.ps1 missing {win_ps}")
                self.assertIn(mac_tilde, docs,
                              f"{name}: docs missing {mac_tilde}")
                self.assertIn(win_env, docs,
                              f"{name}: docs missing {win_env}")

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
        self.assertIn("fetch('/api/latest-release', { headers })", html_src)
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
            self.assertIn("start_new_session=True", src, rel)
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

    # -------------------------------------------------------------------------
    # agents.json — single source of truth
    # -------------------------------------------------------------------------

    def test_agents_json_exists_and_has_valid_structure(self):
        """agents.json must exist and contain a well-formed agents list."""
        import json
        path = ROOT / "_maintenance" / "agents.json"
        self.assertTrue(path.exists(), "agents.json missing")
        data = json.loads(path.read_text(encoding="utf-8"))
        self.assertIn("agents", data)
        agents = data["agents"]
        self.assertGreaterEqual(len(agents), 38, "agents.json should have >= 38 entries")
        for agent in agents:
            self.assertIn("name", agent)
            self.assertIn("mac_path", agent)
            self.assertIn("win_path", agent)
            self.assertTrue(agent["mac_path"].startswith("~/"), f"{agent['name']} mac_path should start with ~/")
            self.assertTrue(agent["win_path"].startswith("%USERPROFILE%\\"), f"{agent['name']} win_path should start with %USERPROFILE%\\")

    def test_scripts_reference_agents_json(self):
        """All four scripts must reference agents.json for loading."""
        for rel in ("_maintenance/deploy.sh", "_maintenance/deploy.ps1",
                    "_maintenance/webui.py", "_maintenance/webui.ps1"):
            src = read(rel)
            self.assertIn("agents.json", src, f"{rel} does not reference agents.json")

    def test_hardcoded_fallbacks_match_agents_json(self):
        """Hardcoded fallback arrays must contain the same paths as agents.json."""
        import json
        data = json.loads((ROOT / "_maintenance" / "agents.json").read_text(encoding="utf-8"))

        # Check deploy.sh fallback — names appear in case statements
        sh_src = read("_maintenance/deploy.sh")
        for agent in data["agents"]:
            name = agent["name"]
            self.assertIn(f'"{name}"', sh_src, f"deploy.sh fallback missing name: {name}")

        # Check deploy.ps1 fallback — paths appear in the targets array
        ps_src = read("_maintenance/deploy.ps1")
        for agent in data["agents"]:
            # win_path uses %USERPROFILE% which expands to $Home in PS fallback
            win_rel = agent["win_path"].replace("%USERPROFILE%\\", "")
            self.assertIn(win_rel, ps_src, f"deploy.ps1 fallback missing path: {win_rel}")

    # -------------------------------------------------------------------------
    # Persistent WebUI token
    # -------------------------------------------------------------------------

    def test_webui_persists_token_to_file(self):
        """webui.py must read/write a persistent token file stored inside
        SCRIPT_DIR (not in the bare home directory root)."""
        src = read("_maintenance/webui.py")
        self.assertIn(".easyskills-token", src)
        self.assertIn("TOKEN_FILE", src)
        self.assertIn("def _load_or_create_token", src)
        # Token must be co-located with the installation, not in bare home
        self.assertIn("TOKEN_FILE = SCRIPT_DIR / \".easyskills-token\"", src)
        self.assertNotIn('TOKEN_FILE = Path.home() / ".easyskills-token"', src)

    def test_windows_webui_persists_token_to_file(self):
        """webui.ps1 must read/write a persistent token file."""
        src = read("_maintenance/webui.ps1")
        self.assertIn(".easyskills-token", src)
        self.assertIn("Initialize-WebUIToken", src)

    # -------------------------------------------------------------------------
    # Rollback support
    # -------------------------------------------------------------------------

    def test_self_update_creates_backup_before_overwrite(self):
        """do_self_update must back up _maintenance atomically before overwriting."""
        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")
        self.assertIn("_maintenance.bak", py_src)
        self.assertIn("_maintenance.bak", ps_src)
        # New atomic pattern: build in .new, then rename
        self.assertIn("_maintenance.new", py_src)
        self.assertIn("dest_maint.rename(backup_maint)", py_src)
        self.assertIn("new_maint_tmp.rename(dest_maint)", py_src)
        self.assertIn("_maintenance.bak/", read(".gitignore"))

    def test_rollback_endpoint_exists(self):
        """Both backends must expose /api/rollback."""
        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")
        html_src = read("_maintenance/webui/index.html")
        self.assertIn('"/api/rollback"', py_src)
        self.assertIn('"/api/rollback"', ps_src)
        self.assertIn("do_rollback", py_src)
        self.assertIn("Do-Rollback", ps_src)

    def test_rollback_ui_in_frontend(self):
        """Frontend must have rollback button and JS function."""
        html_src = read("_maintenance/webui/index.html")
        self.assertIn('id="btn-rollback"', html_src)
        self.assertIn("function performRollback", html_src)
        self.assertIn("t-rollback", html_src)

    def test_status_endpoint_reports_backup_existence(self):
        """Both backends must expose has_backup in /api/status."""
        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")
        self.assertIn("has_backup", py_src)
        self.assertIn("has_backup", ps_src)

    def test_rollback_function_checks_for_backup(self):
        """Rollback must fail gracefully when no backup exists."""
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(webui, "CENTRAL_DIR", Path(tmp)):
                result = webui.do_rollback()
                self.assertFalse(result["success"])
                self.assertIn("No backup", result["message"])

    # -------------------------------------------------------------------------
    # Linux systemd support
    # -------------------------------------------------------------------------

    def test_systemd_unit_files_exist(self):
        """systemd service and path units must exist."""
        self.assertTrue((ROOT / "_maintenance/systemd/easyskills-watcher.service").exists())
        self.assertTrue((ROOT / "_maintenance/systemd/easyskills-watcher.path").exists())

    def test_watch_sh_handles_linux(self):
        """watch.sh must handle Linux with systemd."""
        src = read("_maintenance/watch.sh")
        self.assertIn("Linux", src)
        self.assertIn("systemctl", src)
        self.assertIn("easyskills-watcher.path", src)

    def test_unwatch_sh_handles_linux(self):
        """unwatch.sh must handle Linux with systemd."""
        src = read("_maintenance/unwatch.sh")
        self.assertIn("Linux", src)
        self.assertIn("systemctl", src)

    def test_unwatch_sh_uses_installation_path_for_inflight_deploy(self):
        src = read("_maintenance/unwatch.sh")
        self.assertIn('CENTRAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"', src)
        self.assertIn("find_inflight_deploy_pids", src)
        self.assertNotIn("$HOME/EasySkills", src)
        self.assertNotIn("[E]asySkills/_maintenance/deploy", src)

    # -------------------------------------------------------------------------
    # Code-quality contracts added by code review
    # -------------------------------------------------------------------------

    def test_self_update_verifies_download_integrity(self):
        """do_self_update must perform a SHA-256 double-download check."""
        py_src = read("_maintenance/webui.py")
        self.assertIn("_sha256_file", py_src)
        self.assertIn("import hashlib", py_src)
        self.assertIn("hmac.compare_digest(digest1, digest2)", py_src)
        self.assertIn("Integrity check failed", py_src)

    def test_oversized_body_returns_413(self):
        """_body() must return None and do_POST must send 413 for oversized payloads."""
        py_src = read("_maintenance/webui.py")
        self.assertIn("return None  # Signal to caller: send 413", py_src)
        self.assertIn("self.send_response(413)", py_src)
        self.assertIn("body is None", py_src)

    def test_agent_prefix_map_is_module_level_constant(self):
        """_AGENT_PREFIX_MAP must be defined at module level, not inside a function."""
        py_src = read("_maintenance/webui.py")
        self.assertIn("_AGENT_PREFIX_MAP", py_src)
        # Must not redefine it inside get_agent_name
        fn_body = py_src.split("def get_agent_name")[1].split("\ndef ")[0]
        self.assertNotIn("_AGENT_PREFIX_MAP = [", fn_body)

    def test_rollback_uses_atomic_rename(self):
        """do_rollback must use atomic rename not file-by-file copy."""
        py_src = read("_maintenance/webui.py")
        self.assertIn("_maintenance.rollback", py_src)
        self.assertIn("rollback_tmp.rename(dest_maint)", py_src)
        # The old iterdir() copy loop must not be present in do_rollback
        rollback_fn = py_src.split("def do_rollback")[1].split("\ndef ")[0]
        self.assertNotIn("for item in backup_maint.iterdir()", rollback_fn)

    def test_install_scripts_remove_legacy_skill_md(self):
        """Installer scripts must delete the old SKILL.md to avoid ambiguity."""
        sh_src = read("install.sh")
        ps_src = read("install.ps1")
        self.assertIn('rm -f "$PERM_DIR/SKILL.md"', sh_src)
        self.assertIn('Remove-Item $LegacySkillMd -Force', ps_src)

    def test_deploy_sh_central_resolved_fails_loudly(self):
        """central_resolved must fail loudly (return 1) if cd fails, not produce empty string."""
        sh_src = read("_maintenance/deploy.sh")
        # The error guards must appear in both run_sync and run_cleanup
        self.assertEqual(
            sh_src.count("Aborting sync."),
            1,
            "run_sync must have exactly one loud-fail guard for central_resolved"
        )
        self.assertEqual(
            sh_src.count("Aborting cleanup."),
            1,
            "run_cleanup must have exactly one loud-fail guard for central_resolved"
        )

    # -------------------------------------------------------------------------
    # Link-health: dangling/external-link skill detection (cross-platform)
    # -------------------------------------------------------------------------

    def test_get_skills_marks_external_link_and_excludes_dangling(self):
        """get_skills() must list external-link skills (is_external_link=True) and
        never list dangling symlinks (is_dir() is False for them)."""
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            central = root / "central"
            central.mkdir()
            # external symlink targets live in a sibling dir (unique per test run)
            ext_store = root / "external-store"
            ext_store.mkdir()
            # normal real directory
            (central / "normal-skill").mkdir()
            (central / "normal-skill" / "SKILL.md").write_text("ok")
            # external symlink: target exists outside central dir
            ext_target = ext_store / "ext-target"
            ext_target.mkdir()
            (ext_target / "SKILL.md").write_text("ext")
            (central / "external-skill").symlink_to(ext_target)
            # dangling symlink: target does not exist
            (central / "dangling-skill").symlink_to(ext_store / "gone")

            with mock.patch.object(webui, "CENTRAL_DIR", central):
                skills = webui.get_skills()
            names = {s["name"]: s for s in skills}

            self.assertIn("normal-skill", names)
            self.assertIn("external-skill", names)
            self.assertNotIn("dangling-skill", names,
                             "dangling symlinks must be excluded (is_dir()==False)")
            self.assertFalse(names["normal-skill"]["is_external_link"])
            self.assertTrue(names["external-skill"]["is_external_link"])

    def test_get_central_dir_warnings_counts_dangling_and_external(self):
        """get_central_dir_warnings() must count dangling vs external links correctly."""
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            central = root / "central"
            central.mkdir()
            ext_store = root / "external-store"
            ext_store.mkdir()
            ext_target = ext_store / "ext-target"
            ext_target.mkdir()
            (central / "ext1").symlink_to(ext_target)
            (central / "ext2").symlink_to(ext_target)
            (central / "dangling1").symlink_to(ext_store / "nope")
            (central / "real-dir").mkdir()  # not a link, must be ignored

            with mock.patch.object(webui, "CENTRAL_DIR", central):
                warnings = webui.get_central_dir_warnings()
            self.assertEqual(warnings, {"dangling_count": 1, "external_link_count": 2})

    def test_get_central_dir_warnings_handles_missing_central_dir(self):
        """get_central_dir_warnings() must return zeros if central dir does not exist."""
        webui = load_python_webui_module()
        with mock.patch.object(webui, "CENTRAL_DIR", Path("/nonexistent-easyskills-test-dir")):
            warnings = webui.get_central_dir_warnings()
        self.assertEqual(warnings, {"dangling_count": 0, "external_link_count": 0})

    def test_link_health_fields_in_status_and_skill_endpoints(self):
        """Both backends must expose dangling_count/external_link_count in /api/status
        and is_external_link in /api/skills; the frontend must consume them."""
        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")
        html_src = read("_maintenance/webui/index.html")

        # /api/status link-health counts — both backends
        for src, label in ((py_src, "webui.py"), (ps_src, "webui.ps1")):
            with self.subTest(backend=label):
                self.assertIn("dangling_count", src, f"{label} missing dangling_count in status")
                self.assertIn("external_link_count", src, f"{label} missing external_link_count in status")

        # /api/skills is_external_link field — both backends
        for src, label in ((py_src, "webui.py"), (ps_src, "webui.ps1")):
            with self.subTest(backend_skill_field=label):
                self.assertIn("is_external_link", src, f"{label} missing is_external_link in skills")

        # Frontend must consume these fields
        self.assertIn("s.is_external_link", html_src)
        self.assertIn("status.dangling_count", html_src)
        self.assertIn("status.external_link_count", html_src)

    def test_sync_prunes_dangling_symlinks_in_central_dir(self):
        """deploy.sh run_sync must auto-unlink dangling symlinks from the central dir,
        and deploy.ps1 Run-Sync must do the equivalent for reparse points."""
        sh_src = read("_maintenance/deploy.sh")
        ps_src = read("_maintenance/deploy.ps1")

        # bash: dangling detection + unlink + count
        self.assertIn('PART A.5', sh_src)
        self.assertIn('[ -L "$_entry" ]', sh_src)
        self.assertIn('dangling_removed', sh_src)
        # The dangling branch must unlink
        self.assertRegex(sh_src, r'if \[ ! -e "\$_entry" \][\s\S]*?unlink "\$_entry"')

        # PowerShell: reparse-point detection + Remove-Item + count
        self.assertIn('PART A.5', ps_src)
        self.assertIn('ReparsePoint', ps_src)
        self.assertIn('$DanglingRemoved', ps_src)

    # -------------------------------------------------------------------------
    # Reparse-point safety: never delete link target contents (Fix A/B)
    # -------------------------------------------------------------------------

    def test_deploy_ps1_deletes_reparse_points_without_recurse(self):
        """deploy.ps1 must NEVER use Remove-Item -Recurse on a reparse point.

        Remove-Item -Recurse -Force on a directory junction/symlink can
        traverse into and delete the REAL contents of the link target on
        Windows PowerShell 5.1 — permanent data loss of the central skill
        library. Reparse points must be removed with a non-recursive delete
        (Directory::Delete(path, $false)) that only removes the link itself.
        """
        ps_src = read("_maintenance/deploy.ps1")
        # No Remove-Item call on a reparse-point path may carry -Recurse.
        # Find every ReparsePoint branch and assert the line after the
        # attribute check uses Directory::Delete, not Remove-Item -Recurse.
        self.assertNotIn("Remove-Item $DestPath -Recurse -Force", ps_src,
                         "PART B must not use Remove-Item -Recurse on junctions")
        self.assertNotIn("Remove-Item $Item.FullName -Recurse -Force", ps_src,
                         "PART A legacy cleanup must not use Remove-Item -Recurse on junctions")
        # The safe non-recursive delete must be present.
        self.assertIn("[System.IO.Directory]::Delete(", ps_src)

    def test_deploy_ps1_detects_reparse_points_without_following_links(self):
        """deploy.ps1 PART B must use Get-Item -Force (attributes), not
        Test-Path, to detect an existing entry at the destination.

        Test-Path FOLLOWS reparse points: a dangling junction (target removed)
        reports False, so it would be skipped and New-Item would then fail
        because the dead reparse point still occupies the name. Get-Item
        -Force sees the entry regardless of whether its target exists.
        """
        ps_src = read("_maintenance/deploy.ps1")
        # The existence check in PART B must use Get-Item -Force, not Test-Path.
        self.assertIn("Get-Item -LiteralPath $DestPath -Force -ErrorAction SilentlyContinue", ps_src)

    def test_webui_ps1_deletes_reparse_points_without_recurse(self):
        """webui.ps1 Do-Map and Do-Unmap must NEVER use Remove-Item -Recurse
        on a reparse point.

        Remove-Item -Recurse -Force on a directory junction can traverse into
        and delete the real target contents on Windows PowerShell 5.1. Both
        functions must use [System.IO.Directory]::Delete(path, $false) to
        remove only the link itself, mirroring the contract in deploy.ps1.
        """
        ps_src = read("_maintenance/webui.ps1")
        # Neither Do-Map nor Do-Unmap may use Remove-Item -Recurse on a path
        # derived from a ReparsePoint attribute check.
        self.assertNotIn(
            "Remove-Item $Dest -Recurse -Force",
            ps_src,
            "Do-Map must not use Remove-Item -Recurse on a reparse point"
        )
        self.assertNotIn(
            "Remove-Item $Item.FullName -Recurse -Force",
            ps_src,
            "Do-Unmap must not use Remove-Item -Recurse on a reparse point"
        )
        # The safe non-recursive delete must be present in both functions.
        self.assertIn("[System.IO.Directory]::Delete($Dest, $false)", ps_src,
                      "Do-Map should use Directory::Delete for the reparse point")
        self.assertIn("[System.IO.Directory]::Delete($Item.FullName, $false)", ps_src,
                      "Do-Unmap should use Directory::Delete for the reparse point")

    def test_deploy_ps1_add_remove_target_return_true_on_success(self):
        """Add-Target / Remove-Target must return $true on the success path.

        The main dispatch wraps them as `if (-not (Add-Target $Add)) { ...; exit 1 }`.
        In PowerShell a function with no explicit return on the success path
        yields $null, and `-not $null` is $true — so a missing `return $true`
        makes the script `exit 1` even after a successful add/remove. This
        regressed the WebUI ("Command failed" shown for a successful add).
        Every code path that is NOT the early `return $false` must return $true.
        """
        ps_src = read("_maintenance/deploy.ps1")
        self.assertIn("if (-not (Add-Target $Add))", ps_src,
                      "main dispatch must check Add-Target's return value")
        self.assertIn("if (-not (Remove-Target $Remove))", ps_src,
                      "main dispatch must check Remove-Target's return value")
        # Both functions must have an explicit success return.
        self.assertIn("return $true", ps_src,
                      "Add-Target/Remove-Target must return $true on success")
        # The failure early-out must still be present.
        self.assertIn("return $false", ps_src,
                      "Add-Target/Remove-Target must return $false on bad input")

    def test_update_agent_path_normalizes_old_path_symmetrically(self):
        """update_agent_path must normalize old_path just like new_path.

        Without normalization, a `~`-form or dotted old_path silently fails to
        match the stored absolute path, leaving a stale/duplicate entry behind.
        Both backends (webui.py and webui.ps1) must normalize old_path the same
        way they normalize new_path, keeping the two implementations symmetric.
        """
        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")
        # Python: both old_path and new_path go through expanduser().resolve().
        self.assertIn("old_path = str(Path(old_path).expanduser().resolve())", py_src)
        self.assertIn("new_path = str(Path(new_path).expanduser().resolve())", py_src)
        # PowerShell: both OldPath and NewPath go through GetFullPath.
        self.assertIn("$OldPath = [System.IO.Path]::GetFullPath($OldPath)", ps_src)
        self.assertIn("$NewPath = [System.IO.Path]::GetFullPath($NewPath)", ps_src)

    def test_windows_process_termination_scoped_to_install_path(self):
        """install.ps1, unwatch.ps1, register-tasks.ps1 must scope process
        matching to THIS installation's path, not a bare script-name glob.

        A bare `*watcher-service.ps1*` / `*webui-service.ps1*` matches every
        EasySkills install on the machine — cross-killing a second install's
        services. The fix (already applied to webui.ps1 / install.ps1) is to
        anchor the glob to the script's own directory.
        """
        for rel in ("_maintenance/unwatch.ps1", "_maintenance/register-tasks.ps1"):
            ps_src = read(rel)
            # No bare (un-scoped) service-script globs may remain.
            self.assertNotIn("'*webui-service.ps1*'", ps_src,
                             f"{rel}: webui-service glob must be scoped to $ScriptDir")
            self.assertNotIn("'*watcher-service.ps1*'", ps_src,
                             f"{rel}: watcher-service glob must be scoped to $ScriptDir")

    def test_webui_sets_clickjacking_and_sniffing_security_headers(self):
        """Both WebUI backends must send X-Content-Type-Options and X-Frame-Options.

        The index page embeds the auth token in a <meta> tag, so it must not be
        framable by any other (even loopback) origin.
        """
        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")
        self.assertIn('"X-Content-Type-Options", "nosniff"', py_src)
        self.assertIn('"X-Frame-Options", "DENY"', py_src)
        self.assertIn('"X-Content-Type-Options", "nosniff"', ps_src)
        self.assertIn('"X-Frame-Options", "DENY"', ps_src)

    # -------------------------------------------------------------------------
    # Self-update / rollback: host allowlist + rename-recovery (Fix C/D/E)
    # -------------------------------------------------------------------------

    def test_webui_ps1_self_update_validates_download_host(self):
        """webui.ps1 Run-SelfUpdate must reject download URLs whose host is not
        a trusted GitHub delivery host, mirroring webui.py's
        _is_github_download_url / _GITHUB_TARBALL_HOSTS."""
        ps_src = read("_maintenance/webui.ps1")
        self.assertIn("$TrustedHosts", ps_src)
        self.assertIn("objects.githubusercontent.com", ps_src)
        self.assertIn("Update rejected: download host is not a trusted GitHub host", ps_src)

    def test_webui_py_self_update_rollback_undoes_first_rename(self):
        """do_self_update rollback must UNDO the current->.bak rotation
        (restore the live version to its original place) when the second
        rename fails — it must NOT rmtree the backup, which would destroy the
        currently-running version."""
        py_src = read("_maintenance/webui.py")
        rollback_fn = py_src.split("def do_self_update")[1].split("\ndef ")[0]
        rollback_block = rollback_fn.split("except Exception:")[1] if "except Exception:" in rollback_fn else ""
        # The recovery must rename .bak back to _maintenance (undo), not
        # rmtree the backup (which would destroy the current version).
        self.assertIn("backup_maint.rename(dest_maint)", rollback_block,
                      "rollback must undo current->.bak by renaming back")
        # The destructive rmtree of backup_maint must NOT be in the rollback.
        self.assertNotIn("shutil.rmtree(backup_maint)", rollback_block,
                         "rollback must not destroy the current version in .bak")

    def test_webui_py_rollback_precleans_prev_and_recovers(self):
        """do_rollback must pre-clean _maintenance.prev (a stale .prev would
        make every subsequent rollback fail) and must restore the current
        version from .prev if the second rename fails."""
        py_src = read("_maintenance/webui.py")
        rollback_fn = py_src.split("def do_rollback")[1].split("\ndef ")[0]
        # Pre-clean of .prev must happen BEFORE the rename.
        rename_idx = rollback_fn.index("dest_maint.rename")
        preclean_idx = rollback_fn.index("shutil.rmtree(prev)")
        self.assertLess(preclean_idx, rename_idx,
                        "_maintenance.prev must be cleaned before the rename rotation")
        # Recovery: restore from .prev on failure.
        self.assertIn("prev.rename(dest_maint)", rollback_fn,
                      "rollback must restore current version from .prev on failure")

    def test_webui_ps1_rollback_precleans_prev_and_recovers(self):
        """PowerShell Do-Rollback must pre-clean _maintenance.prev and recover
        from a failed second rename — same contract as the Python side."""
        ps_src = read("_maintenance/webui.ps1")
        rollback_fn = ps_src.split("function Do-Rollback")[1].split("\nfunction ")[0]
        # Pre-clean before rename.
        self.assertIn("Rename-Item -Path $Prev", rollback_fn)
        # Recovery from .prev.
        self.assertRegex(rollback_fn, r"Rename-Item -Path \$Prev -NewName .*_maintenance",
                         "Do-Rollback must restore from .prev on failure")

    # -------------------------------------------------------------------------
    # Run-DeployCommand: async reads prevent deadlock (Fix F)
    # -------------------------------------------------------------------------

    def test_webui_ps1_deploy_command_reads_streams_asynchronously(self):
        """Run-DeployCommand must read stdout/stderr asynchronously
        (ReadToEndAsync) so the 30s timeout actually works. Synchronous
        ReadToEnd on both streams deadlocks when the child fills the pipe
        buffer on one stream while we block reading the other."""
        ps_src = read("_maintenance/webui.ps1")
        self.assertIn("ReadToEndAsync", ps_src)
        # The deadlock-prone synchronous pattern must be gone. (A bare
        # ReadToEndAsync must be the only ReadToEnd-family call here.)
        self.assertNotIn("StandardOutput.ReadToEnd()", ps_src)
        self.assertNotIn("StandardError.ReadToEnd()", ps_src)

    # -------------------------------------------------------------------------
    # Token: corrupt file recovery prevents bricked startup (Fix G)
    # -------------------------------------------------------------------------

    def test_token_loader_reclaims_corrupt_file(self):
        """_load_or_create_token must reclaim a corrupt (empty/short) token
        file instead of looping forever across restarts. A prior interrupted
        write can leave the file existing-but-empty, which the O_CREAT|O_EXCL
        path can never replace — bricking startup with RuntimeError."""
        webui = load_python_webui_module()
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            token_file = Path(tmp) / ".easyskills-token"
            # Simulate a corrupt (empty) token file.
            token_file.write_text("")
            with mock.patch.object(webui, "TOKEN_FILE", token_file):
                token = webui._load_or_create_token()
            # Must have produced a valid token, not raised RuntimeError.
            self.assertGreaterEqual(len(token), 16)
            # The file must now hold the new valid token.
            self.assertEqual(token, token_file.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
