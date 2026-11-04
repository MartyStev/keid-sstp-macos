/// How often the app asks the helper for its status. Every poll starts sudo,
/// a shell, ps and pfctl, so on a MacBook rarely is better — but a drop must
/// still show quickly. Network changes and wake-ups poll at once anyway.
public enum PollingPolicy {
    /// Connecting, reconnecting, blocked, a command running, or the panel open.
    public static let fast: Duration = .seconds(4)
    /// A tunnel that is up and steady; pppd notices a dead one within 20 s.
    public static let connected: Duration = .seconds(15)
    /// Disconnected or not set up: nothing to watch closely.
    public static let idle: Duration = .seconds(30)

    public static func interval(
        state: ConnectionState,
        isBusy: Bool,
        isReconnecting: Bool,
        isPanelVisible: Bool
    ) -> Duration {
        if isBusy || isReconnecting || isPanelVisible { return fast }
        switch state {
        case .connecting, .dropped: return fast
        case .connected: return connected
        case .disconnected, .unavailable: return idle
        }
    }
}
