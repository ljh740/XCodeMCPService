import Foundation
import Testing
import MCP
@testable import MCPServiceCore

@Suite("RequestRouter Tests")
struct RequestRouterTests {

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

    private func makeSlowToolClient() async throws -> (client: Client, server: Server) {
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
            ListTools.Result(tools: [
                Tool(
                    name: "slow_tool",
                    description: "Sleeps before responding",
                    inputSchema: [:]
                )
            ])
        }
        await server.withMethodHandler(CallTool.self) { _ in
            try await Task.sleep(for: .milliseconds(200))
            return CallTool.Result(content: [.text("done")], isError: false)
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
            prefixedName: "nonexistent__tool",
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
            prefixedName: "server__my_tool",
            args: nil
        )
        #expect(result.error?.message.contains("server__my_tool") == true)
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
        let (client, server) = try await makeSlowToolClient()

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
            prefixedName: "xcode-tools__slow_tool",
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
