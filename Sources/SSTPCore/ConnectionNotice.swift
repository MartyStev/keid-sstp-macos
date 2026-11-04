/// What the app tells the user in a notification.
public enum ConnectionNotice: Sendable, Equatable {
    /// The tunnel went away while wanted; the firewall blocks traffic.
    case lost
    /// The tunnel is back after a drop.
    case restored
    /// The server rejected the login or password; no more retries.
    case loginRejected
}

public enum NoticePolicy {
    /// - Parameter recovering: the tunnel dropped earlier in this connection
    ///   and the app has been bringing it back.
    public static func notice(
        previous: ConnectionState,
        next: ConnectionState,
        wantsConnection: Bool,
        recovering: Bool
    ) -> ConnectionNotice? {
        if previous == .connected, next == .dropped || next == .disconnected, wantsConnection {
            return .lost
        }
        if next == .connected, previous != .connected, recovering {
            return .restored
        }
        return nil
    }
}

/// Bytes through an interface, from `netstat -ibn -I <if>`.
public struct TrafficCounters: Sendable, Equatable {
    public var received: Int64
    public var sent: Int64

    public init(received: Int64, sent: Int64) {
        self.received = received
        self.sent = sent
    }

    /// The `<Link#n>` line holds the totals. It ends with Ipkts Ierrs Ibytes
    /// Opkts Oerrs Obytes Coll; the Address column before them is empty for
    /// ppp, so the fields are counted from the end.
    public static func parse(netstat: String) -> TrafficCounters? {
        for line in netstat.split(whereSeparator: \.isNewline) where line.contains("<Link#") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 7,
                  let received = Int64(fields[fields.count - 5]),
                  let sent = Int64(fields[fields.count - 2]) else { return nil }
            return TrafficCounters(received: received, sent: sent)
        }
        return nil
    }
}
