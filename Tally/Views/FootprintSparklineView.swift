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
    private static let stroke: CGFloat = 1
    private static let peakDot: CGFloat = 2
    private static let currentDot: CGFloat = 3
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
    private static let alertLine: Double = 0.45
    private static let alertPeak: Double = 0.7
    private static let alertCurrent: Double = 1
    /// How far the newest dot swells under `pulse`: three points becoming five, which is a change
    /// the eye catches and still fits inside an eleven point frame.
    private static let pulsePeak: Double = 1.7
    /// How long the bright overdraw takes to fade back into the line under `comet`. Longer than the
    /// outline's own motion, because the fade is the thing being read.
    private static let cometFade: Double = 1

    /// A need, not a preference, and the same environment key the rest of this surface reads.
    @Environment(\.accessibilityReduceMotion) private var motionFromEnvironment

    /// This figure's answer to "hold still": what the reader asked the system for, or what the
    /// samples window asked for on one cell.
    private var reduceMotion: Bool { motionFromEnvironment || still }

    /// THE FIGURE TRAVELS TO ITS NEW SHAPE RATHER THAN BEING REPAINTED, which is what the three
    /// shapes below buy over the single `Path` this used to draw (Albert, 2026-09-03). A path built
    /// in the body is a fresh drawing every couple of seconds: nothing about it is interpolable, so
    /// a window that had shifted by one reading arrived as a whole new outline between two frames,
    /// and the pair of dots teleported with it. What is animatable here is the READINGS - the shapes
    /// take the series as their `animatableData` and compute their own geometry from whatever
    /// interpolation hands them (`FootprintSparklineValues`) - so the line, the peak dot and the
    /// current dot are all drawn from the SAME intermediate series and cannot drift apart mid-flight.
    ///
    /// THE DOTS ARE SHAPES FOR THAT REASON ALONE. Each was a `Circle` at an `.offset`, which does
    /// interpolate - but between two POSITIONS, computed from two different series, while the line
    /// under them was interpolating between the series themselves. Two interpolations of one figure
    /// is a dot that leaves its line.
    /// Which figures have already drawn themselves in, by the key their card hands them (see
    /// `identity`). A process-wide note rather than per-view state, which is the whole point of it;
    /// it holds three short strings per live session and a pid handed out again simply costs its
    /// new card the draw-in, which is a card arriving without a flourish.
    @MainActor private static var alreadyDrawn: Set<String> = []

    /// How far through its first drawing this line is (see `firstDraw`).
    @State private var drawn: Double = 0
    /// How far the outline still has to slide, in steps, under `scroll`: set to one whole step the
    /// instant a reading arrives and animated back to nothing.
    @State private var slide: Double = 0
    /// How much of the newest segment has been drawn, under `grow`: nothing the instant a reading
    /// arrives, animated to all of it.
    @State private var grown: Double = 1
    /// How far the newest dot is still swollen, under `pulse`.
    @State private var pulse: Double = 1
    /// How much of the newest segment's bright overdraw is left, under `comet`.
    @State private var comet: Double = 0

    var body: some View {
        let series = FootprintSparklineValues(values)
        ZStack(alignment: .topLeading) {
            FootprintSparklineLine(readings: series, travels: readingsTravel,
                                   slide: carried, inset: Self.stroke / 2, grow: grown)
                .trim(from: 0, to: drawn)
                .stroke(tone(calm: .tertiary, step: Self.alertLine),
                        style: StrokeStyle(lineWidth: Self.stroke, lineCap: .round,
                                           lineJoin: .round))
            // THE NEWEST SEGMENT, OVERDRAWN IN THE READING'S OWN BRIGHT COLOUR AND FADING BACK INTO
            // THE LINE (`comet`). The segment rather than the whole outline, because what has just
            // happened is one reading and lighting the quarter hour behind it would say otherwise.
            if lineStyle == .comet {
                FootprintSparklineTail(readings: series, slide: carried, inset: Self.stroke / 2)
                    .stroke(tone(calm: .primary, step: Self.alertCurrent),
                            style: StrokeStyle(lineWidth: Self.stroke, lineCap: .round))
                    .opacity(comet)
            }
            // THE PEAK'S INDEX IS TAKEN FROM THE READINGS THAT ARRIVED, not interpolated with them:
            // an index is an ordinal rather than a quantity, and half of one is not a moment. The
            // dot therefore travels to where the new peak IS while the line under it is still on its
            // way, which is the honest half of the trade - the alternative is a dot that points at a
            // reading nothing on the card ever showed.
            if let index = FootprintSparkline.peakIndex(values) {
                mark(series, at: index, diameter: Self.peakDot)
                    .fill(tone(calm: .secondary, step: Self.alertPeak))
            }
            // The newest reading, wherever the window's length has got to: asked for by position
            // rather than by index, so a series still growing towards its capacity marks its own
            // last point.
            mark(series, at: nil, diameter: Self.currentDot * pulse)
                .fill(tone(calm: .primary, step: Self.alertCurrent))
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // THE ANIMATION MUST NOT REACH THE LAYOUT AROUND IT, which is what this whole figure cost
        // before it was here (Albert, 2026-09-03, feeling the board lag; `sample` put every one of
        // the top ten frames in SwiftUI's layout engine). This figure is drawn inside a
        // `ViewThatFits` with seven candidates, and that view re-measures its whole candidate list
        // whenever the subtree under it invalidates - so an interpolating shape was asking fifteen
        // cards to re-lay-out three rows apiece on every frame of every spring, and a board of
        // springs re-triggered every two seconds never has a still frame. Grouped, what animates
        // here is redrawn and nothing above it is re-measured. The frame is fixed and was always
        // fixed; what leaked was the invalidation, not a size.
        .geometryGroup()
        // THE READINGS TRAVEL UNDER SOME STYLES AND ARRIVE WHOLE UNDER OTHERS, which is the first
        // fork between them: one moves every point to its new value, the others put the finished
        // outline up at once and let something else carry the change. Interpolating both at the
        // same time would be two motions about one arrival
        // (`MotionChoice.Lines.interpolatesReadings`).
        .animation(travel, value: values)
        // The line says nothing a reader who cannot see it can use; the figures beside it do, and
        // the row states them in words (`SessionCardView.spokenTrends`).
        .accessibilityHidden(true)
        // DRAWN IN ONCE, WHEN THE CARD ARRIVES. A board opening puts a dozen finished outlines on
        // screen at the same instant, which reads as a page that was already there rather than as
        // readings being taken; stroked in, the shapes say what they are. Once, and never again on
        // an update - a line that redrew itself every two seconds would be the opposite of the
        // steadiness the columns on this row were pinned for.
        .onAppear {
            guard firstDraw, !reduceMotion, lineStyle.moves else { drawn = 1; return }
            if let identity {
                guard !Self.alreadyDrawn.contains(identity) else { drawn = 1; return }
                Self.alreadyDrawn.insert(identity)
            }
            withAnimation(.easeOut(duration: CardMotion.firstDrawDuration)) { drawn = 1 }
        }
        // AND WHATEVER ELSE THIS STYLE ANNOUNCES A READING WITH. Each of these is a PHASE rather
        // than a value: it is put at its far end with no animation the instant the readings change
        // and animated home, which is why none of them can live in the shape's own data. Held still
        // for a reader who asked for that, in which case every one of them is simply already home.
        .onChange(of: values) { _, _ in
            guard !reduceMotion else { return }
            switch lineStyle {
            case .plain:
                break                       // the baseline: the outline is simply replaced
            case .morph, .bounce:
                break                       // the readings themselves are the motion
            case .scroll:
                // The whole outline slides one step left as the newest reading enters at the right,
                // which is what a strip chart does.
                slide = 1
                withAnimation(travel ?? curve) { slide = 0 }
            case .pulse:
                // THE DOT SWELLS AND SETTLES, which is what announces a reading on an outline that
                // was replaced whole. A swelling dot rather than a ring spreading out of it: a ring
                // reaching eight points across is taller than this whole figure (11pt), so most of
                // it would be drawn outside the frame and clipped, while three points of dot
                // growing to five stays inside and is still a change the eye catches.
                pulse = Self.pulsePeak
                withAnimation(.easeOut(duration: CardMotion.firstDrawDuration)) { pulse = 1 }
            case .grow:
                // The outline is replaced except for its newest segment, which is drawn from the
                // point before it to where the reading now is.
                grown = 0
                withAnimation(curve) { grown = 1 }
            case .comet:
                // The newest segment is overdrawn bright and fades back into the line, over rather
                // longer than the outline itself takes: the fade is what is being read, and at a
                // quarter of a second it is a flicker.
                comet = 1
                withAnimation(.easeOut(duration: Self.cometFade)) { comet = 0 }
            }
        }
    }

    /// How the readings themselves travel, or nothing at all where the outline arrives whole and
    /// something else carries the change.
    private var travel: Animation? { readingsTravel ? curve : nil }

    /// WHETHER THE READINGS ARE WHAT MOVES, which the shapes below have to be told rather than left
    /// to infer: their animatable data is the series, so a style whose outline arrives WHOLE would
    /// otherwise have ninety readings interpolated on every frame of the phase that does carry its
    /// change (the newest segment being drawn in, the dot swelling). That is arithmetic nobody
    /// looks at, on the default style, sixty times a second per shape and three shapes per metric
    /// (measured 2026-09-03: the pair arithmetic and the series arithmetic together were about a
    /// tenth of the main thread on a nine card board), and it also draws a morph the style says it
    /// does not have.
    private var readingsTravel: Bool { !reduceMotion && lineStyle.interpolatesReadings }

    /// The curve this figure moves on: the launch's own, except under `bounce`, which IS a curve
    /// rather than a shape of motion and states its own.
    private var curve: Animation {
        lineStyle == .bounce ? MotionChoice.Curve.bouncy.animation : CardMotion.figureFlip
    }

    /// How far this figure is still slid to the right, in steps: nothing at all except under
    /// `scroll`, where sliding IS the motion.
    private var carried: Double { lineStyle == .scroll ? slide : 0 }

    /// What one piece of this figure is drawn in: the grey it has on a calm card, or its own step
    /// of this tier's colour (see the three constants above). Every piece asks the same question,
    /// which is what makes a warned figure read as one block - the line, the peak dot and the
    /// current dot change together or not at all - and each is handed the rank it keeps in every
    /// state, so the palettes cannot fall into different orders.
    private func tone(calm: some ShapeStyle, step: Double) -> AnyShapeStyle {
        guard let tint = level.tint else { return AnyShapeStyle(calm) }
        return AnyShapeStyle(tint.opacity(step))
    }

    /// One of the two dots, drawn from the same series the line is (see `body`): a reading by index,
    /// or the newest one when there is no index to name it by.
    private func mark(_ readings: FootprintSparklineValues, at index: Int?,
                      diameter: CGFloat) -> FootprintSparklineMark {
        FootprintSparklineMark(readings: readings, travels: readingsTravel, slide: carried,
                               grow: grown, diameter: diameter, index: index,
                               inset: Self.stroke / 2)
    }
}

