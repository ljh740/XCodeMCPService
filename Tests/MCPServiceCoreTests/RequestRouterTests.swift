import Foundation
import Testing
import MCP
@testable import MCPServiceCore

@Suite("RequestRouter Tests")
struct RequestRouterTests {
    struct ToolFixture: Sendable {
        let name: String
        let response: String
        var delayMs = 0
    }

    actor TimeoutReportProbe: RuntimeHealthReporting {
        private let generation: UInt64
        private var records: [(serverName: String, operation: String, generation: UInt64?)] = []

        init(generation: UInt64) {
            self.generation = generation
        }

        func currentHealthGeneration(serverName _: String) -> UInt64? {
            generation
        }

        func recordRequestTimeout(
            serverName: String,
            operation: String,
            generation: UInt64?
        ) async {
            records.append((serverName, operation, generation))
        }

        func getRecords() -> [(serverName: String, operation: String, generation: UInt64?)] {
            records
        }
    }

    // Create router with empty client manager (no servers)
    private func makeRouter(timeout: Int = 5000) -> RequestRouter {
        let clientManager = StdioClientManager(configs: [])
        let aggregator = CapabilityAggregator(clientManager: clientManager)
        return RequestRouter(
            clientManager: clientManager,
            aggregator: aggregator,
            timeout: timeout
        )
    }

    private func makeToolClient(
        tools: [ToolFixture] = [ToolFixture(name: "slow_tool", response: "done")],
        listDelayMs: Int = 0,
        responseDelayMs: Int = 0
    ) async throws -> (client: Client, server: Server) {
        let listedTools = tools.map { tool in
            Tool(
                name: tool.name,
                description: "Sleeps before responding",
                inputSchema: [:]
            )
        }
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = Server(
            name: "TestServer",
            version: "1.0.0",
            capabilities: .init(
                prompts: .init(),
                resources: .init(),
                tools: .init()
            )
        )
        await server.withMethodHandler(ListTools.self) { _ in
            if listDelayMs > 0 {
                try await Task.sleep(for: .milliseconds(listDelayMs))
            }
            return ListTools.Result(tools: listedTools, nextCursor: nil)
        }
        await server.withMethodHandler(CallTool.self) { params in
            let fixture = tools.first(where: { $0.name == params.name })
            let delayMs = max(responseDelayMs, fixture?.delayMs ?? 0)
            if delayMs > 0 {
                try await Task.sleep(for: .milliseconds(delayMs))
            }
            return CallTool.Result(content: [.text(fixture?.response ?? "done")], isError: false)
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "TestClient", version: "1.0")
        _ = try await client.connect(transport: clientTransport)
        return (client, server)
    }

    // MARK: - Tool Call Tests

    @Test("Capability refresh times out instead of waiting indefinitely")
    func capabilityRefreshTimesOut() async throws {
        let mock = MockStdioClientManager()
        let (client, server) = try await makeToolClient(listDelayMs: 500)

        await mock.setConfiguredServers(["xcode-tools"])
        await mock.addActiveServer("xcode-tools")
        await mock.setClient(client, forServer: "xcode-tools")

        let aggregator = CapabilityAggregator(
            clientManager: mock,
            capabilityRequestTimeoutMs: 50
        )
        let start = ContinuousClock.now
        let summary = await aggregator.refresh()
        let elapsed = ContinuousClock.now - start

        #expect(summary.hasSuccessfulFetch == false)
        #expect(summary.failures["xcode-tools/tools"] == "Timed out after 50ms")
        #expect(elapsed < .milliseconds(250))

        await client.disconnect()
        await server.stop()
    }

    @Test("routeToolCall returns failure for unknown tool")
    func toolCallUnknownTool() async {
        let router = makeRouter()
        let result = await router.routeToolCall(
            toolName: "nonexistent__tool",
            args: nil
        )
        #expect(result.success == false)
        #expect(result.error != nil)
        #expect(result.error?.code == ErrorCodes.methodNotFound)
    }

    @Test("routeToolCall error message contains tool name")
    func toolCallErrorMessage() async {
        let router = makeRouter()
        let result = await router.routeToolCall(
            toolName: "server__my_tool",
            args: nil
        )
        #expect(result.error?.message.contains("server__my_tool") == true)
    }

