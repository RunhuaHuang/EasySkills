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
	"net/url"
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
	// lifecycleMu serializes operations that can replace or invalidate the
	// router's complete visible state. r.mu protects individual maps, but it
	// cannot prevent a long pre-flight Reload from committing a stale snapshot
	// after Close (or another Reload) has completed.
	lifecycleMu sync.Mutex
	mu          sync.RWMutex
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
	resolvedCfg, err := cfg.ResolveRuntime()
	if err != nil {
		return nil, fmt.Errorf("resolve runtime values: %w", err)
	}
	cfg = resolvedCfg
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
		return nil, fmt.Errorf("connect: %w", redactConnectionError(err, cfg))
	}
	return session, nil
}

// redactConnectionError keeps useful transport context while ensuring that a
// downstream error cannot echo credentials from a configured URL, header, or
// environment value into Gateway logs, status JSON, or WebUI test output.
func redactConnectionError(err error, cfg config.ServerConfig) error {
	if err == nil {
		return nil
	}
	message := err.Error()
	if cfg.URL != "" {
		redactedURL := "<redacted endpoint>"
		if parsed, parseErr := url.Parse(cfg.URL); parseErr == nil && parsed.Host != "" {
			originalQuery := parsed.RawQuery
			originalFragment := parsed.Fragment
			queryValues := parsed.Query()
			parsed.User = nil
			parsed.RawQuery = ""
			parsed.Fragment = ""
			redactedURL = parsed.String()
			message = strings.ReplaceAll(message, cfg.URL, redactedURL)
			if originalQuery != "" {
				message = strings.ReplaceAll(message, originalQuery, "<redacted query>")
				for _, values := range queryValues {
					for _, value := range values {
						if value != "" {
							message = strings.ReplaceAll(message, value, "<redacted>")
						}
					}
				}
			}
			if originalFragment != "" {
				message = strings.ReplaceAll(message, originalFragment, "<redacted>")
			}
		} else {
			message = strings.ReplaceAll(message, cfg.URL, redactedURL)
		}
	}
	// Command and args are not credentials; redacting them destroys the only
	// useful troubleshooting context (e.g. "connect: npx -y some-server ...").
	secrets := make([]string, 0, len(cfg.Env)+len(cfg.Headers))
	for _, values := range []map[string]string{cfg.Env, cfg.Headers} {
		for _, value := range values {
			secrets = append(secrets, value)
		}
	}
	sort.Slice(secrets, func(left, right int) bool {
		return len(secrets[left]) > len(secrets[right])
	})
	seen := make(map[string]struct{}, len(secrets))
	for _, value := range secrets {
		if value == "" {
			continue
		}
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		message = strings.ReplaceAll(message, value, "<redacted>")
	}
	return errors.New(message)
}

func newHTTPClient(headers map[string]string) *http.Client {
	base := http.DefaultTransport
	return &http.Client{
		Transport: &headerTransport{base: base, headers: headers},
		CheckRedirect: func(request *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return errors.New("stopped after 10 redirects")
			}
			if len(via) > 0 && !sameOrigin(via[0].URL.Scheme, via[0].URL.Host, request.URL.Scheme, request.URL.Host) {
				return errors.New("refusing cross-origin MCP redirect")
			}
			return nil
		},
	}
}

