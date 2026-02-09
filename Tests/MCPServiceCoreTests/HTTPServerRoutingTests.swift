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
}
