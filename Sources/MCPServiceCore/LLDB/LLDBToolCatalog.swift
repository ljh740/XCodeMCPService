import Foundation
import MCP

enum LLDBToolCatalog {
    static let refreshToolName = "lldb_refresh_sessions"
    static let toolPrefix = "lldb__"
    static let resourcePrefix = "lldb__"

    static func advertisedTools() -> [Tool] {
        [
            Tool(
                name: refreshToolName,
                title: "Refresh LLDB Sessions",
                description: """
                Re-detect the active Xcode, recover confirmed stale LLDB registry entries, and reconnect lldb-mcp so newly started Xcode debug sessions become visible. Call this before concluding that an expected debugger session is unavailable. Xcode 27 or newer is required; older Xcode versions return an explicit unsupported result. The default is safe and refuses to restart while this MCP connection owns active LLDB sessions. Set force=true only when destroying those sessions is acceptable.
                """,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "force": [
                            "type": "boolean",
                            "description": "Destroy LLDB sessions created by this MCP connection before reconnecting.",
                            "default": false,
                        ]
                    ],
                    "additionalProperties": false,
                ],
                annotations: .init(
                    title: "Refresh LLDB Sessions",
                    readOnlyHint: false,
                    destructiveHint: true,
                    idempotentHint: true,
                    openWorldHint: false
                )
            ),
            Tool(
                name: exposedToolName("session_create"),
                title: "Create LLDB Session",
                description: "Create a standalone LLDB debug session when the selected lldb-mcp exposes session_create. Early Xcode 27 beta builds only support attached debugger sessions and return an explicit capability-unavailable result.",
                inputSchema: emptyObjectSchema,
                annotations: .init(
                    title: "Create LLDB Session",
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: false,
                    openWorldHint: false
                )
            ),
            Tool(
                name: exposedToolName("command"),
                title: "Run LLDB Command",
                description: "Run an LLDB command in a reachable debug session. Requires Xcode 27 or newer. If an expected Xcode session is missing, call lldb_refresh_sessions first.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "command": [
                            "type": "string",
                            "description": "The LLDB command to execute."
                        ],
                        "debugger": [
                            "type": "string",
                            "description": "Optional lldb-mcp debugger session URI."
                        ],
                    ],
                    "required": ["command"],
                    "additionalProperties": false,
                ],
                annotations: .init(
                    title: "Run LLDB Command",
                    readOnlyHint: false,
                    destructiveHint: true,
                    idempotentHint: false,
                    openWorldHint: false
                )
            ),
            Tool(
                name: exposedToolName("sessions_list"),
                title: "List LLDB Sessions",
                description: "List every LLDB debug session currently reachable from this MCP connection. The service maps the early Xcode 27 beta debugger_list tool and the newer sessions_list tool to this stable interface, and automatically reconnects when the Xcode or LLDB registry changes and doing so is safe.",
                inputSchema: emptyObjectSchema,
                annotations: .init(
                    title: "List LLDB Sessions",
                    readOnlyHint: true,
                    destructiveHint: false,
                    idempotentHint: true,
                    openWorldHint: false
                )
            ),
            Tool(
                name: exposedToolName("session_close"),
                title: "Close LLDB Session",
                description: "Close a standalone LLDB session created by this MCP connection when the selected lldb-mcp exposes session_close. Interactive Xcode/LLDB sessions and early Xcode 27 beta builds cannot be closed this way.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "session": [
                            "type": "string",
                            "description": "The lldb-mcp session URI returned by session_create."
                        ]
                    ],
                    "required": ["session"],
                    "additionalProperties": false,
                ],
                annotations: .init(
                    title: "Close LLDB Session",
                    readOnlyHint: false,
                    destructiveHint: true,
                    idempotentHint: false,
                    openWorldHint: false
                )
            ),
        ]
    }

    static func exposedToolName(_ downstreamName: String) -> String {
        toolPrefix + downstreamName
    }

    static func stableDownstreamName(from exposedName: String) -> String? {
        guard exposedName.hasPrefix(toolPrefix) else { return nil }
        let downstreamName = String(exposedName.dropFirst(toolPrefix.count))
        return downstreamName.isEmpty ? nil : downstreamName
    }

    static func actualDownstreamName(
        for stableName: String,
        availableToolNames: Set<String>
    ) -> String? {
        if availableToolNames.contains(stableName) {
            return stableName
        }
        if stableName == "sessions_list", availableToolNames.contains("debugger_list") {
            return "debugger_list"
        }
        return nil
    }

    static func sessionURIs(from content: [Tool.Content]) -> [String] {
        let pattern = #"lldb-mcp://(?:instance/[0-9]+/)?debugger/[0-9]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        var uris: Set<String> = []

        for item in content {
            guard case .text(let text, _, _) = item else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in expression.matches(in: text, range: range) {
                guard let matchRange = Range(match.range, in: text) else { continue }
                uris.insert(String(text[matchRange]))
            }
        }
        return uris.sorted()
    }

    static func textContent(_ text: String) -> Tool.Content {
        .text(text: text, annotations: nil, _meta: nil)
    }

    private static let emptyObjectSchema: Value = [
        "type": "object",
        "properties": [:],
        "additionalProperties": false,
    ]
}
