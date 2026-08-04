import SwiftUI

/// The measured widths of the header parts that do NOT change when the clock cluster is trimmed: the
/// rigid cluster at each end, the switch between them, and unrendered copies of the clock and its
/// counter slot. Because no member moves with the decision below, that decision can never feed back
/// into its own inputs and oscillate - the numbers describe the row as it would be laid out with no
/// clock at all.
struct HeaderWidths: Equatable {
    var brand: CGFloat = 0
    var picker: CGFloat = 0
    var refresh: CGFloat = 0
    var clock: CGFloat = 0
    var counter: CGFloat = 0
}

/// How much of the clock cluster the row has room for. The trimming order ranks what the header is
/// for: the countdown is a heartbeat, the clock is the anchor the cards' absolute reset times are
/// read against, and everything else is either identity (wordmark, update badge) or the surface's
/// only controls (the switch, the refresh) - so the heartbeat goes first and the anchor second.
enum HeaderClock { case full, clockOnly, hidden }

/// The popover's header strip, split out of PopoverRootView for file size: the wordmark and its
/// badges, the Usage / Tokens switch, the clock and countdown, and the refresh button.
extension PopoverRootView {
    /// The row's own geometry, read by both the layout below and the fit test that trims the clock,
    /// so the two can never drift apart - an arithmetic slip there is a header wrapped onto two lines.
    private static let gap: CGFloat = 6
    /// The clear space the clock cluster's leading spacer never gives up, so the switch and the clock
    /// read as two things rather than one run-on strip.
    private static let clockLead: CGFloat = 8

    var header: some View {
        HStack(spacing: Self.gap) {
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
                    .tallyTooltip(ready ? L("Update downloaded - click to restart")
                                : L("Update available - click to install"))
                }
            }
            // Held at its ideal width, which is both what it is owed - the product's name and the
            // one nudge that has to be seen to be clicked - and what makes the measurement below
            // true: a cluster free to compress reports the width it was squeezed into, so the row
            // would read "the clock still fits" from a number the clock itself caused.
            .fixedSize(horizontal: true, vertical: false)
            .padding(.leading, 12)
            .frame(maxHeight: .infinity)
            .background(WindowDragArea())
            .background { widthProbe { headerWidths.brand = $0 } }
            // Straight after the wordmark, the way a product names its own screens. Every surface
            // carries it: the pinned panel is where someone watches usage all day, and making them
            // open a different window to see where the tokens went broke that. Not in the footer
            // with the view controls - this switches WHAT the surface is showing, not how it looks.
            surfaceTabPicker
            HStack(spacing: Self.gap) {
                Spacer(minLength: Self.clockLead)
                // TimelineView re-evaluates every second so the countdown ticks live (a plain
                // render would freeze it at whatever it said on open). Hierarchy: the date is the
                // anchor the absolute reset times are read against, so it leads; the countdown is
                // a heartbeat, so it dims - and is the first thing dropped when the row is tight.
                if clockDetail != .hidden {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(spacing: Self.gap) {
                            clockText(UsageFormat.nowShort(context.date))
                            if clockDetail == .full,
                               let counter = store.isRefreshing
                                ? L("refreshing…")
                                : UsageFormat.updatesIn(store.nextRefreshAt, now: context.date) {
                                counterSlot(counter)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .background(WindowDragArea())
            // One refresh for both tabs, because the header frames both: on Tokens it rescans the
            // transcripts rather than re-polling the quota. A button that silently drove the other
            // tab's store would look broken - the numbers under it would not move.
            Button {
                switch tab {
                case .usage: Task { await store.refresh(userInitiated: true) }
                case .tokens: tokens.refresh()
                }
            } label: {
                // A hand-rolled rotation cannot end cleanly: animating back after an interrupted
                // repeatForever unwinds the arrow (a visible bob), and a nil animation does not
                // cancel an in-flight repeat (the arrow spins forever). Swap to the native
                // spinner while refreshing instead - no custom animation to get wrong.
                Group {
                    if isRefreshing {
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
            .disabled(isRefreshing)
            .accessibilityLabel(L("Refresh"))
            .tallyTooltipAroundControl(L("Refresh"))
            .padding(.trailing, 12)
            .background { widthProbe { headerWidths.refresh = $0 } }
        }
        .frame(height: 40)
        .background(alignment: .topLeading) { clockProbes }
    }

    /// Whichever store the visible tab reads from, so the spinner and the disabled state describe
    /// the work the click actually started. The quota poll keeps its own schedule while the Tokens
    /// tab is up, so this is about which one the button is for, not which one is allowed to run.
    private var isRefreshing: Bool { tab == .tokens ? tokens.isScanning : store.isRefreshing }

    /// Same control the footer uses for the meters, in the same size: two words, both always legible,
    /// so the alternative view advertises itself instead of hiding behind an icon. Sized to its text
    /// and placed before the flexible part of the header, so the clock beside it keeps the width it
    /// reserves for its widest string even in the narrowest single-column panel.
    private var surfaceTabPicker: some View {
        NeutralSegmentedPicker(selection: $tabState.tab,
                               options: SurfaceTab.allCases,
                               size: .mini) { $0.label }
            .background { widthProbe { headerWidths.picker = $0 } }
    }

    /// What fits beside the switch. A 380pt single column, an update badge and a language whose two
    /// tab words are long (Japanese) together want more than the row has, and the clock is the only
    /// part that may give: unmeasured parts read 0, which trims everything, because a clock one frame
    /// late beats a header wrapped onto two lines.
    private var clockDetail: HeaderClock {
        let parts = headerWidths
        guard parts.brand > 0, parts.picker > 0, parts.refresh > 0,
              parts.clock > 0, parts.counter > 0 else { return .hidden }
        // What the row owes before the clock: both end clusters (each measured with its own outer
        // padding), the switch, and the three gaps between the four children.
        let rigid = parts.brand + parts.picker + parts.refresh + 3 * Self.gap
        let withClock = rigid + Self.clockLead + Self.gap + parts.clock
        if withClock + Self.gap + parts.counter <= popoverWidth { return .full }
        if withClock <= popoverWidth { return .clockOnly }
        return .hidden
    }

    /// Unrendered, unlaid-out copies of the clock and its counter slot: a background is sized by its
    /// host, not the other way round, so these occupy no part of the row and their widths are known
    /// even in the frames where the real ones are trimmed away - measuring the live pair could only
    /// ever confirm the decision it is already the result of.
    private var clockProbes: some View {
        HStack(spacing: 0) {
            // Any instant will do: the clock's format is fixed-width and its digits are monospaced,
            // so every value it can ever show measures the same.
            clockText(UsageFormat.nowShort(Date(timeIntervalSince1970: 0)))
                .background { widthProbe { headerWidths.clock = $0 } }
            counterSlot(nil)
                .background { widthProbe { headerWidths.counter = $0 } }
        }
        .hidden()
    }

    private func clockText(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium)).monospacedDigit()
            .foregroundStyle(.primary)
    }

    /// The counter's string width changes every second; hidden templates (the widest forms,
    /// localized) reserve a fixed slot so the ticking never pushes the date around. Trailing-aligned
    /// to hug the button. Passing no counter leaves the bare reservation, which is what the probe
    /// above measures.
    private func counterSlot(_ counter: String?) -> some View {
        ZStack(alignment: .trailing) {
            ForEach(UsageFormat.updatesInTemplates, id: \.self) {
                Text($0).hidden()
            }
            if let counter { Text(counter) }
        }
        .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
    }
}
