package gateway

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"path"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/RunhuaHuang/EasySkills/gateway/internal/config"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type Router struct {
	logger   *slog.Logger
	profile  config.Profile
	sessions map[string]*downstream
	tools    map[string]toolRoute
	status   []ServerStatus
	mu       sync.RWMutex
}

type downstream struct {
	session *mcp.ClientSession
}

type toolRoute struct {
	serverName string
	toolName   string
	definition *mcp.Tool
	session    *mcp.ClientSession
	timeout    time.Duration
}

type ServerStatus struct {
	Name      string `json:"name"`
	Transport string `json:"transport"`
	Connected bool   `json:"connected"`
	Tools     int    `json:"tools"`
	Error     string `json:"error,omitempty"`
}

type Summary struct {
	Profile string         `json:"profile"`
	Servers []ServerStatus `json:"servers"`
	Tools   []string       `json:"tools"`
}

func Open(ctx context.Context, cfg *config.Config, profileName string, logger *slog.Logger) (*Router, error) {
	if logger == nil {
		logger = slog.New(slog.NewTextHandler(os.Stderr, nil))
	}
	selected, profile, err := cfg.SelectedServers(profileName)
	if err != nil {
		return nil, err
	}
	router := &Router{
		logger:   logger,
		profile:  profile,
		sessions: make(map[string]*downstream),
		tools:    make(map[string]toolRoute),
	}
	names := make([]string, 0, len(selected))
	for name := range selected {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		serverCfg := selected[name]
		status := ServerStatus{Name: name, Transport: serverCfg.NormalizedTransport()}
		session, err := connect(ctx, name, serverCfg, logger)
		if err != nil {
			status.Error = err.Error()
			router.status = append(router.status, status)
			if serverCfg.Required {
				router.Close()
				return nil, fmt.Errorf("required server %q failed: %w", name, err)
			}
			logger.Warn("MCP server unavailable", "server", name, "error", err)
			continue
		}
		router.sessions[name] = &downstream{session: session}
		discoveryCtx, cancel := context.WithTimeout(ctx, time.Duration(serverCfg.StartupTimeout())*time.Second)
		count, err := router.discover(discoveryCtx, name, serverCfg, session)
		cancel()
		if err != nil {
			session.Close()
			delete(router.sessions, name)
			status.Error = err.Error()
			router.status = append(router.status, status)
			if serverCfg.Required {
				router.Close()
				return nil, fmt.Errorf("required server %q discovery failed: %w", name, err)
			}
			logger.Warn("MCP tool discovery failed", "server", name, "error", err)
			continue
		}
		status.Connected = true
		status.Tools = count
		router.status = append(router.status, status)
		logger.Info("MCP server connected", "server", name, "tools", count)
	}
	return router, nil
}

func connect(parent context.Context, name string, cfg config.ServerConfig, _ *slog.Logger) (*mcp.ClientSession, error) {
	ctx, cancel := context.WithTimeout(parent, time.Duration(cfg.StartupTimeout())*time.Second)
	defer cancel()
	client := mcp.NewClient(
		&mcp.Implementation{Name: "easyskills-gateway", Title: "EasySkills MCP Gateway", Version: "1"},
		&mcp.ClientOptions{Capabilities: &mcp.ClientCapabilities{}},
	)
	var transport mcp.Transport
	switch cfg.NormalizedTransport() {
	case "stdio":
		cmd := exec.Command(cfg.Command, cfg.Args...)
		if cfg.Cwd != "" {
			cmd.Dir = cfg.Cwd
		}
		cmd.Env = os.Environ()
		for key, value := range cfg.Env {
			cmd.Env = append(cmd.Env, key+"="+value)
		}
		// stdout is reserved for MCP. Child stderr is intentionally inherited so
		// diagnostics remain visible without entering protocol messages.
		cmd.Stderr = os.Stderr
		transport = &mcp.CommandTransport{Command: cmd, TerminateDuration: 3 * time.Second}
	case "http":
		transport = &mcp.StreamableClientTransport{
			Endpoint:   cfg.URL,
			HTTPClient: newHTTPClient(cfg.Headers),
			MaxRetries: 2,
		}
	case "sse":
		transport = &mcp.SSEClientTransport{Endpoint: cfg.URL, HTTPClient: newHTTPClient(cfg.Headers)}
	default:
		return nil, fmt.Errorf("unsupported transport %q", cfg.Transport)
	}
	session, err := client.Connect(ctx, transport, nil)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	return session, nil
}

func newHTTPClient(headers map[string]string) *http.Client {
	base := http.DefaultTransport
	return &http.Client{Transport: &headerTransport{base: base, headers: headers}}
}

type headerTransport struct {
	base    http.RoundTripper
	headers map[string]string
}

func (t *headerTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	clone := request.Clone(request.Context())
	clone.Header = request.Header.Clone()
	for key, value := range t.headers {
		clone.Header.Set(key, value)
	}
	return t.base.RoundTrip(clone)
}

