# XCodeMCPService

[English](README.md)

MCP Forward Bridge — 让 `xcrun mcpbridge` 常驻后台，通过 Streamable HTTP 转发 MCP 请求。

每次 MCP 客户端连接都会启动新的 `xcrun mcpbridge` 进程，触发 Xcode 授权弹窗。本项目通过常驻一个 [`xcrun mcpbridge`](https://developer.apple.com/documentation/xcode/giving-agentic-coding-tools-access-to-xcode) 进程并聚合转发请求，避免重复授权。

```
MCP Client ──HTTP/POST──▶ XCodeMCPService ──stdio──▶ MCP Server (xcrun mcpbridge)
           ◀──JSON-RPC───                  ◀──pipe──
```

## 功能特性

- **多服务器聚合** — 同时管理多个 MCP 子进程并自动聚合下游 capabilities；单下游时对外暴露原始 tool 名，多下游时才切换为命名空间前缀（`serverName__toolName`）避免冲突
- **Streamable HTTP Transport** — 基于 `NWListener` 的轻量 HTTP 服务器，提供 `/mcp` endpoint，仅监听 localhost
- **会话管理** — 每个客户端独立会话，安全 token 标识
- **进程生命周期** — 崩溃检测 + 指数退避自动重启
- **macOS 状态栏应用** — 可视化服务状态，一键启停

## 系统要求

- macOS 15.0+
- Swift 6.0+
- Xcode 26.3+（`xcrun mcpbridge` 支持）

## 安装

```bash
git clone git@github.com:ljh740/XCodeMCPService.git
cd XCodeMCPService

# 构建 .app（推荐）
bash build-app.sh

# 安装到 Applications
cp -r "build/XCode MCP Service.app" /Applications/
```

构建产物位于 `build/XCode MCP Service.app`，包含：

| 组件 | 路径 | 说明 |
|------|------|------|
| 状态栏应用 | `Contents/MacOS/XCodeMCPStatusBar` | 主入口，状态栏可视化管理 |
| CLI 服务 | `Contents/MacOS/XCodeMCPService` | 命令行服务（适合后台运行） |

打包脚本还会额外产出：

| 产物 | 路径 | 说明 |
|------|------|------|
| DMG 镜像 | `build/XCodeMCPService.dmg` | 推荐的 macOS 分发包 |
| SHA-256 | `build/XCodeMCPService.dmg.sha256` | DMG 校验值 |
| Zip 压缩包 | `build/XCodeMCPService.app.zip` | 未签名的分发包 |
| SHA-256 | `build/XCodeMCPService.app.zip.sha256` | 压缩包校验值 |

> 独立二进制的真实目录请通过 `swift build -c release --show-bin-path` 查询。

## 快速开始

### 1. 创建配置文件

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

保存为 `~/Library/Application Support/XCodeMCPService/config.json`。

> 不创建配置文件时，服务会使用内置默认配置（端口 13339，自动启动 `xcrun mcpbridge`）。首次启动时自动写入默认路径。

### 2. 启动服务

```bash
# 通过 .app 启动（状态栏应用）
open "/Applications/XCode MCP Service.app"

# 或通过 CLI 启动
BIN_DIR="$(swift build -c release --show-bin-path)"
"$BIN_DIR/XCodeMCPService"

# 指定配置文件
"$BIN_DIR/XCodeMCPService" --config /path/to/config.json

# 通过环境变量
CONFIG_PATH=/path/to/config.json "$BIN_DIR/XCodeMCPService"
```

### 3. 配置 MCP 客户端

在 MCP 客户端的配置文件中添加：

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

## 配置参考

### BridgeConfig

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `port` | Int | `13339` | HTTP 监听端口 |
| `host` | String | `"127.0.0.1"` | 监听地址（仅支持 `127.0.0.1` 或 `localhost`） |
| `timeout` | Int | `30000` | 请求超时（毫秒） |
| `logLevel` | String | `"info"` | 日志级别：debug / info / warn / error |

### ServerConfig

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `name` | String | — | 服务器唯一名称 |
| `command` | String | — | 启动命令 |
| `args` | [String] | `[]` | 命令参数 |
| `env` | {String: String}? | `nil` | 环境变量 |
| `enabled` | Bool | `true` | 是否启用 |

### 配置文件查找顺序

1. `--config` 命令行参数
2. `CONFIG_PATH` 环境变量
3. `~/Library/Application Support/XCodeMCPService/config.json`
4. 内置默认配置（首次启动时自动写入默认路径）

### 日志

日志文件按日期存放在 `~/Library/Application Support/XCodeMCPService/logs/` 目录下，格式为 `yyyy-MM-dd.log`。同时输出到 stderr。

## 测试

```bash
swift test
```

83 个测试覆盖：HTTP 解析/序列化/路由、会话管理、ResponseQueue、ID 映射、进程生命周期管理等。

## CI/CD

- `.github/workflows/ci.yml`：在每次 push 和 pull request 时执行 `swift build -c release` 与 `swift test --parallel`。
- `.github/workflows/release.yml`：在推送 `v*` tag 或手动触发时执行 `bash build-app.sh`，并上传 `.app`、`dmg`、`zip` 及对应的 SHA-256 校验文件作为 workflow artifact。
- tag 构建会把 `build/XCodeMCPService-<tag>.dmg`、`build/XCodeMCPService-<tag>.dmg.sha256`、`build/XCodeMCPService-<tag>.zip`、`build/XCodeMCPService-<tag>.zip.sha256` 自动发布到同名 GitHub Release。

## 许可证

MIT License

## 致谢

- [Model Context Protocol](https://modelcontextprotocol.io/) — MCP 规范
- [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) — MCP Swift SDK
