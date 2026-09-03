import SwiftUI

/// ONE METRIC'S LAST QUARTER HOUR, drawn at the size of a word.
///
/// A LINE RATHER THAN A CHART. Everything a chart brings - axes, ticks, a legend, a scale to
/// configure - is furniture this figure has no room for and no reader for either: what is being
/// asked here is "has it been like this for a while", which is a shape, and the numbers that answer
/// it precisely are already printed beside it (the current value on the line above, the peak on the
/// line's own right). So the geometry is a dozen lines of arithmetic next door
/// (`FootprintSparkline`), stated where an assertion harness can read it, and this only strokes it.
///
/// TWO DOTS, AND THEY ARE THE TWO FIGURES PRINTED BESIDE THE LINE. The brighter, larger one is the
/// last reading, which is the current value in its own group; the quieter, smaller one is the
/// highest, which is the `↑` figure. Neither is decoration: they are what tie the shape to the two
/// numbers a reader can act on (`SessionCardView.sessionFootprintTrends`). A warning turns BOTH of
/// them along with the line, and the order of loudness survives the change of colour: three steps
/// of the one hue, quietest at the line and loudest at the current reading, which is the mirror of
/// the tertiary, secondary and primary greys a calm card draws them in (`alertLine`).
///
/// WHICH HUE IS THE TIER'S, and the three steps are the same either way: amber for the residue a
/// warning has always been about, red for a tree taking a share of the machine itself
/// (`FootprintAlertLevel`). The step ranks are held apart from the colour on purpose, so a tier
/// added here cannot arrive with a loudness order of its own.
///
/// THE BRIGHT ONE IS ONLY HONEST BECAUSE THE CALLER PUTS THE LIVE READING IN. The newest reading
/// the ring has KEPT is up to a bucket old (`FootprintTrendSeries`), so drawn from the ring alone
/// this dot marked 20% on a session whose card said 400% (measured on a live board, 2026-08-15).
/// The row therefore hands over the kept readings with this instant's own reading appended, drawn
/// and never stored, and the last step of the line is worth less time than the others: that is the
/// price of the two figures agreeing, and it is paid on the one step nobody reads for its slope.
///
/// A flat line carries no peak dot at all, because a series that never moved is at its maximum
/// everywhere and a dot on the earliest of those would point at an arbitrary moment.
struct FootprintSparklineView: View {
    let values: [Double]
    /// Whether the reading this shape belongs to is the one worth somebody's eye, and in which
    /// tier, which this whole figure says by taking that tier's colour: the line, the peak dot and
    /// the current dot together, so the group reads as one warned block rather than as a marked
    /// piece beside unmarked ones.
    ///
    /// AND NOTHING ELSE, WHICH IS A DEPARTURE FROM THE ROW ABOVE. That row carries a triangle as
    /// well as the colour, because a warning is not a colour to a reader who cannot separate amber
    /// from grey (`SessionCardView.sessionFootprint`). It cannot be carried HERE: the smallest
    /// triangle that is still a triangle renders about eleven points wide, which is nearly half of
    /// this twenty-four point frame, and wherever it is put it covers readings - drawn over the
    /// line it hides the oldest forty per cent of the window along with the peak dot that most
    /// often sits in it, and drawn under it the shape is read across a filled amber wedge. A mark
    /// that destroys the thing it is marking is not a second channel. What carries the meaning
    /// instead, at this size: the amber has a luminance step from the greys it replaces, measured
    /// against the current dot's primary, where the colour is undimmed (`alertCurrent`) and said
    /// rather than claimed at the two quieter steps, which are dimmed and have not been measured;
    /// and the condition itself is SAID rather than drawn for the reader who gets neither
    /// (`SessionCardView.spokenTrends`, which names it in words). Warned sparkline cells recolour
    /// their marks everywhere this convention appears, for the same reason. (Albert, 2026-08-16,
    /// having seen both the mark in the text flow and the mark on the shape.)
    var level: FootprintAlertLevel = .calm
    /// How far the window has slid since the series began (`FootprintTrendSeries.origin`), which
    /// is what the layers read the peak's identity off between two readings. Zero where there is
    /// no series behind the values, which is the samples window's own strip until it fills.
    var origin: Int = 0
    /// How the outline changes when a reading arrives, defaulting to this launch's choice
    /// (`CardMotion.LineStyle`). Named per instance so the samples window can put both on screen at
    /// once and the board still runs whichever was chosen (`MotionDemoWindow`).
    var lineStyle: CardMotion.LineStyle = CardMotion.lines
    /// Whether the line draws itself in the first time it appears. On for every card, and off in
    /// the sample that exists to show what leaving it out looks like.
    var firstDraw: Bool = true
    /// WHAT "THE FIRST TIME" IS COUNTED PER, and it cannot be this view. The row is laid out by a
    /// `ViewThatFits` that swaps candidates whenever the figures change width class - a peak column
    /// arriving, a culprit's name going - and a swapped candidate is a NEW subtree, so `onAppear`
    /// fires again and the line blinks out and strokes itself back in on a card that has been on
    /// screen for minutes (seen on a live board, 2026-09-03: the dots stayed, being untrimmed, and
    /// the outline vanished). Keyed by the card and the metric instead, the draw-in happens once
    /// per figure however many times its view is rebuilt.
    ///
    /// Nothing at all in the samples window, which wants to replay it on demand (`MotionDemoWindow`).
    var identity: String?
    /// Hold every motion on this figure still. The card never sets it and asks the environment
    /// instead (`reduceMotion`); the samples window sets it, to draw the control cell that has no
    /// transition at all. A parameter rather than a written environment value because Reduce Motion
    /// is a setting somebody made and not a knob a view may turn.
    var still: Bool = false
    /// HOW MUCH LARGER THAN ITS OWN POINTS THIS FIGURE IS BEING DRAWN, which only the samples
    /// window asks for: it draws every style twice, once at the size a card draws it and once at
    /// three times that, because 24 by 11 points is exactly the size at which two motions look
    /// alike (`MotionDemoWindow.lineSample`). The layers rasterise at the resolution they are SHOWN
    /// at, so a magnified sample says so rather than being drawn small and stretched.
    var magnified: CGFloat = 1

