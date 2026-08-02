import SwiftUI

/// The popover's header strip, split out of PopoverRootView for file size: the wordmark and its
/// badges, the Usage / Tokens switch, the clock and countdown, and the refresh button.
extension PopoverRootView {
    var header: some View {
        HStack(spacing: 6) {
            // Everything except the refresh button and the tab picker doubles as the pinned panel's
            // window-move handle (an AppKit background view would steal their clicks, so both sit
            // outside it). The handle comes in two pieces for that reason, and each fills the
            // header's full height - backing only the text line left a thin ~17pt grab strip that
            // was easy to miss.
            HStack(spacing: 6) {
                // The logotype (brand T as the initial) - a bare glyph next to the word "Tally"
                // read as two Ts. The header is the product's line; the jetto credit lives quietly
                // in the footer's empty centre instead of trailing the wordmark like a byline.
                TallyWordmarkView(glyphHeight: 13)
                // The dev variant tags every surface (menu bar strip + panel header), so a test
                // instance can never be mistaken for the installed app.
                if BuildVariant.isDev {
                    Text(verbatim: "DEV")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(TallyColor.warning)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .overlay(Capsule().stroke(TallyColor.warning.opacity(0.6), lineWidth: 1))
                }
                // Docker-style nudge, two states: detected (accent ↑, click walks the install
                // flow) and downloaded (green ↻, the Ghostty semantic - the payload is on disk,
                // a click just restarts into the new version).
                if let version = UpdateAvailability.shared.version {
                    let ready = UpdateAvailability.shared.isDownloaded
                    Button {
                        UpdaterController.shared.checkForUpdates()
                    } label: {
                        Text(verbatim: "\(ready ? "↻" : "↑") \(version)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(ready ? TallyColor.normal : TallyColor.ai))
                    }
                    .buttonStyle(.plain)
                    .help(ready ? L("Update downloaded - click to restart")
                                : L("Update available - click to install"))
                }
            }
            .padding(.leading, 12)
            .frame(maxHeight: .infinity)
            .background(WindowDragArea())
            // Straight after the wordmark, the way a product names its own screens. Every surface
            // carries it: the pinned panel is where someone watches usage all day, and making them
            // open a different window to see where the tokens went broke that. Not in the footer
            // with the view controls - this switches WHAT the surface is showing, not how it looks.
            surfaceTabPicker
            HStack(spacing: 6) {
                Spacer(minLength: 8)
                // TimelineView re-evaluates every second so "updates in 42s" counts down live (a
                // plain render would freeze it at whatever it said on open). Hierarchy: the date is
                // the anchor the absolute reset times are read against, so it leads; the countdown
                // is a heartbeat, so it dims.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 6) {
                        Text(UsageFormat.nowShort(context.date))
                            .font(.caption2.weight(.medium)).monospacedDigit()
                            .foregroundStyle(.primary)
                        if let counter = store.isRefreshing
                            ? L("updating…")
                            : UsageFormat.updatesIn(store.nextRefreshAt, now: context.date) {
                            // The counter's string width changes every second; hidden templates
                            // (the widest forms, localized) reserve a fixed slot so the ticking
                            // never pushes the date around. Trailing-aligned to hug the button.
                            ZStack(alignment: .trailing) {
                                ForEach(UsageFormat.updatesInTemplates, id: \.self) {
                                    Text($0).hidden()
                                }
                                Text(counter)
                            }
                            .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .background(WindowDragArea())
            Button {
                Task { await store.refresh(userInitiated: true) }
            } label: {
                // A hand-rolled rotation cannot end cleanly: animating back after an interrupted
                // repeatForever unwinds the arrow (a visible bob), and a nil animation does not
                // cancel an in-flight repeat (the arrow spins forever). Swap to the native
                // spinner while refreshing instead - no custom animation to get wrong.
                Group {
                    if store.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .accessibilityLabel(L("Refresh"))
            .help(L("Refresh"))
            .padding(.trailing, 12)
        }
        .frame(height: 40)
    }

    /// Same control the footer uses for the meters, in the same size: two words, both always legible,
    /// so the alternative view advertises itself instead of hiding behind an icon. Sized to its text
    /// and placed before the flexible part of the header, so the countdown beside it keeps the width
    /// it reserves for its widest string even in the narrowest single-column panel.
    private var surfaceTabPicker: some View {
        Picker("", selection: tabSelection) {
            ForEach(SurfaceTab.allCases) { tab in
                Text(tab.label).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .fixedSize()
    }}
