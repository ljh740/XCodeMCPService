import AppKit
import Foundation

// MARK: - Runtime Model

/// 当前 Xcode 安装支持的 MCP 运行模式。
public enum XcodeMCPMode: String, Sendable, Equatable {
    /// 依赖前台 Xcode 进程提供工具的传统模式。
    case legacyUIBridge = "legacy-ui-bridge"
    /// 安装中包含 Xcode 27 引入的 headless MCP server。
    case headlessCapable = "headless-capable"
}

/// Xcode 安装的选择来源，用于诊断自动选择是否符合预期。
public enum XcodeSelectionSource: String, Sendable, Equatable {
    case explicitEnvironment = "explicit-environment"
    case singleRunning = "single-running"
    case activeRunning = "active-running"
    case selectedDeveloperDirectory = "xcode-select"
}

/// 一次 mcpbridge 启动所绑定的 Xcode 运行时。
public struct XcodeRuntime: Sendable, Equatable {
    public let applicationURL: URL
    public let developerDirectoryURL: URL
    public let processIdentifier: Int32?
    public let version: String
    public let buildVersion: String
    public let mode: XcodeMCPMode
    public let selectionSource: XcodeSelectionSource

    public init(
        applicationURL: URL,
        developerDirectoryURL: URL,
        processIdentifier: Int32? = nil,
        version: String,
        buildVersion: String,
        mode: XcodeMCPMode,
        selectionSource: XcodeSelectionSource
    ) {
        self.applicationURL = applicationURL
        self.developerDirectoryURL = developerDirectoryURL
        self.processIdentifier = processIdentifier
        self.version = version
        self.buildVersion = buildVersion
        self.mode = mode
        self.selectionSource = selectionSource
    }
}

/// 从 NSWorkspace 提取后的最小运行中 Xcode 信息。
public struct RunningXcodeApplication: Sendable, Equatable {
    public let applicationURL: URL
    public let isActive: Bool
    public let processIdentifier: Int32?

    public init(
        applicationURL: URL,
        isActive: Bool,
        processIdentifier: Int32? = nil
    ) {
        self.applicationURL = applicationURL
        self.isActive = isActive
        self.processIdentifier = processIdentifier
    }
}

// MARK: - Providers

public protocol RunningXcodeProviding: Sendable {
    func runningXcodes() async -> [RunningXcodeApplication]
}

public struct WorkspaceRunningXcodeProvider: RunningXcodeProviding, Sendable {
    public init() {}

    public func runningXcodes() async -> [RunningXcodeApplication] {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { application in
                guard application.bundleIdentifier == "com.apple.dt.Xcode",
                      let applicationURL = application.bundleURL
                else {
                    return nil
                }

                return RunningXcodeApplication(
                    applicationURL: applicationURL,
                    isActive: application.isActive,
                    processIdentifier: application.processIdentifier
                )
            }
        }
    }
}

public protocol SelectedDeveloperDirectoryProviding: Sendable {
    func selectedDeveloperDirectory() async throws -> URL?
}

public struct XcodeSelectDeveloperDirectoryProvider: SelectedDeveloperDirectoryProviding, Sendable {
    public init() {}

    public func selectedDeveloperDirectory() async throws -> URL? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !output.isEmpty
        else {
            return nil
        }
        return URL(fileURLWithPath: output, isDirectory: true)
    }
}

// MARK: - Resolver

public protocol XcodeRuntimeResolving: Sendable {
    func resolve(developerDirectoryOverride: String?) async throws -> XcodeRuntime
}

public enum XcodeRuntimeResolutionError: Error, LocalizedError, Sendable {
    case noSupportedXcode
    case invalidDeveloperDirectory(String)
    case multipleRunningXcodes([String])

    public var errorDescription: String? {
        switch self {
        case .noSupportedXcode:
            return "No supported Xcode installation with mcpbridge was found"
        case .invalidDeveloperDirectory(let path):
            return "Xcode developer directory does not contain an executable mcpbridge: \(path)"
        case .multipleRunningXcodes(let paths):
            return "Multiple Xcode instances are running and none is active or selected: \(paths.joined(separator: ", "))"
        }
    }
}

public struct DefaultXcodeRuntimeResolver: XcodeRuntimeResolving, Sendable {
    private let runningXcodeProvider: any RunningXcodeProviding
    private let selectedDirectoryProvider: any SelectedDeveloperDirectoryProviding

