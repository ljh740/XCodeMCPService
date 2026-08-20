import Foundation
import Testing
@testable import MCPServiceCore

@Suite("Bridge Server Instructions Tests")
struct BridgeServerInstructionsTests {
    /// 客户端对 server instructions 的截断上限（Claude Code 为 2KB）。
    private static let instructionsByteBudget = 2048

    @Test("serverInstructions is non-empty")
    func instructionsNotEmpty() {
        #expect(BridgeServer.serverInstructions.isEmpty == false)
    }

    @Test("serverInstructions mentions every advertised LLDB tool")
    func instructionsCoverAdvertisedLLDBTools() {
        let instructions = BridgeServer.serverInstructions

        for tool in LLDBSessionController.advertisedTools() {
            #expect(
                instructions.contains(tool.name),
                "instructions 未提及 LLDB 工具 \(tool.name)，改名或新增工具后需同步文案"
            )
        }
    }

    @Test("serverInstructions stays within the client truncation budget")
    func instructionsWithinByteBudget() {
        let byteCount = BridgeServer.serverInstructions.utf8.count
        #expect(byteCount <= Self.instructionsByteBudget)
    }
}
