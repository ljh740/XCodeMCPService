import Foundation
import Logging
import MCP

#if canImport(Darwin)
    import Darwin.POSIX
#elseif canImport(Glibc)
    import Glibc
#endif

/// 基于 Pipe 的 MCP Transport 实现，用于与子进程通信。
///
/// 与 `StdioTransport` 不同，本实现使用 POSIX `read()` 进行阻塞读取（在独立线程上），
/// 避免 `O_NONBLOCK` 导致的兼容性问题，也避免 actor 重入死锁。
///
/// 同时处理 id 格式兼容：SDK 使用 UUID 字符串 id，部分 MCP 服务器（如 Xcode mcpbridge）
/// 仅支持整数 id，本实现自动在两种格式间转换。
public actor PipeTransport: Transport {
    /// 从子进程 stdout 读取的 fd
    private let readFD: Int32
    /// 写入子进程 stdin 的 fd
    private let writeFD: Int32
    /// 用于读线程的独立 fd（dup），可独立关闭以解除阻塞
    private let readFDForThread: Int32

    public nonisolated let logger: Logger

    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    /// id 映射：整数 id → 原始字符串 id（用于响应时还原）
    private let idMapper = IDMapper()

    /// 创建 PipeTransport
    ///
    /// - Parameters:
    ///   - readHandle: 从子进程 stdout 读取的 FileHandle
    ///   - writeHandle: 写入子进程 stdin 的 FileHandle
    ///   - logger: 可选的 Logger 实例
    public init(
        readHandle: FileHandle,
        writeHandle: FileHandle,
        logger: Logger? = nil
    ) {
        self.readFD = readHandle.fileDescriptor
        self.writeFD = writeHandle.fileDescriptor
        // 复制 read fd 用于读线程，以便在 disconnect 时独立关闭
        self.readFDForThread = Darwin.dup(readHandle.fileDescriptor)
        self.logger = logger ?? Logger(
            label: "mcp.transport.pipe",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )

        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation
    }

    public func connect() async throws {
        guard !isConnected else { return }
        isConnected = true
        logger.debug("PipeTransport connected, readFD=\(readFD), writeFD=\(writeFD)")

        // 在独立线程上启动阻塞读取循环，完全脱离 actor context
        // 使用 dup'd fd，以便 disconnect 时可以独立关闭
        let fd = readFDForThread
        let continuation = messageContinuation
        let mapper = idMapper
        let log = logger
        Thread.detachNewThread {
            PipeTransport.blockingReadLoop(
                fd: fd, continuation: continuation, idMapper: mapper, logger: log)
        }
    }

    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        // 关闭 dup'd read fd 以解除阻塞读线程
        Darwin.close(readFDForThread)
        messageContinuation.finish()
        logger.debug("PipeTransport disconnected")
    }

    public func send(_ data: Data) async throws {
        guard isConnected else {
            throw MCPError.transportError(
                NSError(domain: "PipeTransport", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Not connected"]))
        }

        // 将字符串 id 替换为整数 id，兼容不支持字符串 id 的 MCP 服务器
        let dataToSend = idMapper.rewriteOutgoing(data)

        // 追加换行符作为消息分隔符
        var messageWithNewline = dataToSend
        messageWithNewline.append(UInt8(ascii: "\n"))

        // POSIX write
        let written = messageWithNewline.withUnsafeBytes { buffer in
            Darwin.write(writeFD, buffer.baseAddress!, buffer.count)
        }
        if written < 0 {
            throw MCPError.transportError(
                NSError(domain: "PipeTransport", code: Int(errno),
                        userInfo: [NSLocalizedDescriptionKey: "Write failed: \(errno)"]))
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        return messageStream
    }

    // MARK: - Read Loop

    /// 纯静态方法，在独立线程上执行阻塞 POSIX read，完全不涉及 actor
    private static func blockingReadLoop(
        fd: Int32,
        continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation,
        idMapper: IDMapper,
        logger: Logger
    ) {
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var pendingData = Data()

        while true {
            let bytesRead = Darwin.read(fd, buffer, bufferSize)

            if bytesRead < 0 {
                let err = errno
                if err == EINTR { continue }
                if err == EBADF {
                    logger.notice("PipeTransport read fd closed, exiting read loop")
                    break
                }
                logger.error("PipeTransport read error", metadata: ["errno": "\(err)"])
                break
            }

            if bytesRead == 0 {
                logger.notice("PipeTransport EOF received")
                break
            }

            pendingData.append(buffer, count: bytesRead)

            // 按换行符分割完整消息
            while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                let messageData = pendingData[..<newlineIndex]
                pendingData = pendingData[(newlineIndex + 1)...]

                if !messageData.isEmpty {
                    // 将整数 id 还原为原始字符串 id
                    let restored = idMapper.rewriteIncoming(Data(messageData))
                    continuation.yield(restored)
                }
            }
        }

        continuation.finish()
    }
}

// MARK: - IDMapper

/// 线程安全的 id 映射器，在字符串 id 和整数 id 之间转换。
///
/// 发送时：将 `"id":"UUID-STRING"` 替换为 `"id":N`（递增整数），记录映射。
/// 接收时：将 `"id":N` 还原为 `"id":"UUID-STRING"`。
///
/// 对于 notification（无 id）和已经是整数 id 的消息，不做任何处理。
final class IDMapper: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var counter: Int = 0
    private var intToString: [Int: (id: String, createdAt: UInt64)] = [:]
    private let maxSize = 10_000
    private let ttlNanos: UInt64 = 120_000_000_000 // 120 seconds

    /// 发送前：将字符串 id 替换为整数 id
    func rewriteOutgoing(_ data: Data) -> Data {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stringId = json["id"] as? String else {
            return data  // 无 id 或已是整数 id，不处理
        }

        let intId: Int
        os_unfair_lock_lock(&lock)
        counter += 1
        intId = counter
        intToString[intId] = (id: stringId, createdAt: mach_absolute_time())
        if intToString.count > maxSize {
            evictOldest()
        }
        os_unfair_lock_unlock(&lock)

        json["id"] = intId
        guard let rewritten = try? JSONSerialization.data(withJSONObject: json, options: []) else {
            return data
        }
        return rewritten
    }

    /// 接收后：将整数 id 还原为原始字符串 id
    func rewriteIncoming(_ data: Data) -> Data {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let intId = json["id"] as? Int else {
            return data  // 无 id 或已是字符串 id，不处理
        }

        let now = mach_absolute_time()
        os_unfair_lock_lock(&lock)
        let entry = intToString.removeValue(forKey: intId)
        os_unfair_lock_unlock(&lock)

        guard let entry else {
            return data  // 未找到映射，可能是服务器主动发送的或已被淘汰
        }

        // TTL 过期检查：超时则丢弃映射，返回原始数据
        if now - entry.createdAt > ttlNanos {
            return data
        }

        json["id"] = entry.id
        guard let rewritten = try? JSONSerialization.data(withJSONObject: json, options: []) else {
            return data
        }
        return rewritten
    }

    /// 淘汰最旧的 20% 条目（必须在持有 lock 时调用）
    private func evictOldest() {
        let evictCount = intToString.count / 5
        guard evictCount > 0 else { return }
        let keysToRemove = intToString
            .sorted { $0.value.createdAt < $1.value.createdAt }
            .prefix(evictCount)
            .map(\.key)
        for key in keysToRemove {
            intToString.removeValue(forKey: key)
        }
    }
}