    public init(
        runningXcodeProvider: any RunningXcodeProviding = WorkspaceRunningXcodeProvider(),
        selectedDirectoryProvider: any SelectedDeveloperDirectoryProviding = XcodeSelectDeveloperDirectoryProvider()
    ) {
        self.runningXcodeProvider = runningXcodeProvider
        self.selectedDirectoryProvider = selectedDirectoryProvider
    }

    public func resolve(developerDirectoryOverride: String?) async throws -> XcodeRuntime {
        if let developerDirectoryOverride,
           !developerDirectoryOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return try inspectDeveloperDirectory(
                URL(fileURLWithPath: developerDirectoryOverride, isDirectory: true),
                selectionSource: .explicitEnvironment
            )
        }

        let runningApplications = await runningXcodeProvider.runningXcodes()
        let supportedRunningXcodes = runningApplications.compactMap { application -> (RunningXcodeApplication, XcodeRuntime)? in
            let developerDirectory = application.applicationURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Developer", isDirectory: true)
            guard let runtime = try? inspectDeveloperDirectory(
                developerDirectory,
                processIdentifier: application.processIdentifier,
                selectionSource: .singleRunning
            ) else {
                return nil
            }
            return (application, runtime)
        }

        if supportedRunningXcodes.count == 1, let runtime = supportedRunningXcodes.first?.1 {
            return runtime
        }

        if supportedRunningXcodes.count > 1 {
            let activeRuntimes = supportedRunningXcodes.filter(\.0.isActive)
            if activeRuntimes.count == 1, let activeRuntime = activeRuntimes.first?.1 {
                return try inspectDeveloperDirectory(
                    activeRuntime.developerDirectoryURL,
                    processIdentifier: activeRuntime.processIdentifier,
                    selectionSource: .activeRunning
                )
            }

            if let selectedDirectory = try await selectedDirectoryProvider.selectedDeveloperDirectory() {
                let normalizedSelectedDirectory = normalize(selectedDirectory)
                if let selectedRuntime = supportedRunningXcodes.first(where: {
                    normalize($0.1.developerDirectoryURL) == normalizedSelectedDirectory
                })?.1 {
                    return try inspectDeveloperDirectory(
                        selectedRuntime.developerDirectoryURL,
                        processIdentifier: selectedRuntime.processIdentifier,
                        selectionSource: .selectedDeveloperDirectory
                    )
                }
            }

            throw XcodeRuntimeResolutionError.multipleRunningXcodes(
                supportedRunningXcodes.map(\.1.applicationURL.path).sorted()
            )
        }

        if let selectedDirectory = try await selectedDirectoryProvider.selectedDeveloperDirectory() {
            return try inspectDeveloperDirectory(
                selectedDirectory,
                selectionSource: .selectedDeveloperDirectory
            )
        }

        throw XcodeRuntimeResolutionError.noSupportedXcode
    }

    private func inspectDeveloperDirectory(
        _ developerDirectory: URL,
        processIdentifier: Int32? = nil,
        selectionSource: XcodeSelectionSource
    ) throws -> XcodeRuntime {
        let normalizedDeveloperDirectory = normalize(developerDirectory)
        let mcpBridgeURL = normalizedDeveloperDirectory
            .appendingPathComponent("usr", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("mcpbridge")

        guard FileManager.default.isExecutableFile(atPath: mcpBridgeURL.path) else {
            throw XcodeRuntimeResolutionError.invalidDeveloperDirectory(normalizedDeveloperDirectory.path)
        }

        let applicationURL = normalizedDeveloperDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let versionInfo = readVersionInfo(applicationURL: applicationURL)
        let mcpServerURL = normalizedDeveloperDirectory
            .appendingPathComponent("usr", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("mcp-server")
        let mode: XcodeMCPMode = FileManager.default.isExecutableFile(atPath: mcpServerURL.path)
            ? .headlessCapable
            : .legacyUIBridge

        return XcodeRuntime(
            applicationURL: applicationURL,
            developerDirectoryURL: normalizedDeveloperDirectory,
            processIdentifier: processIdentifier,
            version: versionInfo.version,
            buildVersion: versionInfo.buildVersion,
            mode: mode,
            selectionSource: selectionSource
        )
    }

    private func normalize(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func readVersionInfo(applicationURL: URL) -> (version: String, buildVersion: String) {
        let versionPlistURL = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("version.plist")
        guard let data = try? Data(contentsOf: versionPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let values = plist as? [String: Any]
        else {
            return ("unknown", "unknown")
        }

        return (
            values["CFBundleShortVersionString"] as? String ?? "unknown",
            values["ProductBuildVersion"] as? String ?? "unknown"
        )
    }
}