    /// MEASURED AGAINST THE NARROWEST CARD, which is the only width that constrains it, and
    /// re-measured every time the row around it gains a field. It was 44pt when the row held three
    /// shapes and three peaks, and 32 when that would not fit ("4.2 G…" on every two-column board).
    /// The row now holds the CURRENT FIGURES as well, which is what it is for, so three shapes,
    /// three figures, a unit word and one peak have to fit the 236pt a 264pt card gives its
    /// content: at 32pt that measures 247pt and the peak is dropped, at 24pt it is 223pt and the
    /// peak stays (measured 2026-08-15 at 10pt against this app's own metrics). The shape survives
    /// the loss - these are 90 readings in a figure under a centimetre wide either way, read for
    /// their outline rather than point by point - and the peak is a number that cannot be inferred
    /// from any width of line at all.
    ///
    /// The height is the caption's own line box less its leading, so the line sits inside the row
    /// rather than setting the card's height.
    static let size = CGSize(width: 24, height: 11)
    /// STATED HERE AND DRAWN NEXT DOOR. The layers do the drawing
    /// (`FootprintSparklineLayerHost`) and these are the numbers they draw with: kept on the view
    /// the rest of this app names, beside the prose that says why each of them is what it is, so
    /// there is one place a figure's proportions are decided rather than two that can drift.
    static let stroke: CGFloat = 1
    static let peakDot: CGFloat = 2
    static let currentDot: CGFloat = 3
    /// THREE STEPS OF ONE COLOUR, IN THE ORDER THE CALM CARD'S OWN GREYS ARE, and the same three
    /// steps whichever tier's colour is in them. A single named colour has no second rank of its
    /// own, so the ranks are opacities of it, and they mirror what the same three pieces wear when
    /// nothing is wrong: the line is the quietest (tertiary), the peak dot a step up (secondary),
    /// the current reading the loudest (primary).
    ///
    /// IT WAS NOT A MIRROR BEFORE, WHICH IS THE DEFECT: the line and the current dot were both
    /// drawn at full amber and only the peak was stepped down, so on a warned card the SHAPE was as
    /// loud as the reading it is about and the ceiling was the one quiet thing on a figure - the
    /// reverse of the order every calm card beside it reads in (2026-08-16). The eye lands on the
    /// current reading on a calm card and has to be able to land in the same place on a warned one.
    static let alertLine: CGFloat = 0.45
    static let alertPeak: CGFloat = 0.7
    static let alertCurrent: CGFloat = 1
    /// How far the newest dot swells under `pulse`: three points becoming five, which is a change
    /// the eye catches and still fits inside an eleven point frame.
    static let pulsePeak: CGFloat = 1.7
    /// How long the bright overdraw takes to fade back into the line under `comet`. Longer than the
    /// outline's own motion, because the fade is the thing being read.
    static let cometFade: Double = 1

