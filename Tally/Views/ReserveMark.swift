import SwiftUI

/// THE TWO PLACES A RESERVE IS DRAWN, in one file because they must look like the same fact: the
/// water line on a usage bar, and the strip in Settings that sets it. One hatching serves both
/// (`ReserveHatch`), so what somebody clicks here is the texture they then recognise on the bar.
/// Tally/Core/AccountReserve.swift owns what the number means.
///
/// THE WATER LINE ON A USAGE BAR: where the personal account's reserve starts, and the stretch below
/// it hatched out.
///
/// WHICH BARS GET ONE IS THE CALLER'S ANSWER, not this view's: the reserve is held back from the
/// two windows the account shares with the user's browser - its weekly all-models one and its 5h
/// one - so the meters hand this a zero on every other bar (`PersonalAccount.reserved`). Drawing it
/// everywhere would put a line on windows no pick treats as reserved.
///
/// AN ABSOLUTE POSITION ON THE TRACK, not a second fill. The track is the whole quota, 0% spent at
/// the left edge and 100% at the right, and a reserve of 30 says "leave 30% standing" - so the line
/// sits at 70% of the width whichever way the bar is filled. That is what lets one mark serve both
/// display modes: used fills from the left and remaining anchors right (`UsageFormat.fillFraction`),
/// but they split the same track at the same boundary, so the reserve's own boundary does not move
/// when the mode does.
///
/// WHY BOTH A LINE AND HATCHING. The line alone reads as a target on a bar whose fill has not
/// reached it; the hatching alone reads as texture. Together they say the thing the feature is: this
/// part of the bar is not Tally's to spend.
///
/// Drawn as an OVERLAY on the track rather than replacing it, so a bar that has spent into the
/// reserve (which naming the account explicitly still allows - the reserve only binds Tally's own
/// choices) shows the fill underneath the hatching rather than losing it.
struct ReserveMark: View {
    /// 0-100. Nothing at all is drawn at zero, which is what every unmarked account has.
    let reserve: Int

    var body: some View {
        if reserve > 0 {
            GeometryReader { geo in
                let fraction = min(max(Double(reserve), 0), 100) / 100
                let start = geo.size.width * (1 - fraction)
                ZStack(alignment: .topLeading) {
                    ReserveHatch()
                        .frame(width: geo.size.width - start)
                        // Clipped where it is DRAWN, before it is moved: the sweep deliberately
                        // starts one slant early so the corner is covered rather than left bare, and
                        // a stroke is not bounded by the frame it was given - so without this the
                        // hatching begins a few points to the left of the very line it is marking.
                        .clipped()
                        .offset(x: start)
                    Rectangle()
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: 1)
                        .offset(x: start)
                }
                // SIZED TO THE TRACK BEFORE IT IS CLIPPED, which is not a tidy-up: a ZStack takes
                // the size of its children, both of these are then moved into place with `offset`
                // (which moves what is drawn and not what was laid out), and the clip that follows
                // would otherwise be a capsule the width of the reserve sitting at the left end of
                // the bar - cutting away every mark this view exists to draw. It rendered as
                // nothing at all, in both densities (measured 2026-08-20).
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                // Clipped to the track's own shape: a capsule's ends curve away, and a hatch drawn
                // square over them spills past the bar it is describing.
                .clipShape(Capsule())
            }
            .allowsHitTesting(false)
        }
    }
}

/// THE HATCHING ITSELF: one texture, one ink, one weight, wherever a reserve is drawn.
///
/// A view rather than two constants each caller strokes with, because "the same hatching" is the
/// whole claim the strip in Settings makes about the bar upstairs, and a claim spelled twice is one
/// somebody eventually re-tunes on one side only.
private struct ReserveHatch: View {
    var body: some View {
        DiagonalHatch().stroke(Color.primary.opacity(0.28), lineWidth: 0.75)
    }
}

