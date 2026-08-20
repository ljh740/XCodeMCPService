import Foundation

/// Xcode 27 headless MCP server 的当前状态。
public struct XcodeMCPServerStatus: Sendable, Equatable {
    public let enabled: Bool
    public let running: Bool
    public let unsafeAlwaysAllowAllAgents: Bool

    public init(
        enabled: Bool,
        running: Bool,
        unsafeAlwaysAllowAllAgents: Bool = false
    ) {
        self.enabled = enabled
        self.running = running
        self.unsafeAlwaysAllowAllAgents = unsafeAlwaysAllowAllAgents
    }
}

public protocol XcodeMCPServerStatusProviding: Sendable {
    func status(developerDirectoryURL: URL) async throws -> XcodeMCPServerStatus
}

public enum XcodeMCPServerStatusError: Error, LocalizedError, Sendable {
    case commandFailed(status: Int32, message: String)
    case invalidResponse(String)
    case timedOut(milliseconds: Int)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let status, let message):
            return "mcp-server status failed with exit code \(status): \(message)"
        case .invalidResponse(let message):
            return "Unable to decode mcp-server status: \(message)"
        case .timedOut(let milliseconds):
            return "mcp-server status timed out after \(milliseconds)ms"
        }
    }
}

/// 通过 Xcode 27 自带的 `mcp-server status --format json` 查询 headless 模式。
public struct DefaultXcodeMCPServerStatusProvider: XcodeMCPServerStatusProviding, Sendable {
    private let timeoutMilliseconds: Int

    public init(timeoutMilliseconds: Int = 2000) {
        self.timeoutMilliseconds = max(timeoutMilliseconds, 1)
    }

    public func status(developerDirectoryURL: URL) async throws -> XcodeMCPServerStatus {
        let executableURL = developerDirectoryURL
            .appendingPathComponent("usr", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("mcp-server")
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["status", "--format", "json"]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = developerDirectoryURL.path
        process.environment = environment

        try process.run()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        do {
            while process.isRunning {
                if clock.now >= deadline {
                    process.terminate()
                    outputPipe.fileHandleForReading.closeFile()
                    errorPipe.fileHandleForReading.closeFile()
                    throw XcodeMCPServerStatusError.timedOut(milliseconds: timeoutMilliseconds)
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            if process.isRunning {
                process.terminate()
            }
            throw error
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw XcodeMCPServerStatusError.commandFailed(
                status: process.terminationStatus,
                message: message.isEmpty ? "unknown error" : message
            )
        }

        return try Self.decodeStatus(outputData)
    }

    static func decodeStatus(_ data: Data) throws -> XcodeMCPServerStatus {
        do {
            let payload = try JSONDecoder().decode(StatusPayload.self, from: data)
            return XcodeMCPServerStatus(
                enabled: payload.permission.enabled,
                running: payload.running,
                unsafeAlwaysAllowAllAgents: payload.permission.unsafeAlwaysAllowAllAgents ?? false
            )
        } catch {
            throw XcodeMCPServerStatusError.invalidResponse(String(describing: error))
        }
    }

    private struct StatusPayload: Decodable {
        struct Permission: Decodable {
            let enabled: Bool
            let unsafeAlwaysAllowAllAgents: Bool?
        }

        let permission: Permission
        let running: Bool
    }
}
