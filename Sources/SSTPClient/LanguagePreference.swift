import AppKit
import SSTPCore

/// The interface language override, stored as the app's own `AppleLanguages`
/// default. macOS reads it at launch, so a change needs a restart.
enum LanguagePreference {
    private static let key = "AppleLanguages"

    /// The language this process runs in; read once at launch (see SSTPClientApp).
    static let atLaunch = current

    /// Read from the app's own domain only: `UserDefaults.standard` would also
    /// return the system-wide list, which is not a choice made in this app.
    static var current: AppLanguage {
        guard let id = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard.persistentDomain(forName: id)
        else { return .system }
        return AppLanguage(appleLanguages: domain[key] as? [String])
    }

    static func set(_ language: AppLanguage) {
        if let list = language.appleLanguages {
            UserDefaults.standard.set(list, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Opens a fresh copy of the app once this one has quit. The tunnel is
    /// run by the helper, so a connection stays up across the restart.
    @MainActor static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // waits until this process is gone (up to 10 s): `open` on a still
        // running app would only bring the old instance to the front
        let script = "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done; /usr/bin/open \"$0\""
        task.arguments = ["-c", script, Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            NSSound.beep()
        }
    }
}
