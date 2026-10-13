import SwiftUI

@main
struct TallyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // App Nap lowered every thread, the main one included, to priority 4, so on a saturated CPU
        // a refresh round waited minutes for its timer and its awaits (B-1745). AppKit reads this
        // switch from user defaults; the same key in Info.plist was measured to have no effect.
        UserDefaults.standard.register(defaults: ["NSAppSleepDisabled": true])
    }

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