/// THE SHAPE OF A SERIES, drawn from whatever series the animation is holding at this frame.
///
/// The geometry itself is not here: it is the pure arithmetic next door, stated where an assertion
/// harness can read it with no view around it (`FootprintSparkline.points`). What this adds is the
/// one thing a pure function cannot say - that the READINGS are what interpolates, so a window that
/// gains a point draws its way there.
private struct FootprintSparklineLine: Shape {
    var readings: FootprintSparklineValues
    /// Whether those readings are what travels under this style, or whether the outline arrives
    /// whole and something else carries the change (`FootprintSparklineView.readingsTravel`).
    let travels: Bool
    /// How far this outline is still slid to the right, in whole steps: one under `scroll` at the
    /// instant a reading lands, animated back to nothing; always nothing under `morph`.
    var slide: Double
    /// How far the line stays off the top and bottom edges, so a reading at the ceiling is drawn
    /// whole rather than clipped in half by the frame.
    let inset: CGFloat
    /// How much of the newest segment is drawn, under `grow`. One at rest.
    var grow: Double


    /// EVERY AXIS TRAVELS TOGETHER, which is what lets one shape draw all six styles: whichever of
    /// the three is moving, the geometry is computed once from the same instant of it, so nothing
    /// on this figure can be a frame ahead of anything else.
    /// EVERY AXIS THAT IS MOVING TRAVELS TOGETHER, and the readings only count as one of them
    /// where the style says they do: offered as the zero otherwise, so a phase animating alone
    /// interpolates two numbers rather than the whole window, and the outline this frame draws is
    /// the one the view was last handed.
    var animatableData: AnimatablePair<FootprintSparklineValues, AnimatablePair<Double, Double>> {
        get { AnimatablePair(travels ? readings : .zero, AnimatablePair(slide, grow)) }
        set { if travels { readings = newValue.first }
              slide = newValue.second.first
              grow = newValue.second.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = FootprintSparkline.slid(readings.series, in: rect.size, inset: inset,
                                             steps: slide, grow: grow)
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }
}

/// JUST THE NEWEST SEGMENT of that line, for the style that overdraws it bright and lets it fade
/// back in (`CardMotion.LineStyle.comet`). The same series and the same arithmetic as the outline
/// under it, so the two cannot be a frame apart.
private struct FootprintSparklineTail: Shape {
    var readings: FootprintSparklineValues
    var slide: Double
    let inset: CGFloat

