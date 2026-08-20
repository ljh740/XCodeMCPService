import Foundation
import Testing
@testable import MCPServiceCore

private struct StaticRunningXcodeProvider: RunningXcodeProviding {
    let applications: [RunningXcodeApplication]

    func runningXcodes() async -> [RunningXcodeApplication] {
        applications
    }
}

private struct StaticSelectedDirectoryProvider: SelectedDeveloperDirectoryProviding {
    let developerDirectory: URL?

    func selectedDeveloperDirectory() async throws -> URL? {
        developerDirectory
    }
}

private struct StaticXcodeMCPServerStatusProvider: XcodeMCPServerStatusProviding {
    let value: XcodeMCPServerStatus

    func status(developerDirectoryURL: URL) async throws -> XcodeMCPServerStatus {
        value
    }
}

private struct FailingXcodeMCPServerStatusProvider: XcodeMCPServerStatusProviding {
    struct StubError: Error, CustomStringConvertible {
        var description: String { "status unavailable" }
    }

    func status(developerDirectoryURL: URL) async throws -> XcodeMCPServerStatus {
        throw StubError()
    }
}

@Suite("Xcode Runtime Resolver Tests")
struct XcodeRuntimeResolverTests {
    private struct Fixture {
        let rootURL: URL
        let applicationURL: URL
        let developerDirectoryURL: URL
    }

