package gateway

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/RunhuaHuang/EasySkills/gateway/internal/config"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestResolveToolName(t *testing.T) {
	occupied := map[string]string{
		"search":       "google",
		"bing__search": "other",
	}
	// Case 1: no collision
	if got := resolveToolName("bing", "find", occupied); got != "find" {
		t.Fatalf("expected find, got %q", got)
	}
	// Case 2: collision, should fall back to prefixing
	if got := resolveToolName("yahoo", "search", occupied); got != "yahoo__search" {
		t.Fatalf("expected yahoo__search, got %q", got)
	}
	// Case 3: secondary collision, should append counter
	if got := resolveToolName("bing", "search", occupied); got != "bing__search_2" {
		t.Fatalf("expected bing__search_2, got %q", got)
	}
	// Case 4: even a collision within one server must not overwrite the first route.
	if got := resolveToolName("google", "search", occupied); got != "google__search" {
		t.Fatalf("expected google__search, got %q", got)
	}
}

func TestValidateToolDefinitionRejectsInvalidSchemas(t *testing.T) {
	if err := validateToolDefinition(&mcp.Tool{
		Name:        "bad-input",
		InputSchema: map[string]any{"type": "string"},
	}); err == nil {
		t.Fatal("expected non-object input schema to be rejected")
	}
	if err := validateToolDefinition(&mcp.Tool{
		Name:         "bad-output",
		OutputSchema: map[string]any{"type": "array"},
	}); err == nil {
		t.Fatal("expected non-object output schema to be rejected even without an input schema")
	}
}

func TestHTTPClientDoesNotForwardConfiguredHeadersAcrossOrigins(t *testing.T) {
	var targetReceivedAuthorization bool
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		targetReceivedAuthorization = request.Header.Get("Authorization") != ""
		w.WriteHeader(http.StatusNoContent)
	}))
	defer target.Close()

	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if request.Header.Get("Authorization") != "Bearer secret" {
			t.Error("configured header was not attached to the original MCP request")
		}
		http.Redirect(w, request, target.URL, http.StatusFound)
	}))
	defer source.Close()

	response, err := newHTTPClient(map[string]string{"Authorization": "Bearer secret"}).Get(source.URL)
	if response != nil {
		response.Body.Close()
	}
	if err == nil || !strings.Contains(err.Error(), "cross-origin") {
		t.Fatalf("cross-origin redirect error = %v", err)
	}
	if targetReceivedAuthorization {
		t.Fatal("configured authorization header leaked to the redirect target")
	}
}

func TestToolFiltering(t *testing.T) {
	server := config.ServerConfig{EnabledTools: []string{"read_*"}, DisabledTools: []string{"read_secret"}}
	profile := config.Profile{EnabledTools: []string{"docs.*"}, DisabledTools: []string{"*.dangerous"}}
	if !toolAllowed("docs", "read_page", server, profile) {
		t.Fatal("read_page should be allowed")
	}
	if toolAllowed("docs", "read_secret", server, profile) {
		t.Fatal("read_secret should be denied")
	}
	if toolAllowed("docs", "write_page", server, profile) {
		t.Fatal("write_page should not pass server allowlist")
	}
}

func TestRedactConnectionError(t *testing.T) {
	cfg := config.ServerConfig{
		Transport: "http",
		URL:       "https://example.com/mcp?token=super-secret#fragment",
		Env:       map[string]string{"TOKEN": "env-secret"},
		Headers:   map[string]string{"Authorization": "Bearer header-secret"},
	}
	err := redactConnectionError(
		fmt.Errorf("Get %s: authorization=%s env=%s", cfg.URL, cfg.Headers["Authorization"], cfg.Env["TOKEN"]),
		cfg,
	)
	if err == nil {
		t.Fatal("redactConnectionError returned nil")
	}
	message := err.Error()
	for _, secret := range []string{"super-secret", "fragment", "Bearer header-secret", "env-secret"} {
		if strings.Contains(message, secret) {
			t.Fatalf("connection error leaked %q: %s", secret, message)
		}
	}
	if !strings.Contains(message, "https://example.com/mcp") {
		t.Fatalf("redacted endpoint lost useful context: %s", message)
	}
}

