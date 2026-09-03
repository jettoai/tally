import SwiftUI
import AppKit

/// In-view drag-to-reorder for the account cards: SwiftUI's
/// pasteboard-backed `.draggable`/`.dropDestination` is unreliable inside a popover/panel and reads
/// poorly (translucent system snapshot, no insertion feedback, order only changes on drop). A plain
/// `DragGesture` stays inside the SwiftUI view tree: each card records its frame, the pointer is
/// hit-tested against those frames, and the order mutates live with a spring while a floating copy
/// of the card tracks the pointer.

enum CardMotion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.80)

    /// How long a LIVE FIGURE takes to reach its new value, on the session board: the digits change
    /// and the line behind them travels, rather than both being repainted between two frames
    /// (Albert, 2026-09-03, on the first live board).
    ///
    /// A DIFFERENT MOTION FROM THE SPRING ABOVE, and deliberately so. That one carries a card the
    /// hand moved, where the overshoot is the feedback; this one carries a number nobody touched.
    /// Short enough to be finished well inside the two seconds until the next reading, so a figure
    /// is never still travelling when its successor arrives.
    static let figureDuration: Double = 0.25
    /// How long a line takes to draw itself the first time a card appears. Longer than a figure's
    /// change because it is a stroke being drawn rather than a value moving, and it happens once.
    static let firstDrawDuration: Double = 0.35

    /// WHICH OF THESE THE BOARD USES IS A LAUNCH FLAG ON A DEV BUILD, because it is a question about
    /// how something LOOKS and the only way to answer that is to look at it side by side. The styles
    /// themselves and the flag's spelling are a pure rule next door (`MotionChoice`); what is here
    /// is what a curve MEANS, which is a SwiftUI animation and cannot be.
    typealias FigureStyle = MotionChoice.Figures
    typealias LineStyle = MotionChoice.Lines
    typealias Curve = MotionChoice.Curve

    /// What this launch asked for, read ONCE. The argument domain, like every other flag in this
    /// family, so it is volatile by construction and an ordinary launch is unaffected
    /// (`CaptureLaunch`). Gated on a dev build or the fixtures for the same reason they are: a
    /// release instance somebody is using must not be reachable.
    static let chosen = MotionChoice(
        BuildVariant.isDev || DemoUsage.isActive
            ? UserDefaults.standard.string(forKey: "TallyMotion") : nil)

    static var figures: FigureStyle { chosen.figures }
    static var lines: LineStyle { chosen.lines }
    /// The one animation every live figure on the board travels on.
    static var figureFlip: Animation { chosen.curve.animation }
}

extension MotionChoice.Curve {
    /// The same three curves at the same duration, so a comparison between them is about the shape
    /// of the motion rather than about its length.
    var animation: Animation {
        switch self {
        case .snappy: .snappy(duration: CardMotion.figureDuration)
        case .smooth: .smooth(duration: CardMotion.figureDuration)
        case .bouncy: .bouncy(duration: CardMotion.figureDuration)
        }
    }
}

/// ONE LIVE FIGURE'S CHANGE, in whichever style this build was launched with. The board's readings
/// and the demo window's samples both come through here, so what is being chosen between in the
/// samples is the very code the board will run (`MotionDemoWindow`).
///
/// KEYED ON THE SPELLING RATHER THAN ON THE QUANTITY, which is what keeps a card still: a CPU
/// wandering between 9.1 and 9.4 per cent is one reading to a reader and two to a `Double`, and
/// animating the second would be a figure in perpetual motion that never visibly changes.
///
/// THE DIRECTION IS THE QUANTITY'S, though, because the spelling cannot supply it: "999 MB" to
/// "1.0 GB" is a rise that reads as a fall. Both styles that have a direction are handed the
/// previous reading, which is kept here rather than asked of the caller - a figure knows what it
/// last was, and every call site would otherwise have to.
private struct FigureMotion: ViewModifier {
    let text: String
    let value: Double?
    let still: Bool
    let style: CardMotion.FigureStyle
    let curve: Animation

    @State private var previous: Double?

    func body(content: Content) -> some View {
        let rising = (value ?? 0) >= (previous ?? value ?? 0)
        return figured(content, rising: rising)
            .animation(still || !style.moves ? nil : curve, value: text)
            // THIS DOES NOT STOP THE BOARD BEING RE-LAID-OUT, WHICH IS WHAT IT WAS PUT HERE FOR
            // (measured 2026-09-03). `.geometryGroup` isolates GEOMETRY - where a child is put, and
            // what its transitions inherit from a moving parent - and geometry is downstream of
            // size, so an invalidation travelling UP the layout computers passes straight through
            // it: with the digits rolling alone and the line held still, the panel was still laid
            // out once per frame, at 47.4% of one core against 12.4% with nothing moving. What it
            // does buy is what its name says, and the figure it wraps is inside a `ViewThatFits`
            // whose candidates are swapped subtrees, so it stays.
            //
            // The cure for the cost is the one the shape beside it took: hand the interpolation to
            // the render server, so the view tree sees one update per reading rather than one per
            // frame (`FootprintSparklineLayerView`). This column still animates in the view tree
            // and still costs what it costs, which is the measurement A2 is about.
            .geometryGroup()
            .onChange(of: value) { old, _ in previous = old }
    }

