import Foundation
import Testing
@testable import MCPServiceCore

@Suite("HTTP Routing Tests")
struct HTTPServerRoutingTests {

    // MARK: - JSON-RPC Notification Detection

    @Test("isJSONRPCNotification returns true for message without id")
    func notificationWithoutId() {
        let data = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        #expect(HTTPParser.isJSONRPCNotification(data) == true)
    }

    @Test("isJSONRPCNotification returns false for message with id")
    func requestWithId() {
        let data = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8)
        #expect(HTTPParser.isJSONRPCNotification(data) == false)
    }

    @Test("isJSONRPCNotification returns false for message with string id")
    func requestWithStringId() {
        let data = Data(#"{"jsonrpc":"2.0","id":"uuid-123","method":"test"}"#.utf8)
        #expect(HTTPParser.isJSONRPCNotification(data) == false)
    }

    @Test("isJSONRPCNotification returns false for invalid JSON")
    func invalidJson() {
        let data = Data("not json".utf8)
        #expect(HTTPParser.isJSONRPCNotification(data) == false)
    }

    @Test("isJSONRPCNotification returns false for non-object JSON")
    func nonObjectJson() {
        let data = Data("[1,2,3]".utf8)
        #expect(HTTPParser.isJSONRPCNotification(data) == false)
    }

    @Test("isJSONRPCNotification returns false for message with null id")
    func nullId() {
        let data = Data(#"{"jsonrpc":"2.0","id":null,"method":"test"}"#.utf8)
        // null id means json["id"] is NSNull, not nil — so it's NOT a notification
        let result = HTTPParser.isJSONRPCNotification(data)
        // json["id"] == nil checks if key is absent. NSNull is not nil.
        #expect(result == false)
    }

    @Test("isJSONRPCNotification returns true for empty object")
    func emptyObject() {
        let data = Data("{}".utf8)
        // No "id" key → notification
        #expect(HTTPParser.isJSONRPCNotification(data) == true)
    }

    @Test("routeRequest returns JSON-RPC parse error for invalid JSON body")
    func routeRequestInvalidJSONBody() async throws {
        let server = HTTPServer(port: 13339)
        let request = HTTPRequest(
            method: "POST",
            path: "/mcp",
            headers: ["content-type": "application/json"],
            body: Data("{".utf8),
            clientIP: nil
        )

        let response = await server.routeRequest(request)
        let json = try #require(try JSONSerialization.jsonObject(with: response.body ?? Data()) as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])

        #expect(response.statusCode == 200)
        #expect((json["id"] is NSNull) == true)
        #expect(error["code"] as? Int == ErrorCodes.parseError)
    }

    @Test("routeRequest returns JSON-RPC invalidRequest for unsupported id type")
    func routeRequestInvalidIDType() async throws {
        let server = HTTPServer(port: 13339)
        let request = HTTPRequest(
            method: "POST",
            path: "/mcp",
            headers: ["content-type": "application/json"],
            body: Data(#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#.utf8),
            clientIP: nil
        )

        let response = await server.routeRequest(request)
        let json = try #require(try JSONSerialization.jsonObject(with: response.body ?? Data()) as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])

        #expect(response.statusCode == 200)
        #expect((json["id"] is NSNull) == true)
        #expect(error["code"] as? Int == ErrorCodes.invalidRequest)
    }

    @Test("routeRequest returns JSON-RPC internalError when factory is missing")
    func routeRequestMissingFactory() async throws {
        let server = HTTPServer(port: 13339)
        let request = HTTPRequest(
            method: "POST",
            path: "/mcp",
            headers: ["content-type": "application/json"],
            body: Data(#"{"jsonrpc":"2.0","id":"build","method":"tools/call"}"#.utf8),
            clientIP: nil
        )

        let response = await server.routeRequest(request)
        let json = try #require(try JSONSerialization.jsonObject(with: response.body ?? Data()) as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])

        #expect(response.statusCode == 200)
        #expect(json["id"] as? String == "build")
        #expect(error["code"] as? Int == ErrorCodes.internalError)
    }
}
