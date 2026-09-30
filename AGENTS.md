# 项目协作指南

本文件是项目级指令入口。`CLAUDE.md` 通过相对符号链接指向本文件；修改规则时只编辑 `AGENTS.md`。

## 项目定位与结构

XCodeMCPService 是 macOS 本地 MCP Gateway，将 `xcrun mcpbridge` 等 stdio MCP Server 聚合为 Streamable HTTP endpoint，同时提供 CLI 和状态栏应用。

- `Package.swift`：Swift Package Manager 清单，Swift tools 6.0，最低 macOS 15。
- `Sources/MCPServiceCore/`：共享服务逻辑，包括 HTTP、会话、请求路由、能力聚合、stdio 客户端、进程生命周期、Xcode 运行时和 LLDB 集成。
- `Sources/XCodeMCPService/`：CLI 入口，使用 ArgumentParser，负责配置入口和启动、退出流程。
- `Sources/XCodeMCPStatusBar/`：AppKit 状态栏应用、服务状态展示和本地化资源。
- `Tests/MCPServiceCoreTests/`：Swift Testing 测试，使用 `@Suite`、`@Test` 和 `#expect`。
- `scripts/signing_identity.rb` 与 `Tests/signing_identity_test.rb`：签名身份发现及 Minitest 测试。
- `build-app.sh`：构建、签名并生成 App、DMG、Zip 和校验文件。
- `README.md` / `README_CN.md`：英文、中文使用文档；用户可见行为或命令变化时同步维护。

## 修改原则

- 修改前阅读相关实现、调用方和测试，沿用现有模式；只改任务要求的内容。
- 共享服务逻辑放在 `MCPServiceCore`，CLI 和状态栏入口复用核心能力，避免重复实现。
- 遵循现有 Swift 命名、缩进和 import 风格；标识符使用英文，新增解释性注释使用中文。
- 遵守 Swift 并发隔离：沿用现有 actor、`Sendable` 和 UI 主线程边界；不得通过关闭检查或无依据的 `@unchecked Sendable` 掩盖问题。
- 修复错误原因，不用吞错、跳过测试或单纯延长超时掩盖失败。生命周期变更需考虑取消、断连、重连和资源释放。
- 保持配置兼容性与 MCP 协议行为；配置默认值、工具命名、超时或错误映射变更需核对对应测试。
- 状态栏新增或修改可见文案时，同步检查 `Resources/en.lproj/Localizable.strings` 和 `Resources/zh-Hans.lproj/Localizable.strings`，沿用 `StatusBarLocalization`。

## 运行与兼容性边界

- HTTP 服务保持仅监听 localhost 的现有约束。
- 保留 Xcode headless MCP 与 GUI 进程绑定的兼容路径，以及显式 `DEVELOPER_DIR` / `MCP_XCODE_PID` 配置的语义。
- 不自动启用 `mcp-server` 或 `--unsafe-always-allow-all-agents`；不把用户机器上的授权状态当作通用默认值。
- 签名调整遵循 `build-app.sh` 和签名发现脚本的现有策略；实际签名失败必须显式失败，不静默降级。
- 构建、运行、安装和真实 Xcode / LLDB 集成验证是不同步骤，汇报时明确哪些已验证，哪些未运行。

## 构建与验证

以 `Package.swift` 和 `.github/workflows/ci.yml` 为准，在仓库根目录执行：

```bash
swift build -c release
swift test --parallel
bash -n build-app.sh
/usr/bin/ruby Tests/signing_identity_test.rb
```

- 定向验证可用 `swift test --filter <测试名称>`；逻辑修复优先补充能复现问题的回归测试，沿用现有 fixture 和依赖注入方式。
- 纯文档或符号链接修改检查内容、链接和 diff 即可，无需构建应用。
- 需要验证打包时执行 `bash build-app.sh`；它会重新生成 `build/` 内的产物并进行签名。
- 二进制路径通过 `swift build -c release --show-bin-path` 获取，不硬编码架构目录。
- 自动化测试通过不能替代真实 Xcode、授权、LLDB 或状态栏交互验证；按改动范围选择验证方式。

## 知识与工作区

- 使用 Maestro 的会话在项目探索前执行任务相关的 `maestro search "<关键词>" --json`，对适用规范显式 `maestro load`；`.workflow/` 是被 Git 忽略的本地知识目录。
- 本仓库的构建和测试命令不依赖 Maestro；共享规则应能从本文件及受版本控制的代码、文档中理解。
- 不提交构建产物、机器本地配置、凭据或与任务无关的文件；保留用户已有改动。
- 结束前检查修改范围和 `git diff --check`，说明验证结果；提交代码前重新核对暂存区。
