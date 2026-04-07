import Foundation
import Testing
import MCP
@testable import MCPServiceCore

@Suite("RequestRouter Tests")
struct RequestRouterTests {
    struct ToolFixture: Sendable {
        let name: String
        let response: String
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
            ListTools.Result(tools: listedTools, nextCursor: nil)
        }
        await server.withMethodHandler(CallTool.self) { params in
            if responseDelayMs > 0 {
                try await Task.sleep(for: .milliseconds(responseDelayMs))
            }
            let response = tools.first(where: { $0.name == params.name })?.response ?? "done"
            return CallTool.Result(content: [.text(response)], isError: false)
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "TestClient", version: "1.0")
        _ = try await client.connect(transport: clientTransport)
        return (client, server)
    }

    // MARK: - Tool Call Tests

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
}
