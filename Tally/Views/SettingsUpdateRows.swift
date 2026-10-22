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
            SettingsToggleRow(
                title: L("Automatically check for updates"),
                icon: "arrow.down.circle",
                isOn: Binding(
                    get: { autoChecks },
                    set: { value in
                        UpdaterController.shared.automaticallyChecksForUpdates = value
                        sync()
                    }
                ))

            SettingsDivider()

            SettingsToggleRow(
                title: L("Install updates automatically"),
                subtitle: L("Downloads in the background and installs when you are away or Tally quits."),
                icon: "square.and.arrow.down",
                info: L("Downloads new versions in the background, then installs while you are away from the keyboard or the next time Tally quits."),
                isOn: Binding(
                    get: { autoInstalls },
                    set: { value in
                        UpdaterController.shared.automaticallyDownloadsUpdates = value
                        sync()
                    }
                ))
                .disabled(!autoChecks)
                .opacity(autoChecks ? 1 : 0.5)
                .onAppear { sync() }

            SettingsDivider()

            // Stays enabled while the automatic-check switch is off: a manual check is not automatic.
            SettingsRow(title: L("Last checked"),
                        subtitle: UpdaterController.shared.lastUpdateCheckDate.map {
                            $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened)
                                .locale(AppLocale.current))
                        },
                        icon: "clock") {
                Button(L("Check Now")) { UpdaterController.shared.checkForUpdates() }
                    .buttonStyle(.bordered)
            }
        } else {
            // The link to GitHub Releases is on the identity card, beside the version.
            Text(OverlayApp.noUpdateNote
                 ?? L("This build has no update feed; download new versions from GitHub Releases."))
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SettingsChrome.rowInsetH)
                .padding(.vertical, SettingsChrome.rowInsetV)
        }
    }

    private func sync() {
        autoChecks = UpdaterController.shared.automaticallyChecksForUpdates
        autoInstalls = UpdaterController.shared.automaticallyDownloadsUpdates
    }
}
