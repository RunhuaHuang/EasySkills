package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

const CurrentVersion = 1
const MaxConfigBytes = 1024 * 1024

var identifierRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)
var envNameRE = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

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
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, MaxConfigBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > MaxConfigBytes {
		return nil, fmt.Errorf("parse %s: configuration exceeds the 1 MB limit", path)
	}
	if err := rejectExplicitNullFields(data); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
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
	if len(data) > MaxConfigBytes {
		return errors.New("configuration exceeds the 1 MB limit")
	}
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
			if strings.ContainsRune(server.Command, '\x00') {
				problems = append(problems, fmt.Sprintf("server %q: command must not contain NUL", name))
			}
		case "http", "sse":
			if !validHTTPURL(server.URL) {
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
		if strings.ContainsRune(server.Cwd, '\x00') {
			problems = append(problems, fmt.Sprintf("server %q: cwd must not contain NUL", name))
		}
		for index, arg := range server.Args {
			if strings.ContainsRune(arg, '\x00') {
				problems = append(problems, fmt.Sprintf("server %q: args[%d] must not contain NUL", name, index))
			}
		}
		for field, values := range map[string]map[string]string{"env": server.Env, "headers": server.Headers} {
			for key, value := range values {
				if field == "env" && !validEnvKey(key) {
					problems = append(problems, fmt.Sprintf("server %q: env %q has an invalid variable name", name, key))
				}
				if field == "headers" && !validHeaderName(key) {
					problems = append(problems, fmt.Sprintf("server %q: headers %q has an invalid HTTP field name", name, key))
				}
				if strings.ContainsRune(value, '\x00') || (field == "headers" && strings.ContainsAny(value, "\r\n")) {
					problems = append(problems, fmt.Sprintf("server %q: %s %q contains invalid control characters", name, field, key))
				}
				if err := validateRuntimeValueSyntax(value); err != nil {
					problems = append(problems, fmt.Sprintf("server %q: %s %q: %v", name, field, key, err))
				}
			}
		}
		for field, patterns := range map[string][]string{
			"enabled_tools":  server.EnabledTools,
			"disabled_tools": server.DisabledTools,
		} {
			for _, pattern := range patterns {
				if _, err := path.Match(pattern, ""); err != nil {
					problems = append(problems, fmt.Sprintf("server %q: %s contains invalid pattern %q", name, field, pattern))
				}
			}
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
		for field, patterns := range map[string][]string{
			"enabled_tools":  profile.EnabledTools,
			"disabled_tools": profile.DisabledTools,
		} {
			for _, pattern := range patterns {
				if _, err := path.Match(pattern, ""); err != nil {
					problems = append(problems, fmt.Sprintf("profile %q: %s contains invalid pattern %q", name, field, pattern))
				}
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

func validHTTPURL(raw string) bool {
	if raw != strings.TrimSpace(raw) || strings.Contains(raw, "\\") || strings.IndexFunc(raw, unicode.IsSpace) >= 0 {
		return false
	}
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Host == "" || parsed.Hostname() == "" || parsed.User != nil {
		return false
	}
	if scheme := strings.ToLower(parsed.Scheme); scheme != "http" && scheme != "https" {
		return false
	}
	// net/url intentionally accepts an authority ending in ':' and reports an
	// empty Port(). Treat that as malformed instead of silently using a
	// transport default; Python and PowerShell apply the same rule.
	if strings.HasSuffix(parsed.Host, ":") {
		return false
	}
	if port := parsed.Port(); port != "" {
		value, err := strconv.Atoi(port)
		if err != nil || value < 1 || value > 65535 {
			return false
		}
	}
	return true
}

func rejectExplicitNullFields(data []byte) error {
	var root map[string]json.RawMessage
	if err := json.Unmarshal(data, &root); err != nil {
		// The strict decoder below reports the useful syntax error. This
		// preflight exists only to preserve the distinction between an omitted
		// optional field and an explicitly supplied JSON null.
		return nil
	}
	if raw, ok := root["profiles"]; ok && isJSONNull(raw) {
		return errors.New("profiles must be an object")
	}
	if raw, ok := root["servers"]; ok && !isJSONNull(raw) {
		var servers map[string]json.RawMessage
		if err := json.Unmarshal(raw, &servers); err == nil {
			names := make([]string, 0, len(servers))
			for name := range servers {
				names = append(names, name)
			}
			sort.Strings(names)
			for _, name := range names {
				serverRaw := servers[name]
				if isJSONNull(serverRaw) {
					return fmt.Errorf("server %q must be an object", name)
				}
				var fields map[string]json.RawMessage
				if err := json.Unmarshal(serverRaw, &fields); err != nil {
					continue
				}
				for _, field := range []string{
					"enabled", "required", "transport", "command", "cwd", "url",
					"startup_timeout_seconds", "tool_timeout_seconds",
				} {
					if value, present := fields[field]; present && isJSONNull(value) {
						return fmt.Errorf("server %q: %s must not be null", name, field)
					}
				}
			}
		}
	}
	if raw, ok := root["profiles"]; ok && !isJSONNull(raw) {
		var profiles map[string]json.RawMessage
		if err := json.Unmarshal(raw, &profiles); err == nil {
			names := make([]string, 0, len(profiles))
			for name := range profiles {
				names = append(names, name)
			}
			sort.Strings(names)
			for _, name := range names {
				profileRaw := profiles[name]
				if isJSONNull(profileRaw) {
					return fmt.Errorf("profile %q must be an object", name)
				}
			}
		}
	}
	return nil
}

func isJSONNull(raw json.RawMessage) bool {
	return strings.TrimSpace(string(raw)) == "null"
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

// ResolveRuntime expands ${env:NAME} references in stdio environment values
// and HTTP headers without mutating the persisted configuration. References
// may appear inside a larger value, for example "Bearer ${env:API_TOKEN}".
// Prefix the reference with an extra dollar sign ($${env:NAME}) to keep it
// literal.
func (s ServerConfig) ResolveRuntime() (ServerConfig, error) {
	resolved := s
	var err error
	resolved.Env, err = resolveRuntimeMap("env", s.Env)
	if err != nil {
		return ServerConfig{}, err
	}
	resolved.Headers, err = resolveRuntimeMap("headers", s.Headers)
	if err != nil {
		return ServerConfig{}, err
	}
	return resolved, nil
}

func resolveRuntimeMap(field string, values map[string]string) (map[string]string, error) {
	if values == nil {
		return nil, nil
	}
	resolved := make(map[string]string, len(values))
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		if field == "env" && !validEnvKey(key) {
			return nil, fmt.Errorf("env %q has an invalid variable name", key)
		}
		if field == "headers" && !validHeaderName(key) {
			return nil, fmt.Errorf("headers %q has an invalid HTTP field name", key)
		}
		value := values[key]
		expanded, err := ResolveRuntimeValue(value)
		if err != nil {
			return nil, fmt.Errorf("%s %q: %w", field, key, err)
		}
		if strings.ContainsRune(expanded, '\x00') || (field == "headers" && strings.ContainsAny(expanded, "\r\n")) {
			return nil, fmt.Errorf("%s %q contains invalid control characters", field, key)
		}
		resolved[key] = expanded
	}
	return resolved, nil
}

func validEnvKey(value string) bool {
	return value != "" && !strings.ContainsAny(value, "=\x00")
}

func validHeaderName(value string) bool {
	if value == "" {
		return false
	}
	for index := 0; index < len(value); index++ {
		char := value[index]
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') || (char >= '0' && char <= '9') {
			continue
		}
		switch char {
		case '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
			continue
		default:
			return false
		}
	}
	return true
}

// ResolveRuntimeValue expands environment references using the current process
// environment. Callers should never log the returned value because it may
// contain credentials.
func ResolveRuntimeValue(value string) (string, error) {
	return parseRuntimeValue(value, os.LookupEnv)
}

func validateRuntimeValueSyntax(value string) error {
	_, err := parseRuntimeValue(value, func(string) (string, bool) { return "", true })
	return err
}

func parseRuntimeValue(value string, lookup func(string) (string, bool)) (string, error) {
	var resolved strings.Builder
	resolved.Grow(len(value))
	for offset := 0; offset < len(value); {
		remaining := value[offset:]
		if strings.HasPrefix(remaining, "$${env:") {
			resolved.WriteString("${env:")
			offset += len("$${env:")
			continue
		}
		if !strings.HasPrefix(remaining, "${env:") {
			resolved.WriteByte(value[offset])
			offset++
			continue
		}

		closing := strings.IndexByte(remaining, '}')
		if closing < 0 {
			return "", errors.New("invalid environment reference; expected ${env:NAME}")
		}
		name := remaining[len("${env:"):closing]
		if !envNameRE.MatchString(name) {
			return "", errors.New("invalid environment reference; expected ${env:NAME}")
		}
		resolvedValue, ok := lookup(name)
		if !ok {
			return "", fmt.Errorf("environment variable %q is not set", name)
		}
		resolved.WriteString(resolvedValue)
		offset += closing + 1
	}
	return resolved.String(), nil
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
