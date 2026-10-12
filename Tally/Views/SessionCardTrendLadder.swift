import SwiftUI

// WHICH CANDIDATE THE TREND ROW TAKES, decided on a copy of the row that holds its widths and
// nothing else (TALLY-8Z). The row used to be a `ViewThatFits` over seven full candidates, each
// with three sparklines and up to six rolling figures, and every one of those is fed a reading
// that changes every two seconds: so every tick invalidated the ladder and it instantiated and
// measured all seven candidates again, NSViews included, on every card on the board. Measured
// on the demo board that was the largest single block of main-thread layout.
//
// The widths of a candidate do not move with the readings: the sparkline is a fixed frame
// (`FootprintSparklineView.size`), the figures sit in columns pinned to their widest reading
// (`SessionCardView.column`), and under `.monospacedDigit()` a digit is a digit. So the ladder is
// measured here on a `TrendShape` that only changes when a width can, and the row a reader sees
// is drawn once, for the rung this chose (`SessionCardView.sessionFootprintTrends`).
extension SessionCardView {

    /// One rung of the ladder: how many ceilings and which quiet words a candidate keeps.
    struct TrendRung: Equatable {
        let peaks: Int
        let asides: TrendAsides
    }

    /// The ladder, widest first, in the order `sessionFootprintTrends` explains: the ceilings go
    /// one at a time, then the unit word, then one name, then the other.
    static let trendRungs: [TrendRung] = [
        TrendRung(peaks: 3, asides: .all),
        TrendRung(peaks: 2, asides: .all),
        TrendRung(peaks: 1, asides: .all),
        TrendRung(peaks: 0, asides: .all),
        TrendRung(peaks: 0, asides: .culpritsOnly),
        TrendRung(peaks: 0, asides: .memoryCulpritOnly),
        TrendRung(peaks: 0, asides: .none),
    ]

    /// Everything a candidate's WIDTH is made of, and nothing that only changes what is drawn.
    /// Equal from one tick to the next unless a width can have changed, which is what lets the
    /// ladder skip the measurement.
    struct TrendShape: Equatable {
        struct Group: Equatable {
            let metric: FootprintTrendMetric
            /// Whether a line is drawn, which is also whether the ceiling column is held.
            let drawsLine: Bool
            /// The figure with its digits masked (`FootprintTrendMetric.widthClass`).
            let figure: String
            let aside: String?
            /// The ceiling as spelled, arrow included, digits masked.
            let peak: String
        }
        let groups: [Group]
        /// The leftovers' count, digits masked, or nothing when there is no mark.
        let leftovers: String?
        let leftoversFlamed: Bool
    }
}

/// The ladder itself: seven hidden copies of the row's widths, each measured once for its width,
/// and the room the card gives the row. It publishes the first rung that fits, or the last when
/// none does, which is the choice a `ViewThatFits` made.
///
/// NOT A `ViewThatFits` (TALLY-8Z): the card is laid out again on every reading, and a
/// `ViewThatFits` measures all seven candidates on every pass, on every card. Here a candidate's
/// width is read when it changes, which is when the shape does.
struct SessionCardTrendLadder: View, Equatable {
    let shape: SessionCardView.TrendShape
    @State private var widths: [Int: CGFloat] = [:]
    @State private var room: CGFloat = 0

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.shape == rhs.shape }

    /// The rung the ladder took; nothing at all (nothing measured yet) reads as the last rung.
    struct Chosen: PreferenceKey {
        static let defaultValue: Int? = nil
        static func reduce(value: inout Int?, nextValue: () -> Int?) { value = value ?? nextValue() }
    }

    private var chosen: Int {
        SessionCardView.trendRungs.indices.first { (widths[$0] ?? .infinity) <= room }
            ?? SessionCardView.trendRungs.count - 1
    }

    /// Sized by the chosen candidate, as a `ViewThatFits` is: the rungs are not all one height (a
    /// ceiling's arrow sits taller than a digit), so the measuring copies stay in the background.
    var body: some View {
        candidate(chosen)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { room = $0 }
            .background(alignment: .leading) {
                ZStack(alignment: .leading) {
                    ForEach(SessionCardView.trendRungs.indices, id: \.self) { index in
                        candidate(index).fixedSize(horizontal: true, vertical: false)
                            .onGeometryChange(for: CGFloat.self, of: \.size.width) { widths[index] = $0 }
                    }
                }
            }
            .preference(key: Chosen.self, value: chosen)
    }

    /// One candidate, built the way `SessionCardView.trendRow` is built, piece for piece: the same
    /// stacks, gaps, columns and font. A piece added to that row has to be added here too, or the
    /// ladder will choose for a row that is not the one drawn (tests/supervisor/
    /// footprinttrendsurfacechecks.swift holds the two to the same pieces).
    private func candidate(_ index: Int) -> some View {
        let rung = SessionCardView.trendRungs[index]
        let named = Set(SessionCardView.peakOrder.prefix(rung.peaks))
        return HStack(spacing: SessionCardView.trendGap) {
            ForEach(shape.groups, id: \.metric) { group in
                HStack(spacing: SessionCardView.trendSpacing) {
                    if group.drawsLine {
                        Color.clear.frame(width: FootprintSparklineView.size.width,
                                          height: FootprintSparklineView.size.height)
                    }
                    SessionCardView.column(group.metric.widestFigure) {
                        Text(verbatim: group.figure)
                    }
                    if let aside = group.aside, rung.asides.keeps(group.metric) {
                        Text(verbatim: aside)
                    }
                    if named.contains(group.metric), group.drawsLine {
                        SessionCardView.column(FootprintPeak.mark + group.metric.widestFigure) {
                            Text(verbatim: group.peak)
                        }
                    }
                }
            }
            // The leftovers' mark as wide as `SessionLeftoversMark` draws it, without its tooltip:
            // a second live mark would publish into the one preview slot the capture flag reads.
            if let count = shape.leftovers {
                HStack(spacing: SessionCardView.trendSpacing) {
                    Image(systemName: "circle.dashed")
                    Text(verbatim: count)
                    if shape.leftoversFlamed { SessionCardView.flameMark }
                }
                .lineLimit(1).fixedSize()
            }
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
        .hidden()
    }
}