    @Test("single configured server exposes original tool name")
    func singleConfiguredServerUsesOriginalToolName() async throws {
        let mock = MockStdioClientManager()
        let (client, server) = try await makeToolClient()

        await mock.setConfiguredServers(["xcode-tools"])
        await mock.addActiveServer("xcode-tools")
        await mock.setClient(client, forServer: "xcode-tools")

        let aggregator = CapabilityAggregator(clientManager: mock)
        await aggregator.refresh()
        let tools = await aggregator.getAggregatedTools()

        #expect(tools.count == 1)
        #expect(tools.first?.name == "slow_tool")
        #expect(tools.first?.canonicalName == "xcode-tools__slow_tool")

        await client.disconnect()
        await server.stop()
    }

    @Test("multiple configured servers keep namespaced tool name")
    func multiConfiguredServersUseNamespacedToolName() async throws {
        let mock = MockStdioClientManager()
        let (client, server) = try await makeToolClient()

        await mock.setConfiguredServers(["xcode-tools", "android-tools"])
        await mock.addActiveServer("xcode-tools")
        await mock.setClient(client, forServer: "xcode-tools")

        let aggregator = CapabilityAggregator(clientManager: mock)
        await aggregator.refresh()
        let tools = await aggregator.getAggregatedTools()

        #expect(tools.count == 1)
        #expect(tools.first?.name == "xcode-tools__slow_tool")
        #expect(tools.first?.canonicalName == "xcode-tools__slow_tool")

        await client.disconnect()
        await server.stop()
    }

    @Test("routeToolCall accepts public tool name for single configured server")
    func toolCallPublicNameSingleServer() async throws {
        let mock = MockStdioClientManager()
        let (client, server) = try await makeToolClient()

        await mock.setConfiguredServers(["xcode-tools"])
        await mock.addActiveServer("xcode-tools")
        await mock.setClient(client, forServer: "xcode-tools")

        let aggregator = CapabilityAggregator(clientManager: mock)
        await aggregator.refresh()
        let router = RequestRouter(
            clientManager: mock,
            aggregator: aggregator,
            timeout: 50
        )

        let result = await router.routeToolCall(
            toolName: "slow_tool",
            args: nil
        )

        #expect(result.success == true)
        #expect(result.error == nil)
        #expect(result.data?.isError == false)

        await client.disconnect()
        await server.stop()
    }

    @Test("routeToolCall prefers public tool name over colliding legacy alias")
    func toolCallPrefersPublicNameWhenLegacyAliasCollides() async throws {
        let mock = MockStdioClientManager()
        let (client, server) = try await makeToolClient(
            tools: [
                ToolFixture(name: "Foo", response: "legacy-alias-owner"),
                ToolFixture(name: "xcode-tools__Foo", response: "public-tool"),
            ]
        )

        await mock.setConfiguredServers(["xcode-tools"])
        await mock.addActiveServer("xcode-tools")
        await mock.setClient(client, forServer: "xcode-tools")

        let aggregator = CapabilityAggregator(clientManager: mock)
        await aggregator.refresh()
        let router = RequestRouter(
            clientManager: mock,
            aggregator: aggregator,
            timeout: 50
        )

        let result = await router.routeToolCall(
            toolName: "xcode-tools__Foo",
            args: nil
        )

        #expect(result.success == true)
        #expect(result.data?.content == [.text("public-tool")])

        await client.disconnect()
        await server.stop()
    }

    @Test("routeToolCall returns invalidParams for duplicate public tool names")
    func toolCallDuplicatePublicNames() async throws {
        let mock = MockStdioClientManager()
        let (client, server) = try await makeToolClient(
            tools: [
                ToolFixture(name: "Foo", response: "first"),
                ToolFixture(name: "Foo", response: "second"),
            ]
        )

        await mock.setConfiguredServers(["xcode-tools"])
        await mock.addActiveServer("xcode-tools")
        await mock.setClient(client, forServer: "xcode-tools")

        let aggregator = CapabilityAggregator(clientManager: mock)
        await aggregator.refresh()
        let router = RequestRouter(
            clientManager: mock,
            aggregator: aggregator,
            timeout: 50
        )

        let result = await router.routeToolCall(
            toolName: "Foo",
            args: nil
        )

        #expect(result.success == false)
        #expect(result.error?.code == ErrorCodes.invalidParams)
        #expect(result.error?.message == "Tool name is ambiguous: Foo")

        await client.disconnect()
        await server.stop()
    }