func TestRedactConnectionErrorDoesNotLeakOverlappingSecrets(t *testing.T) {
	cfg := config.ServerConfig{
		Transport: "stdio",
		Command:   "secret-command",
		Args:      []string{"secret", "secret-long"},
		Env:       map[string]string{"TOKEN": "secret"},
	}
	err := redactConnectionError(fmt.Errorf("command=secret-long short=secret"), cfg)
	if err == nil {
		t.Fatal("redactConnectionError returned nil")
	}
	message := err.Error()
	for _, secret := range []string{"secret-long", "secret"} {
		if strings.Contains(message, secret) {
			t.Fatalf("overlapping secret leaked %q: %s", secret, message)
		}
	}
}

func TestDecodeArgumentsRejectsNull(t *testing.T) {
	if _, err := DecodeArguments(json.RawMessage("null")); err == nil {
		t.Fatal("null tool arguments were accepted")
	}
}

func TestSummaryUsesEmptyArrays(t *testing.T) {
	router := &Router{tools: map[string]toolRoute{}}
	encoded, err := json.Marshal(router.Summary("default"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "null") {
		t.Fatalf("summary contains null arrays: %s", encoded)
	}
}

func TestGatewayCloseClearsVisibleStateAndIsIdempotent(t *testing.T) {
	cfg := &config.Config{
		Version: 1,
		Servers: map[string]config.ServerConfig{
			"fixture": {
				Transport:             "stdio",
				Command:               os.Args[0],
				Args:                  []string{"-test.run=TestMCPHelperProcess"},
				Env:                   map[string]string{"EASYSKILLS_MCP_TEST_HELPER": "1"},
				StartupTimeoutSeconds: 10,
			},
		},
		Profiles: map[string]config.Profile{"default": {Servers: []string{"*"}}},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	router, err := Open(ctx, cfg, "default", slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})))
	if err != nil {
		t.Fatal(err)
	}

	if err := router.Close(); err != nil {
		t.Fatal(err)
	}
	summary := router.Summary("default")
	if len(summary.Servers) != 0 || len(summary.Tools) != 0 {
		t.Fatalf("closed router retained visible state: %#v", summary)
	}
	if err := router.Close(); err != nil {
		t.Fatalf("second Close returned an error: %v", err)
	}
}

func TestGatewayRoutesToolCalls(t *testing.T) {
	cfg := &config.Config{
		Version: 1,
		Servers: map[string]config.ServerConfig{
			"fixture": {
				Transport:             "stdio",
				Command:               os.Args[0],
				Args:                  []string{"-test.run=TestMCPHelperProcess"},
				Env:                   map[string]string{"EASYSKILLS_MCP_TEST_HELPER": "1"},
				StartupTimeoutSeconds: 10,
			},
		},
		Profiles: map[string]config.Profile{"default": {Servers: []string{"*"}}},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	router, err := Open(ctx, cfg, "default", slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})))
	if err != nil {
		t.Fatal(err)
	}
	defer router.Close()

	server := mcp.NewServer(&mcp.Implementation{Name: "gateway-test", Version: "1"}, nil)
	router.Register(server)
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	go func() { _ = server.Run(ctx, serverTransport) }()
	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "1"}, nil)
	session, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	result, err := session.CallTool(ctx, &mcp.CallToolParams{
		Name:      "echo",
		Arguments: map[string]any{"value": "hello"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Content) != 1 {
		t.Fatalf("content length = %d", len(result.Content))
	}
	text, ok := result.Content[0].(*mcp.TextContent)
	if !ok || text.Text != "hello" {
		t.Fatalf("unexpected content: %#v", result.Content[0])
	}
}

func TestMCPHelperProcess(t *testing.T) {
	if os.Getenv("EASYSKILLS_MCP_TEST_HELPER") != "1" {
		return
	}
	server := mcp.NewServer(&mcp.Implementation{Name: "fixture", Version: "1"}, nil)
	server.AddTool(&mcp.Tool{
		Name:        "echo",
		Description: "Echo a value",
		InputSchema: map[string]any{
			"type":       "object",
			"properties": map[string]any{"value": map[string]any{"type": "string"}},
			"required":   []string{"value"},
		},
	}, func(_ context.Context, request *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		var args struct {
			Value string `json:"value"`
		}
		if err := json.Unmarshal(request.Params.Arguments, &args); err != nil {
			return nil, err
		}
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: args.Value}}}, nil
	})
	if err := server.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		os.Exit(2)
	}
	os.Exit(0)
}

