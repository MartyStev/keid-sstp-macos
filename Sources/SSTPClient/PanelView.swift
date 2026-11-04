import AppKit
import SwiftUI
import SSTPCore

/// The window that drops down from the menu bar icon.
struct PanelView: View {
    @Bindable var model: ConnectionModel
    @Environment(\.openSettings) private var openSettings
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.status.state == .connected { details }
            if !model.verifyCertificate && model.setup == .ready { certificateWarning }
            setupNotice
            if !model.lastError.isEmpty {
                Text(model.lastError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            connectButton
            if model.isBlocked && !model.isReconnecting { unblockButton }
            logSection
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
        .background(WindowVisibilityReader(onChange: { model.isPanelVisible = $0 }))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.status.state.symbol)
                .font(.title2)
                .foregroundStyle(model.status.state.tint)
                .frame(width: 28)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.host.isEmpty ? String(localized: "Keid") : model.host)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.status.state.title)
                    .font(.callout)
                    .foregroundStyle(model.status.state.tint)
                if model.isBlocked {
                    Text(model.isReconnecting
                         ? String(localized: "Reconnecting. Internet traffic is blocked until the tunnel is back.")
                         : String(localized: "Internet traffic is blocked. Connect again, or disconnect to unblock it."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            StatusRow(label: String(localized: "Address"), value: model.status.address)
            StatusRow(label: String(localized: "Server"), value: model.status.peer)
            StatusRow(label: String(localized: "Traffic"), value: String(localized: "all through the tunnel"))
            if let traffic = model.traffic {
                StatusRow(label: String(localized: "Data"), value: Self.describe(traffic))
            }
            if let since = model.status.connectedSince {
                HStack {
                    Text("Time").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                    Text(since, style: .timer).monospacedDigit()
                }
                .font(.callout)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var setupNotice: some View {
        switch model.setup {
        case .needsSettings:
            notice(String(localized: "Enter your server, login and password to get started."), action: String(localized: "Open Settings…"))
        case .needsUpdate:
            notice(String(localized: "The network helper needs an update."), action: String(localized: "Update in Settings…"))
        case .ready:
            EmptyView()
        }
    }

    private func notice(_ text: String, action: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Button(action) { openSettingsWindow() }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    private var connectButton: some View {
        Button {
            Task {
                if model.canCancel { await model.cancelConnect() } else { await model.toggleConnection() }
            }
        } label: {
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Text(buttonTitle).frame(maxWidth: .infinity)
            }
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(model.status.state == .connected || model.isReconnecting ? .red : .accentColor)
        .disabled(!model.canConnect && !model.canCancel)
        .keyboardShortcut(.defaultAction)
    }

    /// Blocked after a failure (wrong password, server unreachable): the main
    /// button connects again, this one lets traffic out without the VPN.
    private var unblockButton: some View {
        Button(role: .destructive) {
            Task { await model.unblock() }
        } label: {
            Text("Disconnect and unblock internet").frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(model.isBusy)
    }

    /// Without the check anyone on the way can pose as the server and see
    /// the login exchange.
    private var certificateWarning: some View {
        Label {
            Text("The server certificate is not checked: the connection can be intercepted. Turn the check on in Settings if the server has a valid certificate.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.caption)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private static let byteFormat = ByteCountFormatStyle(style: .file)

    private static func describe(_ traffic: TrafficCounters) -> String {
        "↓ \(byteFormat.format(traffic.received))   ↑ \(byteFormat.format(traffic.sent))"
    }

    private var buttonTitle: String {
        switch model.status.state {
        case .connected: String(localized: "Disconnect")
        case .connecting where model.isCancelling: String(localized: "Cancelling…")
        case .connecting: String(localized: "Cancel")
        case .dropped where model.isReconnecting: String(localized: "Disconnect")
        default: String(localized: "Connect")
        }
    }

    private var logSection: some View {
        DisclosureGroup(String(localized: "Log"), isExpanded: $showLog) {
            ScrollView {
                Text(model.log.isEmpty ? "…" : model.log)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
            Button(String(localized: "Copy Log")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.log, forType: .string)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .disabled(model.log.isEmpty)
        }
        .disabled(model.setup == .needsSettings)
        .task(id: showLog && model.isPanelVisible) {
            // loads at once when opened, then every 4 s while open and seen
            while showLog && model.isPanelVisible && !Task.isCancelled {
                await model.loadLog()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(String(localized: "Settings…")) { openSettingsWindow() }
                .buttonStyle(.borderless)
                .keyboardShortcut(",")
            Spacer()
            Button(String(localized: "Quit")) { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .font(.callout)
    }

    private func openSettingsWindow() {
        NSApp.activate()
        openSettings()
    }
}

struct StatusRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).textSelection(.enabled).monospacedDigit()
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

extension ConnectionState {
    var title: String {
        switch self {
        case .connected: String(localized: "Connected")
        case .connecting: String(localized: "Connecting…")
        case .disconnected: String(localized: "Disconnected")
        case .dropped: String(localized: "Internet blocked")
        case .unavailable: String(localized: "Not set up")
        }
    }

    var symbol: String {
        switch self {
        case .connected: "lock.shield.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .disconnected: "shield"
        // filled, with a cross: unlike any other state, also in the
        // monochrome menu bar
        case .dropped: "xmark.shield.fill"
        case .unavailable: "shield.slash"
        }
    }

    var tint: Color {
        switch self {
        case .connected: .green
        case .connecting: .orange
        case .dropped: .red
        case .disconnected: .secondary
        case .unavailable: .secondary
        }
    }
}
