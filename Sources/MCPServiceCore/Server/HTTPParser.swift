import Foundation

// MARK: - HTTP Request / Response Models

/// 解析后的 HTTP 请求
struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?
    /// 客户端 IP 地址（从 NWConnection 提取）
    let clientIP: String?
}

/// HTTP 响应
struct HTTPResponse: Sendable {
    let statusCode: Int
    let statusText: String
    let headers: [String: String]
    let body: Data?
}

// MARK: - HTTPParser

/// HTTP 解析和序列化工具
struct HTTPParser {

    /// 解析原始 HTTP 请求
    static func parseHTTPRequest(_ data: Data) throws -> HTTPRequest {
        guard let raw = String(data: data, encoding: .utf8),
            let headerEndRange = raw.range(of: "\r\n\r\n")
        else {
            throw BridgeError.parseError("Invalid HTTP request: cannot parse headers")
        }

        let headerSection = String(raw[..<headerEndRange.lowerBound])
        let lines = headerSection.split(separator: "\r\n", omittingEmptySubsequences: false)

        guard let requestLine = lines.first else {
            throw BridgeError.parseError("Invalid HTTP request: missing request line")
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            throw BridgeError.parseError("Invalid HTTP request line: \(requestLine)")
        }

        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(
                    in: .whitespaces)
                headers[key.lowercased()] = value
            }
        }

        let headerEndUTF8Offset = raw[..<headerEndRange.upperBound].utf8.count
        let bodyStartIndex = data.index(data.startIndex, offsetBy: headerEndUTF8Offset)
        let body = bodyStartIndex < data.endIndex ? Data(data[bodyStartIndex...]) : nil

        return HTTPRequest(method: method, path: path, headers: headers, body: body, clientIP: nil)
    }

    /// 从 header 中解析 Content-Length
    static func parseContentLength(from headerPart: String) -> Int? {
        for line in headerPart.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(
                    in: .whitespaces)
                return Int(value)
            }
        }
        return nil
    }

    /// 序列化 HTTP 响应为原始数据
    static func serializeHTTPResponse(_ response: HTTPResponse) -> Data {
        var result = "HTTP/1.1 \(response.statusCode) \(response.statusText)\r\n"

        var headers = response.headers
        if let body = response.body {
            headers["Content-Length"] = String(body.count)
        } else {
            headers["Content-Length"] = "0"
        }
        headers["Connection"] = "close"

        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            result += "\(key): \(value)\r\n"
        }
        result += "\r\n"

        var data = Data(result.utf8)
        if let body = response.body {
            data.append(body)
        }
        return data
    }

    /// 检测 JSON-RPC 消息是否为 notification（没有 "id" 字段）
    static func isJSONRPCNotification(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["id"] == nil
    }
}