func TestGatewayReload(t *testing.T) {
	cfg := &config.Config{
		Version: 1,
		Servers: map[string]config.ServerConfig{
			"fixture": {
				Transport:             "stdio",
				Command:               os.Args[0],
				Args:                  []string{"-test.run=TestMCPHelperProcess"},
				Env:                   map[string]string{"EASYSKILLS_MCP_TEST_HELPER": "1"},
				StartupTimeoutSeconds: 10,
			},
		},
		Profiles: map[string]config.Profile{"default": {Servers: []string{"*"}}},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	router, err := Open(ctx, cfg, "default", slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})))
	if err != nil {
		t.Fatal(err)
	}
	defer router.Close()

	server := mcp.NewServer(&mcp.Implementation{Name: "gateway-test", Version: "1"}, nil)
	router.Register(server)

	// Verify we have the "echo" tool registered
	router.mu.RLock()
	if _, ok := router.tools["echo"]; !ok {
		router.mu.RUnlock()
		t.Fatal("expected echo tool to be registered initially")
	}
	router.mu.RUnlock()

	// Case 1: Modify existing server tool_timeout_seconds
	newCfg := &config.Config{
		Version: 1,
		Servers: map[string]config.ServerConfig{
			"fixture": {
				Transport:             "stdio",
				Command:               os.Args[0],
				Args:                  []string{"-test.run=TestMCPHelperProcess"},
				Env:                   map[string]string{"EASYSKILLS_MCP_TEST_HELPER": "1"},
				StartupTimeoutSeconds: 10,
				ToolTimeoutSeconds:    15, // modified value
			},
		},
		Profiles: map[string]config.Profile{"default": {Servers: []string{"*"}}},
	}
	if err := router.Reload(ctx, newCfg, "default", server); err != nil {
		t.Fatalf("failed to reload modified config: %v", err)
	}
	router.mu.RLock()
	route, ok := router.tools["echo"]
	if !ok {
		router.mu.RUnlock()
		t.Fatal("expected echo tool to still exist after reload")
	}
	if route.timeout != 15*time.Second {
		router.mu.RUnlock()
		t.Fatalf("expected tool timeout to be 15s, got %v", route.timeout)
	}
	router.mu.RUnlock()

	// Case 2: Change profile filtering rules
	filteredCfg := &config.Config{
		Version: 1,
		Servers: map[string]config.ServerConfig{
			"fixture": {
				Transport:             "stdio",
				Command:               os.Args[0],
				Args:                  []string{"-test.run=TestMCPHelperProcess"},
				Env:                   map[string]string{"EASYSKILLS_MCP_TEST_HELPER": "1"},
				StartupTimeoutSeconds: 10,
				ToolTimeoutSeconds:    15,
			},
		},
		Profiles: map[string]config.Profile{"default": {
			Servers:      []string{"*"},
			EnabledTools: []string{"fixture.non_existent"}, // this will filter out "echo"
		}},
	}
	if err := router.Reload(ctx, filteredCfg, "default", server); err != nil {
		t.Fatalf("failed to reload with filtered profile: %v", err)
	}
	router.mu.RLock()
	if _, ok := router.tools["echo"]; ok {
		router.mu.RUnlock()
		t.Fatal("expected echo tool to be filtered out after profile update")
	}
	router.mu.RUnlock()
}

