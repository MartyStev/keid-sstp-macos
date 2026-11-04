import AppKit
import SwiftUI

/// Reports whether the window that hosts this view is on screen. The panel
/// of a MenuBarExtra stays alive while closed, so onAppear/onDisappear are
/// not reliable for "the user is looking"; the window's occlusion state is.
/// `onClose` fires when the window is closed (not when it is just covered).
struct WindowVisibilityReader: NSViewRepresentable {
    var onChange: (Bool) -> Void = { _ in }
    var onClose: () -> Void = {}

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = onChange
        view.onClose = onClose
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        var onClose: (() -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                onChange?(false)
                return
            }
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            })
            observers.append(center.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClose?() }
            })
            report()
        }

        private func report() {
            onChange?(window?.occlusionState.contains(.visible) ?? false)
        }
    }
}
