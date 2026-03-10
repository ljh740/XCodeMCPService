import Foundation
import MCP
import Testing
@testable import MCPServiceCore

@Suite("Transport Disconnect Error Tests")
struct TransportDisconnectErrorTests {

    @Test("connectionClosed is treated as disconnect")
    func connectionClosed() {
        #expect(isDisconnectLikeError(MCPError.connectionClosed))
    }

    @Test("broken pipe transport error is treated as disconnect")
    func brokenPipe() {
        let error = MCPError.transportError(
            NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE))
        )
        #expect(isDisconnectLikeError(error))
    }

    @Test("timeout is not treated as disconnect")
    func timeoutIsNotDisconnect() {
        let error = AsyncTimeoutError(timeoutMs: 1000)
        #expect(isDisconnectLikeError(error) == false)
    }
}
