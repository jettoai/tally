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

    /// HOW MANY OF THE OLDEST READINGS LEFT THE WINDOW between one series and the next.
    ///
    /// READ FROM THE READINGS THEMSELVES, because the two series are the whole of what a figure is
    /// handed: nothing tells the drawing side how many readings arrived. The ring appends until it
    /// is full and only then drops from the front (`FootprintTrendSeries.record`), so the older
    /// series' tail IS the newer one's head, and how far along the older series that overlap starts
    /// is how many readings fell off. Nothing at all while the window is still filling, which is
    /// what makes this free on a session's first quarter of an hour.
    ///
    /// THE SMALLEST SUCH OFFSET IS THE ANSWER: one dropped and one gained is the ordinary tick, and
    /// a longer match would be reading a coincidence in the numbers as history. No overlap at all
    /// is every reading the older series held, which is what a series that starts again after a
    /// sleep looks like (`FootprintTrendSeries.isStale`).
    static func dropped(from previous: [Double], to values: [Double]) -> Int {
        (0 ..< previous.count).first {
            previous.dropFirst($0).elementsEqual(values.prefix(previous.count - $0))
        } ?? previous.count
    }

    /// WHICH MOTION THE DOT ARRIVES ON, asked of the two series and of how far they have slid past
    /// each other.
    ///
    /// THE INDEX ALONE IS NOT AN IDENTITY, which is the whole of why `dropped` is here (codex
    /// review of 36b653b). Once the window is full every kept reading moves one place left on every
    /// tick, so the reading that is still the ceiling is at a DIFFERENT index and a comparison of
    /// bare indices would say `.crossfade` on every tick of a full window, which is every session
    /// past its first quarter of an hour. It fails the other way too: a new reading landing on the
    /// old peak's index is a different reading being slid to as though it were the same one.
    ///
    /// - Parameter dropped: how many of the oldest readings fell out between the two, from
    ///   `dropped(from:to:)`. Zero for a window still filling, and for the hand-written pairs that
    ///   state what this rule means at one length.
    static func peakMotion(from previous: [Double], to values: [Double],
                           dropped: Int = 0) -> PeakMotion {
        guard let was = peakIndex(previous), let now = peakIndex(values),
              was - dropped == now else { return .crossfade }
        return .move
    }
}
