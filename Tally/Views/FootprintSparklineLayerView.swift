import AppKit
import SwiftUI

/// THE SPARKLINE'S MOTION, HANDED TO THE RENDER SERVER INSTEAD OF TO THE VIEW TREE.
///
/// WHAT THIS IS FOR IS A MEASUREMENT (Albert, 2026-09-03, feeling the board lag). A `Shape` whose
/// `animatableData` is the series has a layout computer that depends on the shape's own value, so
/// every frame of every spring made that leaf's computer dirty, and SwiftUI's graph has no
/// truncation between a dirty leaf and the root: `.frame` pins the RESULT of a measurement rather
/// than the dependency on one, and `.geometryGroup` sits downstream of size entirely. So the panel
/// was laid out once per frame, on a board that re-triggers every two seconds and therefore never
/// has a still frame: 12.4% of one core with nothing moving against 41.3% with the line growing
/// alone, and a profile of that minute put two thirds of the main thread in SwiftUI's layout engine
/// with under one per cent in this module (measured 2026-09-03 on a fifteen card board).
///
/// A LAYER IS THE ONE PLACE THE INTERPOLATION IS NOT THIS PROCESS'S WORK. The app commits one
/// animation per reading, every couple of seconds, and the frames between them are the window
/// server's: nothing on the main thread runs at all. That is the whole of the mechanism, and it is
/// what no cheaper geometry could buy back, the cheapest style there is having still cost thirty
/// points (`MotionChoice.lines`).
///
/// THE ARITHMETIC IS STILL THE PURE ONE NEXT DOOR (`FootprintSparkline`), read at the two instants
/// an animation is built from rather than at sixty per second: what changes here is who interpolates
/// between them, not what a reading is worth in points. The one thing this owes the shape it
/// replaced is that the line and both of its dots come from THE SAME pair of series, so a dot can
/// never leave the line it sits on.
struct FootprintSparklineLayerView: NSViewRepresentable {
    let values: [Double]
    let level: FootprintAlertLevel
    let lineStyle: CardMotion.LineStyle
    /// Every motion off, for the reader who asked the system for that or the cell that exists to
    /// show what no transition looks like (`FootprintSparklineView.still`).
    let still: Bool
    /// Whether the outline has drawn itself in yet, which is the shell's decision rather than this
    /// view's (`FootprintSparklineView.identity`).
    let reveal: FootprintSparklineReveal
    /// How much larger than its own points this figure is being drawn, so a magnified sample is
    /// rasterised at the size it is shown at rather than at the size it is (`MotionDemoWindow`).
    var magnified: CGFloat = 1

    func makeNSView(context: Context) -> FootprintSparklineLayerHost {
        let view = FootprintSparklineLayerHost()
        update(view)
        return view
    }

    func updateNSView(_ nsView: FootprintSparklineLayerHost, context: Context) { update(nsView) }

    /// THE SIZE IS A CONSTANT AND ASKS THE SUBTREE NOTHING, which is the half of this change that
    /// the layers alone would not have bought: a leaf whose measurement is a constant cannot make
    /// its ancestors' layout computers dirty, and the seven-candidate ladder above it
    /// (`SessionCardTrendRow.sessionFootprintTrends`) measures a constant seven times instead of
    /// walking a shape seven times.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FootprintSparklineLayerHost,
                      context: Context) -> CGSize? {
        FootprintSparklineView.size
    }

    private func update(_ view: FootprintSparklineLayerHost) {
        view.magnified = magnified
        view.apply(values: values, level: level, lineStyle: lineStyle, still: still, reveal: reveal)
    }
}

/// WHETHER THIS OUTLINE HAS BEEN STROKED IN YET. Three states rather than a flag because the
/// undecided one is a state a reader sees: the figure exists for a frame before `onAppear` has
/// answered, and what it shows then is the dots without the line, which is exactly what the
/// trimmed shape showed (`FootprintSparklineView.reveal`).
enum FootprintSparklineReveal {
    /// Nothing decided yet: the outline is not drawn.
    case pending
    /// Already drawn once under this key, held still, or a style that never moves: it is simply up.
    case instant
    /// This figure's first appearance: the outline strokes itself in.
    case stroked
}

