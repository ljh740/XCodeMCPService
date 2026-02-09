# XCodeMCPService

[中文文档](README_CN.md)

MCP Forward Bridge — Keep `xcrun mcpbridge` running in the background and forward MCP requests via Streamable HTTP.

Every MCP client connection spawns a new `xcrun mcpbridge` process, triggering an Xcode authorization prompt. This project keeps a single [`xcrun mcpbridge`](https://developer.apple.com/documentation/xcode/giving-agentic-coding-tools-access-to-xcode) process alive and aggregates forwarded requests, eliminating repeated authorization.

```
MCP Client ──HTTP/POST──▶ XCodeMCPService ──stdio──▶ MCP Server (xcrun mcpbridge)
           ◀──JSON-RPC───                  ◀──pipe──
```

## Features

- **Multi-server aggregation** — Manage multiple MCP subprocesses, auto-aggregate Tools / Resources / Prompts with namespace prefixes (`serverName__toolName`) to avoid conflicts
- **Streamable HTTP Transport** — Lightweight HTTP server based on `NWListener`, providing `/mcp` endpoint, localhost only
- **Session management** — Independent session per client with secure token identification
- **Process lifecycle** — Crash detection + exponential backoff auto-restart
- **macOS status bar app** — Visual service status, one-click start/stop

## Requirements

- macOS 15.0+
- Swift 6.0+
- Xcode 26.3+ (`xcrun mcpbridge` support)

## Installation

```bash
git clone git@github.com:ljh740/XCodeMCPService.git
cd XCodeMCPService

# Build .app (recommended)
bash build-app.sh

# Install to Applications
cp -r "build/XCode MCP Service.app" /Applications/
```

Build output is at `build/XCode MCP Service.app`, containing:

| Component | Path | Description |
|-----------|------|-------------|
| Status bar app | `Contents/MacOS/XCodeMCPStatusBar` | Main entry, visual status bar management |
| CLI service | `Contents/MacOS/XCodeMCPService` | Command-line service (for background use) |

> You can also run `swift build -c release` to get standalone binaries at `.build/release/`.

## Quick Start

### 1. Create config file

```bash
mkdir -p ~/Library/Application\ Support/XCodeMCPService
```

```json
{
  "bridge": {
    "port": 13339,
    "host": "127.0.0.1",
    "timeout": 30000,
    "logLevel": "info"
  },
  "servers": [
    {
      "name": "xcode-tools",
      "command": "xcrun",
      "args": ["mcpbridge"],
      "enabled": true
    }
  ]
}
```

Save as `~/Library/Application Support/XCodeMCPService/config.json`.

> Without a config file, the service uses built-in defaults (port 13339, auto-start `xcrun mcpbridge`). A default config file is created on first launch.

### 2. Start the service

```bash
# Via .app (status bar app)
open "/Applications/XCode MCP Service.app"

# Or via CLI
.build/release/XCodeMCPService

# Specify config file
.build/release/XCodeMCPService --config /path/to/config.json

# Via environment variable
CONFIG_PATH=/path/to/config.json .build/release/XCodeMCPService
```

### 3. Configure MCP client

Add to your MCP client configuration:

```json
{
  "mcpServers": {
    "local-mcp": {
      "type": "http",
      "url": "http://127.0.0.1:13339/mcp"
    }
  }
}
```

## Configuration Reference

### BridgeConfig

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `port` | Int | `13339` | HTTP listen port |
| `host` | String | `"127.0.0.1"` | Listen address (`127.0.0.1` or `localhost` only) |
| `timeout` | Int | `30000` | Request timeout (ms) |
| `logLevel` | String | `"info"` | Log level: debug / info / warn / error |

### ServerConfig

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | String | — | Unique server name |
| `command` | String | — | Launch command |
| `args` | [String] | `[]` | Command arguments |
| `env` | {String: String}? | `nil` | Environment variables |
| `enabled` | Bool | `true` | Whether enabled |

### Config file lookup order

1. `--config` CLI argument
2. `CONFIG_PATH` environment variable
3. `~/Library/Application Support/XCodeMCPService/config.json`
4. Built-in defaults (auto-written to default path on first launch)

### Logs

Log files are stored by date in `~/Library/Application Support/XCodeMCPService/logs/` as `yyyy-MM-dd.log`. Also output to stderr.

## Testing

```bash
swift test
```

83 tests covering: HTTP parsing/serialization/routing, session management, ResponseQueue, ID mapping, process lifecycle management, etc.

## License

MIT License

## Acknowledgments

- [Model Context Protocol](https://modelcontextprotocol.io/) — MCP specification
- [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) — MCP Swift SDK