/// THE TEN CELLS THAT SET IT, in the Settings row under the marked account.
///
/// WHY A STRIP AND NOT A STEPPER (which it replaces): the reserve is a rough "leave me some room"
/// figure, and the stepper made reaching one a count of presses with nothing on screen saying how
/// far along the scale the number was. Ten cells ARE the scale - the whole range is visible, any
/// value on it is one click away, and the hatching says what the filled part means without a word.
///
/// THE DECISIONS ARE NOT IN HERE. Which cell a point is in, how much of one a value fills, what a
/// press means and where a step lands are all in `ReserveStrip`, where they can be checked without
/// a pointer; this view is the pixels and the gestures over those answers.
struct ReserveCellBar: View {
    /// 0-100, as stored.
    let value: Int
    /// Called with the percentage to store, only ever a multiple of the step.
    let set: (Int) -> Void

    private static let cellWidth: CGFloat = 12
    private static let cellHeight: CGFloat = 11
    private static let gap: CGFloat = 2
    /// Fixed: in its row the sentence is the flexible half and this is not.
    private static let width = CGFloat(ReserveStrip.cells) * cellWidth
        + CGFloat(ReserveStrip.cells - 1) * gap

    /// Read rather than passed, so the caller keeps saying `.disabled(...)` about it in the one
    /// vocabulary every other control in the pane uses.
    @Environment(\.isEnabled) private var isEnabled
    /// The cell under the pointer, 1-based. Preview highlight only - it sets nothing, and it is the
    /// drawing that asks whether the strip is live, so there is one place that decides.
    @State private var hovered: Int?
    /// The value the press began on, and nil whenever no press is in flight. This is what makes a
    /// second click on the cell already filled a clear rather than a no-op: by the time the press
    /// ends the live value has already followed the pointer, so the value alone cannot say so.
    @State private var pressStart: Int?
    /// Whether this press left the cell it started on. A sweep sets what it ends on; only a press
    /// that stayed put may clear.
    @State private var swept = false
    /// True while a press is tracking, and the ONLY hook a cancelled gesture guarantees:
    /// @GestureState resets on cancellation as well as on end, where `onEnded` is skipped entirely.
    ///
    /// The two @State values above are this press's scratch space, and a press that is cancelled
    /// rather than ended would leave them behind: `swept` stuck true makes the next press unable to
    /// clear (the strip's only route back to zero), and a stale `pressStart` makes it judge that
    /// press against a value it never started from. Cancellation is not hypothetical here - this
    /// row is built inside the pane's `ForEach` under an `if isPersonal`, so a refresh that moves
    /// the account list mid-press tears the view down, which is exactly the teardown that leaked a
    /// floating card preview forever on 2026-07-17 (PopoverRootView, SessionBoardReorder: this is
    /// the third copy of their guard, deliberately spelled the same way).
    @GestureState private var pressing = false

