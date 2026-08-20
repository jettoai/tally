import SwiftUI

/// THE WATER LINE ON A USAGE BAR: where the personal account's reserve starts, and the stretch below
/// it hatched out (Tally/Core/AccountReserve.swift owns what the number means).
///
/// WHICH BAR GETS ONE IS THE CALLER'S ANSWER, not this view's: the reserve is held back from the
/// weekly all-models window alone, so the meters hand this a zero on every other bar
/// (`PersonalAccount.reserved`). Drawing it everywhere would put a line on windows no pick treats as
/// reserved.
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
                    DiagonalHatch()
                        .stroke(Color.primary.opacity(0.28), lineWidth: 0.75)
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

/// Evenly spaced diagonal strokes across the rect, slanting the way a "not available" fill
/// conventionally does. `slant` is the horizontal run of one stroke over the full height, so the
/// angle stays the same whether it is drawn on a card's 7pt bar or a list row's 4pt one; the sweep
/// starts one slant early and ends one late so the corners are covered rather than clipped bare.
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
