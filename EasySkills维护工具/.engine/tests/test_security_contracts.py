#!/usr/bin/env python3
import base64
import io
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


# Test file lives at EasySkills维护工具/.engine/tests/, so parents[0]=tests,
# parents[1]=.engine, parents[2]=EasySkills维护工具, parents[3]=repo root.
ROOT = Path(__file__).resolve().parents[3]


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def load_python_webui_module():
    if os.name == "nt":
        raise unittest.SkipTest("The Python WebUI backend is Unix-only; Windows uses webui.ps1.")
    import importlib.util

    spec = importlib.util.spec_from_file_location("easyskills_webui_test", ROOT / "EasySkills维护工具/.engine/webui.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    # Import in doctor mode so the test suite remains read-only: normal module
    # initialization creates a persistent browser token and a Qoder directory.
    with mock.patch.object(sys, "argv", [str(ROOT / "EasySkills维护工具/.engine/webui.py"), "--doctor"]):
        spec.loader.exec_module(module)
    return module


class SecurityContractsTest(unittest.TestCase):
    def test_python_webui_binds_loopback_and_requires_token_for_posts(self):
        src = read("EasySkills维护工具/.engine/webui.py")
        self.assertIn('ThreadedServer(("127.0.0.1", PORT), Handler)', src)
        self.assertIn("WEBUI_TOKEN", src)
        self.assertIn("X-EasySkills-Token", src)
        self.assertIn("def _is_post_allowed", src)
        self.assertIn("self._reject_forbidden()", src)

    def test_api_gets_require_token_and_frontend_sends_it(self):
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        html_src = read("EasySkills维护工具/.engine/webui/index.html")

        for endpoint in ("/api/status", "/api/doctor", "/api/skills", "/api/agents", "/api/latest-release"):
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
        src = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn("$WebUIToken", src)
        self.assertIn("X-EasySkills-Token", src)
        self.assertIn("Test-PostAllowed", src)
        self.assertIn("Send-ForbiddenResponse", src)
        # Browser auto-open failure must not crash the listener
        self.assertIn("Browser open failed", src)

    def test_windows_webui_isolates_request_errors_from_listener_lifetime(self):
        src = read("EasySkills维护工具/.engine/webui.ps1")
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

    def test_windows_webui_bounds_posts_and_protects_tokenized_index(self):
        src = read("EasySkills维护工具/.engine/webui.ps1")
        index_fn = src.split("function Send-IndexResponse", 1)[1].split("\n}", 1)[0]
        self.assertIn('X-Content-Type-Options", "nosniff', index_fn)
        self.assertIn('X-Frame-Options", "DENY', index_fn)
        self.assertIn('Content-Security-Policy', index_fn)
        self.assertIn("script-src 'nonce-$Nonce'", index_fn)
        self.assertIn("script-src-attr 'none'", index_fn)
        self.assertIn("SecurityElement]::Escape", index_fn)
        self.assertIn('Referrer-Policy", "no-referrer', index_fn)
        self.assertIn('Cross-Origin-Resource-Policy", "same-origin', index_fn)
        self.assertIn('$RawContentLength = $Request.Headers["Content-Length"]', src)
        self.assertIn("Request body ended before Content-Length", src)
        self.assertIn("$Offset += $Read", src)
        self.assertIn("Content-Length is required", src)
        self.assertIn("$Context.Response.KeepAlive = $false", src)
        self.assertIn("Invalid JSON request body", src)

    def test_webui_hides_proma_workspace_targets_from_agent_list(self):
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        html_src = read("EasySkills维护工具/.engine/webui/index.html")

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
        self.assertIn('cp "$CURRENT_DIR/EasySkills维护工具/README_SYSTEM.md" "$PERM_DIR/EasySkills维护工具/README_SYSTEM.md"', read("install_mac.command"))
        self.assertIn('copy /Y "%CURRENT_DIR%EasySkills维护工具\\README_SYSTEM.md" "%PERM_DIR%\\EasySkills维护工具\\README_SYSTEM.md" > nul', read("install_windows.bat"))

    def test_cleanup_only_matches_current_central_dir(self):
        for rel in ("EasySkills维护工具/.engine/deploy.sh", "EasySkills维护工具/.engine/deploy.ps1", "EasySkills维护工具/.engine/webui.py", "EasySkills维护工具/.engine/webui.ps1"):
            src = read(rel)
            self.assertNotIn("MyEasySkillsBackup", src)
            self.assertIsNone(re.search(r"EasySkills[\"'` ]?[*]", src), rel)
        self.assertIn("link_points_into_central", read("EasySkills维护工具/.engine/deploy.sh"))
        self.assertIn("Test-EasySkillsLinkTarget", read("EasySkills维护工具/.engine/deploy.ps1"))

    def test_cleanup_failures_propagate_to_uninstallers(self):
        sh_src = read("EasySkills维护工具/.engine/deploy.sh")
        ps_src = read("EasySkills维护工具/.engine/deploy.ps1")
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
        src = read("EasySkills维护工具/.engine/watch.sh")
        self.assertIn("plistlib", src)
        self.assertNotIn('echo "        <string>$arg</string>"', src)

    def test_dynamic_agent_buttons_do_not_use_inline_handlers(self):
        src = read("EasySkills维护工具/.engine/webui/index.html")
        self.assertNotIn("function escapeJsString", src)
        self.assertNotRegex(src, r"\son[a-z]+=")
        self.assertIn("data-es-action", src)
        self.assertIn("document.addEventListener('click'", src)
        self.assertIn("addEventListener('click'", src)

    def test_tokenized_index_is_local_only_and_uses_nonce_csp(self):
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        html_src = read("EasySkills维护工具/.engine/webui/index.html")
        self.assertNotIn("fonts.googleapis.com", html_src)
        self.assertNotIn("fonts.gstatic.com", html_src)
        self.assertNotIn("cdnjs.cloudflare.com", html_src)
        self.assertIn('<script nonce="__EASYSKILLS_NONCE__">', html_src)
        self.assertIn("es-icon-sprite", html_src)
        self.assertIn("renderEasySkillsIcons", html_src)
        self.assertIn("html_lib.escape(token, quote=True)", py_src)
        self.assertIn("script-src 'nonce-{nonce}'", py_src)
        self.assertIn("script-src-attr 'none'", py_src)
        self.assertIn("frame-ancestors 'none'", py_src)
        self.assertIn("frame-ancestors 'none'", ps_src)
        self.assertIn('rel="noopener noreferrer"', html_src)
        self.assertIn('self.send_header("Referrer-Policy", "no-referrer")', py_src)
        self.assertIn('self.send_header("Cross-Origin-Resource-Policy", "same-origin")', py_src)

        webui = load_python_webui_module()
        malicious_token = '\"><script nonce="__EASYSKILLS_NONCE__">bad()</script>'
        rendered, nonce = webui._render_index_template(
            '<meta content="__EASYSKILLS_TOKEN__"><script nonce="__EASYSKILLS_NONCE__"></script>',
            malicious_token,
            nonce="fixed-nonce",
        )
        self.assertEqual(nonce, "fixed-nonce")
        self.assertEqual(rendered.count('nonce="fixed-nonce"'), 1)
        self.assertNotIn('<script nonce="fixed-nonce">bad()', rendered)
        self.assertIn("&lt;script nonce=&quot;__EASYSKILLS_NONCE__&quot;&gt;", rendered)

    def test_skills_tab_supports_folder_import_and_confirmed_delete(self):
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        html_src = read("EasySkills维护工具/.engine/webui/index.html")

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

    def test_skill_and_rule_names_are_portable_across_windows_and_unix(self):
        webui = load_python_webui_module()
        for invalid in ("CON", "nul.md", "COM1.skill", "bad:name", "bad*name", "trailing.", "trailing ", "line\nfeed"):
            with self.subTest(kind="skill", name=invalid):
                self.assertFalse(webui._validate_skill_name(invalid)[0])
            with self.subTest(kind="rule", name=invalid):
                self.assertFalse(webui._validate_instruction_name(invalid)[0])
        self.assertTrue(webui._validate_skill_name("portable-skill")[0])
        self.assertEqual(webui._validate_instruction_name("portable-rule"), (True, "portable-rule.md"))

        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn("$WindowsReservedFileNames", ps_src)
        self.assertGreaterEqual(ps_src.count("$WindowsReservedFileNames -contains $BaseName"), 2)
        self.assertGreaterEqual(ps_src.count("$Clean.EndsWith(\".\")"), 2)
        self.assertGreaterEqual(ps_src.count("$Clean.EndsWith(\" \")"), 2)

    def test_mcp_gateway_module_management_is_cross_platform_and_token_protected(self):
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        html_src = read("EasySkills维护工具/.engine/webui/index.html")

        for endpoint in ("/api/mcp", "/api/mcp/server/add", "/api/mcp/server/update", "/api/mcp/server/delete", "/api/mcp/test"):
            with self.subTest(endpoint=endpoint):
                self.assertIn(endpoint, py_src)
                self.assertIn(endpoint, ps_src)
                self.assertIn(endpoint, html_src)

        self.assertIn('data-target="mcp"', html_src)
        self.assertIn('id="mcp-server-list"', html_src)
        self.assertIn('id="mcp-server-form"', html_src)
        self.assertIn('id="mcp-form-json"', html_src)
        self.assertIn("function openMCPServerEditor", html_src)
        self.assertIn("function saveMCPServerForm", html_src)
        self.assertIn("function toggleMCPServer", html_src)
        self.assertNotIn('id="mcp-config-editor"', html_src)
        self.assertNotIn('id="mcp-add-json"', html_src)
        self.assertNotIn("JSON.parse(editor.value)", html_src)
        self.assertIn('serverName := set.String("server"', read("gateway/cmd/easyskills-mcp/main.go"))
        self.assertIn("MCP_CONFIG_FILE.chmod(0o600)", py_src)
        self.assertIn("Write-Utf8Atomic $MCPConfigFile", ps_src)

    def test_python_mcp_config_round_trip_and_plaintext_credentials(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            mcp_dir = root / "mcp"
            config_file = mcp_dir / "servers.json"
            backup_file = mcp_dir / "servers.json.bak"
            config = {
                "version": 1,
                "servers": {
                    "private-api": {
                        "enabled": True,
                        "transport": "http",
                        "url": "https://example.com/mcp",
                        "headers": {"Authorization": "Bearer plaintext-secret"},
                    }
                },
                "profiles": {"default": {"servers": ["*"]}},
            }
            with mock.patch.object(webui, "MCP_DIR", mcp_dir), \
                 mock.patch.object(webui, "MCP_CONFIG_FILE", config_file), \
                 mock.patch.object(webui, "MCP_CONFIG_BACKUP_FILE", backup_file):
                result = webui.save_mcp_config(config)
                self.assertTrue(result["success"], result)
                saved = json.loads(config_file.read_text(encoding="utf-8"))
                self.assertEqual(saved["servers"]["private-api"]["headers"]["Authorization"], "Bearer plaintext-secret")
                if os.name != "nt":
                    self.assertEqual(config_file.stat().st_mode & 0o777, 0o600)

                invalid = webui.add_mcp_server("bad name", {"transport": "stdio", "command": "x"})
                self.assertFalse(invalid["success"])

                updated_server = dict(saved["servers"]["private-api"])
                updated_server["enabled"] = False
                updated = webui.update_mcp_server("private-api", updated_server)
                self.assertTrue(updated["success"], updated)
                self.assertFalse(json.loads(config_file.read_text(encoding="utf-8"))["servers"]["private-api"]["enabled"])

                removed = webui.delete_mcp_server("private-api")
                self.assertTrue(removed["success"], removed)
                self.assertNotIn("private-api", json.loads(config_file.read_text(encoding="utf-8"))["servers"])

    def test_mcp_backup_replaces_a_symlink_without_following_it(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            mcp_dir = root / "mcp"
            config_file = mcp_dir / "servers.json"
            backup_file = mcp_dir / "servers.json.bak"
            outside = root / "outside.txt"
            outside.write_text("must remain unchanged", encoding="utf-8")
            config_file.parent.mkdir()
            config_file.write_text('{"version":1,"servers":{}}\n', encoding="utf-8")
            backup_file.symlink_to(outside)
            config = {"version": 1, "servers": {"local": {"transport": "stdio", "command": "x"}}}
            with mock.patch.object(webui, "MCP_DIR", mcp_dir), \
                 mock.patch.object(webui, "MCP_CONFIG_FILE", config_file), \
                 mock.patch.object(webui, "MCP_CONFIG_BACKUP_FILE", backup_file):
                result = webui.save_mcp_config(config)
            self.assertTrue(result["success"], result)
            self.assertEqual(outside.read_text(encoding="utf-8"), "must remain unchanged")
            self.assertFalse(backup_file.is_symlink())
            self.assertEqual(json.loads(backup_file.read_text(encoding="utf-8"))["servers"], {})

        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn("Write-Utf8Atomic-Core $MCPConfigBackupFile", ps_src)
        self.assertNotIn("Copy-Item $MCPConfigFile $MCPConfigBackupFile", ps_src)

    def test_mcp_config_reads_enforce_the_same_one_megabyte_limit(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            config_file = Path(tmp) / "servers.json"
            config_file.write_bytes(b" " * (1024 * 1024 + 1))
            with mock.patch.object(webui, "MCP_CONFIG_FILE", config_file):
                config, error = webui._read_mcp_config()
        self.assertIsNone(config)
        self.assertIn("1 MB", error)

        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        config_reader = ps_src.split("function Get-MCPConfigObject", 1)[1].split("\n}", 1)[0]
        self.assertIn("$ConfigInfo.Length -gt 1048576", config_reader)

    def test_mcp_environment_reference_syntax_is_validated_before_save(self):
        webui = load_python_webui_module()

        def config_with(value):
            return {
                "version": 1,
                "servers": {
                    "example": {
                        "transport": "http",
                        "url": "https://example.invalid/mcp",
                        "headers": {"Authorization": value},
                    }
                },
                "profiles": {"default": {"servers": ["*"]}},
            }

        valid, message = webui._validate_mcp_config(config_with("Bearer ${env:API_TOKEN}"))
        self.assertTrue(valid, message)
        valid, message = webui._validate_mcp_config(config_with("$${env:LITERAL-NAME}"))
        self.assertTrue(valid, message)
        for malformed in ("${env:}", "${env:9TOKEN}", "${env:BAD-NAME}", "${env:UNCLOSED"):
            with self.subTest(value=malformed):
                valid, message = webui._validate_mcp_config(config_with(malformed))
                self.assertFalse(valid)
                self.assertIn("expected ${env:NAME}", message)

        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn("function Test-MCPRuntimeValueSyntax", ps_src)
        self.assertIn("Test-MCPRuntimeValueSyntax ([string]$Prop.Value)", ps_src)

    def test_mcp_typed_fields_reject_explicit_json_null(self):
        webui = load_python_webui_module()
        for field in ("enabled", "required", "cwd", "command", "url", "startup_timeout_seconds", "tool_timeout_seconds"):
            with self.subTest(field=field):
                server = {"transport": "stdio", "command": "x"}
                server[field] = None
                valid, message = webui._validate_mcp_config({
                    "version": 1,
                    "servers": {"remote": server},
                })
                self.assertFalse(valid)
                self.assertIn(field, message)
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn('$Server.PSObject.Properties["enabled"]', ps_src)
        self.assertIn('$Server.PSObject.Properties["startup_timeout_seconds"]', ps_src)

    def test_mcp_map_keys_control_characters_and_globs_are_validated(self):
        webui = load_python_webui_module()

        for valid_pattern in ("*", "read_?", "[a-z]*", r"\[literal", "[^a]"):
            with self.subTest(valid_pattern=valid_pattern):
                self.assertTrue(webui._valid_mcp_tool_pattern_syntax(valid_pattern))
        for invalid_pattern in ("[", "[]", "[a-]", "[-a]", "trailing\\"):
            with self.subTest(invalid_pattern=invalid_pattern):
                self.assertFalse(webui._valid_mcp_tool_pattern_syntax(invalid_pattern))

        config = {
            "version": 1,
            "servers": {
                "unsafe": {
                    "transport": "stdio",
                    "command": "example",
                    "env": {"BAD=NAME": "value"},
                    "headers": {"Bad Header": "line1\nline2"},
                    "disabled_tools": ["secret["],
                }
            },
            "profiles": {"default": {"servers": ["*"], "enabled_tools": ["unsafe.["]}},
        }
        valid, message = webui._validate_mcp_config(config)
        self.assertFalse(valid)
        for expected in ("invalid variable name", "invalid HTTP field name", "invalid control characters", "invalid pattern"):
            self.assertIn(expected, message)

        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn("function Test-MCPToolPatternSyntax", ps_src)
        self.assertIn("has an invalid HTTP field name", ps_src)
        self.assertIn("contains invalid control characters", ps_src)

    def test_python_mcp_single_server_test_passes_server_selector(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            config_file = Path(tmp) / "servers.json"
            config_file.write_text('{"version":1,"servers":{}}', encoding="utf-8")
            completed = SimpleNamespace(
                returncode=0,
                stdout='{"profile":"__single__","servers":[],"tools":[]}',
                stderr="",
            )
            with mock.patch.object(webui, "MCP_CONFIG_FILE", config_file), \
                 mock.patch.object(webui, "_gateway_info", return_value={"installed": True, "path": "/fake/gateway", "version": "test"}), \
                 mock.patch.object(webui.subprocess, "run", return_value=completed) as run_mock:
                result = webui.test_mcp_gateway("default", "github")

            self.assertTrue(result["success"], result)
            command = run_mock.call_args.args[0]
            self.assertEqual(command[-2:], ["--server", "github"])

    def test_gateway_installers_pin_and_verify_the_engine_version(self):
        sh_src = read("EasySkills维护工具/.engine/install-gateway.sh")
        ps_src = read("EasySkills维护工具/.engine/install-gateway.ps1")
        self.assertNotIn("releases/latest/download", sh_src)
        self.assertNotIn("releases/latest/download", ps_src)
        self.assertIn('releases/download/v${VERSION}', sh_src)
        self.assertIn('releases/download/v$Version', ps_src)
        self.assertIn("candidate_version", sh_src)
        self.assertIn("Gateway version mismatch", ps_src)

    def test_gateway_info_reports_engine_version_mismatch(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "easyskills-mcp"
            binary.write_bytes(b"placeholder")
            completed = SimpleNamespace(
                returncode=0,
                stdout="easyskills-mcp 4.0.0 (test)\n",
                stderr="",
            )
            with mock.patch.object(webui, "MCP_GATEWAY_BINARY", binary), \
                 mock.patch.object(webui, "get_version", return_value="4.1.0"), \
                 mock.patch.object(webui.subprocess, "run", return_value=completed):
                info = webui._gateway_info()

        self.assertEqual(info["version_number"], "4.0.0")
        self.assertEqual(info["expected_version"], "4.1.0")
        self.assertFalse(info["version_matches"])

    def test_agents_and_guide_are_webui_first(self):
        html_src = read("EasySkills维护工具/.engine/webui/index.html")

        self.assertIn("agent-register-note", html_src)
        self.assertIn("t-agent-config-title", html_src)
        self.assertIn("t-agent-config-desc", html_src)
        self.assertIn("skills folder", html_src)

        self.assertIn("WebUI Quick Start", html_src)
        self.assertIn("WebUI Control Map", html_src)
        self.assertIn("Managing skills in the WebUI", html_src)
        self.assertIn("Connecting Agents and maintaining paths", html_src)
        self.assertIn("Advanced CLI fallback", html_src)
        self.assertIn("bash ~/EasySkills/EasySkills维护工具/.engine/deploy.sh --sync", html_src)
        self.assertIn('powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\\EasySkills\\EasySkills维护工具/.engine\\deploy.ps1" -Sync', html_src)
        self.assertIn('bash ~/EasySkills/EasySkills维护工具/.engine/deploy.sh --add "/absolute/path/to/agent/skills"', html_src)
        self.assertIn('powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\\EasySkills\\EasySkills维护工具/.engine\\deploy.ps1" -Add "C:\\Path\\To\\Agent\\skills"', html_src)
        self.assertNotIn("CLI Reference</span>", html_src)
        self.assertNotIn("Agent Chat Commands</span>", html_src)
        self.assertNotIn("\\\\'", html_src)

    def test_dashboard_exposes_three_channel_control_plane(self):
        html_src = read("EasySkills维护工具/.engine/webui/index.html")

        self.assertIn("dashboard-control-plane", html_src)
        self.assertIn("dashboard-channel-grid", html_src)
        self.assertIn("t-dashboard-skills-channel", html_src)
        self.assertIn("t-dashboard-rules-channel", html_src)
        self.assertIn("dashboard-agent-infrastructure", html_src)
        self.assertIn("One library, three capability channels", html_src)
        self.assertIn("t-dashboard-mcp-channel", html_src)
        self.assertIn('id="stat-mcp-servers"', html_src)
        self.assertIn('id="dashboard-mcp-gateway-tag"', html_src)
        self.assertIn("一个中央库、三条能力通道", html_src)
        self.assertIn('id="dashboard-skill-progress-fill"', html_src)
        self.assertIn('id="dashboard-rule-progress-fill"', html_src)
        self.assertIn('id="stat-agent-paths"', html_src)
        dashboard_markup = html_src.split('<section id="dashboard"', 1)[1].split('<section id="skills"', 1)[0]
        self.assertNotIn("terminal-dots", dashboard_markup)

    def test_skills_and_agents_toolbars_use_shared_visual_system(self):
        html_src = read("EasySkills维护工具/.engine/webui/index.html")

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
        html_src = read("EasySkills维护工具/.engine/webui/index.html")

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
        html_src = read("EasySkills维护工具/.engine/webui/index.html")

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
        self.assertIn('data-es-action="add-agent"', agents_markup)
        self.assertIn("case 'add-agent': addCustomAgent(trigger)", html_src)
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
        self.assertIn("Skill Import/Delete", readme_en)
        self.assertIn("linked agents", readme_en)
        self.assertIn("register a custom skills directory for an unsupported agent", readme_en)
        self.assertNotIn("http://localhost:6633", readme_en)
        self.assertNotIn("agent bridges", readme_en)
        self.assertNotIn("skill registry", readme_en)

        self.assertIn("http://127.0.0.1:6633", readme_cn)
        self.assertIn("技能库导入/删除", readme_cn)
        self.assertIn("Agent 连接", readme_cn)
        self.assertIn("非标准路径安装的 Agent", readme_cn)
        self.assertNotIn("http://localhost:6633", readme_cn)

    def test_python_skill_import_and_delete_are_confined_to_central_dir(self):
        webui = load_python_webui_module()
        for unsafe_path in ("nested/CON", "nested/guide. ", "nested/name:txt", "nested/aux.txt"):
            with self.subTest(unsafe_path=unsafe_path):
                self.assertIsNone(webui._safe_relative_path(unsafe_path))
        self.assertEqual(webui._safe_relative_path("nested/guide.txt").as_posix(), "nested/guide.txt")

        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        safe_path_fn = ps_src.split("function ConvertTo-SafeRelativePath", 1)[1].split(
            "function Import-SkillFolder", 1
        )[0]
        self.assertIn("$WindowsReservedFileNames -contains $BaseName", safe_path_fn)
        self.assertIn('$Part.EndsWith(".")', safe_path_fn)
        self.assertIn('$Part.EndsWith(" ")', safe_path_fn)

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

    def test_skill_import_keeps_cross_process_lock_through_sync(self):
        webui = load_python_webui_module()
        files = [{
            "path": "SKILL.md",
            "data": base64.b64encode(b"---\nname: imported\n---\n").decode("ascii"),
        }]
        with tempfile.TemporaryDirectory() as tmp:
            central = Path(tmp)
            lock_active = False

            @webui.contextlib.contextmanager
            def tracked_lock():
                nonlocal lock_active
                self.assertFalse(lock_active)
                lock_active = True
                try:
                    yield True
                finally:
                    lock_active = False

            def sync_after_unlock(*_args):
                self.assertTrue(lock_active, "import must keep the shared lock through its follow-up sync")
                return {"success": True, "message": "synced"}

            with mock.patch.object(webui, "CENTRAL_DIR", central), \
                 mock.patch.object(webui, "_cross_process_deploy_lock", tracked_lock), \
                 mock.patch.object(webui, "run_deploy", side_effect=sync_after_unlock):
                result = webui.import_skill_folder("ImportedSkill", files)

            self.assertTrue(result["success"], result)
            self.assertTrue(result["sync_success"])

    def test_cross_process_lock_timeout_refuses_mutation(self):
        webui = load_python_webui_module()

        @webui.contextlib.contextmanager
        def unavailable_lock():
            yield False

        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "agent-skills"
            disabled = Path(tmp) / "disabled-targets.txt"
            with mock.patch.object(webui, "_cross_process_deploy_lock", unavailable_lock), \
                 mock.patch.object(webui, "DISABLED_TARGETS_FILE", disabled):
                result = webui.do_map(str(target))

            self.assertFalse(result["success"])
            self.assertIn("still running", result["message"])
            self.assertFalse(target.exists())
            self.assertFalse(disabled.exists())

    def test_mapping_validates_target_and_disabled_state_before_mutation(self):
        webui = load_python_webui_module()

        @webui.contextlib.contextmanager
        def available_lock():
            yield True

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            central = root / "central"
            central.mkdir()
            (central / "example-skill").mkdir()
            (central / "example-skill" / "SKILL.md").write_text("# skill\n", encoding="utf-8")
            target_file = root / "not-a-directory"
            target_file.write_text("keep", encoding="utf-8")
            missing = root / "missing-agent"
            disabled = root / "disabled-targets.txt"

            with mock.patch.object(webui, "CENTRAL_DIR", central), \
                 mock.patch.object(webui, "DISABLED_TARGETS_FILE", disabled), \
                 mock.patch.object(webui, "_cross_process_deploy_lock", available_lock):
                webui._atomic_write_text(disabled, f"Agent={target_file}\n")

                mapped = webui.do_map(str(target_file))
                self.assertFalse(mapped["success"])
                self.assertIn("must be a directory", mapped["message"])
                self.assertIn(f"Agent={target_file}", disabled.read_text(encoding="utf-8"))

                unmapped = webui.do_unmap(str(missing))
                self.assertFalse(unmapped["success"])
                self.assertIn("does not exist", unmapped["message"])
                self.assertNotIn(str(missing), disabled.read_text(encoding="utf-8"))

                unsafe = webui.do_map(str(central / "nested-agent"))
                self.assertFalse(unsafe["success"])
                self.assertIn("EasySkills library", unsafe["message"])
                self.assertFalse((central / "nested-agent").exists())

                self.assertIn(str(target_file.resolve()), webui._get_disabled_targets())
                self.assertTrue(webui._remove_from_disabled_targets(str(target_file)))
                self.assertNotIn("Agent=", disabled.read_text(encoding="utf-8"))

    def test_mapping_contract_is_shared_across_shell_backends(self):
        deploy_sh = read("EasySkills维护工具/.engine/deploy.sh")
        deploy_ps = read("EasySkills维护工具/.engine/deploy.ps1")
        webui_ps = read("EasySkills维护工具/.engine/webui.ps1")

        self.assertIn("is_central_descendant", deploy_sh)
        self.assertIn("Test-IsCentralDescendant", deploy_ps)
        self.assertIn("Resolve-MappingTarget", webui_ps)
        self.assertIn("-PathType Container", deploy_ps)
        self.assertIn("Get-TargetPathFromLine", webui_ps)

    def test_readme_version_and_agent_count_match_release(self):
        # agents.json is the single source of truth for the agent count, and
        # EasySkills维护工具/.engine/.version is the single source of truth for the version.
        # Deriving both expected values from those files (instead of hardcoding
        # them here) means this test never goes red just because a release
        # bumped the version but forgot to update the assertions.
        agent_count = len(json.loads(read("EasySkills维护工具/.engine/agents.json"))["agents"])
        version = read("EasySkills维护工具/.engine/.version").strip()

        self.assertIn(f"Version-{version}", read("README_EN.md"))
        self.assertIn(f"版本-{version}", read("README.md"))
        self.assertIn(f"**Version:** {version}", read("EasySkills维护工具/README_SYSTEM.md"))
        self.assertIn(f"## EasySkills {version}", read("release_notes.md"))
        self.assertIn(f"EasySkills pre-configures mappings for {agent_count}+ agent", read("README_EN.md"))
        self.assertIn(f"EasySkills 开箱即用支持以下 {agent_count}+ 个 Agent", read("README.md"))

        # The published tables must preserve the platform paths from the
        # catalog, including Windows separators. A single slash typo can make
        # a documented target unusable even though the runtime catalog is right.
        aliases = {
            "Codex": "Codex (OpenAI)",
            "Kimi Code": "Kimi Code (Moonshot)",
            "Kiro Agent": "Kiro Agent (AWS)",
            "Goose": "Goose (Block/AAIF)",
        }
        for doc in ("README.md", "README_EN.md"):
            rows = {}
            for line in read(doc).splitlines():
                match = re.match(r"^\|\s*\d+\s*\|\s*\*\*(.*?)\*\*\s*\|\s*`([^`]*)`\s*\|\s*`([^`]*)`\s*\|$", line)
                if match:
                    rows[match.group(1)] = (match.group(2), match.group(3))
            for agent in json.loads(read("EasySkills维护工具/.engine/agents.json"))["agents"]:
                published_name = aliases.get(agent["name"], agent["name"])
                self.assertEqual(
                    rows.get(published_name),
                    (agent["mac_path"], agent["win_path"]),
                    f"{doc} path table drifted for {agent['name']}",
                )

    def test_docs_do_not_claim_automatic_defender_exclusion(self):
        docs = "\n".join([
            read("README.md"),
            read("README_EN.md"),
            read("EasySkills维护工具/README_SYSTEM.md"),
        ])
        self.assertNotIn("Add-MpPreference", docs)
        self.assertNotIn("installer tries to append a Defender exclusion", docs)
        self.assertNotIn("安装器会自动尝试通过 UAC", docs)
        self.assertIn("does not modify Defender exclusions", docs)
        self.assertIn("安装器不会修改 Defender 排除项", docs)

    def test_python_runtime_requirement_is_documented_and_enforced(self):
        docs = "\n".join([
            read("README.md"),
            read("README_EN.md"),
            read("EasySkills维护工具/README_SYSTEM.md"),
        ])
        self.assertIn("Python 3.10+", docs)
        for script in (
            "EasySkills维护工具/.engine/deploy.sh",
            "EasySkills维护工具/.engine/webui-service.sh",
        ):
            with self.subTest(script=script):
                source = read(script)
                self.assertIn("sys.version_info >= (3, 10)", source)
                self.assertIn("Python 3.10+", source)

    def test_unix_installers_preserve_previous_backup_when_restore_fails(self):
        unsafe_restore = (
            '[ ! -d "$BACKUP_MAINT" ] && mv "$PREV_BACKUP" '
            '"$BACKUP_MAINT" || rm -rf "$PREV_BACKUP"'
        )
        warning = "previous backup could not be restored; preserved at $PREV_BACKUP"
        for installer in ("install.sh", "install_mac.command"):
            source = read(installer)
            with self.subTest(installer=installer):
                self.assertNotIn(unsafe_restore, source)
                self.assertIn(warning, source)
                self.assertIn("restore_previous_backup", source)

    @unittest.skipIf(os.name == "nt", "Bash fault injection runs on Unix CI jobs.")
    def test_unix_installer_restore_function_survives_mv_failure(self):
        """Fault-inject a failed backup rename and prove the prior snapshot remains."""
        for installer in ("install.sh", "install_mac.command"):
            source = read(installer)
            match = re.search(
                r"restore_previous_backup\(\) \{\n.*?^\s*\}",
                source,
                re.DOTALL | re.MULTILINE,
            )
            self.assertIsNotNone(match, installer)
            with self.subTest(installer=installer), tempfile.TemporaryDirectory() as tmp:
                tmp_path = Path(tmp)
                previous = tmp_path / ".maintenance-bak.prev"
                backup = tmp_path / ".maintenance-bak"
                previous.mkdir()
                (previous / "recoverable.txt").write_text("keep me", encoding="utf-8")
                fake_bin = tmp_path / "bin"
                fake_bin.mkdir()
                fake_mv = fake_bin / "mv"
                fake_mv.write_text("#!/usr/bin/env bash\nexit 73\n", encoding="utf-8")
                fake_mv.chmod(0o755)
                harness = tmp_path / "restore-test.sh"
                harness.write_text(
                    "set -u\n"
                    f"BACKUP_MAINT={shlex.quote(str(backup))}\n"
                    f"PREV_BACKUP={shlex.quote(str(previous))}\n"
                    + match.group(0)
                    + "\nrestore_previous_backup || true\n",
                    encoding="utf-8",
                )
                result = subprocess.run(
                    ["/bin/bash", str(harness)],
                    text=True,
                    capture_output=True,
                    env={**os.environ, "PATH": f"{fake_bin}:/usr/bin:/bin"},
                    check=False,
                )
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertTrue(previous.is_dir(), "failed restore deleted the recoverable backup")
                self.assertTrue((previous / "recoverable.txt").is_file())
                self.assertFalse(backup.exists())
                self.assertIn("preserved at", result.stderr)

    def test_doctor_cli_api_and_frontend_contracts_exist(self):
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        sh_src = read("EasySkills维护工具/.engine/deploy.sh")
        deploy_ps_src = read("EasySkills维护工具/.engine/deploy.ps1")
        html_src = read("EasySkills维护工具/.engine/webui/index.html")

        self.assertIn("def get_doctor_report", py_src)
        self.assertIn('path == "/api/doctor"', py_src)
        self.assertIn('"--doctor" in _sys.argv', py_src)
        self.assertIn("function Get-DoctorReport", ps_src)
        self.assertIn('$UrlPath -eq "/api/doctor"', ps_src)
        self.assertIn("[switch]$Doctor", ps_src)
        self.assertIn('--doctor) ACTION="doctor"', sh_src)
        self.assertIn("run_doctor", sh_src)
        self.assertIn("[switch]$Doctor", deploy_ps_src)
        self.assertIn("/api/doctor", html_src)
        self.assertIn("copyDoctorDiagnostics", html_src)
        self.assertIn("dashboard-doctor-panel", html_src)

    def test_mcp_credential_posture_ignores_nonsecret_values_and_escaped_refs(self):
        webui = load_python_webui_module()
        config = {
            "servers": {
                "example": {
                    "headers": {
                        "Authorization": "Bearer ${env:AUTH_TOKEN}",
                        "X-API-Key": "literal-api-key",
                        "Accept": "application/json",
                    },
                    "env": {
                        "OPENAI_API_KEY": "$${env:LITERAL_TEXT}",
                        "ACCESS_TOKEN": "${env:ACCESS_TOKEN}",
                        "NODE_ENV": "production",
                    },
                }
            }
        }
        self.assertEqual(
            {"environment_references": 2, "literal_values": 2},
            webui._mcp_credential_posture(config),
        )

    def test_mcp_url_validation_rejects_embedded_credentials(self):
        webui = load_python_webui_module()
        config = {
            "version": 1,
            "servers": {
                "remote": {
                    "transport": "http",
                    "url": "https://user:secret@example.com/mcp",
                }
            },
        }
        ok, message = webui._validate_mcp_config(config)
        self.assertFalse(ok)
        self.assertIn("valid http(s) URL", message)
        self.assertIn("$Uri.UserInfo", read("EasySkills维护工具/.engine/webui.ps1"))

    def test_mcp_url_validation_rejects_invalid_ports(self):
        webui = load_python_webui_module()
        for url in (
            "https://example.com:/mcp",
            "https://example.com:0/mcp",
            "https://example.com:65536/mcp",
            "https://example.com:bad/mcp",
            "https://exa mple.com/mcp",
            "https://example.com\\mcp",
            " https://example.com/mcp",
            "https://example.com/mcp ",
        ):
            with self.subTest(url=url):
                ok, message = webui._validate_mcp_config({
                    "version": 1,
                    "servers": {"remote": {"transport": "http", "url": url}},
                })
                self.assertFalse(ok)
                self.assertIn("valid http(s) URL", message)
        ok, message = webui._validate_mcp_config({
            "version": 1,
            "servers": {"remote": {"transport": "http", "url": "HTTPS://EXAMPLE.COM/mcp"}},
        })
        self.assertTrue(ok, message)
        ps_source = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn("$RawUrl -match '\\s'", ps_source)
        self.assertIn("$RawUrl.Contains('\\')", ps_source)
        self.assertIn("$RawUrl -match '^[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*:$'", ps_source)

    def test_target_lines_preserve_equals_inside_plain_paths(self):
        webui = load_python_webui_module()
        self.assertEqual(("Agent", "/tmp/agent-skills"), webui._target_line_parts("Agent=/tmp/agent-skills"))
        self.assertEqual(("", "/tmp/agent=skills"), webui._target_line_parts("/tmp/agent=skills"))
        self.assertEqual(("", r"C:\\Agent=skills"), webui._target_line_parts(r"C:\\Agent=skills"))
        self.assertEqual(("Agent", "~/.agent/skills"), webui._target_line_parts("Agent=~/.agent/skills"))

        py_src = read("EasySkills维护工具/.engine/webui.py")
        sh_src = read("EasySkills维护工具/.engine/deploy.sh")
        ps_src = read("EasySkills维护工具/.engine/deploy.ps1")
        self.assertIn("def _target_line_parts", py_src)
        self.assertIn("candidate_looks_like_path", py_src)
        self.assertIn("candidate=\"${line#*=}\"", sh_src)
        self.assertIn("$CandidateLooksLikePath", ps_src)

    def test_python_doctor_report_is_redacted_and_actionable(self):
        webui = load_python_webui_module()
        secret = "super-secret-token-value"
        fake_central = Path.home() / ".private-doctor-fixture" / "EasySkills"
        fake_engine = fake_central / "EasySkills维护工具" / ".engine"
        mcp_data = {
            "success": True,
            "config": {
                "servers": {
                    "private": {
                        "enabled": True,
                        "transport": "http",
                        "url": "https://example.invalid/mcp",
                        "headers": {"Authorization": f"Bearer {secret}"},
                    }
                }
            },
            "gateway": {"installed": False, "path": str(fake_central / ".runtime" / "gateway")},
        }
        with mock.patch.object(webui, "CENTRAL_DIR", fake_central), \
             mock.patch.object(webui, "SCRIPT_DIR", fake_engine), \
             mock.patch.object(webui, "get_skills", return_value=[{"name": "one"}]), \
             mock.patch.object(webui, "get_visible_agents", return_value=[{"active": True, "mapped": False}]), \
             mock.patch.object(webui, "get_instructions", return_value={
                 "rules": [{"name": "rule.md"}],
                 "agents": [{"active": True, "managed_rule_count": 0}],
             }), \
             mock.patch.object(webui, "get_central_dir_warnings", return_value={
                 "dangling_count": 0, "external_link_count": 1,
             }), \
             mock.patch.object(webui, "get_watcher_status", return_value={"running": False, "pid": None}), \
             mock.patch.object(webui, "get_mcp_config", return_value=mcp_data), \
             mock.patch.object(webui, "get_version", return_value="test"):
            report = webui.get_doctor_report()

        serialized = json.dumps(report)
        self.assertEqual(1, report["schema_version"])
        self.assertFalse(report["success"])
        self.assertEqual(1, report["summary"]["errors"])
        self.assertGreaterEqual(report["summary"]["warnings"], 5)
        self.assertNotIn(secret, serialized)
        self.assertNotIn(str(Path.home()), serialized)
        self.assertTrue(report["paths"]["central"].startswith("~"))
        self.assertEqual(1, report["metrics"]["credential_posture"]["literal_values"])
        self.assertTrue(any(check["action"] for check in report["checks"] if check["status"] in {"warning", "error"}))

    def test_skills_and_agents_responses_are_always_json_arrays(self):
        # Contract: /api/skills and /api/agents must serialize to JSON *arrays*
        # for 0, 1, or N elements on every backend. The Python side returns a
        # list (json.dumps renders [] / [{...}]); the PowerShell side must
        # preserve array-ness at the call site, because PowerShell function-
        # return unrolling + the PS5.1 ConvertTo-Json quirk would otherwise turn
        # [] / [{...}] into null / a bare object and blank the Windows WebUI.
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn("def get_skills():", py_src)
        # get_visible_agents is a list comprehension -> always a list, even empty.
        self.assertIn("return [agent for agent in get_agents()", py_src)
        # The PowerShell call sites must wrap the data getters in @(...) so a
        # 0/1 element result reaches the serializer as a real array.
        self.assertIn("@(Get-SkillsData)", ps_src)
        self.assertIn("@(Get-VisibleAgentsData)", ps_src)

    def test_python_get_skills_returns_list_even_when_empty(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            empty_central = Path(tmp) / "central"
            empty_central.mkdir()
            with mock.patch.object(webui, "CENTRAL_DIR", empty_central):
                # Empty library -> [] (a list), never None.
                self.assertEqual([], webui.get_skills())
            # A single skill must stay a single-element list, not a bare dict.
            one = empty_central / "demo"
            one.mkdir()
            (one / "SKILL.md").write_text("demo skill\n", encoding="utf-8")
            with mock.patch.object(webui, "CENTRAL_DIR", empty_central):
                skills_one = webui.get_skills()
                self.assertIsInstance(skills_one, list)
                self.assertEqual(["demo"], [s["name"] for s in skills_one])
        # No detected agents -> [] (a list), never None.
        with mock.patch.object(webui, "get_agents", return_value=[]):
            self.assertEqual([], webui.get_visible_agents())

    @unittest.skipIf(os.name == "nt", "The Python doctor CLI is the Unix backend.")
    def test_python_doctor_cli_does_not_create_auth_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake_home = Path(tmp) / "home"
            fake_home.mkdir()
            root = fake_home / "EasySkills"
            engine = root / "EasySkills维护工具" / ".engine"
            engine.mkdir(parents=True)
            shutil.copy2(ROOT / "EasySkills维护工具/.engine/webui.py", engine / "webui.py")
            (engine / ".version").write_text("test\n", encoding="utf-8")
            env = {**os.environ, "HOME": str(fake_home), "EASYSKILLS_CENTRAL_DIR": str(root)}
            result = subprocess.run(
                [os.sys.executable, str(engine / "webui.py"), "--doctor"],
                text=True,
                capture_output=True,
                env=env,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual("test", report["version"])
            self.assertFalse((engine / ".easyskills-token").exists())
            self.assertFalse((engine / ".easyskills-token.lock").exists())
            self.assertFalse((fake_home / ".qoder-cn").exists())

    @unittest.skipIf(os.name == "nt", "The Bash doctor entry point is Unix-only.")
    def test_deploy_doctor_skips_legacy_migrations_and_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "EasySkills"
            engine = root / "EasySkills维护工具" / ".engine"
            engine.mkdir(parents=True)
            for name in ("deploy.sh", "webui.py"):
                shutil.copy2(ROOT / "EasySkills维护工具/.engine" / name, engine / name)
            (engine / ".version").write_text("test\n", encoding="utf-8")
            legacy_targets = root / "custom-targets.txt"
            stale_readme = root / "README.md"
            legacy_targets.write_text("/keep/legacy/path\n", encoding="utf-8")
            stale_readme.write_text("keep stale marker for read-only test\n", encoding="utf-8")
            env = {**os.environ, "EASYSKILLS_CENTRAL_DIR": str(root)}
            result = subprocess.run(
                ["/bin/bash", str(engine / "deploy.sh"), "--doctor"],
                text=True,
                capture_output=True,
                env=env,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            json.loads(result.stdout)
            self.assertEqual("/keep/legacy/path\n", legacy_targets.read_text(encoding="utf-8"))
            self.assertTrue(stale_readme.is_file())
            self.assertFalse((engine / ".easyskills-token").exists())

    @unittest.skipIf(os.name == "nt", "Bash fault injection runs on Unix CI jobs.")
    def test_deploy_legacy_migration_preserves_source_when_atomic_commit_fails(self):
        source = read("EasySkills维护工具/.engine/deploy.sh")
        migration = source.split("migrate_legacy_targets() {", 1)[1].split(
            "\n}\n\ncleanup_stale_root_files() {", 1
        )[0]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            engine = root / "EasySkills维护工具" / ".engine"
            engine.mkdir(parents=True)
            legacy = root / "custom-targets.txt"
            current = engine / "custom-targets.txt"
            legacy.write_text("/legacy/path\n", encoding="utf-8")
            current.write_text("/current/path\n", encoding="utf-8")
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_mv = fake_bin / "mv"
            fake_mv.write_text("#!/usr/bin/env bash\nexit 74\n", encoding="utf-8")
            fake_mv.chmod(0o755)
            harness = root / "migration.sh"
            harness.write_text(
                "DOCTOR_MODE=false\n"
                f"CENTRAL_DIR={shlex.quote(str(root))}\n"
                f"SCRIPT_DIR={shlex.quote(str(engine))}\n"
                f"CUSTOM_TARGETS_FILE={shlex.quote(str(current))}\n"
                "LEGACY_ROOT_TARGETS=\"$CENTRAL_DIR/custom-targets.txt\"\n"
                "migrate_legacy_targets() {\n"
                + migration
                + "}\n"
                "migrate_legacy_targets\n",
                encoding="utf-8",
            )
            result = subprocess.run(
                ["/bin/bash", str(harness)],
                text=True,
                capture_output=True,
                env={**os.environ, "PATH": f"{fake_bin}:/usr/bin:/bin"},
                check=False,
            )

            self.assertNotEqual(0, result.returncode)
            self.assertEqual("/legacy/path\n", legacy.read_text(encoding="utf-8"))
            self.assertEqual("/current/path\n", current.read_text(encoding="utf-8"))

    @unittest.skipIf(os.name == "nt", "The Bash deploy entry point is Unix-only.")
    def test_standalone_deploy_passes_lock_marker_to_nested_rule_sync(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "EasySkills"
            engine = root / "EasySkills维护工具" / ".engine"
            engine.mkdir(parents=True)
            shutil.copy2(ROOT / "EasySkills维护工具/.engine/deploy.sh", engine / "deploy.sh")
            (engine / "webui.py").write_text(
                "import os, sys\n"
                "assert sys.argv[1:] == ['--sync-rules']\n"
                "print('LOCK=' + os.environ.get('EASYSKILLS_DEPLOY_LOCK_HELD', ''))\n"
                "print('PID=' + os.environ.get('EASYSKILLS_DEPLOY_LOCK_PID', ''))\n",
                encoding="utf-8",
            )
            fake_home = Path(tmp) / "home"
            fake_home.mkdir()
            result = subprocess.run(
                ["/bin/bash", str(engine / "deploy.sh"), "--sync"],
                text=True,
                capture_output=True,
                env={**os.environ, "HOME": str(fake_home)},
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIn("LOCK=1", result.stdout)
            self.assertRegex(result.stdout, r"PID=[1-9][0-9]*")

    def test_nested_rule_sync_inherits_the_parent_deploy_lock(self):
        sh_source = read("EasySkills维护工具/.engine/deploy.sh")
        ps_source = read("EasySkills维护工具/.engine/deploy.ps1")
        self.assertIn('export EASYSKILLS_DEPLOY_LOCK_HELD=1', sh_source)
        self.assertIn('export EASYSKILLS_DEPLOY_LOCK_PID="$$"', sh_source)
        self.assertIn('$env:EASYSKILLS_DEPLOY_LOCK_HELD = "1"', ps_source)
        self.assertIn('$env:EASYSKILLS_DEPLOY_LOCK_PID = [string]$PID', ps_source)
        self.assertLess(
            ps_source.index('$env:EASYSKILLS_DEPLOY_LOCK_HELD = "1"'),
            ps_source.index('powershell -NoProfile -ExecutionPolicy Bypass -File "$WebUIScript" -SyncRules'),
        )

    def test_custom_target_add_detects_named_entries_and_directories_only(self):
        sh_source = read("EasySkills维护工具/.engine/deploy.sh")
        ps_source = read("EasySkills维护工具/.engine/deploy.ps1")
        self.assertIn('substr($0, idx + 1) == p', sh_source)
        self.assertIn('target_path=$(target_line_path "$line")', sh_source)
        self.assertIn('candidate="${line#*=}"', sh_source)
        self.assertIn('candidate_looks_like_path', read("EasySkills维护工具/.engine/webui.py"))
        self.assertIn('Test-Path $Path -PathType Container', ps_source)
        self.assertIn('$CandidateLooksLikePath', ps_source)

    def test_windows_live_config_writes_use_atomic_replace(self):
        for rel in (
            "EasySkills维护工具/.engine/deploy.ps1",
            "EasySkills维护工具/.engine/webui.ps1",
        ):
            source = read(rel)
            helper = source.split("function Write-Utf8NoBom", 1)[1].split("\nfunction ", 1)[0]
            with self.subTest(script=rel):
                self.assertIn("[System.IO.File]::Replace", helper)
                self.assertNotIn("Remove-Item -LiteralPath $Path", helper)

    def test_remote_installers_default_to_the_current_stable_release(self):
        version = read("EasySkills维护工具/.engine/.version").strip()
        sh_source = read("install.sh")
        ps_source = read("install.ps1")
        self.assertIn(f'DEFAULT_VERSION="{version}"', sh_source)
        self.assertIn(f'$DefaultVersion = "{version}"', ps_source)
        for source in (sh_source, ps_source):
            self.assertIn("EASYSKILLS_CHANNEL", source)
            self.assertIn("EASYSKILLS_VERSION", source)
            self.assertIn("stable", source)
            self.assertIn("edge", source)
        self.assertNotIn('BRANCH="main"', sh_source)
        self.assertNotIn('$Branch = "main"', ps_source)

    def test_installers_validate_source_before_migrating_or_stopping_services(self):
        sh_source = read("install.sh")
        ps_source = read("install.ps1")
        mac_source = read("install_mac.command")

        self.assertLess(
            sh_source.index("Validate the selected source before touching"),
            sh_source.index('LEGACY_ROOT_CT="$PERM_DIR/custom-targets.txt"'),
        )
        self.assertLess(
            ps_source.index("Validate the selected source before changing"),
            ps_source.index("Stop-StaleEasySkillsProcesses\n"),
        )
        self.assertLess(
            mac_source.index("Validate the local bundle before modifying"),
            mac_source.index("Preserve per-machine runtime files verbatim"),
        )
        self.assertIn("does not match requested version", sh_source)
        self.assertIn("does not match requested version", ps_source)
        self.assertIn("function Assert-SafeZipArchive", ps_source)
        self.assertIn("$Name.StartsWith('\\')", ps_source)
        self.assertIn("$Target.StartsWith('\\')", ps_source)
        self.assertNotIn("$Name.StartsWith('\\\\')", ps_source)
        self.assertNotIn("$Target.StartsWith('\\\\')", ps_source)
        self.assertIn("Downloaded archive exceeds the 512 MB extracted-size safety limit", ps_source)
        self.assertIn("Downloaded archive contains an unsafe path", ps_source)
        self.assertIn("Downloaded archive exceeds the 100 MB safety limit", ps_source)
        self.assertIn("function Save-BoundedWebFile", ps_source)
        self.assertIn("ResponseHeadersRead", ps_source)
        self.assertLess(ps_source.index("Assert-SafeZipArchive $ZipPath $TmpDir"), ps_source.index("Expand-Archive -Path $ZipPath"))
        self.assertIn("$SourceRoots.Count -ne 1", ps_source)
        self.assertNotIn("Select-Object -First 1 -ExpandProperty FullName", ps_source)
        self.assertIn("safe_extract_archive", sh_source)
        self.assertIn("--max-filesize 104857600", sh_source)
        self.assertIn("release archive contains an unsafe path", sh_source)
        self.assertIn("release archive contains an unsafe link", sh_source)
        self.assertNotIn('tar -xzf "$TMP_DIR/repo.tar.gz"', sh_source)
        self.assertIn('_candidate_count" -eq 1', sh_source)
        self.assertIn('MIRROR_PREFIXES=("")', sh_source)
        self.assertNotIn('"https://ghfast.top"                                # ghfast mirror proxy', sh_source)
        self.assertIn("EASYSKILLS_MIRROR must be an explicit HTTPS URL prefix", sh_source)
        self.assertIn('$MirrorPrefixes = @("")', ps_source)
        self.assertNotIn('@("", "https://ghfast.top"', ps_source)
        self.assertIn("EASYSKILLS_MIRROR must be an explicit HTTPS URL prefix", ps_source)

        for rel in (
            "EasySkills维护工具/.engine/install-gateway.sh",
            "EasySkills维护工具/.engine/install-gateway.ps1",
        ):
            gateway_installer = read(rel)
            self.assertNotIn('"https://ghfast.top" "https://gh-proxy.com"', gateway_installer)
            self.assertIn("EASYSKILLS_MIRROR must be an explicit HTTPS URL prefix", gateway_installer)
        gateway_sh = read("EasySkills维护工具/.engine/install-gateway.sh")
        gateway_ps = read("EasySkills维护工具/.engine/install-gateway.ps1")
        self.assertIn("--max-filesize 52428800", gateway_sh)
        self.assertIn("--max-filesize 1048576", gateway_sh)
        self.assertIn('entries="$(tar -tzf', gateway_sh)
        self.assertIn('tar -xOzf "$TMP_DIR/$ASSET" easyskills-mcp', gateway_sh)
        self.assertIn("^[0-9A-Fa-f]{64}$", gateway_sh)
        self.assertIn('$2 == ("*" asset)', gateway_sh)
        self.assertNotIn('tar -xzf "$TMP_DIR/$ASSET"', gateway_sh)
        self.assertIn("function Expand-GatewayCandidate", gateway_ps)
        self.assertIn('FullName -ne "easyskills-mcp.exe"', gateway_ps)
        self.assertIn("Gateway archive exceeds the 50 MB safety limit", gateway_ps)
        self.assertIn("Gateway checksum file exceeds the 1 MB safety limit", gateway_ps)
        self.assertIn("function Save-BoundedWebFile", gateway_ps)
        self.assertIn("ResponseHeadersRead", gateway_ps)
        self.assertIn("^[0-9a-f]{64}$", gateway_ps)
        self.assertNotIn("Expand-Archive -Path $Archive", gateway_ps)

        for rel in ("README.md", "README_EN.md"):
            readme = read(rel)
            self.assertNotIn("built-in multi-source fallback", readme)
            self.assertNotIn("内置多源自动回退", readme)
            self.assertIn("EASYSKILLS_MIRROR", readme)

    def test_unix_installer_safe_archive_helper_rejects_traversal(self):
        sh_source = read("install.sh")
        match = re.search(r"python3 - \"\$archive_path\" \"\$destination\" <<'PY'\n(.*?)\nPY", sh_source, re.DOTALL)
        self.assertIsNotNone(match, "safe archive Python helper not found")
        helper = match.group(1)
        compile(helper, "install.sh:safe_extract_archive", "exec")

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            archive = root / "unsafe.tar.gz"
            destination = root / "extract"
            destination.mkdir()
            payload = b"escape"
            with tarfile.open(archive, "w:gz") as tf:
                member = tarfile.TarInfo("../escape.txt")
                member.size = len(payload)
                tf.addfile(member, io.BytesIO(payload))

            result = subprocess.run(
                [sys.executable, "-", str(archive), str(destination)],
                input=helper,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / "escape.txt").exists())

    def test_installers_reconcile_stranded_previous_backup_before_rotation(self):
        sh_source = read("install.sh")
        mac_source = read("install_mac.command")
        ps_source = read("install.ps1")
        bat_source = read("install_windows.bat")
        for source in (sh_source, mac_source):
            self.assertIn('elif ! mv "$PREV_BACKUP" "$BACKUP_MAINT"', source)
            reconcile = source.index('elif ! mv "$PREV_BACKUP" "$BACKUP_MAINT"')
            rotation = source.index('if [ -d "$OLD_MAINT" ]')
            self.assertLess(reconcile, rotation)
        self.assertIn("Previous recoverable backup is preserved", ps_source)
        pre_rotation = ps_source.split('$PrevBackup = Join-Path $PermDir ".maintenance-bak.prev"', 1)[1].split(
            "  try {", 1
        )[0]
        self.assertNotIn(
            'if (Test-Path $PrevBackup) { Remove-Item $PrevBackup -Recurse -Force }',
            pre_rotation,
        )
        self.assertIn('move /Y "%PERM_DIR%\\.maintenance-bak.prev" "%PERM_DIR%\\.maintenance-bak"', bat_source)
        self.assertLess(
            bat_source.index('move /Y "%PERM_DIR%\\.maintenance-bak.prev" "%PERM_DIR%\\.maintenance-bak"'),
            bat_source.index('if exist "%MAINT_DIR%" ('),
        )

    def test_installers_abort_if_existing_backup_cannot_be_preserved(self):
        for installer in ("install.sh", "install_mac.command"):
            source = read(installer)
            with self.subTest(installer=installer):
                self.assertIn(
                    'if [ -d "$BACKUP_MAINT" ] && ! mv "$BACKUP_MAINT" "$PREV_BACKUP"; then',
                    source,
                )
                self.assertIn("could not preserve the existing rollback backup", source)
        bat_source = read("install_windows.bat")
        rotation = bat_source.split('if exist "%MAINT_DIR%" (', 1)[1].split(")\n  :: Same-parent rename", 1)[0]
        self.assertIn("could not preserve the existing rollback backup", rotation)
        self.assertIn("if errorlevel 1", rotation)

    def test_windows_batch_installer_stages_unique_runtime_snapshot_before_swap(self):
        source = read("install_windows.bat")
        self.assertIn('set "PRESERVE_DIR=%TEMP%\\easyskills-install-%RANDOM%-%RANDOM%"', source)
        self.assertNotIn('%TEMP%\\easyskills-disabled.bak', source)
        self.assertNotIn('%TEMP%\\easyskills-token.bak', source)
        swap_index = source.index('ren "%NEW_MAINT%" .engine')
        for runtime_file in ("custom-targets.txt", "disabled-targets.txt", ".easyskills-token"):
            staged = f'"%NEW_MAINT%\\{runtime_file}"'
            self.assertIn(staged, source)
            self.assertLess(source.index(staged), swap_index)
        self.assertIn('if exist "%PRESERVE_DIR%" rd /S /Q "%PRESERVE_DIR%"', source)

    def test_windows_batch_installer_precomputes_paths_for_fresh_install(self):
        source = read("install_windows.bat")
        block_start = source.index('if /i "%CURRENT_DIR_STRIP%" neq "%PERM_DIR%" (')
        for assignment in (
            'set "VISIBLE_DIR=%PERM_DIR%\\EasySkills维护工具"',
            'set "TARGET_MAINT_DIR=%VISIBLE_DIR%\\.engine"',
            'set "NEW_MAINT=%VISIBLE_DIR%\\.engine.new"',
        ):
            self.assertIn(assignment, source)
            self.assertLess(source.index(assignment), block_start)
        install_block = source[block_start:source.index(":: Initialize user MCP config")]
        self.assertNotIn('set "VISIBLE_DIR=', install_block)
        self.assertNotIn('set "NEW_MAINT=', install_block)
        self.assertIn('set "MAINT_DIR=%TARGET_MAINT_DIR%"', source)
        self.assertIn('move /Y "%PERM_DIR%\\.maintenance-bak" "%TARGET_MAINT_DIR%"', source)
        self.assertIn("if defined MAINT_DIR (", install_block)
        self.assertIn("if not defined SRC_MAINT_DIR (", install_block)
        self.assertIn("could not preserve existing runtime configuration", source)
        self.assertIn("could not stage preserved runtime configuration", source)
        xcopy = source.index('xcopy /E /I /Y /Q "%SRC_MAINT_DIR%" "%NEW_MAINT%"')
        self.assertIn("if errorlevel 1", source[xcopy:xcopy + 500])
        self.assertIn("background service registration failed", source)
        self.assertIn('if "%INSTALL_OK%"=="0" exit /b 1', source)
        self.assertIn("if not defined MAINT_DIR (", source)
        self.assertIn('if not exist "%MAINT_DIR%\\deploy.ps1" (', source)
        self.assertIn("MAINT_DIR_AMBIGUOUS", source)
        self.assertIn("SRC_MAINT_DIR_AMBIGUOUS", source)
        gateway = source.index('if exist "%MAINT_DIR%\\install-gateway.ps1" (')
        self.assertIn("if errorlevel 1", source[gateway:gateway + 600])
        self.assertIn("optional MCP Gateway installation failed", source[gateway:gateway + 600])

    def test_windows_batch_uninstaller_aborts_on_ambiguous_install_root(self):
        source = read("uninstall_windows.bat")
        self.assertIn("MAINT_DIR_AMBIGUOUS", source)
        self.assertIn("call :ResolveMaintDir", source)
        self.assertIn("multiple installed engine directories matched EasySkills*", source)
        self.assertIn("existing install untouched", source)

    def test_default_agent_targets_include_requested_agents_and_corrected_paths(self):
        # Driven by agents.json (the single source of truth): every agent entry
        # is checked across all five runtime surfaces so a new agent can never
        # silently land in only some files. Path forms are derived mechanically
        # from the canonical mac_path/win_path in agents.json.
        agents = json.loads(read("EasySkills维护工具/.engine/agents.json"))["agents"]

        deploy_sh = read("EasySkills维护工具/.engine/deploy.sh")
        deploy_ps = read("EasySkills维护工具/.engine/deploy.ps1")
        webui_py = read("EasySkills维护工具/.engine/webui.py")
        webui_ps = read("EasySkills维护工具/.engine/webui.ps1")
        docs = read("README.md") + read("README_EN.md") + read("EasySkills维护工具/README_SYSTEM.md")

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
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        html_src = read("EasySkills维护工具/.engine/webui/index.html")

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
            "EasySkills维护工具/.engine/watch.ps1",
            "EasySkills维护工具/.engine/deploy.ps1",
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
        reg = read("EasySkills维护工具/.engine/register-tasks.ps1")
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
        watch = read("EasySkills维护工具/.engine/watch.ps1")
        self.assertIn("register-tasks.ps1", watch)

    def test_windows_task_action_uses_wscript_not_powershell_directly(self):
        """The Scheduled Task action MUST be wscript.exe pointing at
        run-hidden.vbs — NOT powershell.exe directly. powershell.exe is a
        console-subsystem app and creates a console window even with
        `-WindowStyle Hidden` under interactive Task Scheduler. wscript.exe
        is GUI-subsystem and never creates a console."""
        reg = read("EasySkills维护工具/.engine/register-tasks.ps1")
        self.assertIn("wscript.exe", reg)
        self.assertIn("run-hidden.vbs", reg)
        # The action's Execute must be wscript.exe (not powershell.exe).
        # The Argument string passes the .vbs and the .ps1 service path.
        self.assertRegex(
            reg,
            r"New-ScheduledTaskAction\s+-Execute\s+\$WscriptExe",
        )

    def test_windows_uninstaller_removes_scheduled_tasks(self):
        unwatch = read("EasySkills维护工具/.engine/unwatch.ps1")
        self.assertIn("Unregister-ScheduledTask", unwatch)
        self.assertIn("EasySkills WebUI", unwatch)
        self.assertIn("EasySkills Watcher", unwatch)
        # Legacy startup shortcuts (old install scheme) are also cleaned up.
        self.assertIn("EasySkillsWatcher.lnk", unwatch)
        self.assertIn("EasySkillsWebUI.lnk", unwatch)

    def test_all_user_facing_uninstallers_preserve_recoverability(self):
        for rel in (
            "uninstall_mac.command",
            "EasySkills维护工具/.engine/launchers/macOS-卸载.command",
        ):
            src = read(rel)
            self.assertIn("move_to_trash", src, rel)
            self.assertIn('osascript - "$target"', src, rel)
            self.assertNotIn('rm -rf "$HOME/EasySkills"', src, rel)
            self.assertIn("Uninstallation incomplete", src, rel)

        for rel in (
            "uninstall_windows.bat",
            "EasySkills维护工具/.engine/launchers/Windows-卸载.bat",
        ):
            src = read(rel)
            self.assertIn("SendToRecycleBin", src, rel)
            self.assertNotIn('rd /S /Q "%PERM_DIR%"', src, rel)
            self.assertIn("if errorlevel 1 goto cleanup_failed", src, rel)
            self.assertIn("Uninstallation incomplete", src, rel)

    def test_macos_uninstaller_does_not_trash_a_live_service_install(self):
        src = read("uninstall_mac.command")
        self.assertIn('launchctl bootout "$SERVICE_TARGET"', src)
        self.assertIn('launchctl print "$SERVICE_TARGET"', src)
        self.assertIn('launchctl print "gui/$UID_VAL/$webui_label"', src)
        self.assertIn('elif [ "$uninstall_ok" = true ] && ! move_to_trash', src)

    def test_windows_launcher_is_silent_vbs_not_visible_bat(self):
        """The user-facing 'Start' launcher must be a .vbs running under
        wscript.exe so it shows ZERO console window. The old .bat is gone."""
        vbs = ROOT / "EasySkills维护工具/.engine/launchers/Windows-启动.vbs"
        bat = ROOT / "EasySkills维护工具/.engine/launchers/Windows-启动.bat"
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
        vbs = ROOT / "EasySkills维护工具/.engine/run-hidden.vbs"
        self.assertTrue(vbs.exists(), "EasySkills维护工具/.engine/run-hidden.vbs missing")
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
            "EasySkills维护工具/.engine/launchers/Windows-卸载.bat",
        ):
            src = read(rel)
            self.assertNotIn("pause > nul", src, rel)
            self.assertIn("timeout /t", src, rel)

    def test_windows_supervisor_has_single_instance_mutex(self):
        """webui-service.ps1 and watcher-service.ps1 must guard against
        multiple concurrent instances via a named mutex (Local\\ scope —
        Global\\ would look like cross-session malware persistence to AV)."""
        webui_svc = read("EasySkills维护工具/.engine/webui-service.ps1")
        watcher_svc = read("EasySkills维护工具/.engine/watcher-service.ps1")
        for src in (webui_svc, watcher_svc):
            self.assertIn("System.Threading.Mutex", src)
            self.assertIn("Local\\EasySkills", src)
            self.assertNotIn("Global\\EasySkills", src)

    def test_windows_webui_uses_supervisor_service(self):
        service = read("EasySkills维护工具/.engine/webui-service.ps1")
        self.assertIn("function Test-WebUIPort", service)
        self.assertIn("while ($true)", service)
        self.assertIn("webui.ps1", service)
        self.assertIn("-NoBrowser", service)

        # The supervisor script is referenced directly by install/watch and
        # by the Scheduled Task registration helper. install_windows.bat
        # delegates to watch.ps1 instead of referencing the supervisor directly.
        for rel in (
            "install.ps1",
            "EasySkills维护工具/.engine/watch.ps1",
            "EasySkills维护工具/.engine/deploy.ps1",
            "EasySkills维护工具/.engine/register-tasks.ps1",
        ):
            self.assertIn("webui-service.ps1", read(rel), rel)
        # install_windows.bat must hand off to watch.ps1 (which then registers
        # the Scheduled Tasks that ultimately invoke webui-service.ps1).
        self.assertIn("watch.ps1", read("install_windows.bat"))

        webui = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn("[switch]$NoBrowser", webui)
        # Browser auto-open must be skippable via either the -NoBrowser
        # switch (used by direct PS invocation) or the
        # EASYSKILLS_NO_BROWSER env var (used by the wscript launcher path
        # where passing a switch is awkward).
        self.assertIn("EASYSKILLS_NO_BROWSER", webui)
        self.assertRegex(webui, r"if \(-not \$SkipBrowser")

    def test_webui_stop_watcher_keeps_backend_running(self):
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        deploy_ps = read("EasySkills维护工具/.engine/deploy.ps1")
        unwatch_ps = read("EasySkills维护工具/.engine/unwatch.ps1")

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
        src = read("EasySkills维护工具/.engine/webui/index.html")
        self.assertIn("refreshEasySkillsToken", src)
        self.assertIn("res.status === 403", src)
        self.assertIn("retryOnForbidden", src)
        agent_update = src.split("async function saveCustomModalEdit()", 1)[1].split(
            "// --- Custom Agent Registration ---", 1
        )[0]
        self.assertIn("res.status === 403 && await refreshEasySkillsToken()", agent_update)

    def test_all_inline_ui_helpers_are_defined(self):
        src = read("EasySkills维护工具/.engine/webui/index.html")
        self.assertIn('data-es-action="copy-webui-url"', src)
        self.assertIn("case 'copy-webui-url': copyWebUiUrl()", src)
        self.assertIn("function copyWebUiUrl()", src)

    def test_macos_webui_launches_through_launchctl_with_loopback_url(self):
        deploy_src = read("EasySkills维护工具/.engine/deploy.sh")
        self.assertIn("com.easyskills.webui.manual", deploy_src)
        self.assertIn("start_new_session=True", deploy_src)
        self.assertIn("command -v python3", deploy_src)
        self.assertIn("http://127.0.0.1:6633", deploy_src)
        self.assertNotIn("nohup python3", deploy_src)

        start_src = read("EasySkills维护工具/.engine/launchers/macOS-启动.command")
        self.assertIn('exec bash "$(pwd)/deploy.sh" --webui', start_src)
        self.assertNotIn("pkill -f", start_src)

        for rel in ("install.sh", "install_mac.command"):
            src = read(rel)
            self.assertIn('bash "$PERM_DIR/EasySkills维护工具/.engine/deploy.sh" --webui', src, rel)
            self.assertIn("http://127.0.0.1:6633", src, rel)
            self.assertNotIn('open "http://127.0.0.1:6633"', src, rel)
            self.assertNotIn('xdg-open "http://127.0.0.1:6633"', src, rel)
            self.assertNotIn("nohup python3", src, rel)
            self.assertNotIn("launchctl submit", src, rel)

        self.assertIn("EASYSKILLS_NO_BROWSER=1", deploy_src)
        self.assertIn("lsof -tiTCP:6633 -sTCP:LISTEN", deploy_src)
        self.assertIn('[[ "$cmdline" == *"$SCRIPT_DIR/webui.py"* ]]', deploy_src)

        webui_src = read("EasySkills维护工具/.engine/webui.py")
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
        path = ROOT / "EasySkills维护工具/.engine" / "agents.json"
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
        for rel in ("EasySkills维护工具/.engine/deploy.sh", "EasySkills维护工具/.engine/deploy.ps1",
                    "EasySkills维护工具/.engine/webui.py", "EasySkills维护工具/.engine/webui.ps1"):
            src = read(rel)
            self.assertIn("agents.json", src, f"{rel} does not reference agents.json")
    def test_skill_sync_runs_for_empty_optional_rule_library(self):
        sh_src = read("EasySkills维护工具/.engine/deploy.sh")
        ps_src = read("EasySkills维护工具/.engine/deploy.ps1")
        self.assertNotIn("find \"$CENTRAL_DIR/instructions\"", sh_src)
        self.assertIn("Agent rule sync failed; skill links were still synchronized", sh_src)
        self.assertNotIn("$RuleFiles.Count -gt 0", ps_src)
        self.assertIn("Agent rule sync failed; skill junctions were still synchronized", ps_src)

    def test_powershell_rule_cleanup_allows_state_tracked_historical_targets(self):
        src = read("EasySkills维护工具/.engine/webui.ps1")
        cleanup = src.split("function Remove-InstructionsFromOne", 1)[1].split(
            "function Remove-RulesFromOne", 1
        )[0]
        self.assertIn("Get-InstructionStateEntry $PathStr", cleanup)
        self.assertIn("$KnownPath = [string]$StateTarget.path", cleanup)

    def test_powershell_mcp_version_requires_a_json_integer(self):
        src = read("EasySkills维护工具/.engine/webui.ps1")
        validation = src.split("function Test-MCPConfig", 1)[1].split(
            "function Get-MCPConfigObject", 1
        )[0]
        self.assertIn("$version -isnot [int] -and $version -isnot [long]", validation)
        self.assertNotIn("$version -isnot [double]", validation)

    def test_powershell_mcp_request_parser_preserves_nested_pscustomobjects(self):
        """PowerShell 7 must not parse MCP payloads as recursive hashtables.

        Test-MCPConfig and the MCP mutation helpers use PSObject.Properties on
        nested servers/profiles/env/headers objects.  ConvertFrom-Json
        -AsHashtable changes that contract only on PowerShell 7+, so the HTTP
        dispatcher must parse a PSCustomObject and convert only the top level
        to a dictionary for request routing.
        """
        src = read("EasySkills维护工具/.engine/webui.ps1")
        body_parser = src.split("$BodyData = @{}", 1)[1].split("if ($UrlPath -eq \"/api/sync\")", 1)[0]
        self.assertIn("$PsObj = $Json | ConvertFrom-Json", body_parser)
        self.assertIn("$PsObj.PSObject.Properties | ForEach-Object", body_parser)
        self.assertNotIn("ConvertFrom-Json -AsHashtable", body_parser)

    def test_hardcoded_fallbacks_match_agents_json(self):
        """Hardcoded fallback arrays must contain the same paths as agents.json."""
        import json
        data = json.loads((ROOT / "EasySkills维护工具/.engine" / "agents.json").read_text(encoding="utf-8"))

        # Check deploy.sh fallback — names appear in case statements
        sh_src = read("EasySkills维护工具/.engine/deploy.sh")
        for agent in data["agents"]:
            name = agent["name"]
            self.assertIn(f'"{name}"', sh_src, f"deploy.sh fallback missing name: {name}")

        # Check deploy.ps1 fallback — paths appear in the targets array
        ps_src = read("EasySkills维护工具/.engine/deploy.ps1")
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
        src = read("EasySkills维护工具/.engine/webui.py")
        self.assertIn(".easyskills-token", src)
        self.assertIn("TOKEN_FILE", src)
        self.assertIn("def _load_or_create_token", src)
        # Token must be co-located with the installation, not in bare home
        self.assertIn("TOKEN_FILE = SCRIPT_DIR / \".easyskills-token\"", src)
        self.assertNotIn('TOKEN_FILE = Path.home() / ".easyskills-token"', src)

    def test_windows_webui_persists_token_to_file(self):
        """webui.ps1 must read/write a persistent token file."""
        src = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn(".easyskills-token", src)
        self.assertIn("Initialize-WebUIToken", src)
        token_fn = src.split("function Initialize-WebUIToken", 1)[1].split("\n}", 1)[0]
        self.assertIn("Local\\EasySkillsWebUIToken", token_fn)
        self.assertIn("Write-Utf8NoBom $TokenFile $New", token_fn)
        self.assertNotIn("Token file exists but could not be read", token_fn)

    # -------------------------------------------------------------------------
    # Rollback support
    # -------------------------------------------------------------------------

    def test_self_update_creates_backup_before_overwrite(self):
        """do_self_update must back up EasySkills维护工具/.engine atomically before overwriting."""
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn(".maintenance-bak", py_src)
        self.assertIn(".maintenance-bak", ps_src)
        # New atomic pattern: build in .new, then rename
        self.assertIn("EasySkills维护工具/.engine.new", py_src)
        self.assertIn("dest_maint.rename(backup_maint)", py_src)
        self.assertIn("new_maint_tmp.rename(dest_maint)", py_src)
        self.assertIn(".maintenance-bak/", read(".gitignore"))
        self.assertGreater(py_src.index("os.replace(readme_staged, readme_dest)"), py_src.index("new_maint_tmp.rename(dest_maint)"))
        self.assertGreater(ps_src.index("[System.IO.File]::Replace($ReadmeStaged"), ps_src.index("Move-Item -LiteralPath $NewMaintTmp -Destination $DestMaint"))
        self.assertIn("Move-Item -LiteralPath $DestMaint -Destination $BackupMaint", ps_src)
        self.assertIn("Move-Item -LiteralPath $BackupMaint -Destination $DestMaint", ps_src)
        self.assertNotIn('Rename-Item -Path $DestMaint -NewName ".maintenance-bak"', ps_src)
        self.assertNotIn('Rename-Item -Path $NewMaintTmp -NewName "EasySkills维护工具/.engine"', ps_src)
        self.assertNotIn('Rename-Item -Path $BackupMaint -NewName "EasySkills维护工具/.engine"', ps_src)
        self.assertNotIn('Rename-Item -Path $DestMaint -NewName "EasySkills维护工具/.engine.prev"', ps_src)
        self.assertLess(py_src.index("staged_script.chmod(0o755)"), py_src.index("dest_maint.rename(backup_maint)"))
        self.assertIn("Old backup snapshot cleanup failed", py_src)
        self.assertIn("Old backup snapshot cleanup failed", ps_src)
        self.assertIn("Documentation refresh failed", py_src)
        self.assertIn("Documentation refresh failed", ps_src)

    def test_rollback_endpoint_exists(self):
        """Both backends must expose /api/rollback."""
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn('"/api/rollback"', py_src)
        self.assertIn('"/api/rollback"', ps_src)
        self.assertIn("do_rollback", py_src)
        self.assertIn("Do-Rollback", ps_src)

    def test_rollback_ui_in_frontend(self):
        """Frontend must have rollback button and JS function."""
        html_src = read("EasySkills维护工具/.engine/webui/index.html")
        self.assertIn('id="btn-rollback"', html_src)
        self.assertIn("function performRollback", html_src)
        self.assertIn("t-rollback", html_src)

    def test_status_endpoint_reports_backup_existence(self):
        """Both backends must expose has_backup in /api/status."""
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn("has_backup", py_src)
        self.assertIn("has_backup", ps_src)

    def test_update_and_rollback_report_resync_failures(self):
        for src in (read("EasySkills维护工具/.engine/webui.py"), read("EasySkills维护工具/.engine/webui.ps1")):
            self.assertIn("sync_success", src)
            self.assertIn("agent re-sync failed", src)

    def test_update_and_rollback_keep_gateway_version_in_sync(self):
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        for src in (py_src, ps_src):
            self.assertIn("gateway_success", src)
            self.assertIn("does not match release tag", src)
            self.assertIn("Gateway update failed", src)
            self.assertIn("Gateway rollback failed", src)
        self.assertIn("_install_gateway_for_engine(dest_maint, src_root / \"gateway\")", py_src)
        self.assertIn("_install_gateway_for_engine(dest_maint)", py_src)
        self.assertIn("Install-MCPGatewayForEngine $DestMaint", ps_src)

    def test_successful_update_and_rollback_restart_backend_code(self):
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        sh_service = read("EasySkills维护工具/.engine/webui-service.sh")
        ps_service = read("EasySkills维护工具/.engine/webui-service.ps1")
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

    def test_rollback_restores_stranded_prev_before_later_failure(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            central = Path(tmp)
            backup = central / ".maintenance-bak"
            backup.mkdir()
            (backup / "backup.txt").write_text("rollback", encoding="utf-8")
            prev = central / "EasySkills维护工具" / ".engine.prev"
            prev.mkdir(parents=True)
            (prev / "current.txt").write_text("keep-current", encoding="utf-8")
            live = central / "EasySkills维护工具" / ".engine"

            with mock.patch.object(webui, "CENTRAL_DIR", central), \
                 mock.patch.object(webui, "CUSTOM_TARGETS_FILE", live / "custom-targets.txt"), \
                 mock.patch.object(webui, "DISABLED_TARGETS_FILE", live / "disabled-targets.txt"), \
                 mock.patch.object(webui, "TOKEN_FILE", live / ".easyskills-token"), \
                 mock.patch.object(webui.shutil, "copytree", side_effect=OSError("stop after recovery")):
                result = webui.do_rollback()

            self.assertFalse(result["success"])
            self.assertTrue((live / "current.txt").is_file())
            self.assertFalse(prev.exists())

    # -------------------------------------------------------------------------
    # Linux systemd support
    # -------------------------------------------------------------------------

    def test_systemd_unit_files_exist(self):
        """systemd service and path units must exist."""
        self.assertTrue((ROOT / "EasySkills维护工具/.engine/systemd/easyskills-watcher.service").exists())
        self.assertTrue((ROOT / "EasySkills维护工具/.engine/systemd/easyskills-watcher.path").exists())

    def test_watch_sh_handles_linux(self):
        """watch.sh must handle Linux with systemd."""
        src = read("EasySkills维护工具/.engine/watch.sh")
        self.assertIn("Linux", src)
        self.assertIn("systemctl", src)
        self.assertIn("initial EasySkills synchronization failed", src)
        self.assertIn("systemctl --user is-active --quiet", src)
        self.assertIn("easyskills-watcher.path", src)

    def test_watcher_installers_propagate_registration_failures(self):
        sh_src = read("EasySkills维护工具/.engine/watch.sh")
        ps_src = read("EasySkills维护工具/.engine/watch.ps1")
        self.assertIn("plutil -lint", sh_src)
        self.assertIn('launchctl print "$SERVICE_TARGET"', sh_src)
        self.assertIn("$LASTEXITCODE -ne 0", ps_src)
        self.assertIn('throw "Initial EasySkills synchronization failed', ps_src)
        self.assertIn("exit 1", ps_src.split("catch {", 1)[1])

    def test_unwatch_sh_handles_linux(self):
        """unwatch.sh must handle Linux with systemd."""
        src = read("EasySkills维护工具/.engine/unwatch.sh")
        self.assertIn("Linux", src)
        self.assertIn("systemctl", src)
        self.assertIn("one or more EasySkills watcher units are still active", src)
        self.assertIn("systemctl not found. Cannot uninstall watcher", src)

    def test_unwatch_sh_uses_installation_path_for_inflight_deploy(self):
        src = read("EasySkills维护工具/.engine/unwatch.sh")
        # Resolve deploy.sh from unwatch.sh's own installation directory. Do
        # not hardcode the user's home or retain an unused central-dir value.
        self.assertIn('local deploy_script="$SCRIPT_DIR/deploy.sh"', src)
        self.assertIn("find_inflight_deploy_pids", src)
        self.assertNotIn("$HOME/EasySkills", src)
        self.assertNotIn("[E]asySkills/EasySkills维护工具/.engine/deploy", src)

    def test_windows_unwatch_propagates_incomplete_cleanup(self):
        src = read("EasySkills维护工具/.engine/unwatch.ps1")
        self.assertIn("$HadErrors = $false", src)
        self.assertIn("Background processes are still running", src)
        self.assertIn("Uninstallation incomplete", src)
        self.assertIn("exit 1", src)

    # -------------------------------------------------------------------------
    # Code-quality contracts added by code review
    # -------------------------------------------------------------------------

    def test_self_update_verifies_download_integrity(self):
        """do_self_update must perform a SHA-256 double-download check."""
        py_src = read("EasySkills维护工具/.engine/webui.py")
        self.assertIn("_sha256_file", py_src)
        self.assertIn("import hashlib", py_src)
        self.assertIn("hmac.compare_digest(digest1, digest2)", py_src)
        self.assertIn("Integrity check failed", py_src)

    def test_python_self_update_bounds_download_and_validates_final_redirect(self):
        src = read("EasySkills维护工具/.engine/webui.py")
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

    def test_github_download_url_rejects_userinfo_and_non_default_ports(self):
        webui = load_python_webui_module()
        self.assertTrue(webui._is_github_download_url("https://github.com/RunhuaHuang/EasySkills/archive/test.tar.gz"))
        self.assertTrue(webui._is_github_download_url("https://github.com:443/RunhuaHuang/EasySkills/archive/test.tar.gz"))
        for unsafe in (
            "https://user@github.com/RunhuaHuang/EasySkills/archive/test.tar.gz",
            "https://github.com:444/RunhuaHuang/EasySkills/archive/test.tar.gz",
            "https://github.com.evil.example/RunhuaHuang/EasySkills/archive/test.tar.gz",
            "http://github.com/RunhuaHuang/EasySkills/archive/test.tar.gz",
        ):
            with self.subTest(url=unsafe):
                self.assertFalse(webui._is_github_download_url(unsafe))

    def test_self_update_rejects_archive_bombs_and_unsafe_zip_paths(self):
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn("max_members", py_src)
        self.assertIn("max_total_size", py_src)
        self.assertIn("extracted-size safety limit", py_src)
        self.assertIn("$Archive.Entries.Count", ps_src)
        self.assertIn("$ExpandedBytes", ps_src)
        self.assertIn("unsafe path", ps_src)
        self.assertIn("$Part.Contains(':')", ps_src)
        self.assertIn("Release archive exceeds the 100 MB safety limit", ps_src)
        self.assertIn("Integrity archive exceeds the 100 MB safety limit", ps_src)
        self.assertIn("function Save-BoundedWebFile", ps_src)
        self.assertGreaterEqual(ps_src.count("ResponseHeadersRead"), 1)
        self.assertIn("function Normalize-ZipPath", ps_src)
        self.assertIn("function Resolve-ZipVirtualPath", ps_src)
        self.assertIn("$Name.StartsWith('\\')", ps_src)
        self.assertIn("$Name.Replace('\\', '/')", ps_src)
        self.assertIn("$Target.StartsWith('\\')", ps_src)
        self.assertNotIn("$Name.StartsWith('\\\\')", ps_src)
        self.assertNotIn("$Name.Replace('\\\\', '/')", ps_src)
        self.assertNotIn("$Target.StartsWith('\\\\')", ps_src)
        self.assertIn("$UnixType", ps_src)
        self.assertIn("$Links", ps_src)
        self.assertIn("Assert-SafeZipArchive $ZipPath $ExtractDir", ps_src)
        self.assertLess(
            ps_src.index("Assert-SafeZipArchive $ZipPath $ExtractDir"),
            ps_src.index("Expand-Archive -Path $ZipPath"),
        )

        import tarfile

        member = tarfile.TarInfo("repo/large.bin")
        member.size = 5
        fake_tar = SimpleNamespace(getmembers=lambda: [member], extract=mock.Mock())
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaisesRegex(ValueError, "extracted-size safety limit"):
                webui._safe_extract_tar(fake_tar, td, max_total_size=4)
        fake_tar.extract.assert_not_called()

    def test_self_update_selects_one_valid_release_root_deterministically(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as td:
            extracted = Path(td)
            (extracted / "metadata").mkdir()
            valid = extracted / "EasySkills-release"
            (valid / "EasySkills维护工具" / ".engine").mkdir(parents=True)
            self.assertEqual(webui._find_release_root(extracted), valid)

            second = extracted / "EasySkills-other"
            (second / "EasySkills维护工具" / ".engine").mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, "multiple EasySkills source roots"):
                webui._find_release_root(extracted)

        with tempfile.TemporaryDirectory() as td:
            archive = Path(td) / "symlink-escape.tar.gz"
            destination = Path(td) / "extract"
            destination.mkdir()
            with tarfile.open(archive, "w:gz") as tf:
                link = tarfile.TarInfo("repo/link")
                link.type = tarfile.SYMTYPE
                link.linkname = "../../outside"
                tf.addfile(link)
                payload = b"escape"
                member = tarfile.TarInfo("repo/link/payload.txt")
                member.size = len(payload)
                tf.addfile(member, io.BytesIO(payload))
            with tarfile.open(archive, "r:gz") as tf:
                with self.assertRaisesRegex(ValueError, "unsafe link"):
                    webui._safe_extract_tar(tf, str(destination))
            self.assertFalse((Path(td) / "outside" / "payload.txt").exists())

        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn("$SourceRoots.Count -eq 0", ps_src)
        self.assertIn("$SourceRoots.Count -ne 1", ps_src)
        self.assertNotIn("Get-ChildItem -Path $ExtractDir -Directory | Select-Object -First 1", ps_src)

    def test_oversized_body_returns_413(self):
        """_body() must return None and do_POST must send 413 for oversized payloads."""
        py_src = read("EasySkills维护工具/.engine/webui.py")
        self.assertIn("return None  # Signal to caller: send 413", py_src)
        self.assertIn("self.send_response(413)", py_src)
        self.assertIn("body is None", py_src)
        self.assertIn("self.close_connection = True", py_src)
        oversized_branch = py_src.split("if length > 10 * 1024 * 1024", 1)[1].split(
            "if length < 0", 1
        )[0]
        self.assertNotIn("self.rfile.read", oversized_branch)

    def test_malformed_or_scalar_request_bodies_are_rejected_before_routing(self):
        webui = load_python_webui_module()

        for content_length, payload in (("invalid", b"{}"), ("-1", b""), ("1", b"["), ("4", b"null")):
            request = SimpleNamespace(
                headers={"Content-Length": content_length},
                rfile=io.BytesIO(payload),
                close_connection=False,
            )
            with self.subTest(content_length=content_length, payload=payload):
                self.assertIs(webui.Handler._body(request), webui._INVALID_REQUEST_BODY)
                self.assertTrue(request.close_connection)

        missing_length = SimpleNamespace(
            headers={},
            rfile=io.BytesIO(b"{}"),
            close_connection=False,
        )
        self.assertIs(webui.Handler._body(missing_length), webui._MISSING_CONTENT_LENGTH)
        self.assertTrue(missing_length.close_connection)

        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn("body is _INVALID_REQUEST_BODY", py_src)
        self.assertIn("body is _MISSING_CONTENT_LENGTH", py_src)
        self.assertIn("$PsObj -isnot [PSCustomObject]", ps_src)
        self.assertIn("JSON request body must be an object", ps_src)

    def test_agent_prefix_map_is_module_level_constant(self):
        """_AGENT_PREFIX_MAP must be defined at module level, not inside a function."""
        py_src = read("EasySkills维护工具/.engine/webui.py")
        self.assertIn("_AGENT_PREFIX_MAP", py_src)
        # Must not redefine it inside get_agent_name
        fn_body = py_src.split("def get_agent_name")[1].split("\ndef ")[0]
        self.assertNotIn("_AGENT_PREFIX_MAP = [", fn_body)

    def test_agent_root_does_not_treat_home_prefix_collisions_as_descendants(self):
        webui = load_python_webui_module()
        home = Path.home()
        outside = Path(str(home) + "-other") / "agent" / "skills"
        self.assertEqual(outside.parent, webui.get_agent_root(outside))
        self.assertEqual(home, webui.get_agent_root(home))

    def test_rollback_uses_atomic_rename(self):
        """do_rollback must use atomic rename not file-by-file copy."""
        py_src = read("EasySkills维护工具/.engine/webui.py")
        self.assertIn("EasySkills维护工具/.engine.rollback", py_src)
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

    def test_install_scripts_migrate_and_clean_legacy_maintenance(self):
        """Installers must migrate runtime config out of a legacy _maintenance
        install and remove the old tree so no stale watcher/engine survives."""
        sh_src = read("install.sh")
        ps_src = read("install.ps1")
        self.assertIn('LEGACY_MAINT="$PERM_DIR/_maintenance"', sh_src)
        self.assertIn('rm -rf "$PERM_DIR/_maintenance"', sh_src)
        self.assertIn('rm -rf "$PERM_DIR/_runtime"', sh_src)
        self.assertIn('$LegacyMaint = Join-Path $PermDir "_maintenance"', ps_src)
        self.assertIn('Remove-Item $LegacyMaint -Recurse -Force', ps_src)
        # $MaintDir already names the final live path. Re-pointing it to
        # .engine.new after Move-Item would make every later service path stale.
        self.assertNotIn("$MaintDir = $NewMaint", ps_src)
        self.assertIn('$NewCustomFile = Join-Path $NewMaint "custom-targets.txt"', ps_src)
        self.assertIn('Copy-Item $PreservedDisabled $NewDisabledFile -Force', ps_src)
        self.assertIn('Copy-Item $PreservedToken $NewTokenFile -Force', ps_src)

    def test_deploy_sh_central_resolved_fails_loudly(self):
        """central_resolved must fail loudly (return 1) if cd fails, not produce empty string."""
        sh_src = read("EasySkills维护工具/.engine/deploy.sh")
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

        script = ROOT / "EasySkills维护工具/.engine/deploy.sh"
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

    def test_unmap_reports_partial_cleanup_without_losing_disabled_state(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            central = root / "central"
            agent = root / "agent"
            disabled = root / "disabled.txt"
            central.mkdir()
            agent.mkdir()
            (central / "good").mkdir()
            (central / "bad").mkdir()
            good = agent / "good"
            bad = agent / "bad"
            good.symlink_to(central / "good", target_is_directory=True)
            bad.symlink_to(central / "bad", target_is_directory=True)

            original_unlink = Path.unlink

            def fail_one(path, *args, **kwargs):
                if Path(path).name == "bad":
                    raise OSError("simulated locked link")
                return original_unlink(path, *args, **kwargs)

            with mock.patch.object(webui, "CENTRAL_DIR", central), \
                 mock.patch.object(webui, "DISABLED_TARGETS_FILE", disabled), \
                 mock.patch.object(webui, "_iter_agent_skill_dirs", return_value=[agent]), \
                 mock.patch.object(Path, "unlink", fail_one):
                result = webui.do_unmap(str(agent))
                self.assertTrue(result["success"])
                self.assertTrue(result.get("partial"))
                self.assertFalse(good.exists())
                self.assertTrue(bad.is_symlink())
                self.assertIn(str(agent.resolve()), webui._get_disabled_targets())

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
        sh_src = read("EasySkills维护工具/.engine/deploy.sh")
        deploy_ps = read("EasySkills维护工具/.engine/deploy.ps1")
        webui_ps = read("EasySkills维护工具/.engine/webui.ps1")
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
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        html_src = read("EasySkills维护工具/.engine/webui/index.html")

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
        sh_src = read("EasySkills维护工具/.engine/deploy.sh")
        ps_src = read("EasySkills维护工具/.engine/deploy.ps1")

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
        ps_src = read("EasySkills维护工具/.engine/deploy.ps1")
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
        ps_src = read("EasySkills维护工具/.engine/deploy.ps1")
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
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
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
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
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
        ps_src = read("EasySkills维护工具/.engine/deploy.ps1")
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
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn("old_path = _normalize_local_path(old_skills_path)", py_src)
        self.assertIn("new_path = _normalize_local_path(skills_path)", py_src)
        self.assertIn("$OldPath = Normalize-AgentPath $OldSkillsPath", ps_src)
        # New targets are validated before being committed so files, the
        # central EasySkills directory, and its descendants can never become
        # Agent mapping targets.  The normalized value is taken from the
        # validation result rather than from the raw input.
        self.assertIn("$TargetValidation = Resolve-MappingTarget $SkillsPath", ps_src)
        self.assertIn("$NewPath = $TargetValidation.path", ps_src)
        self.assertIn("line_path_normalized = _normalize_local_path(line_path)", py_src)
        self.assertIn("$LinePathNormalized = Normalize-AgentPath $LinePath", ps_src)

    def test_update_agent_paths_rejects_file_and_central_targets_before_writing(self):
        """Changing an Agent path must reject unsafe targets atomically.

        A regular file cannot host skill links, while the EasySkills central
        directory (or one of its descendants) is the source tree and must
        never be treated as an Agent destination.  Rejection must happen
        before either custom-targets.txt or the per-Agent JSON is modified.
        """
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            central = root / "EasySkills"
            central.mkdir()
            old_skills = root / "agent" / "skills"
            instructions = root / "agent" / "AGENTS.md"
            instructions.parent.mkdir(parents=True)
            instructions.write_text("# instructions\n", encoding="utf-8")
            custom_targets = root / "custom-targets.txt"
            agent_paths = root / ".agent-paths.json"
            custom_targets.write_text(f"Test Agent={old_skills}\n", encoding="utf-8")
            agent_paths.write_text(
                json.dumps({"version": 1, "agents": [{
                    "name": "Test Agent",
                    "skills_path": str(old_skills),
                    "instructions_path": str(instructions),
                }]}) + "\n",
                encoding="utf-8",
            )
            original_targets = custom_targets.read_text(encoding="utf-8")
            original_config = agent_paths.read_text(encoding="utf-8")
            current = {
                "name": "Test Agent",
                "path": str(old_skills),
                "instructions_path": str(instructions),
                "mapped": False,
            }
            file_target = root / "not-a-directory"
            file_target.write_text("do not replace\n", encoding="utf-8")

            with mock.patch.object(webui, "CENTRAL_DIR", central), \
                 mock.patch.object(webui, "CUSTOM_TARGETS_FILE", custom_targets), \
                 mock.patch.object(webui, "AGENT_PATH_CONFIG_FILE", agent_paths), \
                 mock.patch.object(webui, "get_visible_agents", return_value=[current]), \
                 mock.patch.object(webui, "_remove_from_disabled_targets"), \
                 mock.patch.object(webui, "_add_to_disabled_targets"):
                for unsafe_target in (file_target, central, central / "nested"):
                    with self.subTest(target=str(unsafe_target)):
                        result = webui.update_agent_paths(
                            "Test Agent",
                            str(old_skills),
                            str(unsafe_target),
                            str(instructions),
                        )
                        self.assertFalse(result["success"])
                        self.assertEqual(original_targets, custom_targets.read_text(encoding="utf-8"))
                        self.assertEqual(original_config, agent_paths.read_text(encoding="utf-8"))

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

    def test_update_agent_paths_reports_disabled_state_write_failure(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old_skills = root / "old" / "skills"
            new_skills = root / "new" / "skills"
            instructions = root / "AGENTS.md"
            custom_targets = root / "custom-targets.txt"
            agent_paths = root / ".agent-paths.json"
            current = {
                "name": "Test Agent",
                "path": str(old_skills),
                "instructions_path": str(instructions),
                "mapped": False,
            }
            with mock.patch.object(webui, "CUSTOM_TARGETS_FILE", custom_targets), \
                 mock.patch.object(webui, "AGENT_PATH_CONFIG_FILE", agent_paths), \
                 mock.patch.object(webui, "get_visible_agents", return_value=[current]), \
                 mock.patch.object(webui, "_add_to_disabled_targets", return_value=False), \
                 mock.patch.object(webui, "_remove_from_disabled_targets", return_value=True):
                result = webui.update_agent_paths(
                    "Test Agent",
                    str(old_skills),
                    str(new_skills),
                    str(instructions),
                )

            self.assertFalse(result["success"])
            self.assertTrue(result.get("partial"))
            self.assertIn("disabled-target state", result["message"])

    def test_update_agent_paths_keeps_old_disabled_state_when_cleanup_fails(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old_skills = root / "old" / "skills"
            new_skills = root / "new" / "skills"
            instructions = root / "AGENTS.md"
            custom_targets = root / "custom-targets.txt"
            agent_paths = root / ".agent-paths.json"
            current = {
                "name": "Test Agent",
                "path": str(old_skills),
                "instructions_path": str(instructions),
                "mapped": True,
            }
            remove_state = mock.Mock(return_value=True)
            with mock.patch.object(webui, "CUSTOM_TARGETS_FILE", custom_targets), \
                 mock.patch.object(webui, "AGENT_PATH_CONFIG_FILE", agent_paths), \
                 mock.patch.object(webui, "get_visible_agents", return_value=[current]), \
                 mock.patch.object(webui, "do_map", return_value={"success": True}), \
                 mock.patch.object(webui, "do_unmap", return_value={"success": False, "message": "state write failed"}), \
                 mock.patch.object(webui, "_remove_from_disabled_targets", remove_state), \
                 mock.patch.object(webui, "_add_to_disabled_targets", return_value=True):
                result = webui.update_agent_paths(
                    "Test Agent",
                    str(old_skills),
                    str(new_skills),
                    str(instructions),
                )

            self.assertTrue(result["success"])
            self.assertTrue(result.get("partial"))
            self.assertIn("could not be fully removed", result["message"])
            remove_state.assert_not_called()

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

        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
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
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
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

        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        html_src = read("EasySkills维护工具/.engine/webui/index.html")
        self.assertIn("def register_custom_agent", py_src)
        self.assertIn("function Register-CustomAgent", ps_src)
        self.assertIn("skills_path: skillsPath", html_src)
        self.assertIn("instructions_path: instructionsPath", html_src)

    def test_custom_agent_registration_rejects_file_and_central_targets(self):
        webui = load_python_webui_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            central = root / "EasySkills"
            central.mkdir()
            file_target = root / "not-a-directory"
            file_target.write_text("do not map\n", encoding="utf-8")
            instructions = root / "AGENTS.md"
            instructions.write_text("# instructions\n", encoding="utf-8")
            with mock.patch.object(webui, "CENTRAL_DIR", central), \
                 mock.patch.object(webui, "run_deploy") as run_deploy:
                for target in (file_target, central, central / "nested"):
                    with self.subTest(target=str(target)):
                        result = webui.register_custom_agent(str(target), str(instructions))
                        self.assertFalse(result["success"])
                run_deploy.assert_not_called()

        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn("validated_skills_path, mapping_error = _validate_mapping_target(skills_path)", py_src)
        self.assertIn("$SkillsValidation = Resolve-MappingTarget $SkillsPath", ps_src)

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

        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
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

        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn("$Exists = (Test-Path $T.Path -PathType Leaf)", ps_src)

    def test_windows_process_termination_scoped_to_install_path(self):
        """install.ps1, unwatch.ps1, register-tasks.ps1 must scope process
        matching to THIS installation's path, not a bare script-name glob.

        A bare `*watcher-service.ps1*` / `*webui-service.ps1*` matches every
        EasySkills install on the machine — cross-killing a second install's
        services. The fix (already applied to webui.ps1 / install.ps1) is to
        anchor the glob to the script's own directory.
        """
        for rel in ("EasySkills维护工具/.engine/unwatch.ps1", "EasySkills维护工具/.engine/register-tasks.ps1"):
            ps_src = read(rel)
            # No bare (un-scoped) service-script globs may remain.
            self.assertNotIn("'*webui-service.ps1*'", ps_src,
                             f"{rel}: webui-service glob must be scoped to $ScriptDir")
            self.assertNotIn("'*watcher-service.ps1*'", ps_src,
                             f"{rel}: watcher-service glob must be scoped to $ScriptDir")

    def test_unix_webui_supervisor_uses_literal_process_path_matching(self):
        src = read("EasySkills维护工具/.engine/webui-service.sh")
        self.assertIn("ps -axo pid=,comm=,command=", src)
        self.assertIn('case "$cmdline" in', src)
        self.assertIn('*"$WEBUI_SCRIPT"*)', src)
        self.assertNotIn('pgrep -f "${pattern}"', src)

    def test_webui_sets_clickjacking_and_sniffing_security_headers(self):
        """Both WebUI backends must send X-Content-Type-Options and X-Frame-Options.

        The index page embeds the auth token in a <meta> tag, so it must not be
        framable by any other (even loopback) origin.
        """
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
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
        data = json.loads(read("EasySkills维护工具/.engine/agents.json"))
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
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")

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
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
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

        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
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

        html_src = read("EasySkills维护工具/.engine/webui/index.html")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
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

        self.assertIn("function Write-Utf8Atomic", read("EasySkills维护工具/.engine/webui.ps1"))

    def test_disabled_target_updates_are_atomic(self):
        src = read("EasySkills维护工具/.engine/webui.py")
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

    def test_managed_block_inject_strips_duplicate_legacy_blocks(self):
        """A file containing a second pasted managed block must be collapsed to
        a single clean block on the next write. Previously count=1 left the
        duplicate permanently stuck and unmanageable from the WebUI."""
        webui = load_python_webui_module()
        existing = (
            "# notes\n"
            f"{webui.EASY_SKILLS_BEGIN}\nold\n{webui.EASY_SKILLS_END}\n\n"
            f"{webui.EASY_SKILLS_BEGIN}\npasted duplicate\n{webui.EASY_SKILLS_END}\n"
        )
        block = f"{webui.EASY_SKILLS_BEGIN}\nfresh\n{webui.EASY_SKILLS_END}"
        result = webui._inject_managed_block(existing, block)
        self.assertEqual(result.count(webui.EASY_SKILLS_BEGIN), 1)
        self.assertEqual(result.count(webui.EASY_SKILLS_END), 1)
        self.assertIn("fresh", result)
        self.assertNotIn("pasted duplicate", result)
        self.assertIn("# notes", result)

    def test_managed_block_strip_does_not_eat_handwritten_content_after_orphan_begin(self):
        """An orphan begin marker (no matching end) must not cause the user's
        plain-text content between it and the real block to be deleted. The
        stack-pairing purge keeps that text; a naive begin.*?end regex would
        swallow it."""
        webui = load_python_webui_module()
        existing = (
            "# my notes\n"
            f"{webui.EASY_SKILLS_BEGIN}\n"
            "handwritten comment with no end marker\n"
            f"{webui.EASY_SKILLS_BEGIN}\nreal rule\n{webui.EASY_SKILLS_END}\n"
        )
        remaining = webui._strip_managed_block(existing)
        self.assertIn("# my notes", remaining)
        self.assertIn("handwritten comment with no end marker", remaining)
        self.assertNotIn("real rule", remaining)
        self.assertNotIn(webui.EASY_SKILLS_BEGIN, remaining)
        self.assertNotIn(webui.EASY_SKILLS_END, remaining)

    def test_managed_block_purge_has_mirror_in_powershell_backend(self):
        """webui.ps1 must ship the same stack-pairing purge as the Python
        backend so duplicate/orphan-marker handling is symmetric."""
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn("function Purge-AllManagedMarkers", ps_src)
        self.assertIn("function Inject-ManagedBlock", ps_src)
        self.assertIn("function Strip-ManagedBlock", ps_src)
        # Strip/Inject must delegate to the purge, not use a lone count=1 regex.
        self.assertIn("Purge-AllManagedMarkers $Existing", ps_src)
        self.assertIn("Purge-AllManagedMarkers $Content", ps_src)

    def test_instructions_name_validation_blocks_traversal(self):
        """Rule filenames must be validated to prevent path traversal (e.g.
        ../../etc/passwd.md). Both backends must reject '/', '\\', and null.
        """
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
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
        html_src = read("EasySkills维护工具/.engine/webui/index.html")
        self.assertIn('data-target="instructions"', html_src)
        self.assertIn('id="instructions"', html_src)
        self.assertIn('function renderInstructions', html_src)
        self.assertIn("function writeInstructions", html_src)
        self.assertIn("function removeInstructions", html_src)
        self.assertIn("function openRuleEditor", html_src)
        # i18n keys in both languages
        self.assertIn("'t-instructions'", html_src)

    def test_frontend_surfaces_degraded_mutation_results(self):
        html_src = read("EasySkills维护工具/.engine/webui/index.html")
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn("data.partial", html_src)
        self.assertIn("data.sync_success === false", html_src)
        self.assertIn("data.gateway_success === false", html_src)
        self.assertIn("degraded ? 'warning' : 'success'", html_src)
        self.assertIn('result["partial"] = True', py_src)
        self.assertIn("$Result.partial = $true", ps_src)

    def test_dashboard_exposes_rule_library_and_agent_coverage(self):
        py_src = read("EasySkills维护工具/.engine/webui.py")
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        html_src = read("EasySkills维护工具/.engine/webui/index.html")
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
        self.assertIn('data-es-action="navigate" data-section="instructions"', html_src)
        self.assertIn("case 'navigate': navigateToSection(trigger.dataset.section)", html_src)

    # -------------------------------------------------------------------------
    # Self-update / rollback: host allowlist + rename-recovery (Fix C/D/E)
    # -------------------------------------------------------------------------

    def test_webui_ps1_self_update_validates_download_host(self):
        """webui.ps1 Run-SelfUpdate must reject download URLs whose host is not
        a trusted GitHub delivery host, mirroring webui.py's
        _is_github_download_url / _GITHUB_TARBALL_HOSTS."""
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        self.assertIn("$TrustedDownloadHosts", ps_src)
        self.assertIn("objects.githubusercontent.com", ps_src)
        self.assertIn("Update rejected: download host is not a trusted GitHub host", ps_src)
        self.assertIn("download redirected to an untrusted host", ps_src)
        self.assertIn("UserInfo", ps_src)
        self.assertIn("IsDefaultPort", ps_src)
        self.assertGreaterEqual(ps_src.count("Save-BoundedWebFile"), 3)
        self.assertIn("$Response.RequestMessage.RequestUri", ps_src)

    def test_webui_py_self_update_rollback_undoes_first_rename(self):
        """do_self_update rollback must UNDO the current->.bak rotation
        (restore the live version to its original place) when the second
        rename fails — it must NOT rmtree the backup, which would destroy the
        currently-running version."""
        py_src = read("EasySkills维护工具/.engine/webui.py")
        rollback_fn = py_src.split("def do_self_update")[1].split("\ndef ")[0]
        rollback_block = rollback_fn.split("except Exception:")[1] if "except Exception:" in rollback_fn else ""
        # The recovery must rename .bak back to EasySkills维护工具/.engine (undo), not
        # rmtree the backup (which would destroy the current version).
        self.assertIn("backup_maint.rename(dest_maint)", rollback_block,
                      "rollback must undo current->.bak by renaming back")
        # The destructive rmtree of backup_maint must NOT be in the rollback.
        self.assertNotIn("shutil.rmtree(backup_maint)", rollback_block,
                         "rollback must not destroy the current version in .bak")

    def test_webui_py_rollback_reconciles_prev_without_destroying_recovery(self):
        """A stranded .engine.prev must be restored when the live path is absent,
        not unconditionally deleted before the next rollback."""
        py_src = read("EasySkills维护工具/.engine/webui.py")
        rollback_fn = py_src.split("def do_rollback")[1].split("\ndef ")[0]
        self.assertIn("if dest_maint.exists():", rollback_fn)
        self.assertIn("prev.rename(dest_maint)", rollback_fn,
                      "rollback must restore current version from .prev on failure")

    def test_webui_ps1_rollback_reconciles_prev_and_recovers(self):
        """PowerShell Do-Rollback must preserve the same recovery invariant."""
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
        rollback_fn = ps_src.split("function Do-Rollback")[1].split("\nfunction ")[0]
        self.assertIn("if (Test-Path $DestMaint)", rollback_fn)
        self.assertIn("Rename-Item -LiteralPath $Prev", rollback_fn)
        self.assertRegex(rollback_fn, r'Rename-Item -LiteralPath \$Prev -NewName "\.engine"',
                         "Do-Rollback must restore from .prev on failure")

    # -------------------------------------------------------------------------
    # Run-DeployCommand: async reads prevent deadlock (Fix F)
    # -------------------------------------------------------------------------

    def test_webui_ps1_deploy_command_reads_streams_asynchronously(self):
        """Run-DeployCommand must read stdout/stderr asynchronously
        (ReadToEndAsync) so the 30s timeout actually works. Synchronous
        ReadToEnd on both streams deadlocks when the child fills the pipe
        buffer on one stream while we block reading the other."""
        ps_src = read("EasySkills维护工具/.engine/webui.ps1")
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
        src = read("EasySkills维护工具/.engine/webui.py")
        self.assertIn("fcntl.flock", src)
        self.assertIn("TOKEN_FILE.name + \".lock\"", src)
        self.assertIn("os.replace(temp_path, TOKEN_FILE)", src)


if __name__ == "__main__":
    unittest.main()
