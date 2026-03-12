import Foundation
import MCP

actor ResponseQueue {
    private struct WaiterEntry {
        let continuation: CheckedContinuation<Data, Error>
    }

    private let logger: BridgeLogger
    private var waiters: [JSONRPCID: WaiterEntry] = [:]
    private var bufferedResponses: [JSONRPCID: Data] = [:]
    private var bufferedOrder: [JSONRPCID] = []
    private var abandonedResponseIDs: Set<JSONRPCID> = []
    private var abandonedOrder: [JSONRPCID] = []
    private var readTask: Task<Void, Never>?
    private var terminalError: BridgeError?
    private var droppedCount = 0

    private let maxBufferedResponses = 1_000
    private let maxAbandonedResponseIDs = 1_000

    init(logger: BridgeLogger) {
        self.logger = logger
    }

    func start(transport: InMemoryTransport) {
        readTask = Task {
            let stream = await transport.receive()
            do {
                for try await data in stream {
                    guard !Task.isCancelled else { return }
                    enqueue(data)
                }
                guard !Task.isCancelled else { return }
                finishStream(
                    with: .internalError("Session response stream closed")
                )
            } catch {
                guard !Task.isCancelled else { return }
                finishStream(
                    with: .internalError(
                        "Session response stream failed: \(error.localizedDescription)"
                    )
                )
            }
        }
    }

    func stop() {
        readTask?.cancel()
        finishStream(with: .internalError("Session closed"), clearBufferedResponses: true)
        abandonedResponseIDs.removeAll()
        abandonedOrder.removeAll()
    }

    func getMetrics() -> (buffered: Int, dropped: Int) {
        (buffered: bufferedResponses.count, dropped: droppedCount)
    }

    func waitForResponse(id: JSONRPCID, timeoutMs: Int) async throws -> Data {
        if let buffered = takeBufferedResponse(id: id) {
            return buffered
        }
        if let terminalError {
            throw terminalError
        }
        if abandonedResponseIDs.contains(id) {
            throw BridgeError.invalidRequest(
                "Cannot reuse timed-out request id within the same session: \(id.logValue)"
            )
        }
        guard waiters[id] == nil else {
            throw BridgeError.invalidRequest("Duplicate in-flight request id: \(id.logValue)")
        }

        return try await withCheckedThrowingContinuation { continuation in
            waiters[id] = WaiterEntry(continuation: continuation)
            Task {
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                self.timeoutWaiter(id: id, timeoutMs: timeoutMs)
            }
        }
    }

    private func timeoutWaiter(id: JSONRPCID, timeoutMs: Int) {
        guard let entry = waiters.removeValue(forKey: id) else {
            return
        }
        rememberAbandonedResponseID(id)
        entry.continuation.resume(throwing: BridgeError.timeout(
            "MCP response timed out after \(timeoutMs)ms",
            timeoutMs: timeoutMs
        ))
    }

    private func enqueue(_ data: Data) {
        guard let responseID = JSONRPCMessage.id(from: data) else {
            droppedCount += 1
            logger.warning("Dropping response without JSON-RPC id")
            return
        }

        if abandonedResponseIDs.contains(responseID) {
            droppedCount += 1
            logger.info("Dropping late response for timed-out request", metadata: [
                "responseId": responseID.logValue
            ])
            return
        }

        if let entry = waiters.removeValue(forKey: responseID) {
            entry.continuation.resume(returning: data)
            return
        }

        buffer(data, for: responseID)
    }

    private func takeBufferedResponse(id: JSONRPCID) -> Data? {
        guard let data = bufferedResponses.removeValue(forKey: id) else {
            return nil
        }
        bufferedOrder.removeAll { $0 == id }
        return data
    }

    private func buffer(_ data: Data, for id: JSONRPCID) {
        if bufferedResponses[id] == nil {
            bufferedOrder.append(id)
        }
        bufferedResponses[id] = data
        trimBufferedResponsesIfNeeded()
    }

    private func trimBufferedResponsesIfNeeded() {
        while bufferedResponses.count > maxBufferedResponses {
            let oldestID = bufferedOrder.removeFirst()
            if bufferedResponses.removeValue(forKey: oldestID) != nil {
                droppedCount += 1
                logger.warning("Dropping buffered response because queue is full", metadata: [
                    "responseId": oldestID.logValue
                ])
            }
        }
    }

    private func rememberAbandonedResponseID(_ id: JSONRPCID) {
        guard abandonedResponseIDs.insert(id).inserted else {
            return
        }
        abandonedOrder.append(id)
        while abandonedResponseIDs.count > maxAbandonedResponseIDs {
            let oldestID = abandonedOrder.removeFirst()
            abandonedResponseIDs.remove(oldestID)
        }
    }

    private func finishStream(
        with error: BridgeError,
        clearBufferedResponses: Bool = false
    ) {
        if terminalError == nil {
            terminalError = error
        }
        readTask = nil
        if clearBufferedResponses {
            bufferedResponses.removeAll()
            bufferedOrder.removeAll()
        }
        failPendingWaiters(with: error)
    }

    private func failPendingWaiters(with error: Error) {
        let pending = waiters
        waiters.removeAll()
        for entry in pending.values {
            entry.continuation.resume(throwing: error)
        }
    }
}
