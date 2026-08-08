package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

const CurrentVersion = 1

var identifierRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

// Config is the single, portable EasySkills MCP configuration format.
// Credentials are intentionally plain strings: EasySkills is a local,
// single-user tool and protects the file with owner-only permissions.
type Config struct {
	Version  int                     `json:"version"`
	Servers  map[string]ServerConfig `json:"servers"`
	Profiles map[string]Profile      `json:"profiles,omitempty"`
}

type ServerConfig struct {
	Enabled               *bool             `json:"enabled,omitempty"`
	Required              bool              `json:"required,omitempty"`
	Transport             string            `json:"transport"`
	Command               string            `json:"command,omitempty"`
	Args                  []string          `json:"args,omitempty"`
	Cwd                   string            `json:"cwd,omitempty"`
	Env                   map[string]string `json:"env,omitempty"`
	URL                   string            `json:"url,omitempty"`
	Headers               map[string]string `json:"headers,omitempty"`
	StartupTimeoutSeconds int               `json:"startup_timeout_seconds,omitempty"`
	ToolTimeoutSeconds    int               `json:"tool_timeout_seconds,omitempty"`
	EnabledTools          []string          `json:"enabled_tools,omitempty"`
	DisabledTools         []string          `json:"disabled_tools,omitempty"`
}

type Profile struct {
	Servers       []string `json:"servers,omitempty"`
	EnabledTools  []string `json:"enabled_tools,omitempty"`
	DisabledTools []string `json:"disabled_tools,omitempty"`
}

func boolPtr(v bool) *bool { return &v }

func Default() *Config {
	return &Config{
		Version: CurrentVersion,
		Servers: map[string]ServerConfig{},
		Profiles: map[string]Profile{
			"default": {Servers: []string{"*"}},
		},
	}
}

func DefaultPath() string {
	if path := strings.TrimSpace(os.Getenv("EASYSKILLS_MCP_CONFIG")); path != "" {
		return expandHome(path)
	}
	if exe, err := os.Executable(); err == nil {
		// Installed layout: EasySkills/.runtime/easyskills-mcp (or the legacy
		// EasySkills/_runtime/ layout from before the directory rename).
		binDir := filepath.Dir(exe)
		if filepath.Base(binDir) == ".runtime" || filepath.Base(binDir) == "_runtime" {
			return filepath.Join(filepath.Dir(binDir), "mcp", "servers.json")
		}
	}
	if cwd, err := os.Getwd(); err == nil {
		candidate := filepath.Join(cwd, "mcp", "servers.json")
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join("EasySkills", "mcp", "servers.json")
	}
	return filepath.Join(home, "EasySkills", "mcp", "servers.json")
}

func expandHome(path string) string {
	if path == "~" {
		if home, err := os.UserHomeDir(); err == nil {
			return home
		}
	}
	if strings.HasPrefix(path, "~/") || strings.HasPrefix(path, `~\`) {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, path[2:])
		}
	}
	return path
}

func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg Config
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&cfg); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			err = errors.New("multiple JSON values")
		}
		return nil, fmt.Errorf("parse %s: trailing data: %w", path, err)
	}
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func Save(path string, cfg *Config) error {
	if err := cfg.Validate(); err != nil {
		return err
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(dir, 0o700); err != nil && !errors.Is(err, os.ErrPermission) {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".servers-*.json")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := replaceFile(tmpName, path); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}

func (c *Config) Validate() error {
	if c.Version != CurrentVersion {
		return fmt.Errorf("unsupported config version %d (expected %d)", c.Version, CurrentVersion)
	}
	if c.Servers == nil {
		return errors.New("servers must be an object")
	}
	var problems []string
	for name, server := range c.Servers {
		if !identifierRE.MatchString(name) {
			problems = append(problems, fmt.Sprintf("server %q has an invalid name", name))
		}
		transport := normalizeTransport(server.Transport)
		switch transport {
		case "stdio":
			if strings.TrimSpace(server.Command) == "" {
				problems = append(problems, fmt.Sprintf("server %q: command is required for stdio", name))
			}
		case "http", "sse":
			parsed, err := url.Parse(server.URL)
			if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
				problems = append(problems, fmt.Sprintf("server %q: a valid http(s) url is required", name))
			}
		default:
			problems = append(problems, fmt.Sprintf("server %q: transport must be stdio, http, streamable-http, or sse", name))
		}
		if server.StartupTimeoutSeconds < 0 || server.StartupTimeoutSeconds > 600 {
			problems = append(problems, fmt.Sprintf("server %q: startup_timeout_seconds must be 0..600", name))
		}
		if server.ToolTimeoutSeconds < 0 || server.ToolTimeoutSeconds > 3600 {
			problems = append(problems, fmt.Sprintf("server %q: tool_timeout_seconds must be 0..3600", name))
		}
	}
	for name, profile := range c.Profiles {
		if !identifierRE.MatchString(name) {
			problems = append(problems, fmt.Sprintf("profile %q has an invalid name", name))
		}
		for _, selector := range profile.Servers {
			if selector == "*" {
				continue
			}
			if _, ok := c.Servers[selector]; !ok {
				problems = append(problems, fmt.Sprintf("profile %q references unknown server %q", name, selector))
			}
		}
	}
	if len(problems) > 0 {
		sort.Strings(problems)
		return errors.New(strings.Join(problems, "; "))
	}
	return nil
}

func normalizeTransport(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "streamable-http", "streamable_http":
		return "http"
	default:
		return strings.ToLower(strings.TrimSpace(value))
	}
}

func (s ServerConfig) NormalizedTransport() string { return normalizeTransport(s.Transport) }

func (s ServerConfig) IsEnabled() bool { return s.Enabled == nil || *s.Enabled }

func (s ServerConfig) StartupTimeout() int {
	if s.StartupTimeoutSeconds == 0 {
		return 20
	}
	return s.StartupTimeoutSeconds
}

func (s ServerConfig) ToolTimeout() int {
	if s.ToolTimeoutSeconds == 0 {
		return 60
	}
	return s.ToolTimeoutSeconds
}

func (c *Config) SelectedServers(profileName string) (map[string]ServerConfig, Profile, error) {
	if profileName == "" {
		profileName = "default"
	}
	profile, exists := c.Profiles[profileName]
	if len(c.Profiles) == 0 && profileName == "default" {
		profile = Profile{Servers: []string{"*"}}
		exists = true
	}
	if !exists {
		return nil, Profile{}, fmt.Errorf("profile %q does not exist", profileName)
	}
	selected := make(map[string]ServerConfig)
	all := len(profile.Servers) == 0
	for _, name := range profile.Servers {
		if name == "*" {
			all = true
		}
	}
	for name, server := range c.Servers {
		if !server.IsEnabled() {
			continue
		}
		if all || contains(profile.Servers, name) {
			selected[name] = server
		}
	}
	return selected, profile, nil
}

func contains(values []string, value string) bool {
	for _, item := range values {
		if item == value {
			return true
		}
	}
	return false
}
