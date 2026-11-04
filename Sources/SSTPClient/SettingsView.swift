import SwiftUI
import SSTPCore

/// Server, login and password, plus connection options. Saving goes through
/// the standard administrator prompt: the settings live in a root-only file,
/// so only an administrator can point the tunnel at another server.
struct SettingsView: View {
    @Bindable var model: ConnectionModel
    /// Edited here, applied only when saving worked: a cancelled or failed
    /// administrator prompt leaves the app on the settings the helper has.
    @State private var draft: ServerSettings
    @State private var password = ""
    @State private var message = ""
    @State private var messageIsError = false
    @State private var confirmUninstall = false
    @State private var language = LanguagePreference.current

    init(model: ConnectionModel) {
        self.model = model
        _draft = State(initialValue: model.savedSettings)
    }

    private var hasChanges: Bool { draft != model.savedSettings || !password.isEmpty }

    var body: some View {
        Form {
            Section {
                TextField(String(localized: "Server"), text: $draft.host, prompt: Text(verbatim: "vpn.example.com"))
                    .textContentType(.URL)
                TextField(String(localized: "Login"), text: $draft.login)
                    .textContentType(.username)
                SecureField(String(localized: "Password"), text: $password,
                            prompt: Text(model.hasSavedServer ? String(localized: "saved — leave empty to keep") : ""))
                    .textContentType(.password)
            } header: {
                Text("SSTP server")
            } footer: {
                Text("Port 443 is used unless you add one, e.g. vpn.example.com:4443.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(String(localized: "Connection")) {
                Toggle(String(localized: "Verify the server certificate"), isOn: $draft.verifyCertificate)
                    .help(String(localized: "Turn off only for servers with a self-signed certificate."))
                Toggle(String(localized: "Block IPv6 while connected"), isOn: $draft.blockIPv6)
                    .help(String(localized: "The tunnel carries IPv4 only; without blocking, IPv6 traffic would bypass it."))
                Toggle(String(localized: "Reconnect automatically"), isOn: $model.autoReconnect)
                Toggle(String(localized: "Show notifications"), isOn: $model.showNotifications)
                    .help(String(localized: "When the connection is lost or restored, and when the server rejects the login."))
                Toggle(String(localized: "Launch at login"), isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }

            Section(String(localized: "Language")) {
                Picker(String(localized: "Language"), selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.nativeName ?? String(localized: "System")).tag(option)
                    }
                }
                .onChange(of: language) { _, newValue in LanguagePreference.set(newValue) }
                if language != LanguagePreference.atLaunch {
                    HStack {
                        Text("The new language is used after a restart.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "Restart Now")) { LanguagePreference.relaunch() }
                    }
                }
            }

            Section {
                HStack {
                    if !message.isEmpty {
                        Label(message, systemImage: messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(messageIsError ? .red : .green)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if hasChanges && message.isEmpty && model.hasSavedServer {
                        Text("Not saved yet").font(.callout).foregroundStyle(.secondary)
                    }
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Button(saveTitle) { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isBusy)
                }
            } footer: {
                Text("macOS asks for an administrator password to install the network helper and store these settings. Connecting later needs no password.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if HelperClient.isInstalled {
                Section {
                    Button(String(localized: "Uninstall Helper…"), role: .destructive) { confirmUninstall = true }
                        .disabled(model.isBusy)
                }
            }
        }
        .formStyle(.grouped)
        // the window keeps this view while closed: the next opening starts
        // from the saved settings, not from a stale draft or password
        .background(WindowVisibilityReader(onClose: { if !model.isBusy { resetDraft() } }))
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog(String(localized: "Remove the network helper and the saved server?"), isPresented: $confirmUninstall) {
            Button(String(localized: "Uninstall"), role: .destructive) { Task { await uninstall() } }
        } message: {
            Text("The app itself stays; drag it to the Trash to remove it completely.")
        }
    }

    private var saveTitle: String {
        switch model.setup {
        case .needsSettings: String(localized: "Save and Install")
        case .needsUpdate: String(localized: "Save and Update Helper")
        case .ready: String(localized: "Save")
        }
    }

    private func resetDraft() {
        draft = model.savedSettings
        password = ""
        message = ""
    }

    private func save() async {
        message = ""
        var settings = draft
        settings.password = password
        if let error = await model.saveSettings(settings) {
            message = error
            messageIsError = true
        } else {
            password = ""
            draft = model.savedSettings
            message = String(localized: "Saved. You can connect from the menu bar.")
            messageIsError = false
        }
    }

    private func uninstall() async {
        if let error = await model.uninstallHelper() {
            message = error
            messageIsError = true
        } else {
            message = String(localized: "The helper was removed.")
            messageIsError = false
        }
    }
}
