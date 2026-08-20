import MCP
import Testing
@testable import MCPServiceCore

private actor SessionCloseProbe {
    private var closeCount = 0

    func recordClose() {
        closeCount += 1
    }

    func count() -> Int {
        closeCount
    }
}

@Suite("Session Manager Tests")
struct SessionManagerTests {
    @Test("Closing an HTTP session releases its session-scoped downstream resources")
    func closeRunsSessionCleanup() async throws {
        let manager = SessionManager()
        let probe = SessionCloseProbe()
        let (sessionID, _) = try await manager.createSession {
            McpServerSession(
                server: Server(name: "test", version: "1.0"),
                onClose: {
                    await probe.recordClose()
                }
            )
        }

        await manager.closeSession(id: sessionID)

        #expect(await probe.count() == 1)
        #expect(await manager.getSessionCount() == 0)
    }
}
