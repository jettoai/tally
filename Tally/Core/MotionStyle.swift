import Foundation

/// WHICH MOTION THE BOARD'S LIVE FIGURES USE, as one launch flag spells it
/// (`-TallyMotion roll,morph,snappy`): one axis per position, `<figures>,<lines>,<curve>`.
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

    /// THE FIGURES WERE CHOSEN BY LOOKING, which is the whole reason the samples window exists:
    /// every combination was put on one screen under one clock and this is the one that came back
    /// (Albert, 2026-09-03, sample N3). Rolling digits on the bouncy curve.
    ///
    /// THE LINE DOES NOT MOVE, AND IT IS NOW A PREFERENCE RATHER THAN A PRICE. It was a price: L6
    /// was picked at the same sitting and could not be afforded, a minute of CPU time per state on
    /// a nine card board putting the growing line at 41.6% of one core against 20.8% with nothing
    /// moving. The reason was never this app's arithmetic. Any continuous motion in the VIEW TREE
    /// holds the whole panel in a layout pass per frame, because an animating leaf's layout computer
    /// is dirty on every frame and nothing between it and the root truncates that, so no cheaper
    /// geometry bought it back: the cheapest style there is, one scalar on one shape, still cost
    /// most of it, and cutting the row's seven-candidate ladder to one returned nine of the
    /// forty-three points and left the rest exactly where they were.
    ///
    /// THE LINE'S MOTION IS THE RENDER SERVER'S NOW, so it costs this process nothing: the figure is
    /// four Core Animation layers and one commit per reading, and the frames between them are not
    /// this app's work at all (`FootprintSparklineLayerView`). Measured the same way in one sitting
    /// on the same board, 2026-09-03: 14.8% with nothing moving and 14.7% with the line growing,
    /// which is the same reading twice. A profile of that minute has no panel-wide measurement left
    /// in it (`HostAnchored.sizeThatFits`, 4.7% of the main thread before and absent after).
    ///
    /// THE DIGITS STILL COST WHAT THEY COST, being still a view tree transition: 47.9% with them
    /// rolling alone, 51.2% with both axes, against 14.8% still. Which is the same shape of cost the
    /// line had, for the same reason, and it is the one this row has left.
    ///
    /// SO WHICH STYLE THE LINE RUNS IS A QUESTION ABOUT HOW IT SHOULD LOOK AGAIN, and the default
    /// stays `none` until it is answered by looking rather than by arithmetic (Albert, to decide;
    /// `-TallyMotion` still reaches every combination, and the samples window puts them on one
    /// clock).
    ///
    /// THE STYLES ALL STAY, and that is deliberate rather than leftover: they are what the samples
    /// window is for, the flag still reaches every one of them, and the question they answer comes
    /// back every time this row changes. What changed is which of them an ordinary launch runs.
    var figures: Figures = .roll
    var lines: Lines = .plain
    var curve: Curve = .bouncy

    /// EACH AXIS IS READ OFF ITS OWN POSITION, `<figures>,<lines>,<curve>`, which is the grammar
    /// this flag has always been documented in (`MotionDemoWindow.footer`) and the only one it can
    /// have. `none` IS A STYLE ON TWO OF THE THREE AXES, so a parser that offered every token to
    /// every axis let the line's `none` reach back and turn the figures off as well: the fallback
    /// spelling `-TallyMotion roll,none,bouncy` came out as no motion at all, and `none,roll,bouncy`
    /// - the same three words in the wrong order - was what actually produced rolling digits on a
    /// still line (codex review of 34b4147). Position is what tells the two `none`s apart, and it is
    /// why the order a launch writes them in now matters.
    ///
    /// A TOKEN NOTHING RECOGNISES CHANGES NOTHING, which is the whole of the error handling: a typo
    /// leaves the axis it was written in at its default rather than turning the motion off, an empty
    /// position does the same (`-TallyMotion ,,smooth` is the curve alone), and an absent flag is
    /// every default. There is nothing here a mistyped launch can break.
    ///
    /// `none` ON ITS OWN IS THE BASELINE, both axes off, which is the state a measurement of what
    /// the motion COSTS has to be taken against (`Figures.plain`). Read as one word rather than as a
    /// figures style with the line left running, because a launch that writes only that word is
    /// asking for no motion rather than for half of it.
    init(_ raw: String?) {
        let tokens = (raw ?? "").lowercased()
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if tokens == [Figures.plain.rawValue] {
            figures = .plain
            lines = .plain
            return
        }
        if let one = tokens.first.flatMap(Figures.init(rawValue:)) { figures = one }
        if tokens.count > 1, let one = Lines(rawValue: tokens[1]) { lines = one }
        if tokens.count > 2, let one = Curve(rawValue: tokens[2]) { curve = one }
    }
}
