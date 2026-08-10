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
            // EVERY part of this row moves the panel, and each part says how: the runs with nothing
            // to click move it from the first frame of the press, the controls (the update badge,
            // the tab switch, the refresh) move it only once the press has travelled far enough to
            // not be a click. Laid OVER each region rather than behind it, which is the correction
            // of 2026-08-07: mounted behind, the drag layer was never sent a press at all and this
            // row's wordmark, badges and clock were dead to the pointer while reading as handles.
            //
            // The brand cluster is split for that reason: the wordmark, the version and the DEV tag
            // are one continuous grab area (its own internal gaps included), and the update badge
            // sits beside them keeping its click.
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                // The logotype (brand T as the initial) - a bare glyph next to the word "Tally"
                // read as two Ts. The header is the product's line; the jetto credit lives quietly
                // in the footer's empty centre instead of trailing the wordmark like a byline.
                TallyWordmarkView(glyphHeight: 13)
                // Against the wordmark, which is the whole point of it being here rather than in
                // the footer: trailing the jetto byline it read as the BYLINE's version, and no
                // amount of reordering that line fixed whose number it was. Beside the product's
                // own name it can only be read one way. Not localized: a dotted version is a token.
                if let version = BuildVariant.version {
                    Text(version).font(.caption2).foregroundStyle(.tertiary)
                }
                // The dev variant tags every surface (menu bar strip + panel header), so a test
                // instance can never be mistaken for the installed app.
                if BuildVariant.isDev {
                    TallyDevTagView()
                }
                }
                // The leading padding is inside the grab area on purpose: the margin that seats the
                // wordmark on the panel's content line is space nothing else claims, so it may as
                // well be somewhere to take hold of.
                .padding(.leading, PanelGeometry.brandLead)
                .frame(maxHeight: .infinity)
                .windowDragSurface()
                // Docker-style nudge, two states: detected (accent ↑, click walks the install
                // flow) and downloaded (green ↻, the Ghostty semantic - the payload is on disk,
                // a click just restarts into the new version).
                if let version = UpdateAvailability.shared.version {
                    let ready = UpdateAvailability.shared.isDownloaded
                    Button {
                        UpdaterController.shared.installNow()
                    } label: {
                        Text(verbatim: "\(ready ? "↻" : "↑") \(version)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(ready ? TallyColor.normal : TallyColor.ai))
                    }
                    .buttonStyle(.plain)
                    // A control, so it takes the travelling form: the badge still installs on a
                    // click and the panel still moves if the hand meant to move it.
                    .windowDragOrTap { UpdaterController.shared.installNow() }
                    .tallyTooltip(ready ? L("Update downloaded - click to restart")
                                : L("Update available - click to install"))
                }
            }
            // Held at its ideal width, which is both what it is owed - the product's name and the
            // one nudge that has to be seen to be clicked - and what makes the measurement below
            // true: a cluster free to compress reports the width it was squeezed into, so the row
            // would read "the clock still fits" from a number the clock itself caused.
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxHeight: .infinity)
            .background { widthProbe { headerWidths.brand = $0 } }
            // The slack on the switch's leading side, which is new: the row used to give all of it
            // to the clock, so the switch sat against the wordmark. A grab area like the slack on
            // the other side, or the pinned panel would lose half the strip it has always had.
            Spacer(minLength: Self.gap)
                .frame(maxHeight: .infinity)
                .windowDragSurface()
            // Every surface carries it: the pinned panel is where someone watches usage all day,
            // and making them open a different window to see where the tokens went broke that. Not
            // in the footer with the view controls - this switches WHAT the surface is showing, not
            // how it looks.
            //
            // CENTRED ON THE HEADER, not between its neighbours, which are different points because
            // the two end clusters are never the same width. Two equal spacers would centre it
            // between them and it would drift with every change to either end - the mark that has
            // missed its mark the footer credit was moved for. The offset below pays the difference
            // to whichever side is short.
            surfaceTabPicker
                .padding(.leading, centreOffset.leading)
                .padding(.trailing, centreOffset.trailing)
                // The centring pad is the last unclaimed space in the row, and it is not small: it
                // is whatever the wider end of the header owes the switch. Grabbed by a strip the
                // exact width of the pad, at the edge the pad is on, so the switch itself is never
                // covered by it (an overlay over the padded whole would sit on the segments and
                // take their clicks - which is the mistake this row is being repaired from).
                .overlay(alignment: .leading) { dragPad(centreOffset.leading) }
                .overlay(alignment: .trailing) { dragPad(centreOffset.trailing) }
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
            // Held at its ideal width, for the reason the brand cluster is: a cluster free to
            // compress absorbs whatever the row over-committed elsewhere, and what it absorbs it
            // pays for by wrapping - which is the one thing this header may never do.
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxHeight: .infinity)
            .windowDragSurface()
            // One refresh for both tabs, because the header frames both: on Tokens it rescans the
            // transcripts rather than re-polling the quota. A button that silently drove the other
            // tab's store would look broken - the numbers under it would not move.
            Button {
                startRefresh()
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
            // The other end of the header's grab strip: on the pinned panel a press that travels
            // moves the window, and one that does not is the refresh it always was. The overlay is
            // above a DISABLED control here, which is why the tap path asks the same question the
            // modifier above does rather than trusting SwiftUI to have stopped it.
            .windowDragOrTap { startRefresh() }
            .accessibilityLabel(L("Refresh"))
            .tallyTooltipAroundControl(L("Refresh"))
            .padding(.trailing, 12)
            .background { widthProbe { headerWidths.refresh = $0 } }
        }
        .frame(height: 40)
        .background(alignment: .topLeading) { clockProbes }
    }

    /// One refresh, reached two ways: the button's own action and the press that turned out not to
    /// be a window move. Stated once so the second entrance cannot drift into refreshing a different
    /// tab than the first, and it carries the guard the button expresses with `.disabled` - an
    /// overlay is not a SwiftUI control and nothing stops it on the caller's behalf.
    private func startRefresh() {
        guard !isRefreshing else { return }
        switch tab {
        case .usage: Task { await store.refresh(userInitiated: true) }
        case .tokens: tokens.refresh()
        }
    }

    /// A grab area exactly as wide as one side's centring pad, full height. Zero-width when that
    /// side owes nothing, which is most rows.
    private func dragPad(_ width: CGFloat) -> some View {
        Color.clear
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .windowDragSurface()
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
                               size: .mini,
                               dragsWindow: true) { $0.label }
            .background { widthProbe { headerWidths.picker = $0 } }
    }

    /// What the switch has to be padded by to sit at the ROW's centre rather than at the midpoint
    /// between its neighbours: the difference between the two end clusters, paid to the short side.
    ///
    /// Zero when the row cannot afford it, and that is the trimming order the header already ranks
    /// by: the ends are identity and the only controls, so a centred switch is the first thing to
    /// go. Giving it up costs a switch that sits off-centre; taking the space anyway would cost an
    /// overlap, and at these widths an overlap is a switch drawn on top of the clock.
    ///
    /// Unmeasured parts read 0, which pays nothing - a switch one frame off-centre beats a header
    /// that jumps while its own measurements settle.
    private var centreOffset: (leading: CGFloat, trailing: CGFloat) {
        let parts = headerWidths
        guard parts.brand > 0, parts.picker > 0, parts.refresh > 0 else { return (0, 0) }
        let leftEnd = parts.brand
        let rightEnd = parts.refresh + clockZoneWidth
        // Centring costs the WIDER end twice over, plus the switch and the minimum slack either
        // side of it. Asked of the same numbers the layout uses, so the two cannot disagree about
        // whether it fits.
        // CLAMPED TO THE SLACK THAT ACTUALLY EXISTS, which the first version was not: it asked
        // whether the centred row would fit and then took the whole difference, and the row has no
        // way to refuse. The spacers collapse to their minimums and the overflow lands on the only
        // child that can absorb it - the clock, which wrapped onto three lines (seen in the first
        // capture). An off-centre switch is a compromise; a wrapped header is a broken one.
        let slack = popoverWidth - (leftEnd + parts.picker + rightEnd + Self.gap + Self.clockLead)
        let owed = min(abs(leftEnd - rightEnd), max(0, slack))
        return (rightEnd > leftEnd ? owed : 0, leftEnd > rightEnd ? owed : 0)
    }

    /// How much of the row the clock cluster is occupying right now, which is what the trimming
    /// below has already decided. Read by the centring above so it measures the row as drawn.
    private var clockZoneWidth: CGFloat {
        switch clockDetail {
        case .full: return Self.clockLead + headerWidths.clock + Self.gap + headerWidths.counter
        case .clockOnly: return Self.clockLead + headerWidths.clock
        case .hidden: return 0
        }
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
        // padding), the switch, the gaps between the children, and the slack the switch's own
        // leading spacer never gives up (new with the centred switch, and the clock is measured
        // against the row it is actually in).
        let rigid = parts.brand + parts.picker + parts.refresh + 3 * Self.gap + Self.gap
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
