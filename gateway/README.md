# EasySkills MCP Gateway

The Gateway is the third EasySkills capability channel. It is a small Go MCP
server that speaks stdio to an Agent, connects to multiple downstream MCP
servers, and republishes their tools.

## Build and test

Go 1.25 or newer is required to build from source. Release users receive a
static platform binary and do not need Go.

```bash
go test ./...
go vet ./...
CGO_ENABLED=0 go build -trimpath -o easyskills-mcp ./cmd/easyskills-mcp
```

The test suite includes an end-to-end fixture server and verifies discovery,
namespacing, and routed calls over MCP.

## Commands

```text
easyskills-mcp [serve|connect] [--config PATH] [--profile NAME]
easyskills-mcp validate [--config PATH]
easyskills-mcp init [--config PATH]
easyskills-mcp list [--config PATH] [--json]
easyskills-mcp test [--config PATH] [--profile NAME]
easyskills-mcp path
easyskills-mcp version
```

Running without a command starts the stdio Gateway. The default configuration
is `~/EasySkills/mcp/servers.json`; `EASYSKILLS_MCP_CONFIG` overrides it.

The Gateway is not a permanent daemon. A configured Agent launches it as a
stdio child process when the Agent starts and closes it with the Agent session.
Users do not need to keep a terminal window open; only a Gateway started
manually in that terminal stops when the terminal is closed.

## Routing behavior

- Downstream transports: stdio, Streamable HTTP, and SSE.
- Agent-facing transport: stdio.
- Exposed name: `<tool>`.
- Optional servers degrade independently; a failed `required` server stops
  startup.
- Connection/discovery and individual tool calls have configurable timeouts.
- Server filters match the downstream tool name. Profile filters match
  `server.tool`.
- The v1 Gateway exposes tools only. It does not proxy Resources, Prompts,
  Sampling, or Elicitation.

Environment variables and HTTP headers may contain plaintext credentials. The
Gateway never prints their values; EasySkills stores the JSON with owner-only
permissions on Unix.
