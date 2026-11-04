/// What the app does when a new helper status arrives.
public enum StatusReaction: Sendable, Equatable {
    case none
    /// The tunnel is up: reset the back-off. `adopt`: treat it as the user's
    /// wish to stay connected (only for a tunnel found at launch).
    case connected(adopt: Bool)
    /// Connect again after the back-off delay. A dropped session keeps its
    /// kill-switch meanwhile, so nothing leaks while waiting.
    case reconnect
    /// Remove what a dead session of a helper older than the kill-switch
    /// left behind (routes). A newer helper stays blocked until Disconnect.
    case cleanUp
    /// Clean up, then connect again: a helper older than the kill-switch
    /// cannot reconnect over the routes of a dropped session.
    case cleanUpAndReconnect
}

/// The reconnect and kill-switch rules, kept pure so they are testable
/// without the helper.
public enum StatusPolicy {
    /// The first helper version with the firewall kill-switch.
    public static let killSwitchHelperVersion = 4

    /// The network came back or the Mac woke up: try the tunnel now instead
    /// of waiting out the back-off.
    public static func reconnectsNow(state: ConnectionState, wantsConnection: Bool, autoReconnect: Bool) -> Bool {
        wantsConnection && autoReconnect && (state == .dropped || state == .disconnected)
    }

    public static func reaction(
        previous: ConnectionState,
        next: ConnectionState,
        isFirstStatus: Bool,
        wantsConnection: Bool,
        autoReconnect: Bool,
        helperVersion: Int? = killSwitchHelperVersion
    ) -> StatusReaction {
        let retries = wantsConnection && autoReconnect
        switch next {
        case .connected:
            return .connected(adopt: isFirstStatus)
        case .dropped:
            let hasKillSwitch = (helperVersion ?? 0) >= killSwitchHelperVersion
            if hasKillSwitch {
                // the firewall blocks traffic until the tunnel is back or the
                // user disconnects; nothing is unblocked automatically
                return retries ? .reconnect : .none
            }
            return retries ? .cleanUpAndReconnect : .cleanUp
        case .disconnected where previous == .connected && retries:
            return .reconnect
        default:
            return .none
        }
    }
}
