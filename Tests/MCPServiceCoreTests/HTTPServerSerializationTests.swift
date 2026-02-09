import Foundation
import Testing
@testable import MCPServiceCore

@Suite("HTTP Serialization Tests")
struct HTTPServerSerializationTests {

    @Test("Serialize 200 OK with JSON body")
    func serialize200WithBody() {
        let body = Data(#"{"result":"ok"}"#.utf8)
        let response = HTTPResponse(
            statusCode: 200,
            statusText: "OK",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        let data = HTTPParser.serializeHTTPResponse(response)
        let str = String(data: data, encoding: .utf8)!
        #expect(str.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(str.contains("Content-Length: \(body.count)"))
        #expect(str.contains("Connection: close"))
        #expect(str.contains("Content-Type: application/json"))
        #expect(str.hasSuffix(#"{"result":"ok"}"#))
    }

    @Test("Serialize 404 with body")
    func serialize404() {
        let body = Data(#"{"error":"not found"}"#.utf8)
        let response = HTTPResponse(
            statusCode: 404,
            statusText: "Not Found",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        let data = HTTPParser.serializeHTTPResponse(response)
        let str = String(data: data, encoding: .utf8)!
        #expect(str.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
    }

    @Test("Serialize 202 with nil body has Content-Length 0")
    func serialize202NilBody() {
        let response = HTTPResponse(
            statusCode: 202,
            statusText: "Accepted",
            headers: ["Content-Type": "application/json"],
            body: nil
        )
        let data = HTTPParser.serializeHTTPResponse(response)
        let str = String(data: data, encoding: .utf8)!
        #expect(str.contains("Content-Length: 0"))
    }

    @Test("Headers are sorted alphabetically")
    func headersSorted() {
        let response = HTTPResponse(
            statusCode: 200,
            statusText: "OK",
            headers: ["Z-Header": "z", "A-Header": "a", "Content-Type": "text/plain"],
            body: nil
        )
        let data = HTTPParser.serializeHTTPResponse(response)
        let str = String(data: data, encoding: .utf8)!
        let lines = str.split(separator: "\r\n")
        // Find header lines (skip status line, stop at empty line)
        let headerLines = lines.dropFirst().prefix(while: { !$0.isEmpty })
        let headerKeys = headerLines.map { String($0.split(separator: ":")[0]) }
        #expect(headerKeys == headerKeys.sorted())
    }

    @Test("Connection: close always present")
    func connectionClosePresent() {
        let response = HTTPResponse(
            statusCode: 200,
            statusText: "OK",
            headers: [:],
            body: nil
        )
        let data = HTTPParser.serializeHTTPResponse(response)
        let str = String(data: data, encoding: .utf8)!
        #expect(str.contains("Connection: close"))
    }
}
