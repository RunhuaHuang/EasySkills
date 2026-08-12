package config

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestValidateAndSelectDefaultProfile(t *testing.T) {
	cfg := &Config{
		Version: 1,
		Servers: map[string]ServerConfig{
			"local":  {Transport: "stdio", Command: "example"},
			"remote": {Transport: "streamable-http", URL: "https://example.com/mcp"},
		},
		Profiles: map[string]Profile{"default": {Servers: []string{"local"}}},
	}
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
	selected, _, err := cfg.SelectedServers("default")
	if err != nil {
		t.Fatal(err)
	}
	if len(selected) != 1 {
		t.Fatalf("got %d selected servers, want 1", len(selected))
	}
	if _, ok := selected["local"]; !ok {
		t.Fatal("local server was not selected")
	}
}

func TestSaveUsesOwnerOnlyPermissions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "mcp", "servers.json")
	cfg := Default()
	if err := Save(path, cfg); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" {
		if got := info.Mode().Perm(); got != 0o600 {
			t.Fatalf("permissions = %o, want 600", got)
		}
	}
	if _, err := Load(path); err != nil {
		t.Fatal(err)
	}
}

func TestRejectsUnknownFields(t *testing.T) {
	path := filepath.Join(t.TempDir(), "servers.json")
	data := []byte(`{"version":1,"servers":{},"surprise":true}`)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err == nil {
		t.Fatal("Load succeeded for unknown field")
	}
}

func TestRejectsTrailingJSON(t *testing.T) {
	path := filepath.Join(t.TempDir(), "servers.json")
	data := []byte(`{"version":1,"servers":{}} {"version":1,"servers":{}}`)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err == nil {
		t.Fatal("Load succeeded with a second JSON value")
	}
}

func TestLoadAndSaveRejectOversizedConfigurations(t *testing.T) {
	path := filepath.Join(t.TempDir(), "servers.json")
	if err := os.WriteFile(path, make([]byte, MaxConfigBytes+1), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err == nil || !strings.Contains(err.Error(), "1 MB") {
		t.Fatalf("oversized Load error = %v", err)
	}

	cfg := Default()
	cfg.Servers["large"] = ServerConfig{
		Transport: "stdio",
		Command:   "example",
		Args:      []string{strings.Repeat("x", MaxConfigBytes)},
	}
	if err := Save(path, cfg); err == nil || !strings.Contains(err.Error(), "1 MB") {
		t.Fatalf("oversized Save error = %v", err)
	}
}

func TestResolveRuntimeReferences(t *testing.T) {
	t.Setenv("EASYSKILLS_TEST_TOKEN", "secret-token")
	t.Setenv("EASYSKILLS_TEST_FLAG", "enabled")
	server := ServerConfig{
		Transport: "http",
		URL:       "https://example.com/mcp",
		Env: map[string]string{
			"TOKEN":   "${env:EASYSKILLS_TEST_TOKEN}",
			"LITERAL": "$${env:EASYSKILLS_TEST_TOKEN}",
		},
		Headers: map[string]string{
			"Authorization": "Bearer ${env:EASYSKILLS_TEST_TOKEN}",
			"X-Feature":     "prefix-${env:EASYSKILLS_TEST_FLAG}-suffix",
		},
	}
	resolved, err := server.ResolveRuntime()
	if err != nil {
		t.Fatal(err)
	}
	if got := resolved.Env["TOKEN"]; got != "secret-token" {
		t.Fatalf("resolved TOKEN = %q", got)
	}
	if got := resolved.Env["LITERAL"]; got != "${env:EASYSKILLS_TEST_TOKEN}" {
		t.Fatalf("escaped literal = %q", got)
	}
	if got := resolved.Headers["Authorization"]; got != "Bearer secret-token" {
		t.Fatalf("resolved Authorization = %q", got)
	}
	if got := resolved.Headers["X-Feature"]; got != "prefix-enabled-suffix" {
		t.Fatalf("resolved X-Feature = %q", got)
	}
	if server.Env["TOKEN"] != "${env:EASYSKILLS_TEST_TOKEN}" {
		t.Fatal("ResolveRuntime mutated the persisted server configuration")
	}
}

func TestResolveRuntimeRejectsMissingOrMalformedReference(t *testing.T) {
	os.Unsetenv("EASYSKILLS_MISSING_TOKEN")
	if _, err := ResolveRuntimeValue("${env:EASYSKILLS_MISSING_TOKEN}"); err == nil {
		t.Fatal("missing environment variable was accepted")
	}
	cfg := &Config{
		Version: CurrentVersion,
		Servers: map[string]ServerConfig{
			"remote": {
				Transport: "http",
				URL:       "https://example.com/mcp",
				Headers:   map[string]string{"Authorization": "${env:bad-name}"},
			},
		},
	}
	if err := cfg.Validate(); err == nil {
		t.Fatal("malformed environment reference was accepted")
	}
}

func TestRuntimeReferenceParserHandlesEscapesAndMarkerLikeInput(t *testing.T) {
	value := "$${env:NOT-A-REFERENCE}:\x00EASYSKILLS_ESCAPED_ENV_REFERENCE\x00"
	resolved, err := ResolveRuntimeValue(value)
	if err != nil {
		t.Fatal(err)
	}
	if resolved != "${env:NOT-A-REFERENCE}:\x00EASYSKILLS_ESCAPED_ENV_REFERENCE\x00" {
		t.Fatalf("resolved literal = %q", resolved)
	}

	for _, malformed := range []string{"${env:}", "${env:9TOKEN}", "${env:BAD-NAME}", "${env:UNCLOSED"} {
		t.Run(malformed, func(t *testing.T) {
			if _, err := ResolveRuntimeValue(malformed); err == nil {
				t.Fatalf("malformed reference %q was accepted", malformed)
			}
		})
	}
}

func TestResolveRuntimeMapReportsMissingVariablesDeterministically(t *testing.T) {
	os.Unsetenv("EASYSKILLS_MISSING_ALPHA")
	os.Unsetenv("EASYSKILLS_MISSING_ZULU")
	server := ServerConfig{
		Env: map[string]string{
			"ZULU":  "${env:EASYSKILLS_MISSING_ZULU}",
			"ALPHA": "${env:EASYSKILLS_MISSING_ALPHA}",
		},
	}
	_, err := server.ResolveRuntime()
	if err == nil {
		t.Fatal("missing variables were accepted")
	}
	if got := err.Error(); got != `env "ALPHA": environment variable "EASYSKILLS_MISSING_ALPHA" is not set` {
		t.Fatalf("error = %q", got)
	}
}

func TestValidateRejectsUnsafeMapKeysValuesAndToolPatterns(t *testing.T) {
	cfg := &Config{
		Version: CurrentVersion,
		Servers: map[string]ServerConfig{
			"unsafe": {
				Transport:     "stdio",
				Command:       "example",
				Env:           map[string]string{"BAD=NAME": "value"},
				Headers:       map[string]string{"Bad Header": "line1\nline2"},
				DisabledTools: []string{"secret["},
			},
		},
		Profiles: map[string]Profile{
			"default": {Servers: []string{"*"}, EnabledTools: []string{"unsafe.["}},
		},
	}
	err := cfg.Validate()
	if err == nil {
		t.Fatal("unsafe MCP configuration was accepted")
	}
	message := err.Error()
	for _, expected := range []string{"invalid variable name", "invalid HTTP field name", "invalid control characters", "invalid pattern"} {
		if !strings.Contains(message, expected) {
			t.Fatalf("validation error %q does not contain %q", message, expected)
		}
	}
}

func TestValidateRejectsCredentialsEmbeddedInHTTPURL(t *testing.T) {
	cfg := &Config{
		Version: CurrentVersion,
		Servers: map[string]ServerConfig{
			"remote": {
				Transport: "http",
				URL:       "https://user:secret@example.com/mcp",
			},
		},
	}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "valid http(s) url") {
		t.Fatalf("credential-bearing URL was accepted: %v", err)
	}
}