    /// A need, not a preference, and the same environment key the rest of this surface reads.
    @Environment(\.accessibilityReduceMotion) private var motionFromEnvironment

    /// This figure's answer to "hold still": what the reader asked the system for, or what the
    /// samples window asked for on one cell.
    private var reduceMotion: Bool { motionFromEnvironment || still }

    /// THE FIGURE'S MOTION IS COMMITTED ONCE PER READING AND INTERPOLATED BY THE RENDER SERVER,
    /// which is where the whole of this figure's cost went (Albert, 2026-09-03, feeling the board
    /// lag). The outline, its two dots and every phase that announces a reading are Core Animation
    /// layers next door (`FootprintSparklineLayerView`), and what is left here is the shell: the
    /// size, the reader who cannot see it, and the one decision the layers cannot make for
    /// themselves (`identity`).
    ///
    /// WHY IT COULD NOT STAY A `Shape`. A shape's `animatableData` is an input to its own layout
    /// computer, so a series being interpolated made this leaf dirty on every frame, and nothing
    /// between here and the root truncates that: `.frame` pins the RESULT of a measurement rather
    /// than the dependency on one, and `.geometryGroup` is downstream of size entirely. The whole
    /// panel was therefore laid out once per frame - measured at 12.4% of one core with nothing
    /// moving against 41.3% with the line growing alone, two thirds of it inside SwiftUI's own
    /// layout engine (2026-09-03, fifteen cards). The layers cost one commit every two seconds.
    ///
    /// Which figures have already drawn themselves in, by the key their card hands them (see
    /// `identity`). A process-wide note rather than per-view state, which is the whole point of it;
    /// it holds three short strings per live session and a pid handed out again simply costs its
    /// new card the draw-in, which is a card arriving without a flourish.
    @MainActor private static var alreadyDrawn: Set<String> = []

    /// Whether this figure has stroked itself in yet, which the layers are told rather than asked:
    /// the answer is about a KEY that outlives this view, so it cannot be decided down there.
    @State private var reveal: FootprintSparklineReveal = .pending

    var body: some View {
        FootprintSparklineLayerView(values: values, origin: origin, level: level,
                                    lineStyle: lineStyle, still: reduceMotion, reveal: reveal,
                                    magnified: magnified)
            .frame(width: Self.size.width, height: Self.size.height)
            // The line says nothing a reader who cannot see it can use; the figures beside it do,
            // and the row states them in words (`SessionCardView.spokenTrends`).
            .accessibilityHidden(true)
            // DRAWN IN ONCE, WHEN THE CARD ARRIVES. A board opening puts a dozen finished outlines
            // on screen at the same instant, which reads as a page that was already there rather
            // than as readings being taken; stroked in, the shapes say what they are. Once, and
            // never again on an update - a line that redrew itself every two seconds would be the
            // opposite of the steadiness the columns on this row were pinned for.
            .onAppear {
                guard firstDraw, !reduceMotion, lineStyle.moves else { reveal = .instant; return }
                if let identity {
                    guard !Self.alreadyDrawn.contains(identity) else { reveal = .instant; return }
                    Self.alreadyDrawn.insert(identity)
                }
                reveal = .stroked
            }
    }
}


extension FootprintAlertLevel {
    /// WHAT A TIER LOOKS LIKE, stated once for every surface that draws one: the shape here, the
    /// figure beside it and the sentence a row above (`SessionCardView.figure`, `drawn`). Nothing
    /// for a calm reading, because a calm reading takes the grey it would have had anyway and a
    /// colour standing for "no colour" is a value somebody eventually draws.
    ///
    /// THE RED IS THE ONE THIS BOARD ALREADY MEANS "NOW" WITH, which is what makes a second use of
    /// it legible rather than a second vocabulary: `critical` is the blocked session's dot, its
    /// state word and its reason line, and the account meter's last stop. Read as one sentence,
    /// every red on this app says the same thing - somebody has to do something about this - and a
    /// tree taking the machine belongs in it. The amber keeps saying the other thing: worth an eye,
    /// not worth a hand.
    var tint: Color? {
        switch self {
        case .calm: nil
        case .residue: TallyColor.warning
        case .saturation: TallyColor.critical
        }
    }
}
