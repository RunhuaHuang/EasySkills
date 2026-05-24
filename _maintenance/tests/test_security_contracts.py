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
        self.assertIn("webui.ps1", install)

        watch = read("_maintenance/watch.ps1")
        self.assertIn("EasySkillsWatcher.lnk", watch)
        self.assertIn("EasySkillsWebUI.lnk", watch)
        self.assertIn("watcher-service.ps1", watch)
        self.assertIn("webui.ps1", watch)

        unwatch = read("_maintenance/unwatch.ps1")
        self.assertIn("EasySkillsWatcher.lnk", unwatch)
        self.assertIn("EasySkillsWebUI.lnk", unwatch)
        self.assertIn("webui.ps1", unwatch)

    def test_macos_webui_launches_detached(self):
        self.assertIn("nohup python3", read("install_mac.command"))
        self.assertIn("nohup python3 \"$SCRIPT_DIR/webui.py\"", read("_maintenance/deploy.sh"))
        self.assertIn("nohup python3 webui.py", read("_maintenance/macOS/Start — 启动.command"))


if __name__ == "__main__":
    unittest.main()
