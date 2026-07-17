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

/// The floating copy of the dragged card - the same `AccountCardView` the grid renders, slightly
/// scaled with a shadow, following the pointer. Non-interactive so it never swallows the drag.
struct CardLiftPreview: View {
    let lift: CardLift
    let settings: SettingsStore

    var body: some View {
        AccountCardView(usage: lift.usage, settings: settings)
            .frame(width: lift.sourceFrame.width)
            .scaleEffect(1.025)
            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
            .position(lift.previewCentre)
            .animation(.none, value: lift.location)
            .allowsHitTesting(false)
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
