import SwiftUI

@main
struct SSTPClientApp: App {
    @State private var model = ConnectionModel()

    init() {
        // pin the launch language before Settings can change the stored one
        _ = LanguagePreference.atLaunch
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: model.status.state))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}