func TestGatewayReloadAddsServer(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	router, err := Open(ctx, &config.Config{
		Version:  1,
		Servers:  map[string]config.ServerConfig{},
		Profiles: map[string]config.Profile{"default": {Servers: []string{"*"}}},
	}, "default", slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})))
	if err != nil {
		t.Fatal(err)
	}
	defer router.Close()

	server := mcp.NewServer(&mcp.Implementation{Name: "gateway-test", Version: "1"}, nil)
	added := &config.Config{
		Version: 1,
		Servers: map[string]config.ServerConfig{
			"fixture": {
				Transport:             "stdio",
				Command:               os.Args[0],
				Args:                  []string{"-test.run=TestMCPHelperProcess"},
				Env:                   map[string]string{"EASYSKILLS_MCP_TEST_HELPER": "1"},
				StartupTimeoutSeconds: 10,
			},
		},
		Profiles: map[string]config.Profile{"default": {Servers: []string{"*"}}},
	}
	if err := router.Reload(ctx, added, "default", server); err != nil {
		t.Fatal(err)
	}

	router.mu.RLock()
	defer router.mu.RUnlock()
	if _, ok := router.sessions["fixture"]; !ok {
		t.Fatal("new server session was not retained")
	}
	if _, ok := router.tools["echo"]; !ok {
		t.Fatal("new server tools were not discovered")
	}
}

func TestGatewayReloadRemovesDeletedServerRoutes(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	fixture := config.ServerConfig{
		Transport:             "stdio",
		Command:               os.Args[0],
		Args:                  []string{"-test.run=TestMCPHelperProcess"},
		Env:                   map[string]string{"EASYSKILLS_MCP_TEST_HELPER": "1"},
		StartupTimeoutSeconds: 10,
	}
	router, err := Open(ctx, &config.Config{
		Version:  1,
		Servers:  map[string]config.ServerConfig{"fixture": fixture},
		Profiles: map[string]config.Profile{"default": {Servers: []string{"*"}}},
	}, "default", slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})))
	if err != nil {
		t.Fatal(err)
	}
	defer router.Close()

	server := mcp.NewServer(&mcp.Implementation{Name: "gateway-test", Version: "1"}, nil)
	router.Register(server)
	router.mu.RLock()
	_, hadRoute := router.tools["echo"]
	router.mu.RUnlock()
	if !hadRoute {
		t.Fatal("expected fixture route before deletion")
	}

	if err := router.Reload(ctx, &config.Config{
		Version:  1,
		Servers:  map[string]config.ServerConfig{},
		Profiles: map[string]config.Profile{"default": {Servers: []string{"*"}}},
	}, "default", server); err != nil {
		t.Fatalf("failed to reload after deleting server: %v", err)
	}

	router.mu.RLock()
	if _, ok := router.sessions["fixture"]; ok {
		t.Fatal("deleted server session was retained")
	}
	if _, ok := router.tools["echo"]; ok {
		t.Fatal("deleted server tool route was retained")
	}
	toolCount := len(router.tools)
	router.mu.RUnlock()
	if got := router.Summary("default").Tools; len(got) != 0 || toolCount != 0 {
		t.Fatalf("summary retained deleted server tools: %#v", got)
	}
}

func TestGatewayReloadRequiredFailurePreservesExistingServer(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	initial := config.ServerConfig{
		Transport:             "stdio",
		Command:               os.Args[0],
		Args:                  []string{"-test.run=TestMCPHelperProcess"},
		Env:                   map[string]string{"EASYSKILLS_MCP_TEST_HELPER": "1"},
		StartupTimeoutSeconds: 10,
	}
	router, err := Open(ctx, &config.Config{
		Version:  1,
		Servers:  map[string]config.ServerConfig{"fixture": initial},
		Profiles: map[string]config.Profile{"default": {Servers: []string{"*"}}},
	}, "default", slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})))
	if err != nil {
		t.Fatal(err)
	}
	defer router.Close()

	failing := initial
	failing.Command = "/definitely/not/a/command"
	failing.Required = true
	if err := router.Reload(ctx, &config.Config{
		Version:  1,
		Servers:  map[string]config.ServerConfig{"fixture": failing},
		Profiles: map[string]config.Profile{"default": {Servers: []string{"*"}}},
	}, "default", mcp.NewServer(&mcp.Implementation{Name: "gateway-test", Version: "1"}, nil)); err == nil {
		t.Fatal("expected required replacement to fail")
	}

	router.mu.RLock()
	defer router.mu.RUnlock()
	if _, ok := router.sessions["fixture"]; !ok {
		t.Fatal("failed required reload removed the working session")
	}
	if _, ok := router.tools["echo"]; !ok {
		t.Fatal("failed required reload removed the working route")
	}
}

