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
        self.assertIn("Could not automatically open browser", src)

    def test_windows_webui_isolates_request_errors_from_listener_lifetime(self):
        src = read("_maintenance/webui.ps1")
        self.assertIn("function Invoke-WebUIRequest", src)
        self.assertIn("function Close-ResponseQuietly", src)
        self.assertIn("WebUI request error", src)
        self.assertIn("WebUI listener accept error", src)

        loop = re.search(
            r"while \(\$Listener\.IsListening\) \{(?P<body>.*?)\n    \}",
            src,
            re.DOTALL,
        )
        self.assertIsNotNone(loop)
        body = loop.group("body")
        self.assertIn("$Listener.GetContext()", body)
        self.assertIn("Invoke-WebUIRequest $Context", body)
        self.assertIn("continue", body)

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
        self.assertIn("Version-1.1.0", read("README.md"))
        self.assertIn("版本-1.1.0", read("README_CN.md"))
        self.assertIn("25 agents are pre-configured", read("README.md"))
        self.assertIn("开箱即用支持 25 个 Agent", read("README_CN.md"))

    def test_windows_launchers_do_not_use_wmi_for_background_start(self):
        for rel in ("install.ps1", "_maintenance/watch.ps1"):
            src = read(rel)
            self.assertNotIn("Invoke-CimMethod -ClassName Win32_Process", src, rel)
            self.assertIn("WScript.Shell", src, rel)
            self.assertIn(".Run(", src, rel)
            self.assertIn("$false", src, rel)

    def test_windows_launchers_detach_from_calling_console(self):
        for rel in ("install.ps1", "_maintenance/watch.ps1"):
            src = read(rel)
            self.assertIn("Start-HiddenPowerShell", src, rel)
            self.assertIn("-WindowStyle Hidden", src, rel)

        self.assertNotIn("start \"\" /B powershell", read("install_windows.bat"))
        self.assertNotIn("start \"\" powershell", read("install_windows.bat"))
        self.assertIn("WScript.Shell", read("install_windows.bat"))
        self.assertNotIn('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\\webui.ps1"', read("_maintenance/Windows/Start — 启动.bat"))
        self.assertNotIn("start \"\" powershell", read("_maintenance/Windows/Start — 启动.bat"))
        self.assertIn("WScript.Shell", read("_maintenance/Windows/Start — 启动.bat"))
        self.assertIn("Start-HiddenPowerShell", read("_maintenance/deploy.ps1"))

    def test_windows_installer_registers_watcher_and_webui_startup_shortcuts(self):
        install = read("install.ps1")
        self.assertIn("EasySkillsWatcher.lnk", install)
        self.assertIn("EasySkillsWebUI.lnk", install)
        self.assertIn("watcher-service.ps1", install)
        self.assertIn("webui-service.ps1", install)

        watch = read("_maintenance/watch.ps1")
        self.assertIn("EasySkillsWatcher.lnk", watch)
        self.assertIn("EasySkillsWebUI.lnk", watch)
        self.assertIn("watcher-service.ps1", watch)
        self.assertIn("webui-service.ps1", watch)

        unwatch = read("_maintenance/unwatch.ps1")
        self.assertIn("EasySkillsWatcher.lnk", unwatch)
        self.assertIn("EasySkillsWebUI.lnk", unwatch)
        self.assertIn("webui.ps1", unwatch)
        self.assertIn("webui-service.ps1", unwatch)

    def test_windows_webui_uses_supervisor_service(self):
        service = read("_maintenance/webui-service.ps1")
        self.assertIn("Test-WebUIPort", service)
        self.assertIn("while ($true)", service)
        self.assertIn("webui.ps1", service)
        self.assertIn("-NoBrowser", service)

        for rel in ("install.ps1", "_maintenance/watch.ps1", "_maintenance/deploy.ps1", "install_windows.bat", "_maintenance/Windows/Start — 启动.bat"):
            self.assertIn("webui-service.ps1", read(rel), rel)

        webui = read("_maintenance/webui.ps1")
        self.assertIn("[switch]$NoBrowser", webui)
        self.assertIn("if (-not $NoBrowser)", webui)

    def test_webui_stop_watcher_keeps_backend_running(self):
        py_src = read("_maintenance/webui.py")
        ps_src = read("_maintenance/webui.ps1")
        deploy_ps = read("_maintenance/deploy.ps1")
        unwatch_ps = read("_maintenance/unwatch.ps1")

        self.assertIn('"/api/watcher/stop":         lambda: run_deploy("--unwatch")', py_src)
        self.assertIn('Run-DeployCommand @("-Unwatch", "-KeepWebUI")', ps_src)
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
