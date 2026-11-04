import AppKit
import Network

/// The network coming and going, and the Mac waking from sleep, delivered on
/// the main actor. Both are moments to bring a dropped tunnel back at once
/// instead of waiting out the reconnect back-off.
@MainActor
final class SystemEvents {
    private let monitor = NWPathMonitor()
    private var wakeObserver: NSObjectProtocol?

    func start(
        onNetworkChange: @escaping @MainActor @Sendable (_ isAvailable: Bool) -> Void,
        onWake: @escaping @MainActor @Sendable () -> Void
    ) {
        monitor.pathUpdateHandler = { path in
            let isAvailable = path.status == .satisfied
            Task { @MainActor in onNetworkChange(isAvailable) }
        }
        monitor.start(queue: DispatchQueue(label: "sstp-client.network-monitor"))
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in onWake() }
        }
    }
}
