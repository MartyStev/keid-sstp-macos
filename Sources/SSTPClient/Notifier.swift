import Foundation
import os
import SSTPCore
import UserNotifications

/// macOS notifications about the tunnel. One notification at a time: a new
/// one replaces the previous, so a flapping connection does not pile them up.
@MainActor
enum Notifier {
    /// One permission request; notices posted meanwhile wait for it.
    private static var permission: Task<Void, Never>?
    private static let delegate = PresentationDelegate()
    private static let logger = Logger(subsystem: "io.github.martystev.sstp-mac-client", category: "notifications")

    static func post(_ notice: ConnectionNotice) {
        // `swift run` from .build has no bundle identifier; the notification
        // center refuses such a process
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        switch notice {
        case .lost:
            content.title = String(localized: "VPN connection lost")
            content.body = String(localized: "Internet traffic is blocked until the tunnel is back. Reconnecting…")
            content.sound = .default
        case .restored:
            content.title = String(localized: "VPN connection restored")
            content.body = String(localized: "All traffic goes through the tunnel again.")
        case .loginRejected:
            content.title = String(localized: "VPN login rejected")
            content.body = String(localized: "The server rejected the login or password. Internet traffic stays blocked until you disconnect.")
            content.sound = .default
        }
        let request = UNNotificationRequest(identifier: "connection", content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        if permission == nil {
            // also while the panel is open (the app counts as active then)
            center.delegate = delegate
            permission = Task {
                do {
                    _ = try await center.requestAuthorization(options: [.alert, .sound])
                } catch {
                    logger.error("notification permission: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        let permission = permission
        Task {
            await permission?.value
            do {
                try await center.add(request)
            } catch {
                // permission denied in System Settings: the panel still shows it all
                logger.info("notification not shown: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Shows notifications as banners even while the app is active.
private final class PresentationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
