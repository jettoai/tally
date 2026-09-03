import Foundation

/// WHICH MOTION THE BOARD'S LIVE FIGURES USE, as one launch flag spells it
/// (`-TallyMotion roll,morph,snappy`).
///
/// IT IS A FLAG BECAUSE IT IS A QUESTION ABOUT HOW SOMETHING LOOKS. A quarter-second change is not
/// something anybody can judge from a diff, and three curves at the same duration are
/// indistinguishable read one at a time. So every combination is put on one screen under one clock
/// and the answer is picked by looking (`MotionDemoWindow`, `-TallyMotionDemo`); this is what the
/// picking sets, and what the board then runs.
///
/// PURE, AND HERE RATHER THAN BESIDE THE ANIMATIONS, for the reason the rest of this folder is: the
/// parsing is a rule an assertion harness can state with no view and no launch around it. What a
/// curve MEANS is a SwiftUI `Animation` and stays next to the views (`CardMotion`).
struct MotionChoice: Equatable {
    /// How a live figure's digits change.
    enum Figures: String, CaseIterable {
        /// Nothing at all: the new spelling replaces the old one between two frames. Named `none` on
        /// the command line and `plain` here, `none` being a spelling every optional in this
        /// language already owns. It is what the board did before any of this, and it is what a
        /// measurement of what the motion COSTS has to be taken against.
        case plain = "none"
        /// The digits roll to the new value, in the direction the reading moved.
        case roll
        /// The old spelling fades out and the new one fades in.
        case fade
        /// The new spelling pushes the old one out of the way, from the direction it moved.
        case push

        /// Whether this style animates at all (see `Lines.moves`).
        var moves: Bool { self != .plain }
    }

    /// How a sparkline changes when a reading arrives.
    enum Lines: String, CaseIterable {
        /// Nothing at all: the outline is replaced between two frames, which is the baseline every
        /// other style here is measured against (see `Figures.plain`).
        case plain = "none"
        /// Every point travels to its new value, so the whole outline morphs.
        case morph
        /// The outline slides one step left and the newest reading enters at the right.
        case scroll
        /// The same travelling as `morph`, on the bouncy curve, so the newest point overshoots and
        /// settles. Its own curve rather than the chosen one, because what is being judged is
        /// whether a shape should overshoot at all.
        case bounce
        /// The outline is replaced between two frames and the newest reading is announced instead:
        /// its dot swells and settles.
        case pulse
        /// The outline is replaced, except for the newest segment, which is drawn from the point
        /// before it to where it now is.
        case grow
        /// `morph`, with the newest segment overdrawn in the current reading's own bright colour
        /// and fading back into the line.
        case comet

        /// Whether every point travels to its new value under this style, or the outline arrives
        /// whole and something else carries the change. Asked rather than tested for by name, so a
        /// style added here has to answer it (`FootprintSparklineView`).
        var interpolatesReadings: Bool {
            switch self {
            case .morph, .bounce, .comet: true
            case .plain, .scroll, .pulse, .grow: false
            }
        }

        /// Whether this style animates at all. The one that does not is drawn by the same code as
        /// the rest with every phase already at rest, so the baseline and the styles are one
        /// implementation and a measurement between them is about the motion alone.
        var moves: Bool { self != .plain }
    }

    /// The curve all of it travels on. Three at the same duration, so what is being compared is the
    /// shape of the motion and not its length.
    enum Curve: String, CaseIterable {
        case snappy, smooth, bouncy
    }

    /// THESE THREE DEFAULTS WERE CHOSEN BY LOOKING, which is the whole reason the samples window
    /// exists: every combination was put on one screen under one clock and these are the ones that
    /// came back (Albert, 2026-09-03, samples N3 and L6). Rolling digits on the bouncy curve, and a
    /// line whose newest segment is drawn in while the rest of it is replaced.
    ///
    /// THE OTHER STYLES STAY, and that is deliberate rather than leftover: the question they answer
    /// comes back every time this row gains a reading or changes size, and the cost of keeping them
    /// is a case each.
    var figures: Figures = .roll
    var lines: Lines = .grow
    var curve: Curve = .bouncy

    /// EACH TOKEN IS OFFERED TO ALL THREE AXES and taken by whichever one recognises it, so the
    /// order they are written in does not matter and neither does leaving one out.
    ///
    /// A TOKEN NOTHING RECOGNISES CHANGES NOTHING, which is the whole of the error handling: a typo
    /// leaves the axis it was meant for at its default rather than turning the motion off, and an
    /// absent flag is every default. There is nothing here a mistyped launch can break.
    init(_ raw: String?) {
        for token in (raw ?? "").lowercased().split(separator: ",")
            .map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let one = Figures(rawValue: token) { figures = one }
            if let one = Lines(rawValue: token) { lines = one }
            if let one = Curve(rawValue: token) { curve = one }
        }
    }
}
