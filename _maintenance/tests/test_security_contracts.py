#!/usr/bin/env python3
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


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

    def test_readme_version_and_agent_count_match_release(self):
        self.assertIn("Version-1.2.0", read("README.md"))
        self.assertIn("版本-1.2.0", read("README_CN.md"))
        self.assertIn("25 agents are pre-configured", read("README.md"))
        self.assertIn("开箱即用支持 25 个 Agent", read("README_CN.md"))
        self.assertEqual("1.2.0", read("_maintenance/.version").strip())

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

    def test_macos_webui_launches_detached(self):
        self.assertIn("nohup python3", read("install_mac.command"))
        self.assertIn("nohup python3 \"$SCRIPT_DIR/webui.py\"", read("_maintenance/deploy.sh"))
        self.assertIn("nohup python3 webui.py", read("_maintenance/macOS/Start — 启动.command"))


if __name__ == "__main__":
    unittest.main()
