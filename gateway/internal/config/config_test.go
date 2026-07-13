package config

import (
	"os"
	"path/filepath"
	"runtime"
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
