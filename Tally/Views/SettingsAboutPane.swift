import SwiftUI

/// The Settings window's About pane, in three sections: an identity card (who this build is, its
/// version, when it last looked for an update), the update switches, and the privacy switches.
/// Split out of SettingsView.swift at the repo's 500-line cap, along the one-file-per-pane seam.
extension SettingsView {
    /// Not private: the pane switch that renders it (`SettingsView.paneContent`) is in the other
    /// file, and `private` in Swift is file-scoped.
    var aboutPane: some View {
        SettingsPage(title: L("About"), subtitle: L("Version, updates and what Tally sends.")) {
            // A development build says so once, here, rather than in a hover on the DEV tag.
            SettingsDevBanner(message: L("Runs beside the installed app and never updates itself."))
            SettingsIdentityCard(mark: overlayEditionMark,
                                 backdrop: overlayIdentityBackdrop,
                                 footer: editionFooter)

            // The Sparkle rows live in their own file (SettingsUpdateRows): the two switches carry a
            // hidden Sparkle-side dependency that needs truthful local state, not computed bindings.
            SettingsSection(L("Updates"), symbol: "arrow.triangle.2.circlepath") {
                SettingsUpdateRows()
            }

            SettingsSection(L("Privacy"), symbol: "hand.raised") {
                SettingsErrorReportingRow()
                SettingsDivider()
                SettingsUsagePingRow()
            }

            // The window's way out: the status item's secondary-click menu was the only Quit.
            PageActionButton(title: L("Quit Tally")) { NSApp.terminate(nil) }
        }
    }
}

/// The About pane's top card: card B spanning all four columns (700 x 96), with the build's identity
/// on the left and its version on the right. The three slots are the seams a private build fills
/// (`overlayEditionMark`, `overlayIdentityBackdrop`, `editionFooter`); a non-empty footer makes the
/// card taller than 96.
struct SettingsIdentityCard<Mark: View, Backdrop: View, Footer: View>: View {
    let mark: Mark
    let backdrop: Backdrop
    let footer: Footer

    var body: some View {
        TileGrid {
            TileCard(span: 4) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 0) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .center, spacing: 8) {
                                TallyWordmarkView(glyphHeight: 20)
                                mark
                                buildTag
                            }
                            TallyBatonView(segments: 3, carrying: 1, width: 40, thickness: 4)
                            HStack(spacing: 6) {
                                Text(L("by")).foregroundStyle(.secondary)
                                ProviderIconShape(pathData: ProviderMarks.jettoWordmark, inset: 0)
                                    .fill(Color.secondary, style: FillStyle(eoFill: true))
                                    .frame(width: 44, height: 10)
                                Text(verbatim: "\u{00B7}").foregroundStyle(.tertiary)
                                Link("jetto.ai", destination: URL(string: "https://jetto.ai")!)
                            }
                            .font(.system(size: PageType.note))
                        }
                        Spacer(minLength: 16)
                        versionColumn
                    }
                    .padding(.horizontal, PageSkeleton.rowInsetH)
                    .padding(.vertical, 16)
                    footer
                }
                .frame(maxWidth: .infinity, minHeight: PageSkeleton.tileHeight)
                .background { backdrop.clipShape(RoundedRectangle(cornerRadius: PageSkeleton.cornerRadius, style: .continuous)) }
            }
        }
    }

    /// Which of the look-alike builds is this? DEV for the Debug flavour, "Local build" for a
    /// source-built release (dormant updater, stuck on its version forever); the installed stable
    /// shows nothing extra, its update rows below are the tell.
    @ViewBuilder
    private var buildTag: some View {
        if BuildVariant.isDev {
            capsuleTag(Text(verbatim: "DEV"))
        } else if !UpdateAvailability.shared.updaterActive {
            capsuleTag(Text(L("Local build")))
                .tallyTooltip(L("Built from source without an update feed - it cannot update itself"))
        }
    }

    private func capsuleTag(_ text: Text) -> some View {
        text
            .font(.caption2)
            .foregroundStyle(TallyColor.warning)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(TallyColor.warning.opacity(0.15)))
    }

    private var versionColumn: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text("v\(BuildVariant.version ?? "\u{2014}")")
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
            if !UpdateAvailability.shared.updaterActive, OverlayApp.noUpdateNote == nil {
                Link("GitHub Releases", destination: URL(string: "https://github.com/jettoai/tally/releases")!)
                    .font(.system(size: PageType.note))
            }
        }
    }
}
