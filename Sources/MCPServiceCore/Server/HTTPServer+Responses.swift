import Foundation

extension HTTPServer {
    func closeBrokenSessionIfNeeded(
        _ error: BridgeError,
        sessionId: String
    ) async {
        guard shouldRecycleSession(after: error) else {
            return
        }
        await sessionManager.closeSession(id: sessionId)
    }

    func shouldRecycleSession(after error: BridgeError) -> Bool {
        if case .internalError = error {
            return true
        }
        return false
    }

    func handleDelete(_ request: HTTPRequest) async -> HTTPResponse {
        guard let sessionId = request.headers["mcp-session-id"] else {
            return makeJSONResponse(
                statusCode: 400,
                statusText: "Bad Request",
                body: #"{"error":"missing Mcp-Session-Id header"}"#
            )
        }

        guard await sessionManager.getSession(id: sessionId) != nil else {
            return makeJSONResponse(
                statusCode: 404,
                statusText: "Not Found",
                body: #"{"error":"session not found"}"#
            )
        }

        await sessionManager.closeSession(id: sessionId)
        return makeJSONResponse(
            statusCode: 200,
            statusText: "OK",
            body: #"{"status":"session closed"}"#
        )
    }

    func makeProtocolErrorResponse(
        requestID: JSONRPCID?,
        sessionId: String?,
        bridgeError: BridgeError,
        fallback: HTTPResponse
    ) -> HTTPResponse {
        guard let requestID else {
            return fallback
        }

        do {
            let body = try JSONRPCMessage.makeErrorResponse(
                id: requestID,
                error: bridgeError.toJSONRPCError()
            )
            return HTTPResponse(
                statusCode: 200,
                statusText: "OK",
                headers: makeJSONHeaders(sessionId: sessionId),
                body: body
            )
        } catch {
            logger.error("Failed to serialize JSON-RPC error response", metadata: [
                "error": "\(error)"
            ])
            return fallback
        }
    }

    func makeMethodNotAllowedResponse(body: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: 405,
            statusText: "Method Not Allowed",
            headers: [
                "Content-Type": "application/json",
                "Allow": "POST, DELETE",
            ],
            body: Data(body.utf8)
        )
    }

    func makeJSONResponse(
        statusCode: Int,
        statusText: String,
        body: String,
        sessionId: String? = nil
    ) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            statusText: statusText,
            headers: makeJSONHeaders(sessionId: sessionId),
            body: Data(body.utf8)
        )
    }

    func makeAcceptedResponse(sessionId: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: 202,
            statusText: "Accepted",
            headers: makeJSONHeaders(sessionId: sessionId),
            body: nil
        )
    }

    func makeJSONHeaders(sessionId: String?) -> [String: String] {
        var headers = ["Content-Type": "application/json"]
        if let sessionId {
            headers["Mcp-Session-Id"] = sessionId
        }
        return headers
    }
}