    var animatableData: AnimatablePair<FootprintSparklineValues, Double> {
        get { AnimatablePair(readings, slide) }
        set { readings = newValue.first; slide = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = FootprintSparkline.slid(readings.series, in: rect.size, inset: inset,
                                             steps: slide)
        guard points.count >= FootprintSparkline.minimumReadings else { return path }
        path.move(to: points[points.count - 2])
        path.addLine(to: points[points.count - 1])
        return path
    }
}

/// One dot on that line, from the same series and therefore at the same instant of the flight.
private struct FootprintSparklineMark: Shape {
    var readings: FootprintSparklineValues
    /// The same question the line is asked, and it must be answered the same way: a dot travelling
    /// over a series the line under it is not travelling over is a dot that leaves its line
    /// (`FootprintSparklineLine.travels`).
    let travels: Bool
    var slide: Double
    var grow: Double
    /// How wide this dot is right now. ANIMATABLE, which the line's own geometry is not: the style
    /// that announces a reading by swelling the newest dot has nothing else to interpolate, and a
    /// diameter held outside this would snap back rather than settle (`CardMotion.LineStyle.pulse`).
    var diameter: CGFloat
    /// Which reading to sit on, or nothing for the newest one.
    let index: Int?
    let inset: CGFloat

    var animatableData: AnimatablePair<FootprintSparklineValues,
                                       AnimatablePair<Double, AnimatablePair<Double, Double>>> {
        get {
            AnimatablePair(travels ? readings : .zero,
                           AnimatablePair(slide, AnimatablePair(grow, diameter)))
        }
        set { if travels { readings = newValue.first }
              slide = newValue.second.first
              grow = newValue.second.second.first; diameter = newValue.second.second.second }
    }

