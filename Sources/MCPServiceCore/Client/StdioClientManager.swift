import Foundation
import Logging
import MCP

// MARK: - StdioClientManaging Protocol

/// Protocol abstracting StdioClientManager for testability
public protocol StdioClientManaging: Actor, Sendable {
    func startServer(name: String) async throws
    func stopServer(name: String) async
    func getClient(name: String) -> Client?
    func getActiveServers() -> [String]
    func isServerRunning(name: String) -> Bool
}

// MARK: - StdioClientManager

/// 管理多个 stdio MCP 子进程的生命周期和通信
public actor StdioClientManager: StdioClientManaging {

    // MARK: - ServerInfo

    /// 运行中的 MCP 服务器信息
    public struct ServerInfo: Sendable {
        public let client: Client
        public let process: Process
        public let stdinPipe: Pipe
        public let stdoutPipe: Pipe
        public let config: ServerConfig
    }

    // MARK: - Properties

    private var serverConfigs: [String: ServerConfig]
    private var servers: [String: ServerInfo] = [:]

    private let logger = bridgeLogger.child(label: "client-manager")

    // MARK: - Init

    public init(configs: [ServerConfig]) {
        var map: [String: ServerConfig] = [:]
        for config in configs {
            map[config.name] = config
        }
        self.serverConfigs = map
    }

    // MARK: - Lifecycle

    /// 启动指定名称的 MCP 服务器子进程并建立连接
    public func startServer(name: String) async throws {
        guard let config = serverConfigs[name] else {
            throw BridgeError.serverNotFound("Server config not found: \(name)")
        }

        // 如果已在运行，先停止
        if servers[name] != nil {
            logger.warning("Server '\(name)' already running, stopping first")
            await stopServer(name: name)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [config.command] + config.args

        // 合并当前进程环境变量与配置的环境变量
        var environment = ProcessInfo.processInfo.environment
        if let env = config.env {
            for (key, value) in env {
                environment[key] = value
            }
        }
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // 将 stderr 重定向到 /dev/null，避免子进程 stderr 污染父进程输出
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            throw BridgeError.internalError("Failed to start server '\(name)': \(error)")
        }

        logger.info("Server '\(name)' process started", metadata: [
            "pid": "\(process.processIdentifier)",
            "command": config.command,
        ])

        // PipeTransport: 从子进程 stdout 读取，写入子进程 stdin
        let transport = PipeTransport(
            readHandle: stdoutPipe.fileHandleForReading,
            writeHandle: stdinPipe.fileHandleForWriting,
            logger: Logger(label: "mcp.transport.pipe.\(name)")
        )

        let client = Client(name: "mcp-forward", version: "1.0.0")

        logger.info("Server '\(name)' connecting via MCP client...")
        let connectStart = ContinuousClock.now
        do {
            _ = try await asyncWithTimeout(Self.connectTimeoutMs) {
                try await client.connect(transport: transport)
            }
        } catch is AsyncTimeoutError {
            let elapsed = ContinuousClock.now - connectStart
            logger.error("Server '\(name)' connection timed out", metadata: [
                "timeoutMs": "\(Self.connectTimeoutMs)",
                "elapsed": "\(elapsed)",
            ])
            await client.disconnect()
            kill(process.processIdentifier, SIGKILL)
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            throw BridgeError.internalError(
                "Connection to server '\(name)' timed out after \(Self.connectTimeoutMs)ms")
        } catch {
            // Connection failed — process is useless; use SIGKILL for immediate cleanup
            // (SIGTERM may be ignored by a stuck child, causing process leaks)
            await client.disconnect()
            kill(process.processIdentifier, SIGKILL)
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            throw BridgeError.internalError(
                "Failed to connect to server '\(name)': \(error)")
        }

        let connectDuration = ContinuousClock.now - connectStart

        servers[name] = ServerInfo(
            client: client,
            process: process,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe,
            config: config
        )

        logger.info("Server '\(name)' connected successfully", metadata: [
            "elapsed": "\(connectDuration)",
        ])
    }

    /// Force-kill timeout: maximum time (in milliseconds) to wait after SIGTERM before escalating to SIGKILL.
    private static let forceKillTimeoutMs: Int = 5000

    /// Maximum time (in milliseconds) to wait for MCP client connection (initialize handshake).
    private static let connectTimeoutMs: Int = 15000

    /// Polling interval (in milliseconds) for checking process liveness after SIGTERM.
    private static let pollIntervalMs: UInt64 = 100

    /// 停止指定名称的 MCP 服务器
    /// Sends SIGTERM first, then escalates to SIGKILL if the process does not exit
    /// within `forceKillTimeoutMs` milliseconds.
    public func stopServer(name: String) async {
        guard let info = servers.removeValue(forKey: name) else {
            logger.warning("Server '\(name)' not found in running servers")
            return
        }

        // Ensure pipes are closed on all exit paths to prevent fd leaks
        defer {
            try? info.stdinPipe.fileHandleForWriting.close()
            try? info.stdoutPipe.fileHandleForReading.close()
        }

        await info.client.disconnect()

        // Fast path: process already exited
        guard info.process.isRunning else {
            logger.info("Server '\(name)' already exited")
            return
        }

        let pid = info.process.processIdentifier

        // Step 1: Send SIGTERM (graceful termination)
        // Use kill() instead of Process.terminate() to avoid unrecoverable ObjC
        // NSInvalidArgumentException if process exits between isRunning check and here
        kill(pid, SIGTERM)
        logger.info("Server '\(name)' SIGTERM sent", metadata: ["pid": "\(pid)"])

        // Step 2: Poll isRunning with timeout
        let maxIterations = Self.forceKillTimeoutMs / Int(Self.pollIntervalMs)
        var terminated = false

        for _ in 0..<maxIterations {
            if !info.process.isRunning {
                terminated = true
                break
            }
            do {
                try await Task.sleep(for: .milliseconds(Self.pollIntervalMs))
            } catch {
                // Task cancelled — escalate to SIGKILL immediately
                break
            }
        }

        if terminated {
            logger.info("Server '\(name)' terminated gracefully after SIGTERM", metadata: ["pid": "\(pid)"])
            return
        }

        // Step 3: Final isRunning check (process may have exited during last poll gap)
        guard info.process.isRunning else {
            logger.info("Server '\(name)' exited during final check", metadata: ["pid": "\(pid)"])
            return
        }

        // Step 4: Escalate to SIGKILL
        logger.warning("Server '\(name)' did not exit after \(Self.forceKillTimeoutMs)ms, sending SIGKILL", metadata: ["pid": "\(pid)"])
        kill(pid, SIGKILL)
        logger.info("Server '\(name)' force-killed via SIGKILL", metadata: ["pid": "\(pid)"])
    }

    /// 并发启动所有已启用的服务器，收集启动失败信息
    public func startAll() async throws {
        let enabledConfigs = serverConfigs.values.filter(\.enabled)

        guard !enabledConfigs.isEmpty else {
            logger.info("No enabled servers to start")
            return
        }

        logger.info("Starting \(enabledConfigs.count) server(s)")

        // 并发启动，收集失败
        var failures: [(name: String, error: any Error)] = []

        await withTaskGroup(of: (String, (any Error)?).self) { group in
            for config in enabledConfigs {
                group.addTask {
                    do {
                        try await self.startServer(name: config.name)
                        return (config.name, nil)
                    } catch {
                        return (config.name, error)
                    }
                }
            }

            for await (name, error) in group {
                if let error {
                    failures.append((name: name, error: error))
                }
            }
        }

        if !failures.isEmpty {
            let details = failures.map { "\($0.name): \($0.error)" }.joined(separator: "; ")
            logger.error("Some servers failed to start: \(details)")
            throw BridgeError.internalError(
                "Failed to start \(failures.count) server(s): \(details)")
        }

        logger.info("All servers started successfully")
    }

    /// 并发停止所有运行中的服务器
    public func stopAll() async {
        let names = Array(servers.keys)

        guard !names.isEmpty else {
            logger.info("No running servers to stop")
            return
        }

        logger.info("Stopping \(names.count) server(s)")

        await withTaskGroup(of: Void.self) { group in
            for name in names {
                group.addTask {
                    await self.stopServer(name: name)
                }
            }
        }

        logger.info("All servers stopped")
    }

    // MARK: - Query

    /// 获取指定服务器的 Client，未运行则返回 nil
    public func getClient(name: String) -> Client? {
        servers[name]?.client
    }

    /// 获取所有运行中的服务器名称
    public func getActiveServers() -> [String] {
        Array(servers.keys)
    }

    /// 检查指定服务器是否正在运行
    public func isServerRunning(name: String) -> Bool {
        servers[name] != nil
    }
}
