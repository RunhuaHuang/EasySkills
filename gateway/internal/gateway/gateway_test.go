package gateway

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/RunhuaHuang/EasySkills/gateway/internal/config"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestNamespacedToolName(t *testing.T) {
	if got := namespacedToolName("github", "create-issue"); got != "github__create-issue" {
		t.Fatalf("got %q", got)
	}
	got := namespacedToolName("server with spaces", strings.Repeat("x", 200))
	if len(got) > 128 {
		t.Fatalf("tool name has length %d", len(got))
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
		Name:      "fixture__echo",
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
