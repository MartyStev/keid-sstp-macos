import Foundation

/// Builds the AppleScript for the standard macOS administrator prompt:
/// `do shell script "…" with administrator privileges`.
public enum AdminScript {
    /// POSIX single-quoting, safe for any argument.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a value for an AppleScript string literal.
    public static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func source(executable: String, arguments: [String], prompt: String) -> String {
        let command = ([executable] + arguments).map(shellQuote).joined(separator: " ")
        return "do shell script \(appleScriptLiteral(command)) with prompt \(appleScriptLiteral(prompt)) with administrator privileges"
    }

    /// install-helper.sh prints `ok` as its last line on success. `do shell
    /// script` turns line feeds into carriage returns; both count as newlines.
    public static func succeeded(output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).last?.trimmingCharacters(in: .whitespaces) == "ok"
    }
}

/// Delays between automatic reconnection attempts.
public struct ReconnectPolicy: Sendable {
    public let delays: [Duration]

    public init(delays: [Duration] = [.seconds(3), .seconds(10), .seconds(30), .seconds(60)]) {
        self.delays = delays
    }

    /// Delay before attempt `attempt` (0-based); the last delay repeats.
    public func delay(forAttempt attempt: Int) -> Duration {
        guard let last = delays.last else { return .seconds(30) }
        return attempt < delays.count ? delays[max(attempt, 0)] : last
    }
}
