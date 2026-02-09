import Foundation
import Testing
import MCP
@testable import MCPServiceCore

@Suite("RequestRouter Tests")
struct RequestRouterTests {

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
