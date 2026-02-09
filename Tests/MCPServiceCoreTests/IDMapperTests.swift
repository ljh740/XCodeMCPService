import Foundation
import Testing
@testable import MCPServiceCore

@Suite("IDMapper Tests")
struct IDMapperTests {

    private func makeJSON(id: Any, method: String = "test") -> Data {
        if let strId = id as? String {
            return Data(#"{"jsonrpc":"2.0","id":"\#(strId)","method":"\#(method)"}"#.utf8)
        } else {
            return Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)"}"#.utf8)
        }
    }

    @Test("Basic round-trip: string id → int id → string id restored")
    func basicRoundTrip() {
        let mapper = IDMapper()
        let outgoing = makeJSON(id: "uuid-123")
        let rewritten = mapper.rewriteOutgoing(outgoing)

        // Should have integer id now
        let json = try! JSONSerialization.jsonObject(with: rewritten) as! [String: Any]
        let intId = json["id"] as! Int
        #expect(intId == 1)

        // Simulate response with same int id
        let incoming = makeJSON(id: intId)
        let restored = mapper.rewriteIncoming(incoming)
        let restoredJson = try! JSONSerialization.jsonObject(with: restored) as! [String: Any]
        #expect(restoredJson["id"] as? String == "uuid-123")
    }

    @Test("Notification (no id) passes through unchanged")
    func notificationPassthrough() {
        let mapper = IDMapper()
        let data = Data(#"{"jsonrpc":"2.0","method":"notify"}"#.utf8)
        let result = mapper.rewriteOutgoing(data)
        #expect(result == data)
    }

    @Test("Integer id passes through unchanged")
    func integerIdPassthrough() {
        let mapper = IDMapper()
        let data = makeJSON(id: 42)
        let result = mapper.rewriteOutgoing(data)
        // Should not rewrite - id is already integer
        let json = try! JSONSerialization.jsonObject(with: result) as! [String: Any]
        #expect(json["id"] as? Int == 42)
    }

    @Test("Eviction triggers when exceeding maxSize")
    func evictionOnMaxSize() {
        let mapper = IDMapper()
        // Insert more than maxSize entries (10000)
        for i in 1...10_001 {
            let data = makeJSON(id: "id-\(i)")
            _ = mapper.rewriteOutgoing(data)
        }
        // After eviction, oldest 20% (2000) should be removed
        // Try to restore id-1 (should be evicted)
        let incoming1 = makeJSON(id: 1)
        let restored1 = mapper.rewriteIncoming(incoming1)
        let json1 = try! JSONSerialization.jsonObject(with: restored1) as! [String: Any]
        // Should NOT be restored (evicted) - id stays as integer
        #expect(json1["id"] as? Int == 1)

        // Try to restore id-10001 (should still exist)
        let incoming2 = makeJSON(id: 10_001)
        let restored2 = mapper.rewriteIncoming(incoming2)
        let json2 = try! JSONSerialization.jsonObject(with: restored2) as! [String: Any]
        #expect(json2["id"] as? String == "id-10001")
    }

    @Test("Unknown int id in incoming returns original data")
    func unknownIdPassthrough() {
        let mapper = IDMapper()
        let data = makeJSON(id: 999)
        let result = mapper.rewriteIncoming(data)
        let json = try! JSONSerialization.jsonObject(with: result) as! [String: Any]
        #expect(json["id"] as? Int == 999)
    }

    @Test("Counter increments correctly across multiple calls")
    func counterIncrement() {
        let mapper = IDMapper()
        for i in 1...5 {
            let data = makeJSON(id: "req-\(i)")
            let rewritten = mapper.rewriteOutgoing(data)
            let json = try! JSONSerialization.jsonObject(with: rewritten) as! [String: Any]
            #expect(json["id"] as? Int == i)
        }
    }
}
