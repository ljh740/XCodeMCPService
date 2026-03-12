import Foundation
import Testing
@testable import MCPServiceCore

@Suite("JSONRPC Message Tests")
struct JSONRPCMessageTests {

    @Test("classifyRequest returns parse error with null id for invalid JSON")
    func classifyInvalidJSON() {
        let data = Data("{".utf8)

        switch JSONRPCMessage.classifyRequest(data) {
        case .invalid(let error, let responseID):
            #expect(error.code == ErrorCodes.parseError)
            #expect(responseID == .null)
        default:
            Issue.record("Expected invalid JSON-RPC classification")
        }
    }

    @Test("makeErrorResponse preserves floating-point numeric id")
    func floatingPointIDIsPreserved() throws {
        let body = try JSONRPCMessage.makeErrorResponse(
            id: .floating(1.5),
            error: JSONRPCError(code: ErrorCodes.invalidRequest, message: "invalid")
        )
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let id = try #require(json["id"] as? NSNumber)

        #expect(id.doubleValue == 1.5)
        #expect((json["id"] as? String) == nil)
    }
}
