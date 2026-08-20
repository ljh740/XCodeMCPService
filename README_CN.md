# XCodeMCPService

[English](README.md)

本地 MCP Gateway — 将 `xcrun mcpbridge` 和其他 stdio MCP Server 聚合为一个稳定的 Streamable HTTP endpoint。

Xcode 27+ 已原生提供 headless MCP 和持久授权。只连接一个 Xcode、且客户端支持 stdio 时，应优先直接运行 [`xcrun mcpbridge`](https://developer.apple.com/documentation/xcode/giving-agentic-coding-tools-access-to-xcode)，无需安装本项目。本项目适用于需要 HTTP transport、多 MCP Server 聚合、统一进程治理或旧版 Xcode 兼容的场景。

```
MCP Client ──HTTP/POST──▶ XCodeMCPService ──stdio──▶ MCP Server (xcrun mcpbridge)
           ◀──JSON-RPC───                  ◀──pipe──
```

## 是否需要本项目

| 场景 | 推荐方式 |
|------|----------|
| Xcode 27+、单个本地 Agent、客户端支持 stdio | 直接配置 `xcrun mcpbridge` |
| 客户端只支持 HTTP，或多个客户端需要稳定的 localhost endpoint | 使用 XCodeMCPService |
| 需要聚合多个 MCP Server、统一超时、重启和日志 | 使用 XCodeMCPService |
| Xcode 26.3+，需要绑定运行中的 Xcode | 使用 XCodeMCPService 的兼容模式 |

Xcode 27+ 原生直连示例：

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

首次使用 headless MCP 时，按当前 `xcode-select` 指向的 Xcode 启用一次：

```bash
sudo xcrun mcp-server enable
xcrun mcp-server status
```

> 本项目不会自动执行 `mcp-server enable`，也不会自动启用 `--unsafe-always-allow-all-agents`。Apple 仅建议在隔离的无人值守环境中使用 unsafe 模式；日常开发机应保留 Agent 授权检查。

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

# 查看可用身份；Xcode 27 长期授权需要 Apple 信任链中的签名身份
security find-identity -v -p codesigning

# 本机安装可使用 Apple Development，并关闭分发用 secure timestamp
CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
CODE_SIGN_TIMESTAMP=none \
bash build-app.sh

# 安装到 Applications
cp -r "build/XCode MCP Service.app" /Applications/
```

> 默认 ad-hoc 签名以及普通自签证书在 Xcode 27 beta 5 中仍可能被识别为 `unsigned`，只能获得临时授权。正式分发可改用 `Developer ID Application`，并保留默认 secure timestamp。打包脚本会为 App 和内层 CLI 一并加入 Apple Events entitlement。

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
| Zip 压缩包 | `build/XCodeMCPService.app.zip` | App 压缩包（默认 ad-hoc 签名，可通过 `CODE_SIGN_IDENTITY` 正式签名） |
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

保存为 `~/Library/Application Support/XCodeMCPService/config.json`。

> 不创建配置文件时，服务会使用内置默认配置（端口 13339，自动启动 `xcrun mcpbridge`）。服务会优先选择当前运行的唯一 Xcode；多实例时优先当前活跃或 `xcode-select` 选中的安装。Xcode 27 的 headless MCP 已启用时，服务优先使用该连接，并刻意不设置 `MCP_XCODE_PID`，让 agent 授权在“重启服务”后继续有效。旧版 Xcode 或未启用 headless 模式的 Xcode 27 才绑定检测到的 GUI 进程。可通过 server 的 `env.DEVELOPER_DIR` 或 `env.MCP_XCODE_PID` 显式覆盖。首次启动时自动写入默认路径。

Xcode 27 的 headless MCP 只需针对当前选中的 Xcode 启用一次：

```bash
sudo xcrun mcp-server enable
xcrun mcp-server status
```

如需显式指定另一个 Xcode，可仅在命令中传入其 Developer 目录：

```bash
sudo env DEVELOPER_DIR="/path/to/Xcode.app/Contents/Developer" xcrun mcp-server enable
```

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
| `capabilityTimeout` | Int | `15000` | 启动和重连时获取单类 capability 的超时（毫秒） |
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

测试覆盖：HTTP 解析/序列化/路由、会话管理、ResponseQueue、ID 映射、Xcode 运行时选择和进程生命周期管理等。

## CI/CD

- `.github/workflows/ci.yml`：在每次 push 和 pull request 时执行 `swift build -c release` 与 `swift test --parallel`。
- `.github/workflows/release.yml`：在推送 `v*` tag 或手动触发时执行 `bash build-app.sh`，并上传 `.app`、`dmg`、`zip` 及对应的 SHA-256 校验文件作为 workflow artifact。
- tag 构建会把 `build/XCodeMCPService-<tag>.dmg`、`build/XCodeMCPService-<tag>.dmg.sha256`、`build/XCodeMCPService-<tag>.zip`、`build/XCodeMCPService-<tag>.zip.sha256` 自动发布到同名 GitHub Release。

## 许可证

MIT License

## 致谢

- [Model Context Protocol](https://modelcontextprotocol.io/) — MCP 规范
- [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) — MCP Swift SDK
