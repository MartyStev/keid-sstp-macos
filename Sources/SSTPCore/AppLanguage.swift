/// The interface language chosen in Settings. `system` follows the macOS
/// language list; the others pin the app to one of its localizations.
public enum AppLanguage: String, CaseIterable, Sendable, Identifiable {
    case system
    case english = "en"
    case russian = "ru"

    public var id: String { rawValue }

    /// The value for the app's `AppleLanguages` default, or nil to remove it
    /// and follow the system.
    public var appleLanguages: [String]? {
        self == .system ? nil : [rawValue]
    }

    /// Reads the app's `AppleLanguages` default back; anything that is not
    /// exactly one of our localizations counts as `system`.
    public init(appleLanguages: [String]?) {
        guard let list = appleLanguages, list.count == 1,
              let language = AppLanguage(rawValue: list[0]), language != .system
        else {
            self = .system
            return
        }
        self = language
    }

    /// The language's name in that language, so it is recognisable whatever
    /// the current interface language is.
    public var nativeName: String? {
        switch self {
        case .system: nil
        case .english: "English"
        case .russian: "Русский"
        }
    }
}
