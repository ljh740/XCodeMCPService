import Foundation
import MCP
import Testing
@testable import MCPServiceCore

@Suite("PipeTransport Tests")
struct PipeTransportTests {

    @Test("send returns transport error after peer closes pipe")
    func sendReturnsTransportErrorAfterPeerClosed() async throws {
        let readPipe = Pipe()
        let writePipe = Pipe()
        try writePipe.fileHandleForReading.close()

        let transport = PipeTransport(
            readHandle: readPipe.fileHandleForReading,
            writeHandle: writePipe.fileHandleForWriting
        )
        await #expect(throws: Never.self) {
            try await transport.connect()
        }

        let payload = Data(#"{"jsonrpc":"2.0","id":"1","method":"ping"}"#.utf8)

        await #expect(throws: MCPError.self) {
            try await transport.send(payload)
        }

        await transport.disconnect()
        try? readPipe.fileHandleForReading.close()
        try? readPipe.fileHandleForWriting.close()
        try? writePipe.fileHandleForWriting.close()
    }
}