    func path(in rect: CGRect) -> Path {
        let points = FootprintSparkline.slid(readings.series, in: rect.size, inset: inset,
                                             steps: slide, grow: grow)
        let centre: CGPoint?
        if let index {
            centre = points.indices.contains(index) ? points[index] : nil
        } else {
            centre = points.last
        }
        // A series too short to be a line has no point to mark either, which is the same answer the
        // geometry gives: an empty path draws nothing rather than a dot in a corner.
        guard let centre else { return Path() }
        return Path(ellipseIn: CGRect(x: centre.x - diameter / 2, y: centre.y - diameter / 2,
                                      width: diameter, height: diameter))
    }
}

/// A SERIES THAT CAN BE INTERPOLATED, which is the whole of what this wrapper is for: `[Double]` is
/// not `VectorArithmetic`, and the shapes above need one to animate between.
///
/// TWO LENGTHS ARE THE HARD CASE and the arithmetic for it is pure and stated next door
/// (`FootprintSparkline.aligned`, which carries why the shorter series is padded at its FRONT and
/// with its own oldest reading rather than with zero). Everything here is the conformance around it.
///
/// THE EMPTY SERIES IS THE ZERO, and the padding is what makes that true rather than merely
/// plausible: `a - .zero` pads the empty side to `a`'s length with zeroes and subtracts them, which
/// is `a`. A wrapper that refused to pad would have made `zero` an element the arithmetic could not
/// reach, and SwiftUI reaches for it on the first frame of every animation.
struct FootprintSparklineValues: VectorArithmetic {
    var series: [Double]

    init(_ series: [Double] = []) { self.series = series }

    static var zero: FootprintSparklineValues { FootprintSparklineValues() }

    static func + (lhs: FootprintSparklineValues,
                   rhs: FootprintSparklineValues) -> FootprintSparklineValues {
        combine(lhs, rhs, +)
    }

    static func - (lhs: FootprintSparklineValues,
                   rhs: FootprintSparklineValues) -> FootprintSparklineValues {
        combine(lhs, rhs, -)
    }

    mutating func scale(by rhs: Double) { series = series.map { $0 * rhs } }

    var magnitudeSquared: Double { series.reduce(0) { $0 + $1 * $1 } }

    /// THE EQUAL-LENGTH CASE IS THE ONE THAT RUNS SIXTY TIMES A SECOND, so it does not go through
    /// the padding: a full window and a full window are the shape of every frame of every
    /// animation on a board that has been open for a quarter of an hour, and building two padded
    /// copies of ninety readings to discover that neither needed padding is the sort of arithmetic
    /// that only shows up as a warm machine (`FootprintSparkline.aligned` is still the rule, and is
    /// what the unequal case asks).
    private static func combine(_ lhs: FootprintSparklineValues, _ rhs: FootprintSparklineValues,
                                _ step: (Double, Double) -> Double) -> FootprintSparklineValues {
        guard lhs.series.count != rhs.series.count else {
            return FootprintSparklineValues(zip(lhs.series, rhs.series).map(step))
        }
        let (one, other) = FootprintSparkline.aligned(lhs.series, rhs.series)
        return FootprintSparklineValues(zip(one, other).map(step))
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
