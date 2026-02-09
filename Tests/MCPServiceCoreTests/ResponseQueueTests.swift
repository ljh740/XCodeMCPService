import Foundation
import MCP
import Testing
@testable import MCPServiceCore

@Suite("ResponseQueue Tests")
struct ResponseQueueTests {

    @Test("Initial metrics are zero")
    func initialMetrics() async {
        let queue = ResponseQueue()
        let metrics = await queue.getMetrics()
        #expect(metrics.buffered == 0)
        #expect(metrics.dropped == 0)
    }

    @Test("Stop clears waiters and buffer")
    func stopClears() async {
        let queue = ResponseQueue()
        await queue.stop()
        let metrics = await queue.getMetrics()
        #expect(metrics.buffered == 0)
        #expect(metrics.dropped == 0)
    }

    @Test("Single message enqueue then dequeue via transport")
    func singleMessageRoundTrip() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await clientTransport.connect()
        try await serverTransport.connect()

        let queue = ResponseQueue()
        await queue.start(transport: clientTransport)

        // 通过 serverTransport 发送数据（模拟 MCP server 响应）
        let testData = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        try await serverTransport.send(testData)

        let received = try await queue.waitForNext(timeoutSeconds: 5)
        #expect(received == testData)

        await queue.stop()
    }

    @Test("Multiple messages maintain FIFO order")
    func fifoOrdering() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await clientTransport.connect()
        try await serverTransport.connect()

        let queue = ResponseQueue()
        await queue.start(transport: clientTransport)

        let msg1 = Data(#"{"id":1}"#.utf8)
        let msg2 = Data(#"{"id":2}"#.utf8)
        let msg3 = Data(#"{"id":3}"#.utf8)

        try await serverTransport.send(msg1)
        try await serverTransport.send(msg2)
        try await serverTransport.send(msg3)

        // 短暂等待让消息进入缓冲区
        try await Task.sleep(nanoseconds: 50_000_000)

        let r1 = try await queue.waitForNext(timeoutSeconds: 5)
        let r2 = try await queue.waitForNext(timeoutSeconds: 5)
        let r3 = try await queue.waitForNext(timeoutSeconds: 5)

        #expect(r1 == msg1)
        #expect(r2 == msg2)
        #expect(r3 == msg3)

        await queue.stop()
    }

    @Test("waitForNext blocks until data arrives")
    func waiterResolution() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await clientTransport.connect()
        try await serverTransport.connect()

        let queue = ResponseQueue()
        await queue.start(transport: clientTransport)

        let testData = Data(#"{"delayed":true}"#.utf8)

        // 先启动等待，然后延迟发送
        async let waitResult = queue.waitForNext(timeoutSeconds: 5)

        // 短暂延迟后发送
        try await Task.sleep(nanoseconds: 100_000_000)
        try await serverTransport.send(testData)

        let received = try await waitResult
        #expect(received == testData)

        await queue.stop()
    }

    @Test("stop() causes pending waiters to throw error")
    func stopCancelsPendingWaiters() async throws {
        let (clientTransport, _) = await InMemoryTransport.createConnectedPair()
        try await clientTransport.connect()

        let queue = ResponseQueue()
        await queue.start(transport: clientTransport)

        // 启动等待（不会有数据到达）
        let waitTask = Task {
            try await queue.waitForNext(timeoutSeconds: 30)
        }

        // 短暂延迟后 stop
        try await Task.sleep(nanoseconds: 50_000_000)
        await queue.stop()

        // 等待应该抛出错误
        do {
            _ = try await waitTask.value
            Issue.record("Expected error from stopped queue")
        } catch {
            // 预期行为：stop 导致 waiter 收到错误
        }
    }

    @Test("Timeout throws error with short timeout")
    func timeoutThrows() async throws {
        let (clientTransport, _) = await InMemoryTransport.createConnectedPair()
        try await clientTransport.connect()

        let queue = ResponseQueue()
        await queue.start(transport: clientTransport)

        // 使用 1 秒超时，不发送任何数据
        do {
            _ = try await queue.waitForNext(timeoutSeconds: 1)
            Issue.record("Expected timeout error")
        } catch {
            // 预期行为：超时抛出错误
        }

        await queue.stop()
    }

    @Test("Concurrent waiters each get distinct messages")
    func concurrentWaiters() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await clientTransport.connect()
        try await serverTransport.connect()

        let queue = ResponseQueue()
        await queue.start(transport: clientTransport)

        let msg1 = Data(#"{"id":"a"}"#.utf8)
        let msg2 = Data(#"{"id":"b"}"#.utf8)

        // 启动两个并发等待
        async let wait1 = queue.waitForNext(timeoutSeconds: 5)
        async let wait2 = queue.waitForNext(timeoutSeconds: 5)

        // 短暂延迟后发送两条消息
        try await Task.sleep(nanoseconds: 100_000_000)
        try await serverTransport.send(msg1)
        try await serverTransport.send(msg2)

        let r1 = try await wait1
        let r2 = try await wait2

        // 两个 waiter 应该各收到一条不同的消息
        let results = Set([r1, r2])
        #expect(results.count == 2)
        #expect(results.contains(msg1))
        #expect(results.contains(msg2))

        await queue.stop()
    }
}
