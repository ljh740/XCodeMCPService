import Foundation
import MCP
import Testing
@testable import MCPServiceCore

private struct StaticLLDBRuntimeResolver: XcodeRuntimeResolving {
    let runtime: XcodeRuntime

    func resolve(developerDirectoryOverride: String?) async throws -> XcodeRuntime {
        runtime
    }
}

private actor MutableLLDBRegistryManager: LLDBRegistryManaging {
    private var currentSnapshot: LLDBRegistrySnapshot
    private var queuedSnapshots: [LLDBRegistrySnapshot]
    private let quarantinedEntries: [String]
    private var terminatedProcessIdentifiers: [Int32] = []

    init(
        snapshot: LLDBRegistrySnapshot = .empty,
        quarantinedEntries: [String] = [],
        queuedSnapshots: [LLDBRegistrySnapshot] = []
    ) {
        currentSnapshot = snapshot
        self.quarantinedEntries = quarantinedEntries
        self.queuedSnapshots = queuedSnapshots
    }

    func snapshot() async -> LLDBRegistrySnapshot {
        if !queuedSnapshots.isEmpty {
            return queuedSnapshots.removeFirst()
        }
        return currentSnapshot
    }

    func quarantineConfirmedStaleEntries() async -> [String] {
        quarantinedEntries
    }

    func terminateOwnedBackendProcesses(_ entries: [LLDBRegistryEntry]) async -> [Int32] {
        let processIdentifiers = entries.compactMap(\.processIdentifier).sorted()
        terminatedProcessIdentifiers.append(contentsOf: processIdentifiers)
        return processIdentifiers
    }

    func setSnapshot(_ snapshot: LLDBRegistrySnapshot) {
        currentSnapshot = snapshot
    }

    func terminatedProcesses() -> [Int32] {
        terminatedProcessIdentifiers
    }
}

private actor FakeLLDBMCPClient: LLDBMCPClient {
    private var running = false
    private var startCount = 0
    private var stopCount = 0
    private var sessions: [String]
    private let toolNames: [String]
    private let adapterPID: Int32?
    private let failsListingTools: Bool
    private let failsCreatingSession: Bool
    private let onCreate: (@Sendable () async -> Void)?
    private let onStop: (@Sendable () async -> Void)?
    private var heldOperation: String?
    private var operationContinuation: CheckedContinuation<Void, Never>?

    init(
        sessions: [String] = ["lldb-mcp://instance/900/debugger/1"],
        toolNames: [String] = ["session_create", "command", "sessions_list", "session_close"],
        adapterPID: Int32? = 699,
        failsListingTools: Bool = false,
        failsCreatingSession: Bool = false,
        onCreate: (@Sendable () async -> Void)? = nil,
        onStop: (@Sendable () async -> Void)? = nil
    ) {
        self.sessions = sessions
        self.toolNames = toolNames
        self.adapterPID = adapterPID
        self.failsListingTools = failsListingTools
        self.failsCreatingSession = failsCreatingSession
        self.onCreate = onCreate
        self.onStop = onStop
    }

    func start() async throws {
        running = true
        startCount += 1
    }

    func stop() async {
        await suspendIfNeeded("stop")
        if running {
            stopCount += 1
        }
        running = false
        await onStop?()
    }

    func isRunning() async -> Bool {
        running
    }

    func processIdentifier() async -> Int32? { running ? adapterPID : nil }

    func listTools() async throws -> [Tool] {
        if failsListingTools {
            throw BridgeError.internalError("Fixture capability failure")
        }
        return toolNames.map { name in
            Tool(name: name, description: name, inputSchema: [:])
        }
    }

    func callTool(name: String, arguments: [String: Value]?) async throws -> LLDBToolResponse {
        await suspendIfNeeded("tool")
        switch name {
        case "session_create":
            await onCreate?()
            if failsCreatingSession {
                return LLDBToolResponse(content: [textContent("Fixture creation failure")], isError: true)
            }
            let session = "lldb-mcp://instance/900/debugger/2"
            sessions.append(session)
            return LLDBToolResponse(content: [textContent(session)], isError: false)
        case "sessions_list", "debugger_list":
            return LLDBToolResponse(content: [textContent(sessions.joined(separator: "\n"))], isError: false)
        case "session_close":
            if let session = arguments?["session"]?.stringValue {
                sessions.removeAll { $0 == session }
            }
            return LLDBToolResponse(content: [textContent("closed")], isError: false)
        default:
            return LLDBToolResponse(content: [textContent("ok")], isError: false)
        }
    }

    func listResources() async throws -> [Resource] {
        await suspendIfNeeded("list")
        return [Resource(name: "debugger", uri: "lldb://instance/900/debugger/1")]
    }

    func readResource(uri: String) async throws -> [Resource.Content] {
        await suspendIfNeeded("read")
        return [.text("{}", uri: uri, mimeType: "application/json")]
    }

    func hold(_ operation: String) { heldOperation = operation }

    func isSuspended() -> Bool { operationContinuation != nil }

    func resume() {
        heldOperation = nil
        operationContinuation?.resume()
        operationContinuation = nil
    }

    private func suspendIfNeeded(_ operation: String) async {
        guard heldOperation == operation else { return }
        await withCheckedContinuation { operationContinuation = $0 }
    }

    func counts() -> (starts: Int, stops: Int) {
        (startCount, stopCount)
    }

    private nonisolated func textContent(_ text: String) -> Tool.Content {
        .text(text: text, annotations: nil, _meta: nil)
    }
}

