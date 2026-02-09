import Foundation
import Network

// MARK: - TCPConnectionHelper

/// TCP 连接数据读写辅助工具
enum TCPConnectionHelper {

    /// 从连接读取完整的 HTTP 请求数据
    static func receiveAllData(on connection: NWConnection) async throws -> Data {
        // 先读取 header 部分（最多 8KB）
        let headerData = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(
                minimumIncompleteLength: 1, maximumLength: 8192
            ) { content, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(
                        throwing: BridgeError.internalError("No data received"))
                }
            }
        }

        // 检查是否有 Content-Length，需要读取更多 body 数据
        guard let headerString = String(data: headerData, encoding: .utf8),
            let headerEndRange = headerString.range(of: "\r\n\r\n")
        else {
            return headerData
        }

        let headerPart = String(headerString[..<headerEndRange.lowerBound])
        let headerEndUTF8 = headerString[..<headerEndRange.upperBound].utf8.count
        let receivedBodyLength = headerData.count - headerEndUTF8

        // 解析 Content-Length
        guard let contentLength = HTTPParser.parseContentLength(from: headerPart),
            contentLength > 0
        else {
            return headerData
        }

        let remaining = contentLength - receivedBodyLength
        guard remaining > 0 else {
            return headerData
        }

        // 读取剩余 body
        let additionalData = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(
                minimumIncompleteLength: remaining, maximumLength: remaining
            ) { content, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(
                        throwing: BridgeError.internalError("Incomplete body"))
                }
            }
        }

        return headerData + additionalData
    }

    /// 发送数据到连接
    static func sendData(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data, completion: .contentProcessed({ error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }))
        }
    }
}
