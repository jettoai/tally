import SwiftUI

@main
struct TallyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu-bar presence + all windows are managed by AppDelegate and the window controllers
        // (NSStatusItem / MainWindowController / SettingsWindowController). The Settings scene is a
        // required placeholder; ⌘, is routed to the custom settings window instead.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L("Settings…")) {
                    SettingsWindowController.shared.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