/// The view those layers hang in: no drawing of its own, no hit testing, nothing to say to a
/// listener. Everything it does is in `apply`.
final class FootprintSparklineLayerHost: NSView {
    /// The four pieces, in the order they stack: the outline, the bright overdraw of its newest
    /// segment, the ceiling's dot and the current reading's.
    private let line = CAShapeLayer()
    private let tail = CAShapeLayer()
    private let peak = CAShapeLayer()
    private let current = CAShapeLayer()
    /// What the scroll style slides: one parent for all four, so the outline and its dots cannot
    /// arrive a step apart.
    private let plot = CALayer()

    /// The series on screen, or nothing before the first reading has been applied.
    private var shown: [Double]?
    private var level: FootprintAlertLevel = .calm
    private var lineStyle: CardMotion.LineStyle = .plain
    private var still = false
    private var reveal: FootprintSparklineReveal = .pending
    /// Whether the stroking-in has already run, so a rebuild does not run it twice.
    private var strokedIn = false

    var magnified: CGFloat = 1 { didSet { if magnified != oldValue { rescale() } } }

    /// EVERY PROPORTION OF THIS FIGURE IS THE VIEW'S, not a second copy of it: the sizes, the
    /// three steps of a tier's colour and the two phase constants all live beside the prose that
    /// decided them (`FootprintSparklineView`). What is here is the one number that is about
    /// drawing rather than about the figure: how far the stroke's own width keeps the line off the
    /// top and bottom edges, so a reading at the ceiling is drawn whole rather than clipped in half.
    private static let inset = FootprintSparklineView.stroke / 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let host = CALayer()
        layer = host
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for piece in [line, tail] {
            piece.fillColor = nil
            piece.lineWidth = FootprintSparklineView.stroke
            piece.lineJoin = .round
            piece.lineCap = .round
        }
        tail.opacity = 0
        peak.strokeColor = nil
        current.strokeColor = nil
        for piece in [line, tail, peak, current] { plot.addSublayer(piece) }
        host.addSublayer(plot)
        // The line says nothing a reader who cannot see it can use, and the row beside it states
        // every figure on it in words (`SessionCardTrendRow`).
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// A FIGURE, NOT A CONTROL. The card underneath is one button and the row carries a drag; a
    /// view that answered a hit test would take a click meant for either (`SessionCardView`).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        plot.frame = bounds
        line.frame = bounds
        tail.frame = bounds
        redraw()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rescale()
    }

    /// A figure drawn at the backing store's own resolution, and again when the window moves to a
    /// display with a different one.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rescale()
    }

    /// The calm greys are the system's own and are different colours in the two appearances, so
    /// they are resolved again whenever the appearance under this view changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolour()
    }

    /// EVERYTHING THIS VIEW DOES, ONCE PER READING. Whatever changed decides which animation is
    /// committed; nothing at all is committed when nothing changed, which matters because SwiftUI
    /// re-runs an update for reasons that are not a new reading.
    func apply(values: [Double], level: FootprintAlertLevel, lineStyle: CardMotion.LineStyle,
               still: Bool, reveal: FootprintSparklineReveal) {
        let previous = shown
        let arriving = previous != nil && previous != values
        let restyled = self.level != level || self.lineStyle != lineStyle || self.still != still
        let revealing = self.reveal != reveal
        guard previous == nil || arriving || restyled || revealing else { return }
        shown = values
        self.level = level
        self.lineStyle = lineStyle
        self.still = still
        self.reveal = reveal

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if restyled || previous == nil { recolour() }
        if arriving, !still, lineStyle.moves {
            announce(from: previous ?? [], to: values)
        } else {
            redraw()
        }
        if revealing || previous == nil { stroke(in: reveal) }
        CATransaction.commit()
    }

    // MARK: - The reading arriving

    /// WHICH MOTION A READING ARRIVES ON, which is the same fork the shape drew and the same one
    /// the style itself answers (`MotionChoice.Lines.interpolatesReadings`): either every point
    /// travels to its new value, or the outline is replaced whole and one phase announces the
    /// change. The phases are committed as animations off the value the layer now holds, so a
    /// figure interrupted mid-flight by the next reading lands on the newer one.
    private func announce(from previous: [Double], to values: [Double]) {
        let curve = lineStyle == .bounce ? MotionChoice.Curve.bouncy : CardMotion.chosen.curve
        switch lineStyle {
        case .plain:
            redraw()
        case .morph, .bounce:
            travel(from: previous, to: values, curve: curve)
        case .comet:
            travel(from: previous, to: values, curve: curve)
            // The newest segment, overdrawn in the reading's own bright colour and fading back into
            // the line over rather longer than the outline itself takes: the fade is what is being
            // read, and at a quarter of a second it is a flicker.
            tail.opacity = 0
            tail.add(fade("opacity", from: 1, to: 0, seconds: FootprintSparklineView.cometFade), forKey: "comet")
        case .scroll:
            // The whole outline slides one step left as the newest reading enters at the right,
            // which is what a strip chart does. One step is the gap between two readings, so the
            // figure arrives where it stood before this reading landed.
            redraw()
            let step = FootprintSparkline.stepWidth(values.count, in: canvas)
            plot.add(spring(curve, keyPath: "transform.translation.x", from: step, to: 0),
                     forKey: "scroll")
        case .pulse:
            // The dot swells and settles, which is what announces a reading on an outline that was
            // replaced whole. Three points becoming five stays inside an eleven point frame, where
            // a ring spreading out of it would be drawn mostly outside one.
            redraw()
            current.add(fade("transform.scale", from: FootprintSparklineView.pulsePeak, to: 1,
                              seconds: CardMotion.firstDrawDuration), forKey: "pulse")
        case .grow:
            // The outline is replaced except for its newest segment, which is drawn from the point
            // before it to where the reading now is. The dot rides that segment: it is the same
            // point, and a dot that jumped ahead of it would be the defect the shapes were built to
            // rule out.
            travel(from: values, to: values, curve: curve, grow: 0)
        }
    }

    /// The outline and both dots travelling together, from one series to the other.
    ///
    /// TWO LENGTHS ARE READ AS ONE, by the same rule the interpolation used (`FootprintSparkline`
    /// `.aligned`): a window still filling gains a point at its newest end, and Core Animation
    /// needs the two paths to have the same number of points to travel between them at all.
    private func travel(from previous: [Double], to values: [Double],
                        curve: MotionChoice.Curve, grow: Double = 1) {
        let (before, after) = FootprintSparkline.aligned(previous, values)
        guard after.count == values.count else { redraw(); return }
        redraw()
        let start = geometry(before, grow: grow)
        let end = geometry(after)
        line.add(spring(curve, keyPath: "path", from: start.line, to: end.line), forKey: "line")
        if lineStyle == .comet {
            tail.add(spring(curve, keyPath: "path", from: start.tail, to: end.tail), forKey: "tail")
        }
        for (dot, from, to) in [(peak, start.peak, end.peak),
                                (current, start.current, end.current)] {
            guard let from, let to else { continue }
            dot.add(spring(curve, keyPath: "position", from: NSValue(point: from),
                           to: NSValue(point: to)), forKey: "travel")
        }
    }

    /// The first drawing, once per figure: the outline strokes itself in rather than appearing
    /// whole, which is what makes a board opening read as readings being taken.
    private func stroke(in reveal: FootprintSparklineReveal) {
        switch reveal {
        case .pending:
            line.strokeEnd = 0
        case .instant:
            line.strokeEnd = 1
        case .stroked:
            line.strokeEnd = 1
            guard !strokedIn else { return }
            strokedIn = true
            line.add(fade("strokeEnd", from: 0, to: 1, seconds: CardMotion.firstDrawDuration),
                     forKey: "draw")
        }
    }

    // MARK: - Geometry

    /// The size this figure is drawn at, which is the one its shell pins it to.
    private var canvas: CGSize {
        bounds.width > 0 && bounds.height > 0 ? bounds.size : FootprintSparklineView.size
    }

    /// EVERY PIECE OF ONE INSTANT, computed from one series in one pass. The dots are asked for
    /// where they are rather than told: the ceiling is an ordinal taken from the readings that
    /// arrived and the current reading is the last point, wherever the window's length has got to.
    private func geometry(_ values: [Double], grow: Double = 1)
        -> (line: CGPath, tail: CGPath, peak: CGPoint?, current: CGPoint?) {
        let points = FootprintSparkline.slid(values, in: canvas, inset: Self.inset,
                                             steps: 0, grow: grow).map(flipped)
        let outline = CGMutablePath()
        if let first = points.first {
            outline.move(to: first)
            for point in points.dropFirst() { outline.addLine(to: point) }
        }
        let segment = CGMutablePath()
        if points.count >= FootprintSparkline.minimumReadings {
            segment.move(to: points[points.count - 2])
            segment.addLine(to: points[points.count - 1])
        }
        let ceiling = FootprintSparkline.peakIndex(values).flatMap {
            points.indices.contains($0) ? points[$0] : nil
        }
        return (outline, segment, ceiling, points.last)
    }

    /// A layer's y grows upward and a reading's grows downward, which is the one conversion between
    /// the pure arithmetic and what is drawn (`FootprintSparkline.points`).
    private func flipped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: canvas.height - point.y)
    }

    /// The figure as it stands, with no motion between what it showed and what it shows.
    private func redraw() {
        guard let values = shown else { return }
        let now = geometry(values)
        // The outline is whatever the series is worth, which for a series too short to be a line is
        // an empty path: nothing drawn, and nothing to hide. The dots are the ones that need hiding,
        // their own paths outliving a reading that has nowhere to sit (`place`).
        line.path = now.line
        tail.path = now.tail
        tail.isHidden = lineStyle != .comet
        place(peak, diameter: FootprintSparklineView.peakDot, at: now.peak)
        place(current, diameter: FootprintSparklineView.currentDot, at: now.current)
    }

    /// One dot at one point, or no dot at all where the series is too short to have one: an empty
    /// path draws nothing rather than a dot in a corner.
    private func place(_ dot: CAShapeLayer, diameter: CGFloat, at centre: CGPoint?) {
        guard let centre else { dot.isHidden = true; return }
        dot.isHidden = false
        let box = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        if dot.bounds.size != box.size {
            dot.bounds = box
            dot.path = CGPath(ellipseIn: box, transform: nil)
        }
        dot.position = centre
    }

    // MARK: - Colour and resolution

    /// WHAT ONE PIECE OF THIS FIGURE IS DRAWN IN: the grey it has on a calm card, or its own step of
    /// this tier's colour. Every piece asks the same question, which is what makes a warned figure
    /// read as one block, and the ranks mirror the greys a calm card draws them in: the line is the
    /// quietest, the ceiling's dot a step up, the current reading the loudest.
    private func recolour() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            line.strokeColor = tone(calm: .tertiaryLabelColor, step: FootprintSparklineView.alertLine)
            peak.fillColor = tone(calm: .secondaryLabelColor, step: FootprintSparklineView.alertPeak)
            current.fillColor = tone(calm: .labelColor, step: FootprintSparklineView.alertCurrent)
            tail.strokeColor = tone(calm: .labelColor, step: FootprintSparklineView.alertCurrent)
        }
    }

    private func tone(calm: NSColor, step: CGFloat) -> CGColor {
        guard let tint = level.tint else { return calm.cgColor }
        return NSColor(tint).withAlphaComponent(step).cgColor
    }

    /// Rasterised at the resolution it is SHOWN at, which is the backing store's own except in the
    /// samples window, where the same figure is also drawn three times its size.
    private func rescale() {
        let scale = (window?.backingScaleFactor ?? 2) * max(1, magnified)
        for piece in [line, tail, peak, current] { piece.contentsScale = scale }
    }

    // MARK: - Curves

    /// THE SAME CURVE THE VIEW TREE WOULD HAVE TRAVELLED ON. SwiftUI's three are springs stated as
    /// a perceptual duration and a bounce, and Core Animation takes a spring in exactly those terms
    /// (`CASpringAnimation(perceptualDuration:bounce:)`, macOS 14), so this is the same motion
    /// rather than an approximation of it: smooth has no overshoot, snappy a little, bouncy the
    /// overshoot it is named for (`MotionChoice.Curve.animation`).
    private func spring(_ curve: MotionChoice.Curve, keyPath: String,
                        from: Any, to: Any) -> CASpringAnimation {
        let bounce: CGFloat
        switch curve {
        case .smooth: bounce = 0
        case .snappy: bounce = 0.15
        case .bouncy: bounce = 0.3
        }
        let animation = CASpringAnimation(perceptualDuration: CardMotion.figureDuration,
                                          bounce: bounce)
        animation.keyPath = keyPath
        animation.fromValue = from
        animation.toValue = to
        // A spring is over when it has settled, not when its perceptual duration is up; left at the
        // default this would be cut off partway and snap the rest of the way.
        animation.duration = animation.settlingDuration
        return animation
    }

    /// The one motion here that is not a spring: a phase set at its far end and eased home, which
    /// is what the stroking-in, the swelling dot and the fading overdraw all are.
    private func fade(_ keyPath: String, from: CGFloat, to: CGFloat,
                      seconds: Double) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = seconds
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return animation
    }
}
