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
	"reflect"
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
	cfg     config.ServerConfig
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
		router.sessions[name] = &downstream{session: session, cfg: serverCfg}
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

func (r *Router) discover(ctx context.Context, serverName string, cfg config.ServerConfig, session *mcp.ClientSession) (writtenCount int, err error) {
	cursor := ""
	count := 0
	var added []string
	defer func() {
		if err != nil {
			r.mu.Lock()
			for _, key := range added {
				delete(r.tools, key)
			}
			r.mu.Unlock()
		}
	}()
	for {
		result, errVal := session.ListTools(ctx, &mcp.ListToolsParams{Cursor: cursor})
		if errVal != nil {
			err = errVal
			return 0, err
		}
		for _, tool := range result.Tools {
			if tool == nil || !toolAllowed(serverName, tool.Name, cfg, r.profile) {
				continue
			}
			if validationErr := validateToolDefinition(tool); validationErr != nil {
				err = fmt.Errorf("server %q tool %q: %w", serverName, tool.Name, validationErr)
				return 0, err
			}
			r.mu.Lock()
			occupied := make(map[string]string)
			for gName, route := range r.tools {
				occupied[gName] = route.serverName
			}
			gatewayName := resolveToolName(serverName, tool.Name, occupied)
			r.tools[gatewayName] = toolRoute{
				serverName: serverName,
				toolName:   tool.Name,
				definition: tool,
				session:    session,
				timeout:    time.Duration(cfg.ToolTimeout()) * time.Second,
			}
			r.mu.Unlock()
			added = append(added, gatewayName)
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
		registerTool(server, gatewayName, r.tools[gatewayName])
	}
}

func registerTool(server *mcp.Server, gatewayName string, route toolRoute) {
	downstreamTool := route.definition
	if downstreamTool == nil {
		return
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

func (r *Router) Reload(ctx context.Context, cfg *config.Config, profileName string, server *mcp.Server) (err error) {
	selected, profile, errVal := cfg.SelectedServers(profileName)
	if errVal != nil {
		return errVal
	}

	r.mu.Lock()
	profileChanged := !reflect.DeepEqual(r.profile, profile)
	existingServers := make(map[string]bool, len(r.sessions))
	for name := range r.sessions {
		existingServers[name] = true
	}
	previousToolNames := make(map[string]string, len(r.tools))
	for gatewayName, route := range r.tools {
		previousToolNames[toolIdentity(route.serverName, route.toolName)] = gatewayName
	}

	// Determine which existing servers to close
	var toClose []string
	for name, oldDS := range r.sessions {
		newCfg, exists := selected[name]
		if !exists || !reflect.DeepEqual(oldDS.cfg, newCfg) {
			toClose = append(toClose, name)
		}
	}

	// Determine which servers to re-evaluate
	var toReevaluate []string
	for name := range selected {
		_, exists := r.sessions[name]
		isClosed := false
		for _, closedName := range toClose {
			if closedName == name {
				isClosed = true
				break
			}
		}
		if !exists || isClosed || profileChanged {
			toReevaluate = append(toReevaluate, name)
		}
	}

	// Determine which new/modified servers to connect
	var toConnect []string
	for name := range selected {
		_, exists := r.sessions[name]
		isClosed := false
		for _, closedName := range toClose {
			if closedName == name {
				isClosed = true
				break
			}
		}
		if !exists || isClosed {
			toConnect = append(toConnect, name)
		}
	}
	r.mu.Unlock()

	// Pre-flight Phase 1: Connect to new/modified servers
	newSessions := make(map[string]*downstream)
	connectionErrors := make(map[string]error)

	defer func() {
		if err != nil {
			for _, ds := range newSessions {
				ds.session.Close()
			}
		}
	}()

	for _, name := range toConnect {
		serverCfg := selected[name]
		session, connErr := connect(ctx, name, serverCfg, r.logger)
		if connErr != nil {
			r.logger.Warn("MCP server reload connection failed (pre-flight)", "server", name, "error", connErr)
			connectionErrors[name] = connErr
			if existingServers[name] {
				err = fmt.Errorf("replacement server %q failed: %w", name, connErr)
				return err
			}
			if serverCfg.Required {
				err = fmt.Errorf("required server %q failed: %w", name, connErr)
				return err
			}
			continue
		}
		newSessions[name] = &downstream{session: session, cfg: serverCfg}
	}

	// Pre-flight Phase 2: Run discovery for new sessions or existing sessions that need profile re-evaluation
	discovered := make(map[string][]*mcp.Tool)

	for _, name := range toReevaluate {
		serverCfg, exists := selected[name]
		if !exists {
			continue
		}

		var session *mcp.ClientSession
		if ds, ok := newSessions[name]; ok {
			session = ds.session
		} else {
			r.mu.RLock()
			if ds, ok := r.sessions[name]; ok {
				session = ds.session
			}
			r.mu.RUnlock()
		}

		if session == nil {
			continue
		}

		discoveryCtx, cancel := context.WithTimeout(ctx, time.Duration(serverCfg.StartupTimeout())*time.Second)
		toolsList, discErr := r.discoverToolsLocal(discoveryCtx, name, serverCfg, session, profile)
		cancel()

		if discErr != nil {
			r.logger.Warn("MCP server reload discovery failed (pre-flight)", "server", name, "error", discErr)
			connectionErrors[name] = discErr
			if ds, ok := newSessions[name]; ok {
				ds.session.Close()
				delete(newSessions, name)
			}
			if existingServers[name] {
				err = fmt.Errorf("replacement server %q discovery failed: %w", name, discErr)
				return err
			}
			if serverCfg.Required {
				err = fmt.Errorf("required server %q discovery failed: %w", name, discErr)
				return err
			}
			continue
		}

		discovered[name] = toolsList
	}

	// Commit Phase: Commit connections and register tools
	r.mu.Lock()
	defer r.mu.Unlock()

	// 1. Remove tools for all re-evaluated servers
	for _, name := range toReevaluate {
		var toolNamesToRemove []string
		for gName, route := range r.tools {
			if route.serverName == name {
				toolNamesToRemove = append(toolNamesToRemove, gName)
			}
		}
		for _, gName := range toolNamesToRemove {
			delete(r.tools, gName)
		}
		if len(toolNamesToRemove) > 0 {
			server.RemoveTools(toolNamesToRemove...)
		}
	}

	// 2. Close and remove old sessions
	for _, name := range toClose {
		oldDS, exists := r.sessions[name]
		if exists {
			delete(r.sessions, name)
			oldDS.session.Close()
		}
	}

	// 3. Commit new sessions
	for name, ds := range newSessions {
		r.sessions[name] = ds
	}

	// 4. Register newly discovered tools with dynamic collision resolution
	discoveredNames := make([]string, 0, len(discovered))
	for name := range discovered {
		discoveredNames = append(discoveredNames, name)
	}
	sort.Strings(discoveredNames)
	for _, name := range discoveredNames {
		toolsList := discovered[name]
		serverCfg := selected[name]
		ds, exists := r.sessions[name]
		if !exists {
			continue
		}

		for _, tool := range toolsList {
			occupied := make(map[string]string)
			for gName, route := range r.tools {
				occupied[gName] = route.serverName
			}
			gatewayName := ""
			if previousName, ok := previousToolNames[toolIdentity(name, tool.Name)]; ok {
				if _, occupiedNow := occupied[previousName]; !occupiedNow {
					gatewayName = previousName
				}
			}
			if gatewayName == "" {
				gatewayName = resolveToolName(name, tool.Name, occupied)
			}

			route := toolRoute{
				serverName: name,
				toolName:   tool.Name,
				definition: tool,
				session:    ds.session,
				timeout:    time.Duration(serverCfg.ToolTimeout()) * time.Second,
			}
			r.tools[gatewayName] = route
			registerTool(server, gatewayName, route)
		}
	}

	// 5. Update profiles and status
	r.profile = profile
	var newStatus []ServerStatus
	names := make([]string, 0, len(selected))
	for name := range selected {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		serverCfg := selected[name]
		status := ServerStatus{Name: name, Transport: serverCfg.NormalizedTransport()}
		if _, ok := r.sessions[name]; ok {
			status.Connected = true
			toolCount := 0
			for _, route := range r.tools {
				if route.serverName == name {
					toolCount++
				}
			}
			status.Tools = toolCount
		} else if errVal, ok := connectionErrors[name]; ok {
			status.Error = errVal.Error()
		}
		newStatus = append(newStatus, status)
	}
	r.status = newStatus

	return nil
}

func (r *Router) Summary(profileName string) Summary {
	r.mu.RLock()
	defer r.mu.RUnlock()
	toolNames := make([]string, 0, len(r.tools))
	for name, route := range r.tools {
		toolNames = append(toolNames, route.serverName+"."+name)
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

func resolveToolName(serverName, toolName string, occupied map[string]string) string {
	cleanName := cleanToolName(toolName)
	if _, ok := occupied[cleanName]; !ok {
		return cleanName
	}
	baseFallback := cleanToolName(serverName + "__" + toolName)
	if _, ok := occupied[baseFallback]; !ok {
		return baseFallback
	}
	for suffix := 2; ; suffix++ {
		candidate := cleanToolName(fmt.Sprintf("%s_%d", baseFallback, suffix))
		if _, ok := occupied[candidate]; !ok {
			return candidate
		}
	}
}

func toolIdentity(serverName, toolName string) string {
	return serverName + "\x00" + toolName
}

func cleanToolName(toolName string) string {
	toolPart := strings.Trim(invalidToolChars.ReplaceAllString(toolName, "_"), "_")
	if toolPart == "" {
		toolPart = "tool"
	}
	result := toolPart
	if len(result) <= 128 {
		return result
	}
	hash := sha256.Sum256([]byte(result))
	suffix := "_" + hex.EncodeToString(hash[:4])
	return result[:128-len(suffix)] + suffix
}

func (r *Router) discoverToolsLocal(ctx context.Context, serverName string, cfg config.ServerConfig, session *mcp.ClientSession, prof config.Profile) ([]*mcp.Tool, error) {
	cursor := ""
	var tools []*mcp.Tool
	for {
		result, err := session.ListTools(ctx, &mcp.ListToolsParams{Cursor: cursor})
		if err != nil {
			return nil, err
		}
		for _, tool := range result.Tools {
			if tool == nil || !toolAllowed(serverName, tool.Name, cfg, prof) {
				continue
			}
			if err := validateToolDefinition(tool); err != nil {
				return nil, fmt.Errorf("server %q tool %q: %w", serverName, tool.Name, err)
			}
			tools = append(tools, tool)
		}
		if result.NextCursor == "" {
			break
		}
		cursor = result.NextCursor
	}
	return tools, nil
}

func validateToolDefinition(tool *mcp.Tool) error {
	if tool.InputSchema == nil {
		return nil
	}
	if err := validateObjectSchema(tool.InputSchema, "input"); err != nil {
		return err
	}
	if tool.OutputSchema != nil {
		if err := validateObjectSchema(tool.OutputSchema, "output"); err != nil {
			return err
		}
	}
	return nil
}

func validateObjectSchema(schema any, kind string) error {
	data, err := json.Marshal(schema)
	if err != nil {
		return fmt.Errorf("%s schema is not JSON-serializable: %w", kind, err)
	}
	var object map[string]any
	if err := json.Unmarshal(data, &object); err != nil {
		return fmt.Errorf("%s schema must be a JSON object: %w", kind, err)
	}
	if object == nil || object["type"] != "object" {
		return fmt.Errorf("%s schema must have type object", kind)
	}
	return nil
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