    // MARK: - Tool Timeouts

    @Test("Long task defaults apply to public names and canonical aliases", arguments: [
        "BuildProject", "RunAllTests", "RunSomeTests",
    ], [false, true])
    func longTaskTimeoutDefaults(toolName: String, namespaced: Bool) async throws {
        let mock = MockStdioClientManager()
        let (client, server) = try await makeToolClient(
            tools: [ToolFixture(name: toolName, response: "completed")],
            responseDelayMs: 200
        )
        await mock.setConfiguredServers(["xcode-tools"])
        await mock.addActiveServer("xcode-tools")
        await mock.setClient(client, forServer: "xcode-tools")

        let aggregator = CapabilityAggregator(clientManager: mock)
        await aggregator.refresh()
        let router = RequestRouter(clientManager: mock, aggregator: aggregator, timeout: 50)
        let result = await router.routeToolCall(
            toolName: namespaced ? "xcode-tools__\(toolName)" : toolName,
            args: nil
        )

        await client.disconnect()
        await server.stop()
        #expect(result.success)
        #expect(result.data?.content == [.text(text: "completed", annotations: nil, _meta: nil)])
    }

    @Test("Other tools and servers keep the global timeout", arguments: [
        ("xcode-tools", "GetBuildLog"),
        ("other-tools", "BuildProject"),
    ])
    func otherToolsKeepGlobalTimeout(serverName: String, toolName: String) async throws {
        let mock = MockStdioClientManager()
        let (client, server) = try await makeToolClient(
            tools: [ToolFixture(name: toolName, response: "too late")],
            responseDelayMs: 200
        )
        await mock.setConfiguredServers([serverName])
        await mock.addActiveServer(serverName)
        await mock.setClient(client, forServer: serverName)

        let aggregator = CapabilityAggregator(clientManager: mock)
        await aggregator.refresh()
        let router = RequestRouter(clientManager: mock, aggregator: aggregator, timeout: 50)
        let result = await router.routeToolCall(toolName: toolName, args: nil)

        await client.disconnect()
        await server.stop()
        #expect(result.error?.code == ErrorCodes.timeout)
        #expect(result.error?.message == "Tool call timed out after 50ms: \(toolName)")
    }

    @Test("Configured override controls timeout errors")
    func configuredToolTimeout() async throws {
        let mock = MockStdioClientManager()
        let (client, server) = try await makeToolClient(responseDelayMs: 200)
        await mock.setConfiguredServers(["xcode-tools"])
        await mock.addActiveServer("xcode-tools")
        await mock.setClient(client, forServer: "xcode-tools")

        let aggregator = CapabilityAggregator(clientManager: mock)
        await aggregator.refresh()
        let router = RequestRouter(
            clientManager: mock,
            aggregator: aggregator,
            timeout: 5000,
            toolTimeouts: ["xcode-tools__slow_tool": 50]
        )
        let result = await router.routeToolCall(toolName: "slow_tool", args: nil)

        await client.disconnect()
        await server.stop()
        #expect(result.error?.code == ErrorCodes.timeout)
        #expect(result.error?.message == "Tool call timed out after 50ms: slow_tool")
    }

    @Test("Empty override table disables long task defaults")
    func emptyToolTimeoutsUseGlobalTimeout() async throws {
        let mock = MockStdioClientManager()
        let (client, server) = try await makeToolClient(
            tools: [ToolFixture(name: "BuildProject", response: "too late")],
            responseDelayMs: 200
        )
        await mock.setConfiguredServers(["xcode-tools"])
        await mock.addActiveServer("xcode-tools")
        await mock.setClient(client, forServer: "xcode-tools")

        let aggregator = CapabilityAggregator(clientManager: mock)
        await aggregator.refresh()
        let router = RequestRouter(
            clientManager: mock,
            aggregator: aggregator,
            timeout: 50,
            toolTimeouts: [:]
        )
        let result = await router.routeToolCall(toolName: "BuildProject", args: nil)

        await client.disconnect()
        await server.stop()
        #expect(result.error?.code == ErrorCodes.timeout)
    }

