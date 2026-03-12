import Foundation

enum JSONRPCID: Hashable, Sendable {
    case string(String)
    case integer(Int)
    case floating(Double)
    case null

    init?(jsonValue: Any) {
        switch jsonValue {
        case let string as String:
            self = .string(string)
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return nil
            }
            let doubleValue = number.doubleValue
            if doubleValue.rounded(.towardZero) == doubleValue,
                doubleValue >= Double(Int.min),
                doubleValue <= Double(Int.max)
            {
                self = .integer(number.intValue)
            } else {
                self = .floating(doubleValue)
            }
        default:
            return nil
        }
    }

    var jsonValue: Any {
        switch self {
        case .string(let value):
            value
        case .integer(let value):
            value
        case .floating(let value):
            value
        case .null:
            NSNull()
        }
    }

    var logValue: String {
        switch self {
        case .string(let value):
            "\"\(value)\""
        case .integer(let value):
            String(value)
        case .floating(let value):
            String(value)
        case .null:
            "null"
        }
    }
}

enum JSONRPCMessage {
    enum ClassifiedRequest {
        case notification
        case request(JSONRPCID)
        case invalid(BridgeError, responseID: JSONRPCID?)
    }

    static func jsonObject(from data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func classifyRequest(_ data: Data) -> ClassifiedRequest {
        let rawObject: Any
        do {
            rawObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .invalid(.parseError("Invalid JSON-RPC payload"), responseID: .null)
        }

        guard let json = rawObject as? [String: Any] else {
            return .invalid(.invalidRequest("JSON-RPC payload must be an object"), responseID: .null)
        }

        guard let rawID = json["id"] else {
            return .notification
        }

        guard let requestID = JSONRPCID(jsonValue: rawID) else {
            return .invalid(.invalidRequest("Invalid JSON-RPC request id"), responseID: .null)
        }

        return .request(requestID)
    }

    static func id(from data: Data) -> JSONRPCID? {
        guard let json = jsonObject(from: data), let rawID = json["id"] else {
            return nil
        }
        return JSONRPCID(jsonValue: rawID)
    }

    static func isNotification(_ data: Data) -> Bool {
        switch classifyRequest(data) {
        case .notification:
            return true
        default:
            return false
        }
    }

    static func makeErrorResponse(
        id: JSONRPCID,
        error: JSONRPCError
    ) throws -> Data {
        var errorObject: [String: Any] = [
            "code": error.code,
            "message": error.message,
        ]
        if let data = error.data {
            errorObject["data"] = data
        }
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "error": errorObject,
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }
}
