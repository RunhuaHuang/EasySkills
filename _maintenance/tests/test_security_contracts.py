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
        self.assertIn("link_points_into_central", read("_maintenance/deploy.sh"))
        self.assertIn("Test-EasySkillsLinkTarget", read("_maintenance/deploy.ps1"))

    def test_cleanup_failures_propagate_to_uninstallers(self):
        sh_src = read("_maintenance/deploy.sh")
        ps_src = read("_maintenance/deploy.ps1")
        self.assertIn("cleanup_errors", sh_src)
        self.assertIn("Cleanup incomplete", sh_src)
        self.assertIn("return 1", sh_src)
        self.assertIn("$CleanupErrors", ps_src)
        self.assertIn("if (-not (Run-Cleanup)) { exit 1 }", ps_src)
        self.assertIn('if [ "${ACTION:-sync}" = "sync" ]', sh_src)
        self.assertIn("${ACTION} was not performed", sh_src)
        self.assertIn("$ExplicitMutation", ps_src)
        self.assertIn("$WaitMilliseconds", ps_src)

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
        self.assertIn("t-agent-config-title", html_src)
        self.assertIn("t-agent-config-desc", html_src)
        self.assertIn("skills folder", html_src)

        self.assertIn("WebUI Quick Start", html_src)
        self.assertIn("WebUI Control Map", html_src)
        self.assertIn("Managing skills in the WebUI", html_src)
        self.assertIn("Connecting Agents and maintaining paths", html_src)
        self.assertIn("Advanced CLI fallback", html_src)
        self.assertIn("bash ~/EasySkills/_maintenance/deploy.sh --sync", html_src)
        self.assertIn('powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\\EasySkills\\_maintenance\\deploy.ps1" -Sync', html_src)
        self.assertIn('bash ~/EasySkills/_maintenance/deploy.sh --add "/absolute/path/to/agent/skills"', html_src)
        self.assertIn('powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\\EasySkills\\_maintenance\\deploy.ps1" -Add "C:\\Path\\To\\Agent\\skills"', html_src)
        self.assertNotIn("CLI Reference</span>", html_src)
        self.assertNotIn("Agent Chat Commands</span>", html_src)
        self.assertNotIn("\\\\'", html_src)

    def test_dashboard_exposes_dual_channel_control_plane(self):
        html_src = read("_maintenance/webui/index.html")

        self.assertIn("dashboard-control-plane", html_src)
        self.assertIn("dashboard-channel-grid", html_src)
        self.assertIn("t-dashboard-skills-channel", html_src)
        self.assertIn("t-dashboard-rules-channel", html_src)
        self.assertIn("dashboard-agent-infrastructure", html_src)
        self.assertIn("One library, two synchronization channels", html_src)
        self.assertIn("一个中央库、两条同步通道", html_src)
        self.assertIn('id="dashboard-skill-progress-fill"', html_src)
        self.assertIn('id="dashboard-rule-progress-fill"', html_src)
        self.assertIn('id="stat-agent-paths"', html_src)
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
        self.assertIn("'t-agents': 'Agent Config'", html_src)
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

    def test_skills_page_combines_library_and_agent_sync_targets(self):
        html_src = read("_maintenance/webui/index.html")

        skills_markup = html_src.split('<section id="skills"', 1)[1].split('<section id="agents"', 1)[0]
        self.assertIn('id="skills-grid"', skills_markup)
        self.assertIn('id="skills-agents-grid"', skills_markup)
        self.assertLess(skills_markup.index('id="skills-grid"'), skills_markup.index('id="skills-agents-grid"'))
        self.assertIn("t-skill-sync-context", skills_markup)
        self.assertIn("function renderSkillAgents", html_src)
        self.assertIn("renderSkillAgents(agents, skills)", html_src)
        self.assertIn("Promise.all([", html_src)
        self.assertIn("apiCall('/api/skills')", html_src)
        self.assertIn("apiCall('/api/agents')", html_src)
        self.assertIn("data-skill-agent-action=\"map\"", html_src)
        self.assertIn("data-skill-agent-action=\"unmap\"", html_src)
        self.assertIn("'/api/agents/map'", html_src)
        self.assertIn("'/api/agents/unmap'", html_src)

        agents_markup = html_src.split('<section id="agents"', 1)[1].split('<section id="instructions"', 1)[0]
        self.assertIn("t-agent-config-title", agents_markup)
        self.assertIn("t-agent-config-list", agents_markup)
        self.assertIn("addCustomAgent", agents_markup)
        self.assertIn('id="custom-agent-skills-path"', agents_markup)
        self.assertIn('id="custom-agent-instructions-path"', agents_markup)

        render_agents = html_src.split("function renderAgents(agents)", 1)[1].split("// ==================== Instructions / Rules", 1)[0]
        self.assertNotIn('data-agent-action="map"', render_agents)
        self.assertNotIn('data-agent-action="unmap"', render_agents)
        self.assertIn('data-agent-action="edit"', render_agents)

        nav_markup = html_src.split('<div class="nav-container">', 1)[1].split('<div class="sidebar-footer">', 1)[0]
        self.assertLess(nav_markup.index('data-target="instructions"'), nav_markup.index('data-target="agents"'))
        self.assertIn('id="modal-skills-path-input"', html_src)
        self.assertIn('id="modal-instructions-path-input"', html_src)
        self.assertIn("instructions_path: instructionsPath", html_src)

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

    def test_release_check_handles_total_network_failure(self):
        webui = load_python_webui_module()
        with mock.patch.object(
            webui.urllib.request,
            "urlopen",
            side_effect=OSError("offline"),
        ):
            result = webui.get_latest_release()
        self.assertFalse(result["success"])
        self.assertIn("API error", result["message"])
        self.assertIn("fallback error", result["message"])

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

    def test_all_user_facing_uninstallers_preserve_recoverability(self):
        for rel in (
            "uninstall_mac.command",
            "_maintenance/macOS/Uninstall — 卸载.command",
        ):
            src = read(rel)
            self.assertIn("move_to_trash", src, rel)
            self.assertIn('osascript - "$target"', src, rel)
            self.assertNotIn('rm -rf "$HOME/EasySkills"', src, rel)
            self.assertIn("Uninstallation incomplete", src, rel)

        for rel in (
            "uninstall_windows.bat",
            "_maintenance/Windows/Uninstall — 卸载.bat",
        ):
            src = read(rel)
            self.assertIn("SendToRecycleBin", src, rel)
            self.assertNotIn('rd /S /Q "%PERM_DIR%"', src, rel)
            self.assertIn("if errorlevel 1 goto cleanup_failed", src, rel)
            self.assertIn("Uninstallation incomplete", src, rel)

    def test_windows_launcher_is_silent_vbs_not_visible_bat(self):
        """The user-facing 'Start' launcher must be a .vbs running under
        wscript.exe so it shows ZERO console window. The old .bat is gone."""
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
        self.assertIn("Register-CustomAgent", ps_src)
        self.assertIn('$BodyData["instructions_path"]', ps_src)
        self.assertIn("Remove-CustomAgent", ps_src)

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
        agent_update = src.split("async function saveCustomModalEdit()", 1)[1].split(
            "// --- Custom Agent Registration ---", 1
        )[0]
        self.assertIn("res.status === 403 && await refreshEasySkillsToken()", agent_update)

    def test_all_inline_ui_helpers_are_defined(self):
        src = read("_maintenance/webui/index.html")
        self.assertIn('onclick="copyWebUiUrl()"', src)
        self.assertIn("function copyWebUiUrl()", src)

    def test_macos_webui_launches_through_launchctl_with_loopback_url(self):
        deploy_src = read("_maintenance/deploy.sh")
        self.assertIn("com.easyskills.webui.manual", deploy_src)
        self.assertIn("start_new_session=True", deploy_src)
        self.assertIn("command -v python3", deploy_src)
        self.assertIn("http://127.0.0.1:6633", deploy_src)
        self.assertNotIn("nohup python3", deploy_src)

        start_src = read("_maintenance/macOS/Start — 启动.command")
        self.assertIn('exec bash "$(pwd)/deploy.sh" --webui', start_src)
        self.assertNotIn("pkill -f", start_src)

        for rel in ("install.sh", "install_mac.command"):
            src = read(rel)
            self.assertIn('bash "$PERM_DIR/_maintenance/deploy.sh" --webui', src, rel)
            self.assertIn("http://127.0.0.1:6633", src, rel)
            self.assertNotIn('open "http://127.0.0.1:6633"', src, rel)
            self.assertNotIn('xdg-open "http://127.0.0.1:6633"', src, rel)
            self.assertNotIn("nohup python3", src, rel)
            self.assertNotIn("launchctl submit", src, rel)

        self.assertIn("EASYSKILLS_NO_BROWSER=1", deploy_src)
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

    def test_linux_watcher_status_uses_persistent_systemd_units(self):
        webui = load_python_webui_module()

        def systemctl_result(args, **kwargs):
            unit = args[-1]
            active = unit == "easyskills-watcher.timer"
            return SimpleNamespace(
                returncode=0 if active else 3,
                stdout="active\n" if active else "inactive\n",
            )

        with mock.patch.object(webui.platform, "system", return_value="Linux"), \
             mock.patch.object(webui.subprocess, "run", side_effect=systemctl_result) as run:
            self.assertEqual({"running": True, "pid": None}, webui.get_watcher_status())

        commands = [call.args[0] for call in run.call_args_list]
        self.assertIn(["systemctl", "--user", "is-active", "easyskills-watcher.path"], commands)
        self.assertIn(["systemctl", "--user", "is-active", "easyskills-watcher.timer"], commands)
        self.assertNotIn("pgrep", str(commands))

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

    def test_skill_sync_skips_empty_optional_rule_library(self):
        sh_src = read("_maintenance/deploy.sh")
        ps_src = read("_maintenance/deploy.ps1")
        self.assertIn("find \"$CENTRAL_DIR/instructions\"", sh_src)
        self.assertIn("Agent rule sync failed; skill links were still synchronized", sh_src)
        self.assertIn("$RuleFiles.Count -gt 0", ps_src)
        self.assertIn("Agent rule sync failed; skill junctions were still synchronized", ps_src)

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

    def test_update_and_rollback_report_resync_failures(self):
        for src in (read("_maintenance/webui.py"), read("_maintenance/webui.ps1")):
            self.assertIn("sync_success", src)
            self.assertIn("agent re-sync failed", src)

    def test_successful_update_and_rollback_restart_backend_code(self):
        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")
        sh_service = read("_maintenance/webui-service.sh")
        ps_service = read("_maintenance/webui-service.ps1")
        self.assertIn("def _schedule_backend_restart", py_src)
        self.assertIn("_schedule_backend_restart(self.server)", py_src)
        self.assertIn("Backend restart scheduling failed", py_src)
        self.assertIn('result.get("_restart")', py_src)
        self.assertIn("$script:RestartRequested", ps_src)
        self.assertIn("Backend restart requested after update/rollback", ps_src)
        self.assertIn("Replacement backend launch failed; keeping current process alive", ps_src)
        self.assertIn("EASYSKILLS_SUPERVISED=1", sh_service)
        self.assertIn('EnvironmentVariables["EASYSKILLS_SUPERVISED"] = "1"', ps_service)

        webui = load_python_webui_module()
        stopped = __import__("threading").Event()
        fake_server = SimpleNamespace(shutdown=stopped.set)
        webui._backend_restart_scheduled.clear()
        with mock.patch.dict(webui.os.environ, {"EASYSKILLS_SUPERVISED": "1"}):
            webui._schedule_backend_restart(fake_server)
        self.assertTrue(stopped.wait(2), "supervised backend should schedule shutdown")

        webui._backend_restart_scheduled.clear()
        stopped.clear()
        with mock.patch.dict(webui.os.environ, {}, clear=True), \
             mock.patch.object(webui.subprocess, "Popen", side_effect=OSError("spawn failed")):
            with self.assertRaisesRegex(OSError, "spawn failed"):
                webui._schedule_backend_restart(fake_server)
        self.assertFalse(webui._backend_restart_scheduled.is_set())
        self.assertFalse(stopped.is_set(), "old backend must stay alive when replacement spawn fails")

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

    def test_python_self_update_bounds_download_and_validates_final_redirect(self):
        src = read("_maintenance/webui.py")
        self.assertIn("def _download_github_file", src)
        self.assertIn("timeout=60", src)
        self.assertIn("response.geturl()", src)
        self.assertIn("max_bytes", src)
        self.assertNotIn("urllib.request.urlretrieve(tarball_url", src)

        import io

        class FakeResponse(io.BytesIO):
            def __init__(self, content: bytes, final_url: str, headers=None):
                super().__init__(content)
                self._final_url = final_url
                self.headers = headers or {}

            def geturl(self):
                return self._final_url

            def __enter__(self):
                return self

            def __exit__(self, *args):
                self.close()

        webui = load_python_webui_module()
        trusted = "https://github.com/RunhuaHuang/EasySkills/archive/test.tar.gz"
        with tempfile.TemporaryDirectory() as td:
            destination = str(Path(td) / "release.tar.gz")
            response = FakeResponse(b"payload", "https://evil.example/release.tar.gz")
            with mock.patch.object(webui.urllib.request, "urlopen", return_value=response):
                with self.assertRaisesRegex(ValueError, "untrusted host"):
                    webui._download_github_file(trusted, destination)

            response = FakeResponse(b"12345", trusted)
            with mock.patch.object(webui.urllib.request, "urlopen", return_value=response):
                with self.assertRaisesRegex(ValueError, "safety limit"):
                    webui._download_github_file(trusted, destination, max_bytes=4)

    def test_self_update_rejects_archive_bombs_and_unsafe_zip_paths(self):
        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")
        self.assertIn("max_members", py_src)
        self.assertIn("max_total_size", py_src)
        self.assertIn("extracted-size safety limit", py_src)
        self.assertIn("ZipArchive.Entries.Count", ps_src)
        self.assertIn("$ExpandedBytes", ps_src)
        self.assertIn("unsafe path", ps_src)

        import tarfile

        member = tarfile.TarInfo("repo/large.bin")
        member.size = 5
        fake_tar = SimpleNamespace(getmembers=lambda: [member], extract=mock.Mock())
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaisesRegex(ValueError, "extracted-size safety limit"):
                webui._safe_extract_tar(fake_tar, td, max_total_size=4)
        fake_tar.extract.assert_not_called()

    def test_oversized_body_returns_413(self):
        """_body() must return None and do_POST must send 413 for oversized payloads."""
        py_src = read("_maintenance/webui.py")
        self.assertIn("return None  # Signal to caller: send 413", py_src)
        self.assertIn("self.send_response(413)", py_src)
        self.assertIn("body is None", py_src)
        self.assertIn("self.close_connection = True", py_src)
        oversized_branch = py_src.split("if length > 10 * 1024 * 1024", 1)[1].split(
            "if length < 0", 1
        )[0]
        self.assertNotIn("self.rfile.read", oversized_branch)

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

    def test_deploy_sh_missing_add_remove_arguments_fail_fast(self):
        import subprocess

        script = ROOT / "_maintenance/deploy.sh"
        for option in ("--add", "--remove"):
            result = subprocess.run(
                ["/bin/bash", str(script), option],
                capture_output=True,
                text=True,
                timeout=3,
            )
            self.assertNotEqual(0, result.returncode, option)
            self.assertIn("requires a target directory path", result.stderr)

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

    def test_external_central_skill_links_remain_owned_across_status_and_unmap(self):
        """Agent links to central external-link skills must remain removable."""
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            central = root / "central"
            external = root / "external"
            agent = root / "agent"
            central.mkdir()
            external.mkdir()
            agent.mkdir()
            (central / "linked-skill").symlink_to(external, target_is_directory=True)
            agent_link = agent / "linked-skill"
            agent_link.symlink_to(central / "linked-skill", target_is_directory=True)

            with mock.patch.object(webui, "CENTRAL_DIR", central), \
                 mock.patch.object(webui, "DISABLED_TARGETS_FILE", root / "disabled.txt"):
                self.assertTrue(webui._link_points_into_central(agent_link))
                self.assertTrue(webui.is_mapped(str(agent), set(), True))
                result = webui.do_unmap(str(agent))

            self.assertTrue(result["success"])
            self.assertFalse(agent_link.exists())
            self.assertFalse(agent_link.is_symlink())

    def test_mapping_preserves_foreign_symlink_conflicts(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            central = root / "central"
            foreign = root / "foreign"
            agent = root / "agent"
            central.mkdir()
            foreign.mkdir()
            agent.mkdir()
            (central / "same-name").mkdir()
            conflict = agent / "same-name"
            conflict.symlink_to(foreign, target_is_directory=True)

            with mock.patch.object(webui, "CENTRAL_DIR", central), \
                 mock.patch.object(webui, "DISABLED_TARGETS_FILE", root / "disabled.txt"):
                result = webui.do_map(str(agent))

            self.assertTrue(result["success"])
            self.assertEqual(["same-name"], result["conflicts"])
            self.assertEqual(foreign.resolve(), conflict.resolve())

    def test_python_mutation_helpers_reject_scalar_paths_and_names(self):
        webui = load_python_webui_module()
        self.assertFalse(webui.do_map(123)["success"])
        self.assertFalse(webui.do_unmap(["bad"])["success"])
        self.assertFalse(webui.delete_skill({"bad": "name"})["success"])

    def test_all_mapping_backends_preserve_foreign_links(self):
        sh_src = read("_maintenance/deploy.sh")
        deploy_ps = read("_maintenance/deploy.ps1")
        webui_ps = read("_maintenance/webui.ps1")
        self.assertIn("link_points_into_central", sh_src)
        self.assertIn("foreign symlink", sh_src)
        for src in (deploy_ps, webui_ps):
            self.assertIn("function Test-EasySkillsLinkTarget", src)
            self.assertIn("foreign link", src)
        self.assertIn('link_points_into_central "$link"', sh_src)
        self.assertIn("Where-Object { Test-EasySkillsLinkTarget $_ }", deploy_ps)

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

    def test_windows_delete_skill_never_recurses_through_central_link(self):
        ps_src = read("_maintenance/webui.ps1")
        delete_skill = ps_src.split("function Delete-Skill", 1)[1].split(
            "# --------------------------------------------------------------", 1
        )[0]
        self.assertIn('$TargetItem.Attributes -match "ReparsePoint"', delete_skill)
        self.assertIn("[System.IO.Directory]::Delete($TargetItem.FullName, $false)", delete_skill)
        reparse_branch = delete_skill.split('$TargetItem.Attributes -match "ReparsePoint"', 1)[1].split(
            "} else {", 1
        )[0]
        self.assertNotIn("Remove-Item", reparse_branch)

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
        self.assertIn("old_path = _normalize_local_path(old_skills_path)", py_src)
        self.assertIn("new_path = _normalize_local_path(skills_path)", py_src)
        self.assertIn("$OldPath = Normalize-AgentPath $OldSkillsPath", ps_src)
        self.assertIn("$NewPath = Normalize-AgentPath $SkillsPath", ps_src)
        self.assertIn("line_path_normalized = _normalize_local_path(line_path)", py_src)
        self.assertIn("$LinePathNormalized = Normalize-AgentPath $LinePath", ps_src)

    def test_custom_agent_path_update_replaces_normalized_old_entry_without_duplicates(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old_skills = root / "agent" / "skills"
            dotted_old = root / "agent" / ".." / "agent" / "skills"
            new_skills = root / "moved" / "skills"
            instructions = root / "agent" / "AGENTS.md"
            custom_targets = root / "custom-targets.txt"
            agent_paths = root / ".agent-paths.json"
            custom_targets.write_text(f"{dotted_old}\n", encoding="utf-8")

            current = {
                "name": "Custom Agent",
                "path": str(old_skills),
                "instructions_path": str(instructions),
                "mapped": False,
            }
            with mock.patch.object(webui, "CUSTOM_TARGETS_FILE", custom_targets), \
                 mock.patch.object(webui, "AGENT_PATH_CONFIG_FILE", agent_paths), \
                 mock.patch.object(webui, "get_visible_agents", return_value=[current]), \
                 mock.patch.object(webui, "_remove_from_disabled_targets"), \
                 mock.patch.object(webui, "_add_to_disabled_targets"):
                result = webui.update_agent_paths(
                    "Custom Agent",
                    str(old_skills),
                    str(new_skills),
                    str(instructions),
                )

            self.assertTrue(result["success"])
            active_lines = [
                line for line in custom_targets.read_text(encoding="utf-8").splitlines()
                if line.strip() and not line.lstrip().startswith("#")
            ]
            self.assertEqual(active_lines, [f"Custom Agent={new_skills.resolve()}"])

    def test_moving_a_mapped_agent_cleans_old_skill_links_after_new_map_succeeds(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old_skills = root / "old" / "skills"
            new_skills = root / "new" / "skills"
            alternate_skills = root / "alternate" / "skills"
            instructions = root / "AGENTS.md"
            custom_targets = root / "custom-targets.txt"
            agent_paths = root / ".agent-paths.json"
            custom_targets.write_text(
                f"Test Agent={old_skills}\nTest Agent={alternate_skills}\n",
                encoding="utf-8",
            )
            current = {
                "name": "Test Agent",
                "path": str(old_skills),
                "instructions_path": str(instructions),
                "mapped": True,
            }
            with mock.patch.object(webui, "CUSTOM_TARGETS_FILE", custom_targets), \
                 mock.patch.object(webui, "AGENT_PATH_CONFIG_FILE", agent_paths), \
                 mock.patch.object(webui, "get_visible_agents", return_value=[current]), \
                 mock.patch.object(webui, "do_map", return_value={"success": True}) as do_map, \
                 mock.patch.object(webui, "do_unmap", return_value={"success": True}) as do_unmap, \
                 mock.patch.object(webui, "_remove_from_disabled_targets"), \
                 mock.patch.object(webui, "_add_to_disabled_targets"):
                result = webui.update_agent_paths(
                    "Test Agent",
                    str(old_skills),
                    str(new_skills),
                    str(instructions),
                )

            self.assertTrue(result["success"])
            do_map.assert_called_once_with(str(new_skills.resolve()))
            do_unmap.assert_called_once_with(str(old_skills.resolve()))
            self.assertIn(
                f"Test Agent={alternate_skills}",
                custom_targets.read_text(encoding="utf-8"),
            )

        ps_src = read("_maintenance/webui.ps1")
        self.assertIn("$MapResult = Do-Map $NewPath", ps_src)
        self.assertIn("$CleanupResult = Do-Unmap $OldPath", ps_src)

    def test_editing_only_instruction_path_does_not_remap_skills(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            skills = root / "agent" / "skills"
            old_instructions = root / "agent" / "AGENTS.md"
            new_instructions = root / "agent" / "CUSTOM.md"
            custom_targets = root / "custom-targets.txt"
            agent_paths = root / ".agent-paths.json"
            current = {
                "name": "Test Agent",
                "path": str(skills),
                "instructions_path": str(old_instructions),
                "mapped": True,
            }
            with mock.patch.object(webui, "CUSTOM_TARGETS_FILE", custom_targets), \
                 mock.patch.object(webui, "AGENT_PATH_CONFIG_FILE", agent_paths), \
                 mock.patch.object(webui, "get_visible_agents", return_value=[current]), \
                 mock.patch.object(webui, "do_map") as do_map, \
                 mock.patch.object(webui, "do_unmap") as do_unmap, \
                 mock.patch.object(webui, "_remove_from_disabled_targets"), \
                 mock.patch.object(webui, "_add_to_disabled_targets"):
                result = webui.update_agent_paths(
                    "Test Agent",
                    str(skills),
                    str(skills),
                    str(new_instructions),
                )

            self.assertTrue(result["success"])
            do_map.assert_not_called()
            do_unmap.assert_not_called()

    def test_agent_config_overrides_both_skills_and_instruction_paths(self):
        webui = load_python_webui_module()
        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")
        self.assertIn("AGENT_PATH_CONFIG_FILE", py_src)
        self.assertIn("$AgentPathConfigFile", ps_src)
        self.assertIn("function Update-AgentPaths", ps_src)
        self.assertIn("instructions_path", py_src)
        self.assertIn("instructions_path", ps_src)
        self.assertIn("/.easyskills-agent-paths.json", read(".gitignore"))

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old_skills = root / "old-skills"
            new_skills = root / "new-skills"
            instructions = root / "config" / "AGENTS.md"
            custom_targets = root / "custom-targets.txt"
            agent_paths = root / ".agent-paths.json"

            with mock.patch.object(webui, "CUSTOM_TARGETS_FILE", custom_targets), \
                 mock.patch.object(webui, "AGENT_PATH_CONFIG_FILE", agent_paths), \
                 mock.patch.object(webui, "do_map", return_value={"success": True}), \
                 mock.patch.object(webui, "_remove_from_disabled_targets"), \
                 mock.patch.object(webui, "_add_to_disabled_targets"):
                result = webui.update_agent_paths(
                    "Test Agent",
                    str(old_skills),
                    str(new_skills),
                    str(instructions),
                )

            self.assertTrue(result["success"])
            self.assertIn(f"Test Agent={new_skills.resolve()}", custom_targets.read_text(encoding="utf-8"))
            saved = json.loads(agent_paths.read_text(encoding="utf-8"))
            self.assertEqual(saved["agents"][0]["skills_path"], str(new_skills.resolve()))
            self.assertEqual(saved["agents"][0]["instructions_path"], str(instructions.resolve()))

    def test_custom_agent_registration_requires_and_persists_both_paths(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config_file = root / ".agent-paths.json"
            skills = root / "custom-agent" / "skills"
            instructions = root / "custom-agent" / "AGENTS.md"
            with mock.patch.object(webui, "AGENT_PATH_CONFIG_FILE", config_file), \
                 mock.patch.object(webui, "run_deploy", return_value={"success": True, "message": "added"}):
                missing = webui.register_custom_agent(str(skills), "")
                result = webui.register_custom_agent(str(skills), str(instructions))

            self.assertFalse(missing["success"])
            self.assertTrue(result["success"])
            saved = json.loads(config_file.read_text(encoding="utf-8"))
            self.assertEqual(saved["agents"][0]["skills_path"], str(skills.resolve()))
            self.assertEqual(saved["agents"][0]["instructions_path"], str(instructions.resolve()))

        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")
        html_src = read("_maintenance/webui/index.html")
        self.assertIn("def register_custom_agent", py_src)
        self.assertIn("function Register-CustomAgent", ps_src)
        self.assertIn("skills_path: skillsPath", html_src)
        self.assertIn("instructions_path: instructionsPath", html_src)

    def test_custom_agent_registration_failure_does_not_remove_preexisting_target(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            skills = root / "custom-agent" / "skills"
            instructions = root / "custom-agent" / "AGENTS.md"
            deploy = mock.Mock(return_value={"success": True, "message": "already added"})
            with mock.patch.object(webui, "get_custom_targets", return_value=[str(skills)]), \
                 mock.patch.object(webui, "run_deploy", deploy), \
                 mock.patch.object(webui, "_save_agent_path_configs", side_effect=OSError("disk full")):
                result = webui.register_custom_agent(str(skills), str(instructions))

            self.assertFalse(result["success"])
            deploy.assert_called_once_with("--add", str(skills.resolve()))

        ps_src = read("_maintenance/webui.ps1")
        self.assertIn("$WasRegistered = $false", ps_src)
        self.assertIn("if (-not $WasRegistered)", ps_src)

    def test_instruction_targets_follow_agent_path_config(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            skills = root / "skills"
            rules_file = root / "custom" / "AGENTS.md"
            config_file = root / ".agent-paths.json"
            config_file.write_text(json.dumps({
                "version": 1,
                "agents": [{
                    "name": "Test Agent",
                    "skills_path": str(skills),
                    "instructions_path": str(rules_file),
                }],
            }), encoding="utf-8")

            with mock.patch.object(webui, "AGENT_PATH_CONFIG_FILE", config_file), \
                 mock.patch.object(webui, "DEFAULT_AGENTS", [("Test Agent", skills)]), \
                 mock.patch.object(webui, "DEFAULT_INSTRUCTION_PATHS", {"Test Agent": str(root / "default.md")}), \
                 mock.patch.object(webui, "CUSTOM_TARGETS_FILE", root / "missing-targets.txt"), \
                 mock.patch.object(webui, "DISABLED_TARGETS_FILE", root / "missing-disabled.txt"), \
                 mock.patch.object(webui, "get_skills", return_value=[]):
                agents = webui.get_visible_agents()
                targets = webui._load_instruction_targets()

            self.assertEqual(agents[0]["instructions_path"], str(rules_file.resolve()))
            self.assertEqual(targets, [("Test Agent", rules_file.resolve())])

    def test_instruction_status_does_not_report_a_directory_as_an_existing_file(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            target_directory = Path(tmp) / "AGENTS.md"
            target_directory.mkdir()
            with mock.patch.object(
                webui,
                "_load_instruction_targets",
                return_value=[("Broken Agent", target_directory)],
            ), mock.patch.object(
                webui,
                "_instruction_target_activity",
                return_value={str(target_directory.resolve()): True},
            ):
                data = webui.get_instructions()

            self.assertFalse(data["agents"][0]["exists"])

        ps_src = read("_maintenance/webui.ps1")
        self.assertIn("$Exists = (Test-Path $T.Path -PathType Leaf)", ps_src)

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
    # Instructions / Rules management (AGENTS.md modular rule library)
    # -------------------------------------------------------------------------

    def test_agents_json_has_instructions_fields(self):
        """Every agent in agents.json must have mac/win instructions file paths.

        The instructions feature reads these fields as its single source of
        truth for where to write each agent's global instruction file.
        """
        import json
        data = json.loads(read("_maintenance/agents.json"))
        agents = data.get("agents", [])
        self.assertGreater(len(agents), 30, "agents.json should have 30+ agents")
        for a in agents:
            with self.subTest(agent=a.get("name")):
                self.assertIn("mac_instructions_file", a,
                              f"{a.get('name')}: missing mac_instructions_file")
                self.assertIn("win_instructions_file", a,
                              f"{a.get('name')}: missing win_instructions_file")
                self.assertTrue(a["mac_instructions_file"].strip())
                self.assertTrue(a["win_instructions_file"].strip())

    def test_instructions_apis_exist_in_both_backends(self):
        """Both WebUI backends must expose the same set of instructions API
        endpoints (GET + POST), keeping the cross-platform implementations
        symmetric — just like the existing skills/agents endpoints.
        """
        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")

        # GET endpoints
        for endpoint in ('/api/instructions"', '/api/instructions/content/'):
            self.assertIn(endpoint, py_src, f"webui.py missing GET {endpoint}")
            self.assertIn(endpoint, ps_src, f"webui.ps1 missing GET {endpoint}")

        # POST endpoints (must be present in both)
        post_endpoints = [
            "/api/instructions/save",
            "/api/instructions/delete",
            "/api/instructions/write-all",
            "/api/instructions/remove-all",
            "/api/instructions/write-one",
            "/api/instructions/remove-one",
            "/api/instructions/write-selected",
            "/api/instructions/remove-selected",
        ]
        for ep in post_endpoints:
            self.assertIn(ep, py_src, f"webui.py missing POST {ep}")
            self.assertIn(ep, ps_src, f"webui.ps1 missing POST {ep}")

    def test_instructions_use_managed_block_markers(self):
        """Write/remove must use clearly-marked managed blocks so removing the
        injected rules never destroys the user's own content.

        The begin/end markers must be identical across both backends.
        """
        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")
        # Python constants
        self.assertIn("EASY_SKILLS_BEGIN", py_src)
        self.assertIn("EASY_SKILLS_END", py_src)
        self.assertIn("EasySkills:begin", py_src)
        self.assertIn("EasySkills:end", py_src)
        # PowerShell constants
        self.assertIn("$EasySkillsBegin", ps_src)
        self.assertIn("$EasySkillsEnd", ps_src)
        self.assertIn("EasySkills:begin", ps_src)
        self.assertIn("EasySkills:end", ps_src)

    def test_managed_rules_use_only_outer_markers_and_read_older_formats(self):
        """Agent files contain only outer markers; rule identity lives in the
        hidden state file while both older labelled formats remain readable.
        """
        webui = load_python_webui_module()
        rules = {"rule-a.md": "123", "规则 b.md": "321"}

        marker_free = webui._build_managed_block(rules)
        self.assertEqual(marker_free.count("<!-- EasySkills:"), 2)
        self.assertNotIn("EasySkills:rule", marker_free)

        verbose = (
            f"{webui.EASY_SKILLS_BEGIN}\n"
            "<!-- EasySkills:rule:begin rule-a.md -->\n123\n"
            "<!-- EasySkills:rule:end -->\n\n"
            "<!-- EasySkills:rule:begin %E8%A7%84%E5%88%99%20b.md -->\n321\n"
            "<!-- EasySkills:rule:end -->\n"
            f"{webui.EASY_SKILLS_END}"
        )
        self.assertEqual(webui._managed_rules(verbose), (rules, ""))
        migrated = webui._build_managed_block(*webui._managed_rules(verbose))
        self.assertEqual(migrated.count("<!-- EasySkills:"), 2)

        previous_compact = (
            f"{webui.EASY_SKILLS_BEGIN}\n"
            "<!-- EasySkills:rule rule-a.md -->\n123\n\n"
            "<!-- EasySkills:rule %E8%A7%84%E5%88%99%20b.md -->\n321\n"
            f"{webui.EASY_SKILLS_END}"
        )
        self.assertEqual(webui._managed_rules(previous_compact), (rules, ""))

        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "AGENTS.md"
            state_file = Path(tmp) / ".state.json"
            with mock.patch.object(webui, "INSTRUCTION_SYNC_STATE_FILE", state_file):
                webui._set_instruction_state(target, rules)
                self.assertEqual(webui._managed_rules(marker_free, target), (rules, ""))

    def test_marker_free_managed_rules_preserve_unresolved_legacy_content_in_state(self):
        webui = load_python_webui_module()
        rules = {"rule-a.md": "123"}
        block = webui._build_managed_block(rules, "unresolved text")
        self.assertEqual(block.count("<!-- EasySkills:"), 2)
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "AGENTS.md"
            with mock.patch.object(webui, "INSTRUCTION_SYNC_STATE_FILE", Path(tmp) / ".state.json"):
                webui._set_instruction_state(target, rules, "unresolved text")
                self.assertEqual(
                    webui._managed_rules(block, target),
                    (rules, "unresolved text"),
                )

    def test_labelled_managed_block_migrates_to_two_outer_markers_on_write(self):
        webui = load_python_webui_module()
        old_block = (
            f"{webui.EASY_SKILLS_BEGIN}\n"
            "<!-- EasySkills:rule:begin old.md -->\nold content\n"
            "<!-- EasySkills:rule:end -->\n"
            f"{webui.EASY_SKILLS_END}\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "AGENTS.md"
            target.write_text(old_block, encoding="utf-8")
            with mock.patch.object(webui, "INSTRUCTION_SYNC_STATE_FILE", Path(tmp) / ".state.json"):
                self.assertTrue(webui._write_to_one(target, {"new.md": "new content"}))
                migrated = target.read_text(encoding="utf-8")
                self.assertEqual(migrated.count("<!-- EasySkills:"), 2)
                self.assertNotIn("EasySkills:rule", migrated)
                self.assertEqual(
                    webui._managed_rules(migrated, target)[0],
                    {"old.md": "old content", "new.md": "new content"},
                )

    def test_marker_free_state_hash_prevents_using_stale_rule_metadata(self):
        webui = load_python_webui_module()
        rules = {"rule.md": "managed"}
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "AGENTS.md"
            state_file = Path(tmp) / ".state.json"
            with mock.patch.object(webui, "INSTRUCTION_SYNC_STATE_FILE", state_file):
                webui._set_instruction_state(target, rules)
                edited = webui._build_managed_block(rules).replace("managed", "manually edited")
                parsed_rules, legacy = webui._managed_rules(edited, target)
                self.assertEqual(parsed_rules, {})
                self.assertIn("manually edited", legacy)
                target.write_text(edited, encoding="utf-8")
                self.assertFalse(webui._write_to_one(target, {"other.md": "other"}))
                self.assertEqual(target.read_text(encoding="utf-8"), edited)

    def test_instruction_single_target_apis_reject_unknown_paths(self):
        webui = load_python_webui_module()
        with mock.patch.object(webui, "_load_instruction_targets", return_value=[]):
            self.assertFalse(webui.write_instructions_to_one("/tmp/not-an-agent.md")["success"])
            self.assertFalse(webui.remove_instructions_from_one("/tmp/not-an-agent.md")["success"])

        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")
        self.assertIn("def _known_instruction_target", py_src)
        self.assertIn("function Resolve-KnownInstructionTarget", ps_src)

    def test_instruction_selection_rejects_scalar_payloads(self):
        webui = load_python_webui_module()
        result = webui.write_selected_instructions("rule-a.md", "/tmp/AGENTS.md")
        self.assertFalse(result["success"])
        result = webui.remove_selected_instructions("rule-a.md", "/tmp/AGENTS.md")
        self.assertFalse(result["success"])

    def test_instruction_selection_rejects_invalid_agent_paths_without_crashing(self):
        webui = load_python_webui_module()
        with mock.patch.object(webui, "_rule_library", return_value=({"rule-a.md": "content"}, None)), \
             mock.patch.object(webui, "_load_instruction_targets", return_value=[("Agent", Path("/tmp/AGENTS.md"))]):
            write_result = webui.write_selected_instructions(
                ["rule-a.md"],
                ["invalid\x00path"],
            )
            remove_result = webui.remove_selected_instructions(
                ["rule-a.md"],
                ["invalid\x00path"],
            )
        self.assertFalse(write_result["success"])
        self.assertFalse(remove_result["success"])

    def test_selected_rule_sync_changes_only_selected_rules_and_agents(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rules_dir = root / "instructions"
            rules_dir.mkdir()
            (rules_dir / "rule-a.md").write_text("AAA", encoding="utf-8")
            (rules_dir / "rule-b.md").write_text("BBB", encoding="utf-8")
            (rules_dir / "rule-c.md").write_text("CCC", encoding="utf-8")
            first = root / "first" / "AGENTS.md"
            second = root / "second" / "AGENTS.md"
            state_file = root / ".instruction-state.json"
            targets = [("First", first), ("Second", second)]

            with mock.patch.object(webui, "INSTRUCTIONS_DIR", rules_dir), \
                 mock.patch.object(webui, "INSTRUCTION_SYNC_STATE_FILE", state_file), \
                 mock.patch.object(webui, "_load_instruction_targets", return_value=targets):
                write_result = webui.write_selected_instructions(
                    ["rule-a.md", "rule-c.md"],
                    [str(first)],
                )
                self.assertTrue(write_result["success"])
                self.assertTrue(first.exists())
                self.assertFalse(second.exists())
                first_text = first.read_text(encoding="utf-8")
                self.assertIn("AAA", first_text)
                self.assertIn("CCC", first_text)
                self.assertNotIn("BBB", first_text)

                remove_result = webui.remove_selected_instructions(
                    ["rule-a.md"],
                    [str(first)],
                )
                self.assertTrue(remove_result["success"])
                first_text = first.read_text(encoding="utf-8")
                self.assertNotIn("AAA", first_text)
                self.assertIn("CCC", first_text)

    def test_unreadable_rule_content_is_reported_without_breaking_the_rules_page(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            rules_dir = Path(tmp) / "instructions"
            rules_dir.mkdir()
            broken = rules_dir / "broken.md"
            broken.write_bytes(b"\xff\xfe\x00")
            with mock.patch.object(webui, "INSTRUCTIONS_DIR", rules_dir), \
                 mock.patch.object(webui, "_load_instruction_targets", return_value=[]), \
                 mock.patch.object(webui, "_instruction_target_activity", return_value={}):
                listing = webui.get_instructions()
                content = webui.get_instruction_content("broken.md")
                rules, error = webui._rule_library(["broken.md"])

            self.assertTrue(listing["success"])
            self.assertTrue(listing["rules"][0]["read_error"])
            self.assertFalse(content["success"])
            self.assertEqual(rules, {})
            self.assertIn("Could not read rule", error)

        html_src = read("_maintenance/webui/index.html")
        ps_src = read("_maintenance/webui.ps1")
        self.assertIn("r.read_error", html_src)
        self.assertIn("data.success === false", html_src)
        self.assertIn("Could not read rule", ps_src)

    def test_atomic_instruction_write_keeps_old_file_when_replace_fails(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "AGENTS.md"
            target.write_text("handwritten", encoding="utf-8")
            with mock.patch.object(webui.os, "replace", side_effect=OSError("simulated")):
                with self.assertRaises(OSError):
                    webui._atomic_write_text(target, "replacement")
            self.assertEqual(target.read_text(encoding="utf-8"), "handwritten")
            self.assertEqual(list(target.parent.glob(".AGENTS.md.*.tmp")), [])

        self.assertIn("function Write-Utf8Atomic", read("_maintenance/webui.ps1"))

    def test_disabled_target_updates_are_atomic(self):
        src = read("_maintenance/webui.py")
        add_block = src.split("def _add_to_disabled_targets", 1)[1].split(
            "def _remove_from_disabled_targets", 1
        )[0]
        remove_block = src.split("def _remove_from_disabled_targets", 1)[1].split(
            "def _get_disabled_targets", 1
        )[0]
        self.assertIn("_atomic_write_text", add_block)
        self.assertIn("_atomic_write_text", remove_block)
        self.assertNotIn("DISABLED_TARGETS_FILE.write_text", add_block + remove_block)

    def test_removing_appended_managed_block_does_not_leave_extra_blank_line(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "AGENTS.md"
            target.write_text("handwritten\n", encoding="utf-8")
            with mock.patch.object(webui, "INSTRUCTION_SYNC_STATE_FILE", Path(tmp) / ".state.json"):
                self.assertTrue(webui._write_to_one(target, {"rule.md": "managed"}))
                self.assertTrue(webui._remove_from_one(target))
                self.assertEqual(target.read_text(encoding="utf-8"), "handwritten\n")

    def test_instructions_name_validation_blocks_traversal(self):
        """Rule filenames must be validated to prevent path traversal (e.g.
        ../../etc/passwd.md). Both backends must reject '/', '\\', and null.
        """
        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")
        # Python validator
        self.assertIn("def _validate_instruction_name", py_src)
        self.assertIn('"/" in name', py_src)
        self.assertIn('"\\\\" in name', py_src)
        # PowerShell validator
        self.assertIn("function Test-InstructionName", ps_src)
        self.assertIn("Contains(", ps_src)

    def test_instructions_tab_and_js_exist_in_frontend(self):
        """The frontend must have the instructions nav tab, section, and JS
        rendering function."""
        html_src = read("_maintenance/webui/index.html")
        self.assertIn('data-target="instructions"', html_src)
        self.assertIn('id="instructions"', html_src)
        self.assertIn('function renderInstructions', html_src)
        self.assertIn("function writeInstructions", html_src)
        self.assertIn("function removeInstructions", html_src)
        self.assertIn("function openRuleEditor", html_src)
        # i18n keys in both languages
        self.assertIn("'t-instructions'", html_src)

    def test_dashboard_exposes_rule_library_and_agent_coverage(self):
        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")
        html_src = read("_maintenance/webui/index.html")
        for field in (
            "rules_count",
            "agents_detected",
            "agent_instruction_paths_configured",
            "instruction_targets_total",
            "instruction_target_files_existing",
            "instruction_agents_detected",
            "instruction_agents_managed",
            "managed_rule_instances",
        ):
            self.assertIn(field, py_src)
            self.assertIn(field, ps_src)
            self.assertIn(field, html_src)
        self.assertIn('id="stat-rules"', html_src)
        self.assertIn('id="dashboard-rule-progress-fill"', html_src)
        self.assertIn("navigateToSection('instructions')", html_src)

    # -------------------------------------------------------------------------
    # Self-update / rollback: host allowlist + rename-recovery (Fix C/D/E)
    # -------------------------------------------------------------------------

    def test_webui_ps1_self_update_validates_download_host(self):
        """webui.ps1 Run-SelfUpdate must reject download URLs whose host is not
        a trusted GitHub delivery host, mirroring webui.py's
        _is_github_download_url / _GITHUB_TARBALL_HOSTS."""
        ps_src = read("_maintenance/webui.ps1")
        self.assertIn("$TrustedDownloadHosts", ps_src)
        self.assertIn("objects.githubusercontent.com", ps_src)
        self.assertIn("Update rejected: download host is not a trusted GitHub host", ps_src)
        self.assertIn("Get-WebResponseFinalUrl", ps_src)
        self.assertIn("download redirected to an untrusted host", ps_src)
        self.assertGreaterEqual(ps_src.count("-PassThru"), 2)

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
            self.assertEqual(0o600, token_file.stat().st_mode & 0o777)

    def test_token_loader_uses_cross_process_lock_and_atomic_replace(self):
        src = read("_maintenance/webui.py")
        self.assertIn("fcntl.flock", src)
        self.assertIn("TOKEN_FILE.name + \".lock\"", src)
        self.assertIn("os.replace(temp_path, TOKEN_FILE)", src)


if __name__ == "__main__":
    unittest.main()
