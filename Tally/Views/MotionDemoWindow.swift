import AppKit
import SwiftUI

/// EVERY MOTION THE BOARD COULD USE, ON ONE SCREEN, DRIVEN BY ONE CLOCK.
///
/// WHY IT IS A WINDOW AND NOT A DIFF. What a figure's change should look like is a question about
/// how it LOOKS, and the only honest way to answer it is to watch the candidates side by side while
/// the same numbers move through all of them (Albert, 2026-09-03: "open a demo and let me pick").
/// Read one at a time on a live board, three curves at a quarter of a second each are
/// indistinguishable; read together, they are not.
///
/// EVERY CELL IS THE PRODUCTION CODE PATH. The figures go through the very column the card lays its
/// readings out in and the very speller it draws them with (`SessionCardView.column`,
/// `SessionCardView.figure`, `figureMotion`); the lines are `FootprintSparklineView` at the size the
/// card draws it. What differs between cells is the style argument and nothing else, so a choice
/// made here is a choice about what will actually ship (`CardMotion.FigureStyle`, `LineStyle`,
/// `Curve` - the same enums the `-TallyMotion` flag sets).
///
/// AND IT COSTS THE SHIPPING APP NOTHING. Nothing constructs any of this unless
/// `-TallyMotionDemo YES` is on the command line of a dev build or a fixture launch, which is the
/// same gate every other observation flag stands behind (`CaptureLaunch`). The strings are written
/// in place rather than put through the catalogue: nobody but a developer choosing a motion ever
/// reads them, and a translator handed "N3 · fade · bouncy" would have nothing to do with it.
@MainActor
final class MotionDemoWindowController: NSObject, NSWindowDelegate {
    static let shared = MotionDemoWindowController()

    private var window: NSWindow?

    /// Put the samples up, if this launch asked for them. Answers whether it did, so the caller can
    /// say so in one line rather than asking the same question twice.
    @discardableResult
    func showIfAsked() -> Bool {
        guard BuildVariant.isDev || DemoUsage.isActive,
              UserDefaults.standard.bool(forKey: "TallyMotionDemo") else { return false }
        show()
        return true
    }

    private func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: MotionDemoView())
        // THE WINDOW IS THE SIZE AUTHORITY AND THE HOSTING CONTROLLER IS NOT, which is the one rule
        // this pairing has (~/.claude/docs/patterns/swiftui-appkit.md): a controller that also sized
        // itself from Auto Layout would fight the frame set below, and the two of them recurse.
        host.sizingOptions = []
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
        panel.title = "Motion samples"
        panel.contentViewController = host
        // SET AFTER THE CONTROLLER, WHICH IS THE WHOLE OF WHY IT IS SET TWICE. Handing a window a
        // content view controller resizes the window to whatever that controller says it wants, and
        // a scrolling SwiftUI root says it wants almost no height at all: the window came up 906 by
        // 32 with the size passed to the initializer above (measured, 2026-09-03). The window is the
        // size authority here, so it states its size last.
        panel.setContentSize(NSSize(width: Self.width, height: Self.height))
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        window = panel
    }

    func windowWillClose(_ notification: Notification) { window = nil }

    private static let width: CGFloat = 950
    private static let height: CGFloat = 470
}

/// The samples themselves.
private struct MotionDemoView: View {
    /// THE SAME NUMBERS THROUGH EVERY CELL, ON ONE CLOCK. Cells driven by clocks of their own would
    /// be showing different arrivals at the same instant, which is exactly the comparison this
    /// window exists to make possible.
    @State private var step = 0
    /// The window the lines are drawn from, at the length a real one runs to
    /// (`FootprintTrendSeries.capacity`).
    @State private var window: [Double] = MotionDemoView.opening
    /// How many readings the strip has dropped off its oldest end, which is what a card's series
    /// tells its shape (`FootprintTrendSeries.origin`) and this window has to tell its own.
    @State private var origin = 0
    /// Bumped to build the lines again, so the once-only first drawing can be seen more than once.
    @State private var replay = 0

    /// A cycle that covers what a live figure does: rises, falls, and the digit changes at ten and
    /// a hundred that are the whole reason a rolling figure has to be looked at.
    private static let readings: [Double] = [9, 12, 41, 126, 98, 130, 77, 15, 8]