    @ViewBuilder
    private func figured(_ content: Content, rising: Bool) -> some View {
        switch style {
        case .plain:
            content
        case .roll:
            // Handed the quantity, so the digits know which way to turn. A figure with no reading
            // behind it (a metric this tick could not state) still rolls, with no direction claimed.
            content.contentTransition(value.map { .numericText(value: $0) } ?? .numericText())
        case .fade:
            content.contentTransition(.opacity)
        case .push:
            // An identity change is what a transition needs, and the spelling is the identity: the
            // column around it holds the width either way (`SessionCardView.column`), so nothing
            // moves except the figure being replaced.
            content.id(text).transition(.push(from: rising ? .bottom : .top))
        }
    }
}

extension View {
    /// - Parameters:
    ///   - text: the figure as it is spelled, which is what a change is judged on.
    ///   - value: the same reading as a quantity, for the styles that have a direction.
    ///   - still: hold it still, for a reader who has asked for that.
    ///   - style: which motion, defaulting to this launch's.
    ///   - curve: which curve, defaulting to this launch's.
    func figureMotion(_ text: String, value: Double?, still: Bool,
                      style: CardMotion.FigureStyle = CardMotion.figures,
                      curve: Animation = CardMotion.figureFlip) -> some View {
        modifier(FigureMotion(text: text, value: value, still: still, style: style, curve: curve))
    }
}

/// Trackpad haptic via the Force Touch Taptic Engine; silent no-op without one. Fire only when a drag
/// actually commits a new order - never on plain movement. Rapid slot-crossings are floored so they
/// don't run together into a buzz.
@MainActor
enum Haptics {
    private static let minimumSnapInterval: TimeInterval = 0.12
    private static var lastSnapAt: TimeInterval = 0

    static func snap() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSnapAt >= minimumSnapInterval else { return }
        lastSnapAt = now
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}

struct CardFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

extension View {
    /// What a card LIFTED off the page looks like: a touch larger, a shadow under it, sitting at
    /// the point the drag says, and untouchable so it can never swallow the gesture carrying it.
    /// Spelled once because two boards now carry cards (the accounts, and the sessions one tab
    /// over) and a hand-held card that looked different on each would read as two gestures.
    ///
    /// The position is fed the CENTRE the drag computes rather than a translation, and the
    /// animation is switched off against it: the copy has to track the pointer 1:1, and a spring on
    /// its own position is a card that lags the hand it is in.
    func liftedCard(width: CGFloat, centre: CGPoint, following location: CGPoint) -> some View {
        frame(width: width)
            .scaleEffect(1.025)
            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
            .position(centre)
            .animation(.none, value: location)
            .allowsHitTesting(false)
    }

    /// Records this card's frame (in the named reorder coordinate space) for drag hit-testing.
    func cardFrame(id: String, in space: String) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: CardFramePreferenceKey.self,
                                       value: [id: proxy.frame(in: .named(space))])
            }
        )
    }
}

/// The card lifted by an in-flight drag: its source frame and where inside it the drag started, so
/// the floating preview tracks the pointer 1:1 from the exact grab point.
struct CardLift {
    let id: String
    let usage: AccountUsage
    let sourceFrame: CGRect
    let touchOffset: CGPoint
    var location: CGPoint

    /// Where the floating preview's centre currently sits. The single source for BOTH the preview's
    /// rendered position and the reorder hit-test probe: the two must never diverge, or reordering
    /// silently stops matching what the user sees.
    var previewCentre: CGPoint {
        CGPoint(x: location.x - touchOffset.x + sourceFrame.width / 2,
                y: location.y - touchOffset.y + sourceFrame.height / 2)
    }
}

/// The floating copy of the dragged account - the very view the layout renders at the current
/// density, slightly scaled with a shadow, following the pointer. Non-interactive so it never
/// swallows the drag. It has to follow the density: a card-shaped preview over a list of rows would
/// cover the targets it is being dropped between.
struct CardLiftPreview: View {
    let lift: CardLift
    let settings: SettingsStore
    var density: PanelDensity = .cards

    var body: some View {
        Group {
            if density == .list {
                // A row draws no surface of its own (the list's single card does), so the preview
                // lends it one - a floating row with nothing behind it would show the panel through.
                AccountListRowView(usage: lift.usage, settings: settings,
                                   showsDragHandle: true, handleProminent: true)
                    .tallyCard()
            } else {
                AccountCardView(usage: lift.usage, settings: settings,
                                showsDragHandle: true, handleProminent: true)
            }
        }
        .liftedCard(width: lift.sourceFrame.width, centre: lift.previewCentre,
                    following: lift.location)
    }
}

/// The card the drag should displace, or nil. The probe point (the lifted card's centre) must reach
/// the target's core (inset 20% per side) rather than merely graze its edge - the grid has horizontal
/// *and* vertical neighbors, and edge-triggered reordering feels jumpy in both directions.
func reorderTarget(at location: CGPoint, frames: [String: CGRect],
                   excluding draggedID: String, orderedIDs: [String]) -> String? {
    for id in orderedIDs where id != draggedID {
        guard let frame = frames[id] else { continue }
        let core = frame.insetBy(dx: frame.width * 0.2, dy: frame.height * 0.2)
        if core.contains(location) { return id }
    }
    return nil
}