func (r *Router) discover(ctx context.Context, serverName string, cfg config.ServerConfig, session *mcp.ClientSession) (int, error) {
	cursor := ""
	count := 0
	for {
		result, err := session.ListTools(ctx, &mcp.ListToolsParams{Cursor: cursor})
		if err != nil {
			return 0, err
		}
		for _, tool := range result.Tools {
			if tool == nil || !toolAllowed(serverName, tool.Name, cfg, r.profile) {
				continue
			}
			gatewayName := namespacedToolName(serverName, tool.Name)
			if existing, exists := r.tools[gatewayName]; exists {
				return 0, fmt.Errorf("tool name collision %q between %s.%s and %s.%s", gatewayName, existing.serverName, existing.toolName, serverName, tool.Name)
			}
			r.tools[gatewayName] = toolRoute{
				serverName: serverName,
				toolName:   tool.Name,
				definition: tool,
				session:    session,
				timeout:    time.Duration(cfg.ToolTimeout()) * time.Second,
			}
			count++
		}
		if result.NextCursor == "" {
			break
		}
		cursor = result.NextCursor
	}
	return count, nil
}

func (r *Router) Register(server *mcp.Server) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	names := make([]string, 0, len(r.tools))
	for name := range r.tools {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, gatewayName := range names {
		route := r.tools[gatewayName]
		downstreamTool := route.definition
		if downstreamTool == nil {
			continue
		}
		published := *downstreamTool
		published.Name = gatewayName
		if published.Title == "" {
			published.Title = route.serverName + ": " + route.toolName
		}
		origin := "Provided by the " + route.serverName + " MCP server."
		if published.Description == "" {
			published.Description = origin
		} else {
			published.Description = origin + " " + published.Description
		}
		if published.InputSchema == nil {
			published.InputSchema = map[string]any{"type": "object"}
		}
		routeCopy := route
		server.AddTool(&published, func(ctx context.Context, request *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			callCtx, cancel := context.WithTimeout(ctx, routeCopy.timeout)
			defer cancel()
			params := &mcp.CallToolParams{Name: routeCopy.toolName}
			if request != nil && request.Params != nil {
				params.Meta = request.Params.Meta
				params.Arguments = request.Params.Arguments
			}
			result, err := routeCopy.session.CallTool(callCtx, params)
			if err != nil {
				if errors.Is(err, context.DeadlineExceeded) || errors.Is(callCtx.Err(), context.DeadlineExceeded) {
					return nil, fmt.Errorf("%s.%s timed out", routeCopy.serverName, routeCopy.toolName)
				}
				return nil, fmt.Errorf("%s.%s: %w", routeCopy.serverName, routeCopy.toolName, err)
			}
			return result, nil
		})
	}
}

func (r *Router) Summary(profileName string) Summary {
	r.mu.RLock()
	defer r.mu.RUnlock()
	toolNames := make([]string, 0, len(r.tools))
	for name := range r.tools {
		toolNames = append(toolNames, name)
	}
	sort.Strings(toolNames)
	statuses := append([]ServerStatus{}, r.status...)
	return Summary{Profile: profileName, Servers: statuses, Tools: toolNames}
}

func (r *Router) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	var errs []error
	for name, downstream := range r.sessions {
		if err := downstream.session.Close(); err != nil {
			errs = append(errs, fmt.Errorf("close %s: %w", name, err))
		}
	}
	r.sessions = make(map[string]*downstream)
	return errors.Join(errs...)
}

func toolAllowed(serverName, toolName string, server config.ServerConfig, profile config.Profile) bool {
	qualified := serverName + "." + toolName
	if len(server.EnabledTools) > 0 && !matchesAny(server.EnabledTools, toolName) {
		return false
	}
	if matchesAny(server.DisabledTools, toolName) {
		return false
	}
	if len(profile.EnabledTools) > 0 && !matchesAny(profile.EnabledTools, qualified) {
		return false
	}
	return !matchesAny(profile.DisabledTools, qualified)
}

func matchesAny(patterns []string, value string) bool {
	for _, pattern := range patterns {
		matched, err := path.Match(pattern, value)
		if err == nil && matched {
			return true
		}
		if pattern == value {
			return true
		}
	}
	return false
}

var invalidToolChars = regexp.MustCompile(`[^A-Za-z0-9_-]+`)

func namespacedToolName(serverName, toolName string) string {
	serverPart := strings.Trim(invalidToolChars.ReplaceAllString(serverName, "_"), "_")
	toolPart := strings.Trim(invalidToolChars.ReplaceAllString(toolName, "_"), "_")
	if serverPart == "" {
		serverPart = "server"
	}
	if toolPart == "" {
		toolPart = "tool"
	}
	result := serverPart + "__" + toolPart
	if len(result) <= 128 {
		return result
	}
	hash := sha256.Sum256([]byte(result))
	suffix := "_" + hex.EncodeToString(hash[:4])
	return result[:128-len(suffix)] + suffix
}

// DecodeArguments is kept small and exported for contract tests and future
// admin APIs. It never logs argument values because they may contain secrets.
func DecodeArguments(raw json.RawMessage) (map[string]any, error) {
	if len(raw) == 0 {
		return map[string]any{}, nil
	}
	var value map[string]any
	if err := json.Unmarshal(raw, &value); err != nil {
		return nil, err
	}
	return value, nil
}
