// MARK: - JSON-RPC Error Codes

/// JSON-RPC 标准错误码，对应 TypeScript 版 ErrorCodes
enum ErrorCodes {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    static let serverNotFound = -32002
    static let timeout = -32001
    static let bridgeError = -32000
    static let healthCheckFailed = -32003
}

// MARK: - BridgeError

/// MCP Forward 桥接服务错误类型
public enum BridgeError: Error, Sendable {
    case parseError(String)
    case invalidRequest(String)
    case methodNotFound(String)
    case invalidParams(String)
    case internalError(String)
    case serverNotFound(String)
    case timeout(String, timeoutMs: Int)
    case configError(String)
    case routeError(String, resourceType: String, resourceName: String)
    case healthCheckFailed(String, serverName: String)

    public var code: Int {
        switch self {
        case .parseError: ErrorCodes.parseError
        case .invalidRequest: ErrorCodes.invalidRequest
        case .methodNotFound: ErrorCodes.methodNotFound
        case .invalidParams: ErrorCodes.invalidParams
        case .internalError: ErrorCodes.internalError
        case .serverNotFound: ErrorCodes.serverNotFound
        case .timeout: ErrorCodes.timeout
        case .configError: ErrorCodes.bridgeError
        case .routeError: ErrorCodes.methodNotFound
        case .healthCheckFailed: ErrorCodes.healthCheckFailed
        }
    }

    public var message: String {
        switch self {
        case .parseError(let msg),
             .invalidRequest(let msg),
             .methodNotFound(let msg),
             .invalidParams(let msg),
             .internalError(let msg),
             .serverNotFound(let msg),
             .configError(let msg):
            return msg
        case .timeout(let msg, _):
            return msg
        case .routeError(let msg, _, _):
            return msg
        case .healthCheckFailed(let msg, _):
            return msg
        }
    }

    public func toJSONRPCError() -> JSONRPCError {
        var data: [String: String]?
        switch self {
        case .timeout(_, let timeoutMs):
            data = ["timeoutMs": String(timeoutMs)]
        case .routeError(_, let resourceType, let resourceName):
            data = ["resourceType": resourceType, "resourceName": resourceName]
        case .healthCheckFailed(_, let serverName):
            data = ["serverName": serverName]
        default:
            break
        }
        return JSONRPCError(code: code, message: message, data: data)
    }
}

// MARK: - JSONRPCError

/// JSON-RPC 错误响应结构
public struct JSONRPCError: Codable, Sendable {
    public let code: Int
    public let message: String
    public let data: [String: String]?

    public init(code: Int, message: String, data: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

// MARK: - RouteResult

/// 路由操作结果，携带成功数据或错误信息
public struct RouteResult<T: Sendable>: Sendable {
    public let success: Bool
    public let data: T?
    public let error: JSONRPCError?

    public static func success(_ data: T) -> RouteResult<T> {
        RouteResult(success: true, data: data, error: nil)
    }

    public static func failure(code: Int, message: String) -> RouteResult<T> {
        RouteResult(success: false, data: nil, error: JSONRPCError(code: code, message: message))
    }
}
