import Foundation
import MCP
import Testing
@testable import MCPServiceCore

@Suite("Bridge Tool Compatibility Tests")
struct BridgeToolCompatibilityTests {
    @Test("Tool metadata survives HTTP exposure in both naming modes", arguments: [false, true])
    func toolMetadata(namespaced: Bool) async throws {
        let tool = Tool(
            name: "RenderPreview",
            title: "Render Preview",
            description: "Renders a preview on the selected destination",
            inputSchema: ["type": "object", "properties": ["sourceFilePath": ["type": "string"]]],
            annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false),
            outputSchema: ["type": "object", "properties": ["snapshot": ["type": "object"]]],
            icons: [Icon(src: "https://example.com/preview.png", mimeType: "image/png", sizes: ["48x48"])],
            _meta: Metadata(additionalFields: ["fixture/version": "27.2"])
        )
        try await withBridge(tool: tool, namespaced: namespaced) { http, sessionID in
            let response = await http.routeRequest(try request(
                method: "tools/list", id: 2, sessionID: sessionID
            ))
            let payload = try resultObject(response)
            let tools = try #require(payload["tools"] as? [[String: Any]])
            let publicName = namespaced ? "xcode-tools__RenderPreview" : "RenderPreview"
            let exposed = try #require(tools.first { $0["name"] as? String == publicName })
            var expected = try jsonObject(tool)
            expected["name"] = publicName

            #expect(NSDictionary(dictionary: exposed).isEqual(to: expected))
        }
    }

    @Test("Legacy tools keep optional metadata absent")
    func legacyToolMetadata() async throws {
        let tool = Tool(name: "XcodeRead", description: "Reads a file", inputSchema: [:])
        try await withBridge(tool: tool) { http, sessionID in
            let response = await http.routeRequest(try request(
                method: "tools/list", id: 2, sessionID: sessionID
            ))
            let payload = try resultObject(response)
            let tools = try #require(payload["tools"] as? [[String: Any]])
            let exposed = try #require(tools.first { $0["name"] as? String == "XcodeRead" })

            #expect(NSDictionary(dictionary: exposed).isEqual(to: try jsonObject(tool)))
            for key in ["title", "outputSchema", "annotations", "icons", "_meta"] {
                #expect(exposed[key] == nil)
            }
        }
    }

    @Test("Legacy, structured, and structured-only error results survive HTTP", arguments: [
        "legacy", "structured", "structured-error",
    ], [false, true])
    func toolResults(format: String, namespaced: Bool) async throws {
        let legacy = format == "legacy"
        let failed = format == "structured-error"
        let content: [Tool.Content] = failed ? [] : [
            .text(text: legacy ? "Preview rendered" : "Preview result", annotations: nil, _meta: nil)
        ]
        let result = CallTool.Result(
            content: content,
            structuredContent: legacy ? nil : .object([
                "snapshot": .object(["path": .string("/tmp/preview.png")]),
                "supportedOverrides": .object(["renderDestinations": .array([])]),
                "errors": .array(failed ? [.string("Destination unavailable")] : []),
            ]),
            isError: legacy ? nil : failed,
            _meta: legacy ? nil : Metadata(additionalFields: ["fixture/version": "27.2"])
        )
        let arguments: [String: Value] = legacy
            ? ["sourceFilePath": "App/Preview.swift"]
            : [
                "sourceFilePath": "App/Preview.swift",
                "preferredRenderDestination": ["identifier": "simulator-1"],
                "displayMode": "interactive",
                "snapshotDelay": 1,
            ]
        let tool = Tool(name: "RenderPreview", description: "Renders a preview", inputSchema: [:])
        try await withBridge(
            tool: tool, namespaced: namespaced, result: result, expectedArguments: arguments
        ) { http, sessionID in
            let response = await http.routeRequest(try request(
                method: "tools/call",
                id: 2,
                params: [
                    "name": .string(namespaced ? "xcode-tools__RenderPreview" : "RenderPreview"),
                    "arguments": .object(arguments),
                ],
                sessionID: sessionID
            ))
            let payload = try resultObject(response)

            #expect(NSDictionary(dictionary: payload).isEqual(to: try jsonObject(result)))
            if legacy {
                #expect(payload["structuredContent"] == nil)
                #expect(payload["_meta"] == nil)
                #expect(payload["isError"] == nil)
            }
        }
    }

    private func withBridge(
        tool: Tool,
        namespaced: Bool = false,
        result: CallTool.Result = .init(),
        expectedArguments: [String: Value]? = nil,
        operation: (HTTPServer, String) async throws -> Void
    ) async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let downstream = Server(name: "Fixture", version: "1.0", capabilities: .init(tools: .init()))
        await downstream.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [tool])
        }
        await downstream.withMethodHandler(CallTool.self) { params in
            #expect(params.name == tool.name)
            #expect(params.arguments == expectedArguments)
            return result
        }
        let client = Client(name: "FixtureBridge", version: "1.0")
        let http = HTTPServer(port: 13339)
        do {
            try await downstream.start(transport: serverTransport)
            _ = try await client.connect(transport: clientTransport)
            let manager = MockStdioClientManager()
            await manager.setConfiguredServers(namespaced ? ["xcode-tools", "other-tools"] : ["xcode-tools"])
            await manager.addActiveServer("xcode-tools")
            await manager.setClient(client, forServer: "xcode-tools")
            let aggregator = CapabilityAggregator(clientManager: manager)
            await aggregator.refresh()
            let router = RequestRouter(clientManager: manager, aggregator: aggregator)
            await http.setMcpServerFactory {
                let lldb = LLDBSessionController()
                let server = Server(name: "FixtureGateway", version: "1.0", capabilities: .init(tools: .init()))
                await BridgeServer.registerHandlers(
                    on: server, aggregator: aggregator, router: router, lldbController: lldb
                )
                return McpServerSession(server: server, onClose: { await lldb.shutdown() })
            }
            let initialized = await http.routeRequest(try request(
                method: "initialize",
                id: 1,
                params: [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [:],
                    "clientInfo": ["name": "CompatibilityTest", "version": "1.0"],
                ]
            ))
            let sessionID = try #require(initialized.headers["Mcp-Session-Id"])
            _ = await http.routeRequest(try request(method: "notifications/initialized", sessionID: sessionID))
            try await operation(http, sessionID)
        } catch {
            await http.stop()
            await client.disconnect()
            await downstream.stop()
            throw error
        }
        await http.stop()
        await client.disconnect()
        await downstream.stop()
    }

    private func request(
        method: String,
        id: Int? = nil,
        params: [String: Value] = [:],
        sessionID: String? = nil
    ) throws -> MCPServiceCore.HTTPRequest {
        var payload: [String: Value] = ["jsonrpc": "2.0", "method": .string(method), "params": .object(params)]
        if let id { payload["id"] = .int(id) }
        var headers = ["content-type": "application/json"]
        if let sessionID { headers["mcp-session-id"] = sessionID }
        return MCPServiceCore.HTTPRequest(
            method: "POST", path: "/mcp", headers: headers,
            body: try JSONEncoder().encode(payload), clientIP: nil
        )
    }

    private func resultObject(_ response: MCPServiceCore.HTTPResponse) throws -> [String: Any] {
        #expect(response.statusCode == 200)
        let body = try #require(response.body)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["error"] == nil)
        return try #require(payload["result"] as? [String: Any])
    }

    private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
}