    // MARK: - Resource Read Tests

    @Test("routeResourceRead returns failure for unknown resource")
    func resourceReadUnknown() async {
        let router = makeRouter()
        let result = await router.routeResourceRead(
            prefixedUri: "nonexistent://resource"
        )
        #expect(result.success == false)
        #expect(result.error?.code == ErrorCodes.methodNotFound)
    }

    @Test("routeResourceRead error message contains URI")
    func resourceReadErrorMessage() async {
        let router = makeRouter()
        let result = await router.routeResourceRead(
            prefixedUri: "server://my/resource"
        )
        #expect(result.error?.message.contains("server://my/resource") == true)
    }

    // MARK: - Prompt Get Tests

    @Test("routePromptGet returns failure for unknown prompt")
    func promptGetUnknown() async {
        let router = makeRouter()
        let result = await router.routePromptGet(
            prefixedName: "nonexistent__prompt",
            args: nil
        )
        #expect(result.success == false)
        #expect(result.error?.code == ErrorCodes.methodNotFound)
    }

    @Test("routePromptGet error message contains prompt name")
    func promptGetErrorMessage() async {
        let router = makeRouter()
        let result = await router.routePromptGet(
            prefixedName: "server__my_prompt",
            args: nil
        )
        #expect(result.error?.message.contains("server__my_prompt") == true)
    }

    @Test("routeToolCall timeout reports runtime health")
    func toolCallTimeoutReportsRuntimeHealth() async throws {
        let mock = MockStdioClientManager()
        let probe = TimeoutReportProbe(generation: 7)
        let (client, server) = try await makeToolClient(responseDelayMs: 200)

        await mock.setConfiguredServers(["xcode-tools"])
        await mock.addActiveServer("xcode-tools")
        await mock.setClient(client, forServer: "xcode-tools")

        let aggregator = CapabilityAggregator(clientManager: mock)
        await aggregator.refresh()
        let router = RequestRouter(
            clientManager: mock,
            aggregator: aggregator,
            timeout: 50,
            runtimeHealthReporter: probe
        )

        let result = await router.routeToolCall(
            toolName: "xcode-tools__slow_tool",
            args: nil
        )
        #expect(result.success == false)
        #expect(result.error?.code == ErrorCodes.timeout)

        var records = await probe.getRecords()
        for _ in 0..<20 where records.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            records = await probe.getRecords()
        }
        #expect(records.count == 1)
        #expect(records.first?.serverName == "xcode-tools")
        #expect(records.first?.operation == "tool:xcode-tools__slow_tool")
        #expect(records.first?.generation == 7)

