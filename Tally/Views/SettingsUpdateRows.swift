import SwiftUI

/// The Sparkle rows of the settings pane, with truthful toggle state.
///
/// Sparkle's effective "automatically download" value is `automatic checks AND
/// SUAutomaticallyUpdate`, and its setter silently refuses writes while automatic checks are
/// off, so the two switches are NOT independent. Rendering them straight from computed bindings
/// let the install switch flip visually whenever anything re-rendered the pane (it "turned
/// itself off" after Check Now). These rows keep local state that re-syncs from Sparkle after
/// every write instead, and the dependency is visible: the install row disables while automatic
/// checks are off.
struct SettingsUpdateRows: View {
    @State private var autoChecks = false
    @State private var autoInstalls = false

    var body: some View {
        if UpdaterController.shared.isActive {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Automatically check for updates")).font(.subheadline)
                    if let last = UpdaterController.shared.lastUpdateCheckDate {
                        Text(L("Last checked") + ": "
                             + last.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened)
                                 .locale(AppLocale.current)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle(isOn: Binding(
                    get: { autoChecks },
                    set: { value in
                        UpdaterController.shared.automaticallyChecksForUpdates = value
                        sync()
                    }
                )) { EmptyView() }
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            divider
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Install updates automatically")).font(.subheadline)
                    Text(L("Downloads and installs new versions in the background instead of asking each time."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(isOn: Binding(
                    get: { autoInstalls },
                    set: { value in
                        UpdaterController.shared.automaticallyDownloadsUpdates = value
                        sync()
                    }
                )) { EmptyView() }
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .disabled(!autoChecks)
            .opacity(autoChecks ? 1 : 0.5)

            divider
            HStack {
                Text(L("Check for Updates…")).font(.subheadline)
                Spacer()
                Button(L("Check Now")) { UpdaterController.shared.checkForUpdates() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .onAppear { sync() }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(L("This build has no update feed; download new versions from GitHub Releases."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Link("GitHub", destination: URL(string: "https://github.com/jettoai/tally/releases")!)
                    .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private var divider: some View {
        Divider().padding(.leading, 14)
    }

    private func sync() {
        autoChecks = UpdaterController.shared.automaticallyChecksForUpdates
        autoInstalls = UpdaterController.shared.automaticallyDownloadsUpdates
    }
}
