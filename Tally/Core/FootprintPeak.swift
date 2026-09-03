import Foundation

/// THE CEILING OF A WINDOW: how a card spells it, and what its dot does between two readings.
///
/// SPLIT OFF THE SHAPE ITSELF (`FootprintTrend.swift`) on the 500 line rule, along the seam that
/// rule found: everything next door is one series read at ONE instant, and the motion here is one
/// series read at TWO. The dot's rule stays an extension of the shape's own type, so nothing that
/// consumed it changed.
enum FootprintPeak {
    /// WHAT MARKS A FIGURE AS THE CEILING rather than as the current reading. A glyph rather than
    /// the word, because "peak" three times costs about a third of the card's width and that row
    /// holds three of everything; the word itself is what VoiceOver is given instead
    /// (`SessionCardTrendRow.spokenTrends`).
    static let mark = "\u{2191}"

    /// HOW A CEILING IS SPELLED WHEREVER IT IS DRAWN, and the reason it is a function: the row
    /// prints it twice, once as the `Text` that measures the column and once as the string handed
    /// to the motion, and under the default roller the `Text` is HIDDEN and what a reader sees is
    /// the second one (`FigureRoller.layers`). Written out at both, the two drifted the day they
    /// were introduced: the motion was handed the bare number, so every ceiling on the board lost
    /// its arrow while every assertion stayed green (codex review of 40054b3).
    ///
    /// Nothing at all where there is no ceiling to print, the column being held either way: a peak
    /// is hidden exactly when the newest reading has just become the highest of the window, so a
    /// column that came and went would take the group beside it along on every climb.
    static func spelled(_ peak: String?) -> String { peak.map { mark + $0 } ?? "" }
}

/// WHAT THE PEAK DOT DOES BETWEEN TWO READINGS OF ONE SERIES, which is the one question about this
/// figure that its arithmetic cannot answer on its own: the dot marks A READING, and whether two
/// series hold the same reading is a fact about the window's history rather than about the numbers
/// in them (`FootprintTrendSeries.record`).
extension FootprintSparkline {
    /// Whether the peak dot has anywhere to travel FROM, between two series: the same reading is
    /// still the highest one, so the dot has one point to slide between, or a different reading has
    /// taken the ceiling (or given it up, or there was none before), and there is no single path
    /// between two unrelated readings that would read as motion rather than as a dot cutting across
    /// the figure (codex review of c99f4a6, where the dot tweened `position` between two peaks that
    /// were not the same reading).
    enum PeakMotion: Equatable {
        /// The peak is the same reading in both series: slide the dot from where it was.
        case move
        /// The peak moved to a different reading, or appeared, or vanished: fade the old dot out
        /// where it stood and the new one in where it now stands, rather than sliding between them.
        case crossfade
    }

    /// THE SERIES AS A CARD DRAWS IT: the kept readings with this instant's own on the end, so
    /// the line ends where the figure beside it says the session is, or nothing at all while there
    /// are too few kept ones to be a line (`SessionCardView.sessionFootprintTrendGroups`). Spelled
    /// here, next to the rule it matters most to, because the live reading is never kept: any
    /// fixture that judges the peak's motion off the ring alone is judging a shape no card draws
    /// (codex review of c2a932d).
    static func drawn(_ readings: [Double], now: Double?) -> [Double] {
        readings.count >= minimumReadings ? readings + [now].compactMap { $0 } : []
    }

    /// WHICH MOTION THE DOT ARRIVES ON, asked of the two series and of how far the window slid
    /// between them.
    ///
    /// THE INDEX ALONE IS NOT AN IDENTITY, which is the whole of why `shifted` is here (codex
    /// review of 36b653b). Once the window is full every kept reading moves one place left on every
    /// tick, so the reading that is still the ceiling is at a DIFFERENT index and a comparison of
    /// bare indices would say `.crossfade` on every tick of a full window, which is every session
    /// past its first quarter of an hour. It fails the other way too: a new reading landing on the
    /// old peak's index is a different reading being slid to as though it were the same one.
    ///
    /// TOLD, NOT READ OFF THE READINGS. A first version searched the two series for the overlap
    /// the ring's rolling leaves, and never found it: the series a card draws ends in a live
    /// reading the ring never keeps, so the two disagreed at every offset and every peak under a
    /// moving line faded when it should have slid (codex review of c2a932d, `[1, 9, 3]` to
    /// `[1, 9, 4]` read as three readings gone). The series knows how far it slid
    /// (`FootprintTrendSeries.origin`), and that is what is asked.
    ///
    /// - Parameter shifted: how many readings left the window's oldest end between the two, the
    ///   difference of the two series' `origin`. Zero for a window still filling, and for the
    ///   hand-written pairs that state this rule at one length; negative is a different series
    ///   altogether (a session's history begun again), which holds no reading in common.
    static func peakMotion(from previous: [Double], to values: [Double],
                           shifted: Int = 0) -> PeakMotion {
        guard shifted >= 0, let was = peakIndex(previous), let now = peakIndex(values),
              was - shifted == now else { return .crossfade }
        return .move
    }
}