func sameOrigin(leftScheme, leftHost, rightScheme, rightHost string) bool {
	return strings.EqualFold(leftScheme, rightScheme) && strings.EqualFold(leftHost, rightHost)
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
	r.lifecycleMu.Lock()
	defer r.lifecycleMu.Unlock()
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
	// Connect/discovery can take seconds and happen outside r.mu. Keep the
	// whole lifecycle operation serialized so a concurrent Close or Reload
	// cannot invalidate the snapshot that this call is preparing to commit.
	r.lifecycleMu.Lock()
	defer r.lifecycleMu.Unlock()

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
	sort.Strings(toClose)
	sort.Strings(toReevaluate)
	sort.Strings(toConnect)
	r.mu.Unlock()

	// Pre-flight Phase 1: Connect to new/modified servers
	newSessions := make(map[string]*downstream)
	connectionErrors := make(map[string]error)
	// Servers whose replacement failed but whose previous session must keep
	// serving (tools and connection untouched) instead of aborting the reload.
	keepServers := make(map[string]struct{})

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
			if serverCfg.Required {
				err = fmt.Errorf("required server %q failed: %w", name, connErr)
				return err
			}
			if existingServers[name] {
				// Match Open()'s tolerance: one flapping downstream must not
				// abort the whole reload. Keep the previous working session.
				keepServers[name] = struct{}{}
				continue
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
			if serverCfg.Required {
				err = fmt.Errorf("required server %q discovery failed: %w", name, discErr)
				return err
			}
			if existingServers[name] {
				// Match Open()'s tolerance: one flapping downstream must not
				// abort the whole reload. Keep the previous working session
				// and its already-registered tool routes.
				r.logger.Warn("Keeping previous session and tools after failed replacement discovery", "server", name)
				keepServers[name] = struct{}{}
				continue
			}
			continue
		}

		discovered[name] = toolsList
	}

	// Commit Phase: swap connections and routes while holding the router lock.
	// Closing a downstream can block on process/network shutdown, so retain the
	// old sessions here and close them only after the new state is visible.
	var oldSessions []*downstream
	r.mu.Lock()

	// 1. Remove tools for all servers whose route set is no longer valid.
	//
	// A deleted server appears in toClose but not in toReevaluate because it is
	// absent from the new profile.  Removing only re-evaluated servers therefore
	// left stale tool routes behind: sessions disappeared while the old tools
	// remained published and still pointed at a closed downstream session.
	toolsToRemoveFor := make(map[string]struct{}, len(toClose)+len(toReevaluate))
	for _, name := range toClose {
		if _, kept := keepServers[name]; kept {
			continue
		}
		toolsToRemoveFor[name] = struct{}{}
	}
	for _, name := range toReevaluate {
		if _, kept := keepServers[name]; kept {
			continue
		}
		toolsToRemoveFor[name] = struct{}{}
	}
	toolServerNames := make([]string, 0, len(toolsToRemoveFor))
	for name := range toolsToRemoveFor {
		toolServerNames = append(toolServerNames, name)
	}
	sort.Strings(toolServerNames)
	for _, name := range toolServerNames {
		var toolNamesToRemove []string
		for gName, route := range r.tools {
			if route.serverName == name {
				toolNamesToRemove = append(toolNamesToRemove, gName)
			}
		}
		sort.Strings(toolNamesToRemove)
		for _, gName := range toolNamesToRemove {
			delete(r.tools, gName)
		}
		if len(toolNamesToRemove) > 0 {
			server.RemoveTools(toolNamesToRemove...)
		}
	}

	// 2. Close and remove old sessions
	for _, name := range toClose {
		if _, kept := keepServers[name]; kept {
			continue
		}
		oldDS, exists := r.sessions[name]
		if exists {
			delete(r.sessions, name)
			oldSessions = append(oldSessions, oldDS)
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
	r.mu.Unlock()

	for _, oldDS := range oldSessions {
		if closeErr := oldDS.session.Close(); closeErr != nil {
			r.logger.Warn("MCP server reload close failed", "error", closeErr)
		}
	}

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
	r.lifecycleMu.Lock()
	defer r.lifecycleMu.Unlock()

	r.mu.Lock()
	sessions := r.sessions
	r.sessions = make(map[string]*downstream)
	r.tools = make(map[string]toolRoute)
	r.status = []ServerStatus{}
	r.mu.Unlock()

	var errs []error
	for name, downstream := range sessions {
		if err := downstream.session.Close(); err != nil {
			errs = append(errs, fmt.Errorf("close %s: %w", name, err))
		}
	}
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
	if tool.InputSchema != nil {
		if err := validateObjectSchema(tool.InputSchema, "input"); err != nil {
			return err
		}
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
	if value == nil {
		return nil, errors.New("tool arguments must be a JSON object")
	}
	return value, nil
}
