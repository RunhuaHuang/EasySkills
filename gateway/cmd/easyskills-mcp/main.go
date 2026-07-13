package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"sort"
	"strings"
	"syscall"

	"github.com/RunhuaHuang/EasySkills/gateway/internal/config"
	gatewayruntime "github.com/RunhuaHuang/EasySkills/gateway/internal/gateway"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

var (
	version = "dev"
	commit  = "unknown"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "easyskills-mcp:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return serve(nil)
	}
	switch args[0] {
	case "serve", "gateway", "connect":
		return serve(args[1:])
	case "validate":
		return validate(args[1:])
	case "init":
		return initConfig(args[1:])
	case "list":
		return listConfig(args[1:])
	case "test":
		return testGateway(args[1:])
	case "path":
		fmt.Println(config.DefaultPath())
		return nil
	case "version", "--version", "-version":
		fmt.Printf("easyskills-mcp %s (%s)\n", version, commit)
		return nil
	case "help", "--help", "-h":
		printHelp()
		return nil
	default:
		return fmt.Errorf("unknown command %q (run easyskills-mcp help)", args[0])
	}
}

func commonFlags(name string, args []string) (*flag.FlagSet, *string, *string, error) {
	set := flag.NewFlagSet(name, flag.ContinueOnError)
	set.SetOutput(os.Stderr)
	configPath := set.String("config", config.DefaultPath(), "path to EasySkills MCP JSON")
	profile := set.String("profile", "default", "MCP profile to expose")
	if err := set.Parse(args); err != nil {
		return nil, nil, nil, err
	}
	return set, configPath, profile, nil
}

func serve(args []string) error {
	_, configPath, profile, err := commonFlags("serve", args)
	if err != nil {
		return err
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("MCP config not found at %s; create it in EasySkills WebUI or run easyskills-mcp init", *configPath)
		}
		return err
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	router, err := gatewayruntime.Open(ctx, cfg, *profile, logger)
	if err != nil {
		return err
	}
	defer router.Close()
	server := mcp.NewServer(
		&mcp.Implementation{Name: "easyskills", Title: "EasySkills MCP Gateway", Version: version},
		&mcp.ServerOptions{Instructions: "Tools are routed through EasySkills. Tool names use the server__tool namespace."},
	)
	router.Register(server)
	return server.Run(ctx, &mcp.StdioTransport{})
}

func validate(args []string) error {
	set := flag.NewFlagSet("validate", flag.ContinueOnError)
	configPath := set.String("config", config.DefaultPath(), "path to EasySkills MCP JSON")
	if err := set.Parse(args); err != nil {
		return err
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	fmt.Printf("Valid EasySkills MCP configuration: %d servers, %d profiles\n", len(cfg.Servers), len(cfg.Profiles))
	return nil
}

func initConfig(args []string) error {
	set := flag.NewFlagSet("init", flag.ContinueOnError)
	configPath := set.String("config", config.DefaultPath(), "path to EasySkills MCP JSON")
	if err := set.Parse(args); err != nil {
		return err
	}
	if _, err := os.Stat(*configPath); err == nil {
		return fmt.Errorf("config already exists at %s", *configPath)
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := config.Save(*configPath, config.Default()); err != nil {
		return err
	}
	fmt.Println(*configPath)
	return nil
}

type listedServer struct {
	Name      string `json:"name"`
	Enabled   bool   `json:"enabled"`
	Transport string `json:"transport"`
	Target    string `json:"target"`
}

func listConfig(args []string) error {
	set := flag.NewFlagSet("list", flag.ContinueOnError)
	configPath := set.String("config", config.DefaultPath(), "path to EasySkills MCP JSON")
	asJSON := set.Bool("json", false, "print JSON")
	if err := set.Parse(args); err != nil {
		return err
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	names := make([]string, 0, len(cfg.Servers))
	for name := range cfg.Servers {
		names = append(names, name)
	}
	sort.Strings(names)
	items := make([]listedServer, 0, len(names))
	for _, name := range names {
		server := cfg.Servers[name]
		target := server.URL
		if server.NormalizedTransport() == "stdio" {
			target = strings.TrimSpace(server.Command + " " + strings.Join(server.Args, " "))
		}
		items = append(items, listedServer{Name: name, Enabled: server.IsEnabled(), Transport: server.NormalizedTransport(), Target: target})
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(items)
	}
	for _, item := range items {
		state := "enabled"
		if !item.Enabled {
			state = "disabled"
		}
		fmt.Printf("%-24s %-8s %-6s %s\n", item.Name, state, item.Transport, item.Target)
	}
	return nil
}

func testGateway(args []string) error {
	set := flag.NewFlagSet("test", flag.ContinueOnError)
	configPath := set.String("config", config.DefaultPath(), "path to EasySkills MCP JSON")
	profile := set.String("profile", "default", "MCP profile to test")
	serverName := set.String("server", "", "test one configured server, including when disabled")
	if err := set.Parse(args); err != nil {
		return err
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	if *serverName != "" {
		serverCfg, ok := cfg.Servers[*serverName]
		if !ok {
			return fmt.Errorf("MCP server %q does not exist", *serverName)
		}
		enabled := true
		serverCfg.Enabled = &enabled
		cfg.Servers = map[string]config.ServerConfig{*serverName: serverCfg}
		cfg.Profiles = map[string]config.Profile{"__single__": {Servers: []string{*serverName}}}
		*profile = "__single__"
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	router, err := gatewayruntime.Open(ctx, cfg, *profile, logger)
	if err != nil {
		return err
	}
	defer router.Close()
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(router.Summary(*profile))
}

func printHelp() {
	fmt.Print(`EasySkills MCP Gateway

Usage:
  easyskills-mcp [serve|connect] [--config PATH] [--profile NAME]
  easyskills-mcp validate [--config PATH]
  easyskills-mcp init [--config PATH]
  easyskills-mcp list [--config PATH] [--json]
  easyskills-mcp test [--config PATH] [--profile NAME] [--server NAME]
  easyskills-mcp path
  easyskills-mcp version

Running without a command starts the stdio MCP gateway.
`)
}