        await client.disconnect()
        await server.stop()
    }

    // MARK: - RouteResult Tests

    @Test("RouteResult.success creates successful result")
    func routeResultSuccess() {
        let result = RouteResult<String>.success("hello")
        #expect(result.success == true)
        #expect(result.data == "hello")
        #expect(result.error == nil)
    }

    @Test("RouteResult.failure creates failed result")
    func routeResultFailure() {
        let result = RouteResult<String>.failure(
            code: ErrorCodes.serverNotFound,
            message: "not found"
        )
        #expect(result.success == false)
        #expect(result.data == nil)
        #expect(result.error?.code == ErrorCodes.serverNotFound)
        #expect(result.error?.message == "not found")
    }

    // MARK: - Device Lock Watch

    private func makeDeviceLockRouter(
        destinationsResponse: String,
        lockScript: [Bool],
        testDelayMs: Int = 100
    ) async throws -> (
        router: RequestRouter,
        provider: ScriptedLockStateProvider,
        recorder: DeviceLockEventRecorder,
        client: Client,
        server: Server
    ) {
        let mock = MockStdioClientManager()
        let (client, server) = try await makeToolClient(
            tools: [
                ToolFixture(name: "RunSomeTests", response: "tests passed", delayMs: testDelayMs),
                ToolFixture(name: "XcodeListRunDestinations", response: destinationsResponse),
            ]
        )
        await mock.setConfiguredServers(["xcode-tools"])
        await mock.addActiveServer("xcode-tools")
        await mock.setClient(client, forServer: "xcode-tools")

        let aggregator = CapabilityAggregator(clientManager: mock)
        await aggregator.refresh()
        let router = RequestRouter(clientManager: mock, aggregator: aggregator, timeout: 5000)

        let provider = ScriptedLockStateProvider(lockScript)
        let recorder = DeviceLockEventRecorder()
        let monitor = DeviceLockMonitor(provider: provider, pollInterval: .milliseconds(5)) { event in
            recorder.append(event)
        }
        await router.setDeviceLockMonitor(monitor)
        return (router, provider, recorder, client, server)
    }

    @Test("test tool on locked physical device emits locked and clears when call ends")
    func deviceLockWatchedDuringTestCall() async throws {
        let destinations = #"{"destinations":[{"displayTitle":"darkedge","isActive":true,"isSimulator":false,"isGenericDevice":false,"platformIdentifier":"com.apple.platform.iphoneos"}]}"#
        let fixture = try await makeDeviceLockRouter(destinationsResponse: destinations, lockScript: [true])

        let result = await fixture.router.routeToolCall(toolName: "RunSomeTests", args: ["tests": []])

        #expect(result.success)
        #expect(fixture.provider.queries.first == "darkedge")
        #expect(fixture.recorder.events == [.locked(deviceName: "darkedge"), .cleared(deviceName: "darkedge")])

        await fixture.client.disconnect()
        await fixture.server.stop()
    }

    @Test("cancelling a watched call returns promptly and clears the lock reminder")
    func cancelledCallClearsDeviceLock() async throws {
        let destinations = #"{"destinations":[{"displayTitle":"darkedge","isActive":true,"isSimulator":false,"isGenericDevice":false,"platformIdentifier":"com.apple.platform.iphoneos"}]}"#
        let fixture = try await makeDeviceLockRouter(
            destinationsResponse: destinations,
            lockScript: [true],
            testDelayMs: 10_000
        )

        let call = Task {
            await fixture.router.routeToolCall(toolName: "RunSomeTests", args: ["tests": []])
        }
        try await waitUntil { fixture.recorder.events == [.locked(deviceName: "darkedge")] }

        let cancelledAt = ContinuousClock.now
        call.cancel()
        let result = await call.value

        #expect(ContinuousClock.now - cancelledAt < .seconds(1))
        #expect(result.success == false)
        #expect(fixture.recorder.events == [.locked(deviceName: "darkedge"), .cleared(deviceName: "darkedge")])

        await fixture.client.disconnect()
        await fixture.server.stop()
    }

    @Test("test tool on simulator does not query device lock state")
    func simulatorDestinationNotWatched() async throws {
        let destinations = #"{"destinations":[{"displayTitle":"iPhone 17","isActive":true,"isSimulator":true,"isGenericDevice":false,"platformIdentifier":"com.apple.platform.iphonesimulator"}]}"#
        let fixture = try await makeDeviceLockRouter(destinationsResponse: destinations, lockScript: [true])

        let result = await fixture.router.routeToolCall(toolName: "RunSomeTests", args: ["tests": []])

        #expect(result.success)
        #expect(fixture.provider.queries.isEmpty)
        #expect(fixture.recorder.events.isEmpty)

        await fixture.client.disconnect()
        await fixture.server.stop()
    }

    @Test("non-device tools skip run destination lookup")
    func nonDeviceToolNotWatched() async throws {
        let destinations = #"{"destinations":[{"displayTitle":"darkedge","isActive":true,"isSimulator":false,"isGenericDevice":false,"platformIdentifier":"com.apple.platform.iphoneos"}]}"#
        let fixture = try await makeDeviceLockRouter(destinationsResponse: destinations, lockScript: [true])

        let result = await fixture.router.routeToolCall(toolName: "XcodeListRunDestinations", args: nil)

        #expect(result.success)
        #expect(fixture.provider.queries.isEmpty)
        #expect(fixture.recorder.events.isEmpty)

        await fixture.client.disconnect()
        await fixture.server.stop()
    }
}