    /// A window that is already full when the samples open, so the lines have a shape from the first
    /// frame rather than growing into one for three minutes.
    ///
    /// SHAPED LIKE A SESSION RATHER THAN LIKE THE CYCLE ABOVE. Filled with the readings themselves
    /// it drew a comb - nine values repeated ten times, which is a texture rather than a trend - and
    /// what is being judged here is how a REAL outline moves. A slow swell with a little noise on it
    /// is what a tree under a working session actually traces.
    private static let opening: [Double] = (0 ..< FootprintTrendSeries.capacity).map { index in
        let phase = Double(index) / Double(FootprintTrendSeries.capacity)
        let swell = 40 + 55 * sin(phase * 2.6 * .pi) + 25 * sin(phase * 0.7 * .pi)
        return max(2, swell + Double((index * 37) % 17) - 8)
    }

    /// The cadence the board itself reads at with the page on screen (`ProcessFootprintStore`).
    private static let cadence: TimeInterval = 2

    private var reading: Double { Self.readings[step % Self.readings.count] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                figures
                Divider()
                lines
                footer
            }
            .padding(20)
        }
        .onReceive(Timer.publish(every: Self.cadence, on: .main, in: .common).autoconnect()) { _ in
            step += 1
            window.append(reading)
            if window.count > FootprintTrendSeries.capacity { window.removeFirst(); origin += 1 }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "Motion samples")
                .font(.title3.weight(.semibold))
            Text(verbatim: "Every cell is fed the same reading every "
                 + "\(Int(Self.cadence)) seconds. Reply with the numbers you want: "
                 + "one N and one L.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Figures

    private var figures: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "Figures").font(.headline)
            HStack(alignment: .top, spacing: 14) {
                cell("N0", "none", detail: "no transition") {
                    plainFigure
                }
                ForEach(Array(styleGrid.enumerated()), id: \.offset) { index, pair in
                    cell("N\(index + 1)", pair.0.rawValue, detail: pair.1.rawValue) {
                        sample(style: pair.0, curve: pair.1)
                    }
                    // THE PICK, DRAWN THE OTHER WAY, BESIDE ITSELF. The rolling digits are a
                    // layer's work now, and the one thing that buys nothing is `numericText`'s own
                    // blur, which no layer property spells (`RollingFigureLayerView`). Whether that
                    // is missed cannot be settled from a diff, so the version it replaces is drawn
                    // next to it under the same clock. Beside WHICHEVER cell the defaults name,
                    // asked of the rule rather than counted to, so a new default moves the
                    // comparison with it (`MotionChoice`).
                    if pair.0 == Self.picked.figures, pair.1 == Self.picked.curve {
                        cell("N\(index + 1)v", "SwiftUI numericText", detail: "view tree") {
                            sample(style: pair.0, curve: pair.1, roller: .viewTree)
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The nine combinations, in the order the labels number them: each style THAT MOVES with each
    /// curve.
    ///
    /// THE STILL ONE IS ALREADY N0, and enumerating it again cost the window the thing it exists for:
    /// three more cells of nothing happening took N1 to N3 - the numbers a reader picks a style BY -
    /// and pushed rolling digits on the bouncy curve out to N6, while thirteen cells across a 950pt
    /// window put the last of them off the edge (codex review of 34b4147; the pick was made against
    /// `docs/plans/captures/2026-09-03-motion-demo-v2.png`, where N3 is roll on bouncy). Asked of the
    /// style rather than tested for by name, so one added here has to answer it
    /// (`MotionChoice.Figures.moves`).
    private var styleGrid: [(CardMotion.FigureStyle, CardMotion.Curve)] {
        CardMotion.FigureStyle.allCases.filter(\.moves).flatMap { style in
            CardMotion.Curve.allCases.map { (style, $0) }
        }
    }

    /// The defaults, which are what the board runs when a launch says nothing: the cell they name is
    /// the one the contrast is drawn beside (`MotionChoice.figures`).
    private static let picked = MotionChoice(nil)

    /// ONE SAMPLE FIGURE: the very column the card lays a reading out in and the very speller it
    /// draws it with, in one style on one curve. Spelled once so the cells cannot differ in anything
    /// but their arguments, which is the whole premise of comparing them.
    private func sample(style: CardMotion.FigureStyle, curve: CardMotion.Curve,
                        roller: FigureRoller = .layers) -> some View {
        SessionCardView.column(FootprintTrendMetric.cpu.widestFigure) {
            SessionCardView.figure(figureText, level: .calm)
        }
        .font(.caption2.monospacedDigit())
        .figureMotion(figureText, value: reading, still: false, style: style, curve: curve,
                      roller: roller)
    }

    private var figureText: String {
        FootprintTrendMetric.cpu.figureText(reading) ?? ""
    }

    /// The control: the same column, drawn with no transition at all, which is what the board did
    /// before any of this.
    private var plainFigure: some View {
        SessionCardView.column(FootprintTrendMetric.cpu.widestFigure) {
            SessionCardView.figure(figureText, level: .calm)
        }
        .font(.caption2.monospacedDigit())
    }

    // MARK: - Lines

    private var lines: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(verbatim: "Lines").font(.headline)
                Button("Replay first draw") { replay += 1 }
                    .controlSize(.small)
            }
            HStack(alignment: .top, spacing: 20) {
                ForEach(Array(Self.lineCells.enumerated()), id: \.offset) { index, sample in
                    cell("L\(index)", sample.style.rawValue, detail: sample.detail) {
                        lineSample(style: sample.style, firstDraw: sample.firstDraw,
                                   animated: sample.animated)
                    }
                }
            }
            .id(replay)
        }
    }

    /// One sample line: which style, whether it draws itself in on arrival, and whether it moves at
    /// all. The control cell is the one that does not.
    private struct LineCell {
        let style: CardMotion.LineStyle
        let detail: String
        var firstDraw = false
        var animated = true
    }

    /// The samples, in the order the labels number them. L0 is the control - the very style L1 uses,
    /// with the motion turned off - so what the pair shows is the transition and nothing else.
    private static let lineCells: [LineCell] = [
        LineCell(style: .morph, detail: "no transition", animated: false),
        LineCell(style: .morph, detail: "points travel"),
        LineCell(style: .scroll, detail: "slides left"),
        LineCell(style: .morph, detail: "+ first draw", firstDraw: true),
        LineCell(style: .bounce, detail: "travel, overshoots"),
        LineCell(style: .pulse, detail: "hard swap, dot swells"),
        LineCell(style: .grow, detail: "hard swap, tail drawn"),
        LineCell(style: .comet, detail: "travel, bright tail fades"),
    ]

    /// How much larger the second copy of each line is drawn. The figure is told as well as scaled,
    /// because what draws it is a layer and a layer rasterises at the resolution it is given: blown
    /// up without being told, a one point stroke is drawn once and stretched
    /// (`FootprintSparklineView.magnified`).
    private static let magnification: CGFloat = 3

    /// One line at the size a card draws it, and again at three times that, because a 24 by 11 point
    /// figure is exactly the size at which two motions look alike.
    ///
    /// - Parameter animated: the control cell asks for none, which is what "no transition" means for
    ///   a shape: the outline is replaced between two frames.
    private func lineSample(style: CardMotion.LineStyle, firstDraw: Bool,
                            animated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            FootprintSparklineView(values: window, origin: origin, lineStyle: style,
                                   firstDraw: firstDraw, still: !animated)
            FootprintSparklineView(values: window, origin: origin, lineStyle: style,
                                   firstDraw: firstDraw, still: !animated,
                                   magnified: Self.magnification)
                .scaleEffect(Self.magnification, anchor: .topLeading)
                .frame(width: FootprintSparklineView.size.width * Self.magnification,
                       height: FootprintSparklineView.size.height * Self.magnification,
                       alignment: .topLeading)
        }
    }

    // MARK: - Chrome

    private func cell(_ number: String, _ style: String, detail: String,
                      @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
            Text(verbatim: "\(number) · \(style)")
                .font(.caption2.weight(.semibold))
            Text(verbatim: detail)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 74, alignment: .leading)
    }

    private var footer: some View {
        Text(verbatim: "The board runs whichever of these the launch asks for: "
             + "-TallyMotion <figure style>,<line style>,<curve>, for example "
             + "-TallyMotion push,scroll,smooth. One axis per position, so a style left out is "
             + "written as an empty one (-TallyMotion ,,smooth is the curve alone) and none on its "
             + "own is every motion off. Defaults are roll, none, bouncy (N3, and L0 for the line, "
             + "which is now a preference rather than a price: both axes are a layer's work now "
             + "and no longer lay the board out on every frame - see MotionChoice.lines for what "
             + "each one used to cost). N3v is the digits drawn the old way, in the view tree, for "
             + "the one difference a layer cannot spell: numericText's own blur.")
            .font(.caption2).foregroundStyle(.secondary)
    }
}
