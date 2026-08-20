import SwiftUI

/// Which Claude account the person at this machine is signed into in their BROWSER, which is the one
/// thing the Artifact guard cannot work out for itself (Tally/Core/ArtifactHookContract.swift).
///
/// A ROW OF ITS OWN, under the install row rather than inside it: the hook is a thing that is
/// installed or not, and this is an answer the user gives. It is shown whatever the row above says,
/// because the answer outlives a Remove and a later Reinstall must not re-guess it.
///
/// THE OPTIONS ARE THE PANEL'S OWN ACCOUNTS, in the panel's order and under the panel's names
/// (`AccountFacts.label` is the nickname when there is one). Their home is `identityHome`, the
/// property that NAMES a config home rather than acting on one, so a demo launch shows its fixtures
/// here exactly as it shows them everywhere else.
struct SettingsArtifactAccountRow: View {
    let store: UsageStore
    let settings: SettingsStore

    private struct Option: Identifiable {
        let id: String
        let label: String
        let home: String
    }

    private var options: [Option] {
        store.accounts
            .filter { $0.providerID == "claude" }
            .compactMap { usage in
                let facts = AccountFacts(usage: usage, settings: settings)
                guard let home = facts.identityHome else { return nil }
                return Option(id: usage.id, label: facts.label, home: home)
            }
    }

    var body: some View {
        let launch = LaunchPolicyStore.shared
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Publish artifacts from")).font(.subheadline)
                Text(L("The account you are signed into on claude.ai. A published artifact is private to the account that published it, so one published from anywhere else opens as Page not found for you."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { launch.artifactAccount },
                set: { launch.setArtifactAccount($0) }
            )) {
                // Nothing chosen is a real state rather than a placeholder: the guard abstains on it,
                // so this entry is also how somebody turns the checking off without removing the
                // hook.
                Text(L("Not chosen")).tag(String?.none)
                ForEach(options) { option in
                    Text(option.label).tag(String?.some(option.home))
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .padding(.leading, 18)
    }
}