func TestGatewayReloadOptionalReplacementFailurePreservesExistingServer(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	initial := config.ServerConfig{
		Transport:             "stdio",
		Command:               os.Args[0],
		Args:                  []string{"-test.run=TestMCPHelperProcess"},
		Env:                   map[string]string{"EASYSKILLS_MCP_TEST_HELPER": "1"},
		StartupTimeoutSeconds: 10,
	}
	router, err := Open(ctx, &config.Config{
		Version:  1,
		Servers:  map[string]config.ServerConfig{"fixture": initial},
		Profiles: map[string]config.Profile{"default": {Servers: []string{"*"}}},
	}, "default", slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})))
	if err != nil {
		t.Fatal(err)
	}
	defer router.Close()

	failing := initial
	failing.Command = "/definitely/not/a/command"
	if err := router.Reload(ctx, &config.Config{
		Version:  1,
		Servers:  map[string]config.ServerConfig{"fixture": failing},
		Profiles: map[string]config.Profile{"default": {Servers: []string{"*"}}},
	}, "default", mcp.NewServer(&mcp.Implementation{Name: "gateway-test", Version: "1"}, nil)); err == nil {
		t.Fatal("expected optional replacement to fail transactionally")
	}

	router.mu.RLock()
	defer router.mu.RUnlock()
	if _, ok := router.sessions["fixture"]; !ok {
		t.Fatal("failed optional replacement removed the working session")
	}
	if _, ok := router.tools["echo"]; !ok {
		t.Fatal("failed optional replacement removed the working route")
	}
}

func TestGatewayReloadPreservesPublishedNamesAcrossProfileReevaluation(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	fixture := config.ServerConfig{
		Transport:             "stdio",
		Command:               os.Args[0],
		Args:                  []string{"-test.run=TestMCPHelperProcess"},
		Env:                   map[string]string{"EASYSKILLS_MCP_TEST_HELPER": "1"},
		StartupTimeoutSeconds: 10,
	}
	router, err := Open(ctx, &config.Config{
		Version:  1,
		Servers:  map[string]config.ServerConfig{"zeta": fixture},
		Profiles: map[string]config.Profile{"default": {Servers: []string{"*"}}},
	}, "default", slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})))
	if err != nil {
		t.Fatal(err)
	}
	defer router.Close()
	server := mcp.NewServer(&mcp.Implementation{Name: "gateway-test", Version: "1"}, nil)

	both := map[string]config.ServerConfig{"zeta": fixture, "alpha": fixture}
	if err := router.Reload(ctx, &config.Config{
		Version:  1,
		Servers:  both,
		Profiles: map[string]config.Profile{"default": {Servers: []string{"*"}}},
	}, "default", server); err != nil {
		t.Fatal(err)
	}
	if err := router.Reload(ctx, &config.Config{
		Version: 1,
		Servers: both,
		Profiles: map[string]config.Profile{"default": {
			Servers:       []string{"*"},
			DisabledTools: []string{"*.never"},
		}},
	}, "default", server); err != nil {
		t.Fatal(err)
	}

	router.mu.RLock()
	defer router.mu.RUnlock()
	if route, ok := router.tools["echo"]; !ok || route.serverName != "zeta" {
		t.Fatalf("original bare tool name changed owner after reload: %#v", router.tools)
	}
	if route, ok := router.tools["alpha__echo"]; !ok || route.serverName != "alpha" {
		t.Fatalf("collision fallback name was not preserved after reload: %#v", router.tools)
	}
}
