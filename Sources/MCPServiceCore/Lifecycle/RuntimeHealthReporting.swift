// MARK: - RuntimeHealthReporting

/// 运行时健康上报接口，供请求路由层把真实业务超时上报给生命周期管理器。
public protocol RuntimeHealthReporting: Actor, Sendable {
    func currentHealthGeneration(serverName: String) -> UInt64?
    func recordRequestTimeout(serverName: String, operation: String, generation: UInt64?) async
}
