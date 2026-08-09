import SwiftUI

/// The update rows of the settings pane, with truthful toggle state.
///
/// Rendering these straight from computed bindings let the install switch flip visually whenever
/// anything re-rendered the pane (it "turned itself off" after Check Now), so the rows keep local
/// state and re-sync after every write instead.
///
/// The two switches are still shown as dependent, and now that is this app's rule rather than
/// Sparkle's: installing what nobody went looking for is not a thing that can happen, so the
/// install row disables while the checks row is off. (Sparkle used to impose the same dependency
/// on its own setter. It no longer does here: `SUAllowsAutomaticUpdates` in Info.plist unties
/// them, because Sparkle's scheduler is deliberately off and its switch would otherwise be stuck.)
struct SettingsUpdateRows: View {
    @State private var autoChecks = false
    @State private var autoInstalls = false

    var body: some View {
        if UpdateAvailability.shared.updaterActive {
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
                    Text(L("Downloads new versions in the background, then installs while you are away from the keyboard or the next time Tally quits."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