@Suite("LLDB Session Controller Tests")
struct LLDBSessionControllerTests {
    @Test("Idle adapters are reclaimed even with owned sessions and restart on demand")
    func idleReclaimsAndRestarts() async throws {
        let fixture = try makeRuntime(version: "27.0", includesLLDBMCP: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let client = FakeLLDBMCPClient()
        let controller = makeController(runtime: fixture.runtime, client: client, idleTimeout: .milliseconds(50))
        _ = await controller.routeToolCall(toolName: "lldb__session_create", args: nil)
        try await waitUntil { await client.counts().stops == 1 }
        #expect(await client.counts().starts == 1)
        let result = await controller.routeToolCall(toolName: "lldb__sessions_list", args: nil)
        #expect(result?.data?.isError == false)
        #expect(await client.counts().starts == 2)
        await controller.shutdown()
    }

    @Test("Idle collection waits for tools and resource operations", arguments: ["tool", "list", "read"])
    func inFlightOperationsAreProtected(operation: String) async throws {
        let fixture = try makeRuntime(version: "27.0", includesLLDBMCP: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let client = FakeLLDBMCPClient()
        let controller = makeController(runtime: fixture.runtime, client: client, idleTimeout: .milliseconds(50))
        _ = await controller.routeToolCall(toolName: "lldb__sessions_list", args: nil)
        await client.hold(operation)
        let call = Task {
            switch operation {
            case "list": _ = await controller.listResources()
            case "read": _ = await controller.routeResourceRead(prefixedURI: "lldb__lldb://debugger/1")
            default: _ = await controller.routeToolCall(toolName: "lldb__command", args: ["command": "bt"])
            }
        }
        try await waitUntil { await client.isSuspended() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await client.counts().stops == 0)
        await client.resume()
        await call.value
        try await waitUntil { await client.counts().stops == 1 }
        await controller.shutdown()
    }

    @Test("New requests wait for idle cleanup before restarting")
    func requestDuringCleanup() async throws {
        let fixture = try makeRuntime(version: "27.0", includesLLDBMCP: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let client = FakeLLDBMCPClient()
        let controller = makeController(runtime: fixture.runtime, client: client, idleTimeout: .milliseconds(50))
        await client.hold("stop")
        _ = await controller.routeToolCall(toolName: "lldb__sessions_list", args: nil)
        try await waitUntil { await client.isSuspended() }
        let call = Task { await controller.routeToolCall(toolName: "lldb__sessions_list", args: nil) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await client.counts().starts == 1)
        await client.resume()
        let result = await call.value
        #expect(result?.data?.isError == false)
        #expect(await client.counts() == (starts: 2, stops: 1))
        await controller.shutdown()
    }

    @Test("Explicit and automatic refresh preserve in-flight resource operations", arguments: ["list", "read"])
    func refreshPreservesResourceOperations(operation: String) async throws {
        let fixture = try makeRuntime(version: "27.0", includesLLDBMCP: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let client = FakeLLDBMCPClient()
        let registry = MutableLLDBRegistryManager()
        let controller = makeController(runtime: fixture.runtime, registry: registry, client: client)
        _ = await controller.routeToolCall(toolName: "lldb__sessions_list", args: nil)
        await client.hold(operation)
        let pending = Task {
            if operation == "list" {
                _ = await controller.listResources()
            } else {
                _ = await controller.routeResourceRead(prefixedURI: "lldb__lldb://debugger/1")
            }
        }
        try await waitUntil { await client.isSuspended() }

        let refresh = await controller.routeToolCall(toolName: "lldb_refresh_sessions", args: ["force": true])
        #expect(refresh?.data.map(text(from:))?.contains(#""action" : "blocked""#) == true)
        await registry.setSnapshot(snapshot(processIdentifier: 100))
        _ = await controller.routeToolCall(toolName: "lldb__sessions_list", args: nil)
        #expect(await client.counts() == (starts: 1, stops: 0))

        await client.resume()
        await pending.value
        _ = await controller.routeToolCall(toolName: "lldb_refresh_sessions", args: nil)
        #expect(await client.counts() == (starts: 2, stops: 1))
        await controller.shutdown()
    }

    @Test("Capability failure captures owned backends before stopping the adapter", arguments: [true, false])
    func failedStartupCapturesOwnedBackends(hasAdapterPID: Bool) async throws {
        let fixture = try makeRuntime(version: "27.0", includesLLDBMCP: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let registry = MutableLLDBRegistryManager(
            snapshot: LLDBRegistrySnapshot(entries: [
                backend(processIdentifier: 700, parent: 699, runtime: fixture.runtime),
                backend(processIdentifier: 800, parent: 799, runtime: fixture.runtime),
            ]),
            queuedSnapshots: [.empty, .empty]
        )
        let client = FakeLLDBMCPClient(
            adapterPID: hasAdapterPID ? 699 : nil,
            failsListingTools: true,
            onStop: { await registry.setSnapshot(.empty) }
        )
        let controller = makeController(runtime: fixture.runtime, registry: registry, client: client)
        let result = await controller.routeToolCall(toolName: "lldb__sessions_list", args: nil)

        #expect(result?.data?.isError == true)
        #expect(await client.counts() == (starts: 1, stops: 1))
        #expect(await registry.terminatedProcesses() == (hasAdapterPID ? [700] : []))
        await controller.shutdown()
    }

    @Test("Session creation tracks only this adapter's backends, including error responses", arguments: [false, true])
    func creationTracksOwnedBackends(fails: Bool) async throws {
        let fixture = try makeRuntime(version: "27.0", includesLLDBMCP: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let registry = MutableLLDBRegistryManager()
        let created = LLDBRegistrySnapshot(entries: [
            backend(processIdentifier: 700, parent: 699, runtime: fixture.runtime),
            backend(processIdentifier: 800, parent: 799, runtime: fixture.runtime),
        ])
        let client = FakeLLDBMCPClient(
            failsCreatingSession: fails,
            onCreate: { await registry.setSnapshot(created) }
        )
        let controller = makeController(runtime: fixture.runtime, registry: registry, client: client)
        let result = await controller.routeToolCall(toolName: "lldb__session_create", args: nil)
        #expect(result?.data?.isError == fails)
        await controller.shutdown()
        #expect(await registry.terminatedProcesses() == [700])
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for lifecycle event")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("Stable surface includes refresh and all four LLDB tools")
    func advertisedToolsAreStable() {
        let names = Set(LLDBSessionController.advertisedTools().map(\.name))

        #expect(names == [
            "lldb_refresh_sessions",
            "lldb__session_create",
            "lldb__command",
            "lldb__sessions_list",
            "lldb__session_close",
        ])
    }

    @Test("Xcode 26 returns explicit unsupported feedback without starting LLDB")
    func xcode26Feedback() async throws {
        let fixture = try makeRuntime(version: "26.4", includesLLDBMCP: false)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let fakeClient = FakeLLDBMCPClient()
        let controller = makeController(runtime: fixture.runtime, client: fakeClient)

        let refresh = try #require(await controller.routeToolCall(
            toolName: "lldb_refresh_sessions",
            args: nil
        ))
        let refreshData = try #require(refresh.data)
        let refreshText = text(from: refreshData)

        #expect(refresh.success)
        #expect(refreshData.isError == false)
        #expect(refreshText.contains(#""supported" : false"#))
        #expect(refreshText.contains("Xcode 26.4 does not provide lldb-mcp"))
        #expect(refreshText.contains("Existing Xcode project, build, and test tools remain available"))

        let command = try #require(await controller.routeToolCall(
            toolName: "lldb__command",
            args: ["command": "frame variable"]
        ))
        #expect(command.data?.isError == true)
        #expect(await fakeClient.counts().starts == 0)
    }

    @Test("Xcode 27 starts the session-scoped adapter and proxies LLDB tools")
    func xcode27ProxiesTools() async throws {
        let fixture = try makeRuntime(version: "27.0", includesLLDBMCP: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let fakeClient = FakeLLDBMCPClient()
        let controller = makeController(runtime: fixture.runtime, client: fakeClient)

        let result = try #require(await controller.routeToolCall(
            toolName: "lldb__sessions_list",
            args: nil
        ))

        #expect(result.success)
        #expect(result.data?.isError == false)
        #expect(result.data.map(text(from:))?.contains("lldb-mcp://instance/900/debugger/1") == true)
        #expect(await fakeClient.counts().starts == 1)

        let resources = await controller.listResources()
        #expect(resources.map(\.uri) == ["lldb__lldb://instance/900/debugger/1"])
    }

