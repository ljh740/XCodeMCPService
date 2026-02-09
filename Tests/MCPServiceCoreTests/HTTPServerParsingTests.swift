import Foundation
import Testing
@testable import MCPServiceCore

@Suite("HTTP Parsing Tests")
struct HTTPServerParsingTests {

    private func makeHTTPRequest(_ raw: String) -> Data {
        Data(raw.utf8)
    }

    @Test("Parse valid GET request")
    func parseValidGet() throws {
        let raw = "GET /mcp HTTP/1.1\r\nHost: localhost\r\nAccept: */*\r\n\r\n"
        let request = try HTTPParser.parseHTTPRequest(Data(raw.utf8))
        #expect(request.method == "GET")
        #expect(request.path == "/mcp")
        #expect(request.headers["host"] == "localhost")
        #expect(request.headers["accept"] == "*/*")
        #expect(request.body == nil || request.body?.isEmpty == true)
    }

    @Test("Parse valid POST with body")
    func parseValidPost() throws {
        let body = #"{"jsonrpc":"2.0","method":"test","id":1}"#
        let raw = "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let request = try HTTPParser.parseHTTPRequest(Data(raw.utf8))
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
        #expect(request.headers["content-type"] == "application/json")
        #expect(request.body != nil)
        let bodyStr = String(data: request.body!, encoding: .utf8)
        #expect(bodyStr == body)
    }

    @Test("Parse request with missing CRLFCRLF throws")
    func parseMissingCRLFCRLF() {
        let raw = "GET /mcp HTTP/1.1\r\nHost: localhost"
        #expect(throws: (any Error).self) {
            try HTTPParser.parseHTTPRequest(Data(raw.utf8))
        }
    }

    @Test("Parse empty data throws")
    func parseEmptyData() {
        #expect(throws: (any Error).self) {
            try HTTPParser.parseHTTPRequest(Data())
        }
    }

    @Test("Parse request with multiple headers")
    func parseMultipleHeaders() throws {
        let raw = "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nX-Custom: value\r\nAuthorization: Bearer token\r\n\r\n{}"
        let request = try HTTPParser.parseHTTPRequest(Data(raw.utf8))
        #expect(request.headers["host"] == "localhost")
        #expect(request.headers["content-type"] == "application/json")
        #expect(request.headers["x-custom"] == "value")
        #expect(request.headers["authorization"] == "Bearer token")
    }

    @Test("parseContentLength with present header")
    func contentLengthPresent() {
        let header = "Host: localhost\r\nContent-Length: 42"
        #expect(HTTPParser.parseContentLength(from: header) == 42)
    }

    @Test("parseContentLength with absent header")
    func contentLengthAbsent() {
        let header = "Host: localhost\r\nAccept: */*"
        #expect(HTTPParser.parseContentLength(from: header) == nil)
    }

    @Test("parseContentLength with malformed value")
    func contentLengthMalformed() {
        let header = "Host: localhost\r\nContent-Length: abc"
        #expect(HTTPParser.parseContentLength(from: header) == nil)
    }
}
