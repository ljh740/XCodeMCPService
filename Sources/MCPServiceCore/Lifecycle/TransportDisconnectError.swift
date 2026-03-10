import Foundation
import MCP

#if canImport(Darwin)
    import Darwin.POSIX
#elseif canImport(Glibc)
    import Glibc
#endif

private let disconnectErrnos: Set<Int> = [Int(EPIPE), Int(EBADF), Int(ENOTCONN)]

func isDisconnectLikeError(_ error: any Error) -> Bool {
    if let mcpError = error as? MCPError {
        switch mcpError {
        case .connectionClosed:
            return true
        case .transportError(let underlying):
            return isDisconnectLikeError(underlying)
        default:
            break
        }
    }

    let nsError = error as NSError
    guard nsError.domain == NSPOSIXErrorDomain else { return false }
    return disconnectErrnos.contains(nsError.code)
}
