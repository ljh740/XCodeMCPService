import Foundation
import MCP
import Testing
@testable import MCPServiceCore

@Suite("ResponseQueue Tests")
struct ResponseQueueTests {

    private func makeQueue() async throws -> (
        queue: ResponseQueue,
        clientTransport: InMemoryTransport,
        serverTransport: InMemoryTransport
    ) {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await clientTransport.connect()
        try await serverTransport.connect()

        let queue = ResponseQueue(logger: BridgeLogger(label: "test.response-queue"))
        await queue.start(transport: clientTransport)
        return (queue, clientTransport, serverTransport)
    }

    private func makeResponse(id: Any, value: String) throws -> Data {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": ["value": value],
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    @Test("Initial metrics are zero")
    func initialMetrics() async {
        let queue = ResponseQueue(logger: BridgeLogger(label: "test.response-queue"))
        let metrics = await queue.getMetrics()
        #expect(metrics.buffered == 0)
        #expect(metrics.dropped == 0)
    }

    @Test("Stop clears waiters and buffer")
    func stopClears() async {
        let queue = ResponseQueue(logger: BridgeLogger(label: "test.response-queue"))
        await queue.stop()
        let metrics = await queue.getMetrics()
        #expect(metrics.buffered == 0)
        #expect(metrics.dropped == 0)
    }

    @Test("Single response is matched by request id")
    func singleMessageRoundTrip() async throws {
        let (queue, _, serverTransport) = try await makeQueue()
        let testData = try makeResponse(id: 1, value: "ok")
        try await serverTransport.send(testData)

        let received = try await queue.waitForResponse(id: .integer(1), timeoutMs: 5_000)
        #expect(received == testData)

        await queue.stop()
    }

    @Test("Concurrent responses are matched by id even when arrival order is reversed")
    func outOfOrderResponsesMatchCorrectWaiters() async throws {
        let (queue, _, serverTransport) = try await makeQueue()
        let buildResponse = try makeResponse(id: "build", value: "build")
        let logResponse = try makeResponse(id: "log", value: "log")

        async let buildWait = queue.waitForResponse(id: .string("build"), timeoutMs: 5_000)
        async let logWait = queue.waitForResponse(id: .string("log"), timeoutMs: 5_000)

        try await Task.sleep(for: .milliseconds(50))
        try await serverTransport.send(logResponse)
        try await serverTransport.send(buildResponse)

        let receivedBuild = try await buildWait
        let receivedLog = try await logWait

        #expect(receivedBuild == buildResponse)
        #expect(receivedLog == logResponse)

        await queue.stop()
    }

    @Test("stop() causes pending waiters to throw error")
    func stopCancelsPendingWaiters() async throws {
        let (queue, _, _) = try await makeQueue()
        let waitTask = Task {
            try await queue.waitForResponse(id: .string("pending"), timeoutMs: 30_000)
        }

        try await Task.sleep(for: .milliseconds(50))
        await queue.stop()

        await #expect(throws: (any Error).self) {
            _ = try await waitTask.value
        }
    }

    @Test("Late response from timed-out request is dropped instead of poisoning next request")
    func lateTimedOutResponseIsDropped() async throws {
        let (queue, _, serverTransport) = try await makeQueue()
        let slowResponse = try makeResponse(id: "slow", value: "slow")
        let fastResponse = try makeResponse(id: "fast", value: "fast")

        await #expect(throws: BridgeError.self) {
            _ = try await queue.waitForResponse(id: .string("slow"), timeoutMs: 20)
        }

        try await serverTransport.send(slowResponse)
        async let fastWait = queue.waitForResponse(id: .string("fast"), timeoutMs: 1_000)
        try await Task.sleep(for: .milliseconds(20))
        try await serverTransport.send(fastResponse)

        let received = try await fastWait
        let metrics = await queue.getMetrics()

        #expect(received == fastResponse)
        #expect(metrics.buffered == 0)
        #expect(metrics.dropped >= 1)

        await queue.stop()
    }

    @Test("Timed-out request id cannot be reused within the same session")
    func timedOutRequestIDCannotBeReused() async throws {
        let (queue, _, _) = try await makeQueue()

        await #expect(throws: BridgeError.self) {
            _ = try await queue.waitForResponse(id: .string("stale"), timeoutMs: 20)
        }

        do {
            _ = try await queue.waitForResponse(id: .string("stale"), timeoutMs: 1_000)
            Issue.record("Expected invalid request error for reused timed-out id")
        } catch let error as BridgeError {
            #expect(error.code == ErrorCodes.invalidRequest)
        }

        await queue.stop()
    }

    @Test("Transport disconnection fails future waits immediately instead of timing out")
    func disconnectedTransportFailsImmediately() async throws {
        let (queue, _, serverTransport) = try await makeQueue()
        let pendingWait = Task {
            try await queue.waitForResponse(id: .string("first"), timeoutMs: 30_000)
        }

        try await Task.sleep(for: .milliseconds(20))
        await serverTransport.disconnect()

        do {
            _ = try await pendingWait.value
            Issue.record("Expected pending waiter to fail when transport disconnects")
        } catch let error as BridgeError {
            #expect(error.code == ErrorCodes.internalError)
        }

        do {
            _ = try await queue.waitForResponse(id: .string("second"), timeoutMs: 30_000)
            Issue.record("Expected future wait to fail immediately after transport disconnect")
        } catch let error as BridgeError {
            #expect(error.code == ErrorCodes.internalError)
        }
    }
}
