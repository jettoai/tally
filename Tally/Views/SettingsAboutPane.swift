import SwiftUI

/// The Settings window's About pane, in three sections: an identity card (who this build is, its
/// version, when it last looked for an update), the update switches, and the privacy switches.
/// Split out of SettingsView.swift at the repo's 500-line cap, along the one-file-per-pane seam.
extension SettingsView {
    /// Not private: the pane switch that renders it (`SettingsView.paneContent`) is in the other
    /// file, and `private` in Swift is file-scoped.
    var aboutPane: some View {
        SettingsPage {
            SettingsPageHeader(title: L("About"), subtitle: L("Version, updates and what Tally sends."))
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
        }
    }
}

/// The About pane's top card: a step higher than a plain card, with the build's identity on the
/// left and its version and update check on the right. The three slots are the seams a private
/// build fills (`overlayEditionMark`, `overlayIdentityBackdrop`, `editionFooter`).
struct SettingsIdentityCard<Mark: View, Backdrop: View, Footer: View>: View {
    let mark: Mark
    let backdrop: Backdrop
    let footer: Footer
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        TallyWordmarkView(glyphHeight: 20)
                        mark
                        buildTag
                    }
                    TallyBatonView(segments: 3, carrying: 1, width: 40, thickness: 4)
                    HStack(spacing: 6) {
                        Text(L("by")).font(.subheadline).foregroundStyle(.secondary)
                        ProviderIconShape(pathData: ProviderMarks.jettoWordmark, inset: 0)
                            .fill(Color.secondary, style: FillStyle(eoFill: true))
                            .frame(width: 44, height: 10)
                        Text(verbatim: "\u{00B7}").font(.subheadline).foregroundStyle(.tertiary)
                        Link("jetto.ai", destination: URL(string: "https://jetto.ai")!)
                            .font(.subheadline)
                    }
                }
                Spacer(minLength: 16)
                versionColumn
            }
            .padding(SettingsChrome.heroInset)
            footer
        }
        .background { backdrop.clipShape(shape) }
        .background(shape.fill(dark ? Color.white.opacity(0.08) : Color.white)
            .shadow(color: .black.opacity(dark ? 0 : 0.07), radius: 8, y: 2))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
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
                .font(.title3.weight(.semibold).monospacedDigit())
            if !UpdateAvailability.shared.updaterActive, OverlayApp.noUpdateNote == nil {
                Link("GitHub Releases", destination: URL(string: "https://github.com/jettoai/tally/releases")!)
                    .font(.subheadline)
            }
        }
    }
}
