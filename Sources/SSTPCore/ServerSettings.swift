import Foundation

/// What the user enters in Settings. Mirrors the checks in install-helper.sh,
/// so problems are shown before the administrator prompt appears.
public struct ServerSettings: Sendable, Equatable {
    public var host: String
    public var login: String
    /// Empty means "keep the password saved on this Mac".
    public var password: String
    public var verifyCertificate: Bool
    public var blockIPv6: Bool

    public init(host: String, login: String, password: String, verifyCertificate: Bool = true, blockIPv6: Bool = true) {
        self.host = host
        self.login = login
        self.password = password
        self.verifyCertificate = verifyCertificate
        self.blockIPv6 = blockIPv6
    }

    public enum Problem: Sendable, Equatable {
        case hostEmpty
        case hostInvalidCharacters
        case portInvalid
        case loginEmpty
        case passwordEmpty
        /// A double quote or a backslash: pppd would read a different password.
        case passwordHasUnsupportedCharacter
        /// Longer than sstpc's buffer for `password "…"` can hold safely.
        case passwordTooLong
        case containsNewline
    }

    /// Host and login trimmed; the password is kept verbatim.
    public var normalized: ServerSettings {
        var copy = self
        copy.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.login = login.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }

    /// sstpc formats `password "…"` into a 255-byte buffer and writes the
    /// whole formatted length, so a longer password overruns it.
    public static let maxPasswordBytes = 128

    /// - Parameter hasSavedPassword: an empty password is fine when one is
    ///   already saved (the installer keeps it).
    public func problems(hasSavedPassword: Bool) -> [Problem] {
        let s = normalized
        var result: [Problem] = []
        if s.host.isEmpty {
            result.append(.hostEmpty)
        } else if !s.host.unicodeScalars.allSatisfy(Self.hostCharacters.contains)
                    || !(s.host.unicodeScalars.first.map(Self.hostFirstCharacters.contains) ?? false) {
            // a leading dash or dot: sstpc would read the host as an option
            result.append(.hostInvalidCharacters)
        } else if let colon = s.host.lastIndex(of: ":") {
            let port = Int(s.host[s.host.index(after: colon)...])
            if port == nil || !(1...65535).contains(port!) { result.append(.portInvalid) }
        }
        if s.login.isEmpty { result.append(.loginEmpty) }
        if s.password.isEmpty && !hasSavedPassword { result.append(.passwordEmpty) }
        if s.password.contains(where: { $0 == "\"" || $0 == "\\" }) { result.append(.passwordHasUnsupportedCharacter) }
        if s.password.utf8.count > Self.maxPasswordBytes { result.append(.passwordTooLong) }
        if [s.host, s.login, s.password].contains(where: { $0.contains(where: \.isNewline) }) {
            result.append(.containsNewline)
        }
        return result
    }

    /// The file handed to install-helper.sh: one raw KEY=VALUE per line.
    /// Returns nil when the settings are not valid.
    public func settingsFileContents(hasSavedPassword: Bool) -> String? {
        guard problems(hasSavedPassword: hasSavedPassword).isEmpty else { return nil }
        let s = normalized
        return [
            "SSTP_HOST=\(s.host)",
            "SSTP_USER=\(s.login)",
            "SSTP_PASS=\(s.password)",
            "VERIFY_CERT=\(s.verifyCertificate ? 1 : 0)",
            "BLOCK_IPV6=\(s.blockIPv6 ? 1 : 0)",
        ].joined(separator: "\n") + "\n"
    }

    private static let hostFirstCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private static let hostCharacters = hostFirstCharacters.union(CharacterSet(charactersIn: ".-:"))
}