    @Test("Early Xcode 27 beta maps debugger_list and reports missing session lifecycle tools")
    func earlyXcode27BetaCompatibility() async throws {
        let fixture = try makeRuntime(version: "27.0", includesLLDBMCP: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let fakeClient = FakeLLDBMCPClient(
            sessions: ["lldb-mcp://debugger/1"],
            toolNames: ["command", "debugger_list"]
        )
        let controller = makeController(runtime: fixture.runtime, client: fakeClient)

        let listed = try #require(await controller.routeToolCall(
            toolName: "lldb__sessions_list",
            args: nil
        ))
        #expect(listed.data.map(text(from:))?.contains("lldb-mcp://debugger/1") == true)

        let create = try #require(await controller.routeToolCall(
            toolName: "lldb__session_create",
            args: nil
        ))
        let message = create.data.map(text(from:)) ?? ""
        #expect(create.data?.isError == true)
        #expect(message.contains("early lldb-mcp tool set [command, debugger_list]"))
        #expect(message.contains("lldb__sessions_list"))
        #expect(message.contains("lldb__command"))
    }

    @Test("Refresh protects owned sessions unless force is explicit")
    func refreshProtectsOwnedSessions() async throws {
        let fixture = try makeRuntime(version: "27.0", includesLLDBMCP: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let fakeClient = FakeLLDBMCPClient()
        let controller = makeController(runtime: fixture.runtime, client: fakeClient)

        _ = try #require(await controller.routeToolCall(
            toolName: "lldb__session_create",
            args: nil
        ))

        let blocked = try #require(await controller.routeToolCall(
            toolName: "lldb_refresh_sessions",
            args: nil
        ))
        #expect(blocked.data.map(text(from:))?.contains(#""action" : "blocked""#) == true)
        #expect(await fakeClient.counts() == (starts: 1, stops: 0))

        let forced = try #require(await controller.routeToolCall(
            toolName: "lldb_refresh_sessions",
            args: ["force": true]
        ))
        let forcedText = forced.data.map(text(from:)) ?? ""
        #expect(forcedText.contains(#""destroyedOwnedSessionCount" : 1"#))
        #expect(await fakeClient.counts() == (starts: 2, stops: 1))
    }

    @Test("Registry changes trigger a safe automatic reconnect")
    func registryChangeReconnects() async throws {
        let fixture = try makeRuntime(version: "27.0", includesLLDBMCP: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let fakeClient = FakeLLDBMCPClient()
        let firstSnapshot = snapshot(processIdentifier: 100)
        let registry = MutableLLDBRegistryManager(snapshot: firstSnapshot)
        let controller = makeController(
            runtime: fixture.runtime,
            registry: registry,
            client: fakeClient
        )

        _ = try #require(await controller.routeToolCall(
            toolName: "lldb__sessions_list",
            args: nil
        ))
        await registry.setSnapshot(snapshot(processIdentifier: 200))
        _ = try #require(await controller.routeToolCall(
            toolName: "lldb__sessions_list",
            args: nil
        ))

        #expect(await fakeClient.counts() == (starts: 2, stops: 1))
    }

    @Test("Closing the HTTP session stops its LLDB adapter")
    func shutdownStopsAdapter() async throws {
        let fixture = try makeRuntime(version: "27.0", includesLLDBMCP: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let fakeClient = FakeLLDBMCPClient()
        let controller = makeController(runtime: fixture.runtime, client: fakeClient)

        _ = try #require(await controller.routeToolCall(
            toolName: "lldb__sessions_list",
            args: nil
        ))
        await controller.shutdown()

        #expect(await fakeClient.counts() == (starts: 1, stops: 1))
    }

    @Test("Shutdown and idle collection terminate only this adapter's backends", arguments: [false, true])
    func shutdownTerminatesOwnedBackend(idle: Bool) async throws {
        let fixture = try makeRuntime(version: "27.0", includesLLDBMCP: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let fakeClient = FakeLLDBMCPClient()
        let ownedBackend = LLDBRegistryEntry(
            fileURL: URL(fileURLWithPath: "/tmp/lldb-mcp-700.json"),
            processIdentifier: 700,
            connectionURI: "connection://[127.0.0.1]:5700",
            contents: "owned",
            processExecutablePath: fixture.runtime.developerDirectoryURL
                .appendingPathComponent("usr/bin/lldb").path,
            parentProcessIdentifier: 699,
            parentProcessExecutablePath: fixture.runtime.developerDirectoryURL
                .appendingPathComponent("usr/bin/lldb-mcp").path
        )
        let registry = MutableLLDBRegistryManager(
            queuedSnapshots: [
                .empty,
                .empty,
                LLDBRegistrySnapshot(entries: [ownedBackend, LLDBRegistryEntry(
                    fileURL: URL(fileURLWithPath: "/tmp/lldb-mcp-800.json"),
                    processIdentifier: 800,
                    connectionURI: nil,
                    contents: "another adapter",
                    processExecutablePath: ownedBackend.processExecutablePath,
                    parentProcessIdentifier: 799,
                    parentProcessExecutablePath: ownedBackend.parentProcessExecutablePath
                )]),
            ]
        )
        let controller = makeController(
            runtime: fixture.runtime,
            registry: registry,
            client: fakeClient,
            idleTimeout: idle ? .milliseconds(50) : .seconds(1800)
        )

        _ = try #require(await controller.routeToolCall(
            toolName: "lldb__sessions_list",
            args: nil
        ))
        if idle {
            try await waitUntil { await registry.terminatedProcesses() == [700] }
        }
        await controller.shutdown()
        #expect(await registry.terminatedProcesses() == [700])
    }

    private struct RuntimeFixture {
        let rootURL: URL
        let runtime: XcodeRuntime
    }

    private func makeRuntime(version: String, includesLLDBMCP: Bool) throws -> RuntimeFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("XCodeMCPService-LLDBSession-\(UUID().uuidString)", isDirectory: true)
        let applicationURL = rootURL.appendingPathComponent("Xcode.app", isDirectory: true)
        let developerDirectoryURL = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Developer", isDirectory: true)
        let binURL = developerDirectoryURL
            .appendingPathComponent("usr", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        if includesLLDBMCP {
            let executableURL = binURL.appendingPathComponent("lldb-mcp")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: executableURL.path
            )
        }

        return RuntimeFixture(
            rootURL: rootURL,
            runtime: XcodeRuntime(
                applicationURL: applicationURL,
                developerDirectoryURL: developerDirectoryURL,
                version: version,
                buildVersion: version.hasPrefix("27") ? "27A123" : "18A123",
                mode: includesLLDBMCP ? .headlessCapable : .legacyUIBridge,
                selectionSource: .singleRunning
            )
        )
    }

    private func makeController(
        runtime: XcodeRuntime,
        registry: MutableLLDBRegistryManager = MutableLLDBRegistryManager(),
        client: FakeLLDBMCPClient,
        idleTimeout: Duration = .seconds(30 * 60)
    ) -> LLDBSessionController {
        LLDBSessionController(
            runtimeResolver: StaticLLDBRuntimeResolver(runtime: runtime),
            registryManager: registry,
            idleTimeout: idleTimeout,
            clientFactory: { _ in client }
        )
    }

    private func snapshot(processIdentifier: Int32) -> LLDBRegistrySnapshot {
        let fileURL = URL(fileURLWithPath: "/tmp/lldb-mcp-\(processIdentifier).json")
        return LLDBRegistrySnapshot(entries: [
            LLDBRegistryEntry(
                fileURL: fileURL,
                processIdentifier: processIdentifier,
                connectionURI: "connection://[127.0.0.1]:\(processIdentifier)",
                contents: "\(processIdentifier)"
            )
        ])
    }

    private func backend(processIdentifier: Int32, parent: Int32, runtime: XcodeRuntime) -> LLDBRegistryEntry {
        LLDBRegistryEntry(
            fileURL: URL(fileURLWithPath: "/tmp/lldb-mcp-\(processIdentifier).json"),
            processIdentifier: processIdentifier,
            connectionURI: nil,
            contents: "backend",
            processExecutablePath: runtime.developerDirectoryURL.appendingPathComponent("usr/bin/lldb").path,
            parentProcessIdentifier: parent,
            parentProcessExecutablePath: runtime.developerDirectoryURL.appendingPathComponent("usr/bin/lldb-mcp").path
        )
    }

    private func text(from result: ToolCallResult) -> String {
        result.content.compactMap { content in
            guard case .text(let text, _, _) = content else { return nil }
            return text
        }.joined(separator: "\n")
    }
}
