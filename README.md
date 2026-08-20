# XCodeMCPService

[中文文档](README_CN.md)

Local MCP Gateway — Aggregate `xcrun mcpbridge` and other stdio MCP servers behind one stable Streamable HTTP endpoint.

Xcode 27+ provides native headless MCP and persistent authorization. If you only need one Xcode connection and your client supports stdio, prefer running [`xcrun mcpbridge`](https://developer.apple.com/documentation/xcode/giving-agentic-coding-tools-access-to-xcode) directly and do not install this project. Use this project when you need HTTP transport, multi-server aggregation, centralized process management, or compatibility with older Xcode versions.

```
MCP Client ──HTTP/POST──▶ XCodeMCPService ──stdio──▶ MCP Server (xcrun mcpbridge)
           ◀──JSON-RPC───                  ◀──pipe──
```

## Do You Need This Project?

| Scenario | Recommended approach |
|----------|----------------------|
| Xcode 27+, one local agent, client supports stdio | Configure `xcrun mcpbridge` directly |
| HTTP-only client, or multiple clients need a stable localhost endpoint | Use XCodeMCPService |
| Multiple MCP servers need aggregation, timeouts, restart, and shared logging | Use XCodeMCPService |
| Xcode 26.3+ needs to bind to a running Xcode instance | Use XCodeMCPService compatibility mode |

Direct Xcode 27+ configuration example:

```json
{
  "mcpServers": {
    "xcode-tools": {
      "command": "xcrun",
      "args": ["mcpbridge"]
    }
  }
}
```

Enable headless MCP once for the Xcode selected by `xcode-select`:

```bash
sudo xcrun mcp-server enable
xcrun mcp-server status
```

> This project never runs `mcp-server enable` or enables `--unsafe-always-allow-all-agents` automatically. Apple recommends unsafe mode only for isolated unattended environments; keep per-agent authorization enabled on a daily workstation.

## Features

- **Multi-server aggregation** — Manage multiple MCP subprocesses and auto-aggregate downstream capabilities; tool names stay original in single-server mode and switch to namespace prefixes (`serverName__toolName`) only when multiple servers are configured
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

# List available identities; durable Xcode 27 trust requires an Apple-issued chain
security find-identity -v -p codesigning

# Apple Development is suitable for a local install; disable distribution timestamps
CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
CODE_SIGN_TIMESTAMP=none \
bash build-app.sh

# Install to Applications
cp -r "build/XCode MCP Service.app" /Applications/
```

> The default ad-hoc signature and ordinary self-signed certificates may still appear as `unsigned` in Xcode 27 beta 5 and receive temporary grants only. For distribution, use `Developer ID Application` and keep the default secure timestamp. The packaging script applies the Apple Events entitlement to both the app and its bundled CLI.

Build output is at `build/XCode MCP Service.app`, containing:

| Component | Path | Description |
|-----------|------|-------------|
| Status bar app | `Contents/MacOS/XCodeMCPStatusBar` | Main entry, visual status bar management |
| CLI service | `Contents/MacOS/XCodeMCPService` | Command-line service (for background use) |

The packaging script also produces:

| Artifact | Path | Description |
|----------|------|-------------|
| Disk image | `build/XCodeMCPService.dmg` | Recommended macOS release package |
| SHA-256 | `build/XCodeMCPService.dmg.sha256` | Disk image checksum |
| Zip archive | `build/XCodeMCPService.app.zip` | App archive (ad-hoc signed by default; stable identity is optional) |
| SHA-256 | `build/XCodeMCPService.app.zip.sha256` | Archive checksum |

> You can locate standalone binaries with `swift build -c release --show-bin-path`.

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
    "capabilityTimeout": 15000,
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

> Without a config file, the service uses built-in defaults (port 13339, auto-start `xcrun mcpbridge`). The service selects the only running Xcode first; with multiple instances it prefers the active or `xcode-select`-selected installation. When Xcode 27 headless MCP is enabled, it prefers that connection and intentionally leaves `MCP_XCODE_PID` unset so persistent agent grants survive service restarts. Older Xcode versions, or Xcode 27 with headless mode disabled, bind to the detected GUI process. Set `env.DEVELOPER_DIR` or `env.MCP_XCODE_PID` for an explicit override. A default config file is created on first launch.

Enable the Xcode 27 headless MCP experience once for the currently selected Xcode:

```bash
sudo xcrun mcp-server enable
xcrun mcp-server status
```

To target another Xcode explicitly, pass only that installation's Developer directory:

```bash
sudo env DEVELOPER_DIR="/path/to/Xcode.app/Contents/Developer" xcrun mcp-server enable
```

### 2. Start the service

```bash
# Via .app (status bar app)
open "/Applications/XCode MCP Service.app"

# Or via CLI
BIN_DIR="$(swift build -c release --show-bin-path)"
"$BIN_DIR/XCodeMCPService"

# Specify config file
"$BIN_DIR/XCodeMCPService" --config /path/to/config.json

# Via environment variable
CONFIG_PATH=/path/to/config.json "$BIN_DIR/XCodeMCPService"
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
| `capabilityTimeout` | Int | `15000` | Per-category capability timeout during startup and reconnect (ms) |
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

Tests cover HTTP parsing/serialization/routing, session management, ResponseQueue, ID mapping, Xcode runtime selection, process lifecycle management, and more.

## CI/CD

- `.github/workflows/ci.yml`: runs `swift build -c release` and `swift test --parallel` on every push and pull request.
- `.github/workflows/release.yml`: runs `bash build-app.sh` on every `v*` tag push or manual dispatch, then uploads the `.app` bundle, `dmg`, `zip`, and SHA-256 checksum files as workflow artifacts.
- Tag builds also publish `build/XCodeMCPService-<tag>.dmg`, `build/XCodeMCPService-<tag>.dmg.sha256`, `build/XCodeMCPService-<tag>.zip`, and `build/XCodeMCPService-<tag>.zip.sha256` to the matching GitHub Release.

## License

MIT License

## Acknowledgments

- [Model Context Protocol](https://modelcontextprotocol.io/) — MCP specification
- [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) — MCP Swift SDK
