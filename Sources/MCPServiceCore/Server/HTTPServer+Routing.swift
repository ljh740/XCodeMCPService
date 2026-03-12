import Foundation

private struct HTTPServerRequestContext {
    let body: Data
    let requestID: JSONRPCID?
    let isNotification: Bool
}

private enum HTTPServerRoutingResult<Success> {
    case success(Success)
    case failure(HTTPResponse)
}

extension HTTPServer {
    func routeRequest(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.path == endpoint || request.path.hasPrefix(endpoint + "?") else {
            return makeJSONResponse(
                statusCode: 404,
                statusText: "Not Found",
                body: #"{"error":"not found"}"#
            )
        }

        switch request.method {
        case "POST":
            return await handlePost(request)
        case "DELETE":
            return await handleDelete(request)
        case "GET":
            return makeMethodNotAllowedResponse(
                body: #"{"error":"GET not supported, SSE not implemented"}"#
            )
        default:
            return makeMethodNotAllowedResponse(body: #"{"error":"method not allowed"}"#)
        }
    }

    private func handlePost(_ request: HTTPRequest) async -> HTTPResponse {
        let requestContext: HTTPServerRequestContext
        switch classifyPostRequest(request) {
        case .success(let context):
            requestContext = context
        case .failure(let response):
            return response
        }

        let (sessionId, session): (String, SessionInfo)
        switch await resolveSession(for: requestContext.requestID, headers: request.headers) {
        case .success(let resolved):
            sessionId = resolved.sessionId
            session = resolved.session
        case .failure(let response):
            return response
        }

        if let sendFailure = await sendRequestBody(
            requestContext.body,
            sessionId: sessionId,
            session: session,
            requestID: requestContext.requestID
        ) {
            return sendFailure
        }

        if requestContext.isNotification {
            return makeAcceptedResponse(sessionId: sessionId)
        }

        return await awaitResponse(
            sessionId: sessionId,
            session: session,
            requestID: requestContext.requestID
        )
    }

    private func classifyPostRequest(
        _ request: HTTPRequest
    ) -> HTTPServerRoutingResult<HTTPServerRequestContext> {
        guard let body = request.body, !body.isEmpty else {
            return .failure(makeJSONResponse(
                statusCode: 400,
                statusText: "Bad Request",
                body: #"{"error":"empty request body"}"#
            ))
        }

        switch JSONRPCMessage.classifyRequest(body) {
        case .notification:
            return .success(HTTPServerRequestContext(body: body, requestID: nil, isNotification: true))
        case .request(let requestID):
            return .success(
                HTTPServerRequestContext(body: body, requestID: requestID, isNotification: false)
            )
        case .invalid(let error, let responseID):
            return .failure(makeProtocolErrorResponse(
                requestID: responseID,
                sessionId: nil,
                bridgeError: error,
                fallback: makeJSONResponse(
                    statusCode: 400,
                    statusText: "Bad Request",
                    body: #"{"error":"invalid JSON-RPC request"}"#
                )
            ))
        }
    }

    private func resolveSession(
        for requestID: JSONRPCID?,
        headers: [String: String]
    ) async -> HTTPServerRoutingResult<(sessionId: String, session: SessionInfo)> {
        if let existingId = headers["mcp-session-id"],
            let existingSession = await sessionManager.getSession(id: existingId)
        {
            return .success((existingId, existingSession))
        }

        guard let factory = mcpServerFactory else {
            return .failure(makeProtocolErrorResponse(
                requestID: requestID,
                sessionId: nil,
                bridgeError: .internalError("mcpServerFactory not set"),
                fallback: makeJSONResponse(
                    statusCode: 500,
                    statusText: "Internal Server Error",
                    body: #"{"error":"mcpServerFactory not set"}"#
                )
            ))
        }

        do {
            return .success(try await sessionManager.createSession(factory: factory))
        } catch {
            logger.error("Failed to create session", metadata: ["error": "\(error)"])
            return .failure(makeProtocolErrorResponse(
                requestID: requestID,
                sessionId: nil,
                bridgeError: .internalError("Failed to create session: \(error.localizedDescription)"),
                fallback: makeJSONResponse(
                    statusCode: 500,
                    statusText: "Internal Server Error",
                    body: #"{"error":"failed to create session"}"#
                )
            ))
        }
    }

    private func sendRequestBody(
        _ body: Data,
        sessionId: String,
        session: SessionInfo,
        requestID: JSONRPCID?
    ) async -> HTTPResponse? {
        do {
            try await session.clientTransport.send(body)
            return nil
        } catch {
            logger.error("Failed to send to MCP server", metadata: [
                "sessionId": sessionId,
                "error": "\(error)",
            ])
            let bridgeError = BridgeError.internalError("Failed to send to MCP server")
            await closeBrokenSessionIfNeeded(bridgeError, sessionId: sessionId)
            return makeProtocolErrorResponse(
                requestID: requestID,
                sessionId: sessionId,
                bridgeError: bridgeError,
                fallback: makeJSONResponse(
                    statusCode: 502,
                    statusText: "Bad Gateway",
                    body: #"{"error":"failed to send to MCP server"}"#,
                    sessionId: sessionId
                )
            )
        }
    }

    private func awaitResponse(
        sessionId: String,
        session: SessionInfo,
        requestID: JSONRPCID?
    ) async -> HTTPResponse {
        guard let requestID else {
            return makeProtocolErrorResponse(
                requestID: .null,
                sessionId: sessionId,
                bridgeError: .invalidRequest("Missing JSON-RPC request id"),
                fallback: makeJSONResponse(
                    statusCode: 400,
                    statusText: "Bad Request",
                    body: #"{"error":"missing JSON-RPC request id"}"#,
                    sessionId: sessionId
                )
            )
        }

        do {
            let responseData = try await session.responseQueue.waitForResponse(
                id: requestID,
                timeoutMs: responseTimeoutMs
            )
            return HTTPResponse(
                statusCode: 200,
                statusText: "OK",
                headers: makeJSONHeaders(sessionId: sessionId),
                body: responseData
            )
        } catch {
            logger.error("Timeout or error waiting for MCP response", metadata: [
                "sessionId": sessionId,
                "error": "\(error)",
            ])
            let bridgeError = (error as? BridgeError)
                ?? .internalError("Failed while waiting for MCP response: \(error)")
            await closeBrokenSessionIfNeeded(bridgeError, sessionId: sessionId)
            return makeProtocolErrorResponse(
                requestID: requestID,
                sessionId: sessionId,
                bridgeError: bridgeError,
                fallback: makeJSONResponse(
                    statusCode: 504,
                    statusText: "Gateway Timeout",
                    body: #"{"error":"MCP server response timeout"}"#,
                    sessionId: sessionId
                )
            )
        }
    }

}
