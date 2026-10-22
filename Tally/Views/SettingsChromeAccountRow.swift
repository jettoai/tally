import SwiftUI

/// Which Claude account the Claude in Chrome extension is signed in to. The one fact Tally cannot
/// read for itself, so it is asked here and nowhere guessed: a session on another account that
/// gets "not connected" is pointed at a session on this one (TallyCLI/ChromeReach.swift).
///
/// Stored as the account id (`claude:.claude2`), the same value the supervisor's `.account` file and
/// the snapshot carry, so the CLI compares it without any translation.
struct SettingsChromeAccountRow: View {
    let store: UsageStore
    let settings: SettingsStore

    private struct Option: Identifiable {
        let id: String
        let label: String
    }

    private var options: [Option] {
        store.accounts.filter { $0.providerID == "claude" }.map {
            Option(id: $0.id, label: AccountFacts(usage: $0, settings: settings).label)
        }
    }

    var body: some View {
        let launch = LaunchPolicyStore.shared
        SettingsRow(title: L("Claude in Chrome account"),
                    subtitle: L("Which account the Claude in Chrome extension is signed in to."),
                    icon: "globe",
                    info: L("The account the Claude in Chrome extension is signed in to. A session on another account hands its browser steps to a one-off run on this account and keeps its own.")) {
            Picker("", selection: Binding(
                get: { launch.chromeAccount },
                set: { launch.setChromeAccount($0) }
            )) {
                Text(L("Not chosen")).tag(String?.none)
                ForEach(options) { option in
                    Text(option.label).tag(String?.some(option.id))
                }
            }
            .labelsHidden()
        }
    }
}
