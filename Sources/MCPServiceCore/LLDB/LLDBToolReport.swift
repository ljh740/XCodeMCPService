import Foundation

struct LLDBSupportContext: Sendable {
    let reason: String
    let message: String
    let xcodeVersion: String?
    let xcodeBuild: String?
    let xcodePath: String?

    static func runtime(
        _ runtime: XcodeRuntime,
        reason: String,
        message: String? = nil
    ) -> LLDBSupportContext {
        LLDBSupportContext(
            reason: reason,
            message: message ?? "LLDB MCP is unavailable for Xcode \(runtime.version).",
            xcodeVersion: runtime.version,
            xcodeBuild: runtime.buildVersion,
            xcodePath: runtime.applicationURL.path
        )
    }
}

struct LLDBToolReport: Encodable, Sendable {
    let action: String
    let supported: Bool
    let generation: Int
    let reason: String?
    let message: String
    let xcodeVersion: String?
    let xcodeBuild: String?
    let xcodePath: String?
    let quarantinedRegistryEntries: [String]
    let ownedSessions: [String]
    let ownedSessionCount: Int
    let destroyedOwnedSessionCount: Int
    let sessions: [String]

    func toolResult(isError: Bool = false) -> ToolCallResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let text: String
        if let data = try? encoder.encode(self) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = message
        }
        return ToolCallResult(
            content: [LLDBToolCatalog.textContent(text)],
            isError: isError
        )
    }
}
