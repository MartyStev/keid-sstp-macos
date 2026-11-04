import Foundation

/// Connection state as reported by `sstp-helper status`.
public enum ConnectionState: String, Sendable, Equatable {
    case connected
    case connecting
    case disconnected
    /// The tunnel went away but its routes are still installed (Wi-Fi change,
    /// sleep, server restart). The app cleans up and reconnects.
    case dropped
    /// The helper could not be reached (not installed, sudo rule missing).
    case unavailable
}

/// Parsed output of `sstp-helper status|up|down` — `key=value` lines.
public struct HelperStatus: Sendable, Equatable {
    public var state: ConnectionState
    public var interface: String
    public var address: String
    public var peer: String
    public var connectedSince: Date?
    public var helperVersion: Int?
    public var error: String
    /// Machine-readable reason for `error` (`auth`: login or password
    /// rejected). Empty from helpers older than version 6.
    public var errorCode: String

    /// The server rejected the login or password: retrying only risks
    /// locking the account.
    public var isAuthenticationFailure: Bool {
        errorCode == "auth" || error == "authentication failed"
    }

    public init(
        state: ConnectionState = .unavailable,
        interface: String = "",
        address: String = "",
        peer: String = "",
        connectedSince: Date? = nil,
        helperVersion: Int? = nil,
        error: String = "",
        errorCode: String = ""
    ) {
        self.state = state
        self.interface = interface
        self.address = address
        self.peer = peer
        self.connectedSince = connectedSince
        self.helperVersion = helperVersion
        self.error = error
        self.errorCode = errorCode
    }

    public static func parse(_ text: String) -> HelperStatus {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            // first occurrence wins: `up` prints status after its own lines
            if fields[key] == nil {
                fields[key] = String(line[line.index(after: eq)...])
            }
        }
        let since = TimeInterval(fields["since"] ?? "").flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        return HelperStatus(
            state: fields["state"].flatMap(ConnectionState.init(rawValue:)) ?? .unavailable,
            interface: fields["if"] ?? "",
            address: fields["addr"] ?? "",
            peer: fields["peer"] ?? "",
            connectedSince: since,
            helperVersion: fields["version"].flatMap { Int($0) },
            error: fields["error"] ?? "",
            errorCode: fields["error_code"] ?? ""
        )
    }
}

public enum HelperScript {
    /// `HELPER_VERSION=<n>` from the helper script shipped in the app bundle.
    public static func version(inScript text: String) -> Int? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("HELPER_VERSION=") {
            return Int(line.dropFirst("HELPER_VERSION=".count))
        }
        return nil
    }
}
