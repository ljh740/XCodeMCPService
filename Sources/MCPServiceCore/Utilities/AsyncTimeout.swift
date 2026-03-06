import Foundation
import Synchronization

// MARK: - AsyncTimeoutError

/// Error thrown when an async operation exceeds its timeout.
struct AsyncTimeoutError: Error, CustomStringConvertible {
    let timeoutMs: Int
    var description: String { "Operation timed out after \(timeoutMs)ms" }
}

// MARK: - TimeoutState

/// Mutex-protected state shared between operation and timeout tasks.
/// `@unchecked Sendable` is safe because all access is serialized through the internal Mutex.
final class TimeoutState<T: Sendable>: @unchecked Sendable {
    private let mutex = Mutex<Inner>(.init())

    private struct Inner {
        var continuation: CheckedContinuation<T, any Error>?
        var operationTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    func setContinuation(_ cont: CheckedContinuation<T, any Error>) {
        mutex.withLock { $0.continuation = cont }
    }

    func setOperationTask(_ task: Task<Void, Never>) {
        let shouldCancel = mutex.withLock { s -> Bool in
            if s.continuation == nil { return true }
            s.operationTask = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        let shouldCancel = mutex.withLock { s -> Bool in
            if s.continuation == nil { return true }
            s.timeoutTask = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    /// Attempt to resume with a successful result. Cancels the timeout task and clears refs.
    func resumeReturning(_ value: T) -> Bool {
        mutex.withLock { s in
            guard let cont = s.continuation else { return false }
            s.continuation = nil
            s.timeoutTask?.cancel()
            s.operationTask = nil
            s.timeoutTask = nil
            cont.resume(returning: value)
            return true
        }
    }

    /// Attempt to resume with an error. Cancels the timeout task and clears refs.
    func resumeThrowing(_ error: any Error) -> Bool {
        mutex.withLock { s in
            guard let cont = s.continuation else { return false }
            s.continuation = nil
            s.timeoutTask?.cancel()
            s.operationTask = nil
            s.timeoutTask = nil
            cont.resume(throwing: error)
            return true
        }
    }

    /// Attempt to fire timeout: resume with error, cancel both tasks, clear refs.
    func fireTimeout(_ error: any Error) {
        mutex.withLock { s in
            guard let cont = s.continuation else { return }
            s.continuation = nil
            s.operationTask?.cancel()
            s.timeoutTask?.cancel()
            s.operationTask = nil
            s.timeoutTask = nil
            cont.resume(throwing: error)
        }
    }
}

// MARK: - asyncWithTimeout

/// Race an async operation against a timeout using non-structured Tasks.
///
/// Unlike TaskGroup, this does NOT wait for cancelled operations to complete,
/// making it suitable for operations that may block on non-cancellable I/O.
func asyncWithTimeout<T: Sendable>(
    _ timeoutMs: Int,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let state = TimeoutState<T>()

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            state.setContinuation(continuation)

            let opTask = Task {
                do {
                    let result = try await operation()
                    _ = state.resumeReturning(result)
                } catch {
                    _ = state.resumeThrowing(error)
                }
            }
            state.setOperationTask(opTask)

            let timeoutTask = Task {
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                state.fireTimeout(AsyncTimeoutError(timeoutMs: timeoutMs))
            }
            state.setTimeoutTask(timeoutTask)
        }
    } onCancel: {
        state.fireTimeout(CancellationError())
    }
}