    var body: some View {
        HStack(spacing: Self.gap) {
            ForEach(1 ... ReserveStrip.cells, id: \.self, content: cell)
        }
        .frame(width: Self.width, height: Self.cellHeight)
        // The strip takes the press, not each cell: a sweep must cross the gaps between them
        // without being dropped by one.
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.45)
        .onContinuousHover { phase in
            if case .active(let point) = phase {
                hovered = cellIndex(atX: point.x)
            } else {
                hovered = nil
            }
        }
        .gesture(press)
        // Cancellation safety net, mirroring the two card grids: @GestureState resets on cancel as
        // well as on end, which is the only hook a cancelled gesture guarantees.
        .onChange(of: pressing) { _, active in if !active { endPress() } }
        .onDisappear { endPress() }
        // NOT FOCUSABLE, and that is the whole of it: nothing here takes the keyboard.
        //
        // It was, for the arrow keys - and being the first focusable thing in the pane, it wore a
        // blue ring the moment Settings opened, on a row most people are not here for (reported
        // from the built app, 2026-08-21). `focusEffectDisabled()` is NOT the fix: it hides the ring
        // and keeps the focus, so the strip would go on swallowing arrow keys invisibly. The keys
        // go instead; the pointer sets this, and VoiceOver has its own way in below.
        //
        // One element with a value, not ten cells to arrow through: what a screen reader is being
        // asked here is a percentage. The LABEL is the meter's own words for the same texture, so
        // the two surfaces are read out alike and this invents no string to translate; the VALUE is
        // a number rather than a sentence, so it is formatted for the reader's locale instead of
        // spelled with a percent sign of ours. The adjustable action is an accessibility affordance,
        // not a key handler - VoiceOver drives it through its own cursor, which is why
        // `ReserveStrip.nudged` still has a caller.
        .accessibilityElement()
        .accessibilityLabel(Text(L("Kept for web use")))
        .accessibilityValue(Text(value.formatted(.percent)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(up: true)
            case .decrement: nudge(up: false)
            @unknown default: break
            }
        }
        .help(L("Kept for web use"))
    }

    private func cell(_ index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        let covered = ReserveStrip.fill(value, cell: index)
        return ZStack(alignment: .leading) {
            shape.fill(Color.primary.opacity(hovered == index && isEnabled ? 0.16 : 0.07))
            if covered > 0 {
                ReserveHatch()
                    .frame(width: Self.cellWidth * covered)
                    // A stroke is not bounded by the frame it was given (the water line above says
                    // what that cost there), so a half-covered cell would hatch the whole of it.
                    .clipped()
            }
        }
        .frame(width: Self.cellWidth, height: Self.cellHeight)
        .clipShape(shape)
        .overlay(shape.stroke(Color.primary.opacity(0.16), lineWidth: 0.5))
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($pressing) { _, state, _ in state = true }
            .onChanged { move in
                guard isEnabled else { return }
                let here = cellIndex(atX: move.location.x)
                if pressStart == nil { pressStart = value }
                // A SWEEP IS A PRESS THAT REACHED ANOTHER CELL, which is what the word means here,
                // rather than one that travelled some number of points. A distance threshold has to
                // name a number, and every number is wrong somewhere: 2pt called a hand tremor a
                // sweep and silently cost that click its clearing (found in review of 8482bcb),
                // while a threshold loose enough to survive a tremor would let a real drag inside a
                // wide cell pass as a still press. A cell boundary is a line that already means
                // something to the user, and crossing one is visible on screen as it happens.
                //
                // Asked of the gesture's OWN start point rather than a cell remembered in state:
                // one less thing that a cancelled press could leave behind stale.
                if here != cellIndex(atX: move.startLocation.x) { swept = true }
                // Live, and never a clear: a press still moving has not said what it means yet, so
                // only the end of one is allowed to ask `pressed`.
                apply(ReserveStrip.percent(cell: here))
            }
            .onEnded { move in
                defer { endPress() }
                guard isEnabled, let start = pressStart else { return }
                apply(ReserveStrip.pressed(cell: cellIndex(atX: move.location.x),
                                           from: start, swept: swept))
            }
    }

    /// This press's scratch space, dropped. Called from the end of a press AND from the reset of
    /// `pressing`, because only the second of those is reached when a press is cancelled.
    private func endPress() {
        pressStart = nil
        swept = false
    }

    /// One write per cell actually crossed. `setReserve` persists, so an unguarded sweep would be a
    /// write to disk per pointer sample.
    private func apply(_ percent: Int) { if percent != value { set(percent) } }

    private func cellIndex(atX x: CGFloat) -> Int {
        ReserveStrip.cell(atX: x, cellWidth: Self.cellWidth, gap: Self.gap)
    }

    /// VoiceOver's one step. No key handler reaches this: the strip does not take the keyboard.
    private func nudge(up: Bool) {
        guard isEnabled else { return }
        apply(ReserveStrip.nudged(value, up: up))
    }
}

/// Evenly spaced diagonal strokes across the rect, slanting the way a "not available" fill
/// conventionally does. `slant` is the horizontal run of one stroke over the full height, so the
/// angle stays the same whether it is drawn on a card's 7pt bar, a list row's 4pt one or a Settings
/// cell; the sweep starts one slant early and ends one late so the corners are covered rather than
/// clipped bare.
private struct DiagonalHatch: Shape {
    func path(in rect: CGRect) -> Path {
        let spacing: CGFloat = 3
        var path = Path()
        let slant = rect.height
        var x = rect.minX - slant
        while x < rect.maxX + slant {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + slant, y: rect.minY))
            x += spacing
        }
        return path
    }
}