func TestValidateRejectsInvalidHTTPPorts(t *testing.T) {
	for _, endpoint := range []string{
		"https://example.com:/mcp",
		"https://example.com:0/mcp",
		"https://example.com:65536/mcp",
		"https://example.com:bad/mcp",
		"https://exa mple.com/mcp",
		"https://example.com\\mcp",
		" https://example.com/mcp",
		"https://example.com/mcp ",
	} {
		t.Run(endpoint, func(t *testing.T) {
			cfg := &Config{
				Version: CurrentVersion,
				Servers: map[string]ServerConfig{
					"remote": {Transport: "http", URL: endpoint},
				},
			}
			if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "valid http(s) url") {
				t.Fatalf("invalid port was accepted: %v", err)
			}
		})
	}
}

func TestValidateAcceptsCaseInsensitiveHTTPScheme(t *testing.T) {
	cfg := &Config{
		Version: CurrentVersion,
		Servers: map[string]ServerConfig{
			"remote": {Transport: "http", URL: "HTTPS://EXAMPLE.COM/mcp"},
		},
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("uppercase HTTP scheme was rejected: %v", err)
	}
}

func TestLoadRejectsExplicitNullTypedFields(t *testing.T) {
	cases := []struct {
		name string
		json string
	}{
		{"profiles", `{"version":1,"servers":{},"profiles":null}`},
		{"server", `{"version":1,"servers":{"remote":null}}`},
		{"profile", `{"version":1,"servers":{},"profiles":{"default":null}}`},
		{"enabled", `{"version":1,"servers":{"remote":{"transport":"stdio","command":"x","enabled":null}}}`},
		{"required", `{"version":1,"servers":{"remote":{"transport":"stdio","command":"x","required":null}}}`},
		{"cwd", `{"version":1,"servers":{"remote":{"transport":"stdio","command":"x","cwd":null}}}`},
		{"startup_timeout_seconds", `{"version":1,"servers":{"remote":{"transport":"stdio","command":"x","startup_timeout_seconds":null}}}`},
		{"tool_timeout_seconds", `{"version":1,"servers":{"remote":{"transport":"stdio","command":"x","tool_timeout_seconds":null}}}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			file := filepath.Join(t.TempDir(), "servers.json")
			if err := os.WriteFile(file, []byte(tc.json), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := Load(file); err == nil {
				t.Fatalf("Load accepted explicit null for %s", tc.name)
			}
		})
	}
}

func TestResolveRuntimeRejectsHeaderInjectionFromEnvironment(t *testing.T) {
	t.Setenv("EASYSKILLS_BAD_HEADER", "safe\r\ninjected: value")
	server := ServerConfig{
		Headers: map[string]string{"Authorization": "${env:EASYSKILLS_BAD_HEADER}"},
	}
	if _, err := server.ResolveRuntime(); err == nil {
		t.Fatal("header injection from an environment reference was accepted")
	}
}