    @Test("mcp-server JSON status is decoded")
    func mcpServerStatusDecoding() throws {
        let json = """
        {
          "permission": {
            "enabled": true,
            "unsafeAlwaysAllowAllAgents": true
          },
          "running": false,
          "openWorkspaces": []
        }
        """

        let status = try DefaultXcodeMCPServerStatusProvider.decodeStatus(Data(json.utf8))

        #expect(status == XcodeMCPServerStatus(
            enabled: true,
            running: false,
            unsafeAlwaysAllowAllAgents: true
        ))
    }

    @Test("mcp-server status provider executes the selected Xcode tool")
    func mcpServerStatusProviderExecutesSelectedTool() async throws {
        let beta = try makeFixture(name: "Xcode-beta.app", version: "27.0", build: "27A123", headless: true)
        defer { removeFixture(beta) }

        let status = try await DefaultXcodeMCPServerStatusProvider().status(
            developerDirectoryURL: beta.developerDirectoryURL
        )

        #expect(status == XcodeMCPServerStatus(enabled: true, running: true))
    }

    @Test("mcp-server status provider times out instead of blocking startup")
    func mcpServerStatusProviderTimesOut() async throws {
        let beta = try makeFixture(
            name: "Xcode-beta.app",
            version: "27.0",
            build: "27A123",
            headless: true,
            mcpServerContents: """
            #!/bin/sh
            sleep 2
            printf '{"permission":{"enabled":true},"running":true}'
            """
        )
        defer { removeFixture(beta) }

        await #expect(throws: XcodeMCPServerStatusError.self) {
            _ = try await DefaultXcodeMCPServerStatusProvider(timeoutMilliseconds: 50).status(
                developerDirectoryURL: beta.developerDirectoryURL
            )
        }
    }

    @Test("Single running Xcode is selected instead of xcode-select")
    func singleRunningXcodeWins() async throws {
        let running = try makeFixture(name: "Xcode-beta.app", version: "27.0", build: "27A123", headless: true)
        let selected = try makeFixture(name: "Xcode.app", version: "26.5", build: "17F42", headless: false)
        defer {
            removeFixture(running)
            removeFixture(selected)
        }

        let resolver = makeResolver(
            running: [RunningXcodeApplication(
                applicationURL: running.applicationURL,
                isActive: false
            )],
            selected: selected.developerDirectoryURL
        )

        let runtime = try await resolver.resolve(developerDirectoryOverride: nil)

        #expect(runtime.applicationURL == running.applicationURL.resolvingSymlinksInPath())
        #expect(runtime.version == "27.0")
        #expect(runtime.buildVersion == "27A123")
        #expect(runtime.mode == .headlessCapable)
        #expect(runtime.selectionSource == .singleRunning)
    }

    @Test("Active Xcode wins when multiple supported instances are running")
    func activeRunningXcodeWins() async throws {
        let stable = try makeFixture(name: "Xcode.app", version: "26.5", build: "17F42", headless: false)
        let beta = try makeFixture(name: "Xcode-beta.app", version: "27.0", build: "27A123", headless: true)
        defer {
            removeFixture(stable)
            removeFixture(beta)
        }

        let resolver = makeResolver(
            running: [
                RunningXcodeApplication(
                    applicationURL: stable.applicationURL,
                    isActive: false
                ),
                RunningXcodeApplication(
                    applicationURL: beta.applicationURL,
                    isActive: true
                ),
            ],
            selected: stable.developerDirectoryURL
        )

        let runtime = try await resolver.resolve(developerDirectoryOverride: nil)

        #expect(runtime.applicationURL == beta.applicationURL.resolvingSymlinksInPath())
        #expect(runtime.selectionSource == .activeRunning)
    }

    @Test("xcode-select breaks a tie between multiple background Xcode instances")
    func selectedDirectoryBreaksTie() async throws {
        let stable = try makeFixture(name: "Xcode.app", version: "26.5", build: "17F42", headless: false)
        let beta = try makeFixture(name: "Xcode-beta.app", version: "27.0", build: "27A123", headless: true)
        defer {
            removeFixture(stable)
            removeFixture(beta)
        }

        let resolver = makeResolver(
            running: [
                RunningXcodeApplication(applicationURL: stable.applicationURL, isActive: false),
                RunningXcodeApplication(applicationURL: beta.applicationURL, isActive: false),
            ],
            selected: beta.developerDirectoryURL
        )

        let runtime = try await resolver.resolve(developerDirectoryOverride: nil)

        #expect(runtime.applicationURL == beta.applicationURL.resolvingSymlinksInPath())
        #expect(runtime.selectionSource == .selectedDeveloperDirectory)
    }

    @Test("Multiple ambiguous Xcode instances produce an actionable error")
    func multipleRunningXcodesAreRejected() async throws {
        let stable = try makeFixture(name: "Xcode.app", version: "26.5", build: "17F42", headless: false)
        let beta = try makeFixture(name: "Xcode-beta.app", version: "27.0", build: "27A123", headless: true)
        let unrelated = try makeFixture(name: "Unrelated.app", version: "27.0", build: "27A999", headless: true)
        defer {
            removeFixture(stable)
            removeFixture(beta)
            removeFixture(unrelated)
        }

        let resolver = makeResolver(
            running: [
                RunningXcodeApplication(applicationURL: stable.applicationURL, isActive: false),
                RunningXcodeApplication(applicationURL: beta.applicationURL, isActive: false),
            ],
            selected: unrelated.developerDirectoryURL
        )

        await #expect(throws: XcodeRuntimeResolutionError.self) {
            _ = try await resolver.resolve(developerDirectoryOverride: nil)
        }
    }

    @Test("Explicit DEVELOPER_DIR remains an intentional override")
    func explicitDeveloperDirectoryWins() async throws {
        let stable = try makeFixture(name: "Xcode.app", version: "26.5", build: "17F42", headless: false)
        let beta = try makeFixture(name: "Xcode-beta.app", version: "27.0", build: "27A123", headless: true)
        defer {
            removeFixture(stable)
            removeFixture(beta)
        }

        let resolver = makeResolver(
            running: [RunningXcodeApplication(
                applicationURL: beta.applicationURL,
                isActive: true
            )],
            selected: beta.developerDirectoryURL
        )

        let runtime = try await resolver.resolve(
            developerDirectoryOverride: stable.developerDirectoryURL.path
        )

        #expect(runtime.applicationURL == stable.applicationURL.resolvingSymlinksInPath())
        #expect(runtime.mode == .legacyUIBridge)
        #expect(runtime.selectionSource == .explicitEnvironment)
    }

    @Test("Headless-capable Xcode avoids GUI PID when mcp-server is enabled")
    func headlessLaunchAvoidsGUIProcessIdentifier() async throws {
        let beta = try makeFixture(name: "Xcode-beta.app", version: "27.0", build: "27A123", headless: true)
        defer { removeFixture(beta) }

        let xcodeResolver = makeResolver(
            running: [RunningXcodeApplication(
                applicationURL: beta.applicationURL,
                isActive: false,
                processIdentifier: 4242
            )],
            selected: nil
        )
        let launchResolver = DefaultServerLaunchResolver(
            xcodeRuntimeResolver: xcodeResolver,
            xcodeMCPServerStatusProvider: StaticXcodeMCPServerStatusProvider(
                value: XcodeMCPServerStatus(
                    enabled: true,
                    running: true,
                    unsafeAlwaysAllowAllAgents: true
                )
            )
        )
        let config = ServerConfig(name: "xcode-tools", command: "xcrun", args: ["mcpbridge"])

        let launch = try await launchResolver.resolve(config: config, environment: ["PATH": "/usr/bin"])

        #expect(launch.environment["DEVELOPER_DIR"] == beta.developerDirectoryURL.resolvingSymlinksInPath().path)
        #expect(launch.environment["MCP_XCODE_PID"] == nil)
        #expect(launch.metadata["xcodeVersion"] == "27.0")
        #expect(launch.metadata["xcodeMode"] == XcodeMCPMode.headlessCapable.rawValue)
        #expect(launch.metadata["xcodeSelection"] == XcodeSelectionSource.singleRunning.rawValue)
        #expect(launch.metadata["xcodeConnection"] == "headless-mcp-server")
        #expect(launch.metadata["xcodeHeadlessRunning"] == "true")
        #expect(launch.metadata["xcodeUnsafeAlwaysAllowAllAgents"] == "true")
    }

    @Test("Legacy Xcode binds the detected GUI process")
    func legacyLaunchBindsGUIProcessIdentifier() async throws {
        let stable = try makeFixture(name: "Xcode.app", version: "26.5", build: "17F42", headless: false)
        defer { removeFixture(stable) }

        let xcodeResolver = makeResolver(
            running: [RunningXcodeApplication(
                applicationURL: stable.applicationURL,
                isActive: false,
                processIdentifier: 4242
            )],
            selected: nil
        )
        let launchResolver = DefaultServerLaunchResolver(
            xcodeRuntimeResolver: xcodeResolver,
            xcodeMCPServerStatusProvider: StaticXcodeMCPServerStatusProvider(
                value: XcodeMCPServerStatus(enabled: true, running: true)
            )
        )
        let config = ServerConfig(name: "xcode-tools", command: "xcrun", args: ["mcpbridge"])

        let launch = try await launchResolver.resolve(config: config, environment: ["PATH": "/usr/bin"])

        #expect(launch.environment["MCP_XCODE_PID"] == "4242")
        #expect(launch.metadata["xcodeMode"] == XcodeMCPMode.legacyUIBridge.rawValue)
        #expect(launch.metadata["xcodeConnection"] == "running-xcode")
    }

    @Test("Headless-capable Xcode falls back to GUI when mcp-server is disabled")
    func disabledHeadlessFallsBackToGUI() async throws {
        let beta = try makeFixture(name: "Xcode-beta.app", version: "27.0", build: "27A123", headless: true)
        defer { removeFixture(beta) }

        let xcodeResolver = makeResolver(
            running: [RunningXcodeApplication(
                applicationURL: beta.applicationURL,
                isActive: false,
                processIdentifier: 4242
            )],
            selected: nil
        )
        let launchResolver = DefaultServerLaunchResolver(
            xcodeRuntimeResolver: xcodeResolver,
            xcodeMCPServerStatusProvider: StaticXcodeMCPServerStatusProvider(
                value: XcodeMCPServerStatus(enabled: false, running: false)
            )
        )
        let config = ServerConfig(name: "xcode-tools", command: "xcrun", args: ["mcpbridge"])

        let launch = try await launchResolver.resolve(config: config, environment: ["PATH": "/usr/bin"])

        #expect(launch.environment["MCP_XCODE_PID"] == "4242")
        #expect(launch.metadata["xcodeConnection"] == "running-xcode")
        #expect(launch.metadata["xcodeHeadlessFallback"] == "disabled")
    }

    @Test("Headless status failure does not fall back to GUI authorization")
    func unavailableHeadlessStatusKeepsPIDUnset() async throws {
        let beta = try makeFixture(name: "Xcode-beta.app", version: "27.0", build: "27A123", headless: true)
        defer { removeFixture(beta) }

        let xcodeResolver = makeResolver(
            running: [RunningXcodeApplication(
                applicationURL: beta.applicationURL,
                isActive: false,
                processIdentifier: 4242
            )],
            selected: nil
        )
        let launchResolver = DefaultServerLaunchResolver(
            xcodeRuntimeResolver: xcodeResolver,
            xcodeMCPServerStatusProvider: FailingXcodeMCPServerStatusProvider()
        )
        let config = ServerConfig(name: "xcode-tools", command: "xcrun", args: ["mcpbridge"])

        let launch = try await launchResolver.resolve(config: config, environment: ["PATH": "/usr/bin"])

        #expect(launch.environment["MCP_XCODE_PID"] == nil)
        #expect(launch.metadata["xcodeConnection"] == "headless-mcp-server-unverified")
        #expect(launch.metadata["xcodeHeadlessStatusError"] == "status unavailable")
    }

    @Test("Explicit MCP_XCODE_PID is preserved")
    func explicitProcessIdentifierWins() async throws {
        let beta = try makeFixture(name: "Xcode-beta.app", version: "27.0", build: "27A123", headless: true)
        defer { removeFixture(beta) }

        let xcodeResolver = makeResolver(
            running: [RunningXcodeApplication(
                applicationURL: beta.applicationURL,
                isActive: false,
                processIdentifier: 4242
            )],
            selected: nil
        )
        let launchResolver = DefaultServerLaunchResolver(
            xcodeRuntimeResolver: xcodeResolver,
            xcodeMCPServerStatusProvider: StaticXcodeMCPServerStatusProvider(
                value: XcodeMCPServerStatus(enabled: true, running: true)
            )
        )
        let config = ServerConfig(name: "xcode-tools", command: "xcrun", args: ["mcpbridge"])

        let launch = try await launchResolver.resolve(
            config: config,
            environment: ["PATH": "/usr/bin", "MCP_XCODE_PID": "9001"]
        )

        #expect(launch.environment["MCP_XCODE_PID"] == "9001")
        #expect(launch.metadata["xcodePID"] == "9001")
        #expect(launch.metadata["xcodeConnection"] == "running-xcode-explicit")
    }

    @Test("Non-Xcode MCP servers are not modified")
    func nonXcodeServerPassesThrough() async throws {
        let resolver = DefaultServerLaunchResolver(
            xcodeRuntimeResolver: makeResolver(running: [], selected: nil)
        )
        let config = ServerConfig(name: "other", command: "node", args: ["server.js"])
        let environment = ["PATH": "/usr/bin", "TOKEN": "value"]

        let launch = try await resolver.resolve(config: config, environment: environment)

        #expect(launch.command == config.command)
        #expect(launch.args == config.args)
        #expect(launch.environment == environment)
        #expect(launch.metadata.isEmpty)
    }

    @Test("lldb-mcp uses the selected Xcode without inheriting mcpbridge PID binding")
    func lldbMCPUsesSelectedXcode() async throws {
        let beta = try makeFixture(
            name: "Xcode-beta.app",
            version: "27.0",
            build: "27A123",
            headless: true,
            lldbMCP: true
        )
        defer { removeFixture(beta) }

        let launchResolver = DefaultServerLaunchResolver(
            xcodeRuntimeResolver: makeResolver(
                running: [RunningXcodeApplication(
                    applicationURL: beta.applicationURL,
                    isActive: true,
                    processIdentifier: 4242
                )],
                selected: nil
            ),
            xcodeMCPServerStatusProvider: FailingXcodeMCPServerStatusProvider()
        )
        let config = ServerConfig(name: "lldb", command: "xcrun", args: ["lldb-mcp"])

        let launch = try await launchResolver.resolve(
            config: config,
            environment: ["PATH": "/usr/bin", "MCP_XCODE_PID": "9001"]
        )

        #expect(launch.environment["DEVELOPER_DIR"] == beta.developerDirectoryURL.resolvingSymlinksInPath().path)
        #expect(launch.environment["MCP_XCODE_PID"] == nil)
        #expect(launch.metadata["xcodeConnection"] == "lldb-mcp")
        #expect(launch.metadata["xcodeVersion"] == "27.0")
    }

    private func makeResolver(
        running: [RunningXcodeApplication],
        selected: URL?
    ) -> DefaultXcodeRuntimeResolver {
        DefaultXcodeRuntimeResolver(
            runningXcodeProvider: StaticRunningXcodeProvider(applications: running),
            selectedDirectoryProvider: StaticSelectedDirectoryProvider(developerDirectory: selected)
        )
    }

    private func makeFixture(
        name: String,
        version: String,
        build: String,
        headless: Bool,
        mcpServerContents: String? = nil,
        lldbMCP: Bool = false
    ) throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("XCodeMCPServiceTests-\(UUID().uuidString)", isDirectory: true)
        let applicationURL = rootURL.appendingPathComponent(name, isDirectory: true)
        let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        let developerDirectoryURL = contentsURL.appendingPathComponent("Developer", isDirectory: true)
        let binURL = developerDirectoryURL
            .appendingPathComponent("usr", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        try makeExecutable(at: binURL.appendingPathComponent("mcpbridge"))
        if headless {
            try makeExecutable(
                at: binURL.appendingPathComponent("mcp-server"),
                contents: mcpServerContents ?? """
                #!/bin/sh
                printf '{"permission":{"enabled":true},"running":true,"openWorkspaces":[]}'
                """
            )
        }
        if lldbMCP {
            try makeExecutable(at: binURL.appendingPathComponent("lldb-mcp"))
        }

        let versionPlist: [String: String] = [
            "CFBundleShortVersionString": version,
            "ProductBuildVersion": build,
        ]
        let versionData = try PropertyListSerialization.data(
            fromPropertyList: versionPlist,
            format: .xml,
            options: 0
        )
        try versionData.write(to: contentsURL.appendingPathComponent("version.plist"))

        return Fixture(
            rootURL: rootURL,
            applicationURL: applicationURL,
            developerDirectoryURL: developerDirectoryURL
        )
    }

    private func makeExecutable(
        at url: URL,
        contents: String = "#!/bin/sh\nexit 0\n"
    ) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
    }

    private func removeFixture(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.rootURL)
    }
}
