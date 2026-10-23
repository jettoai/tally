import SwiftUI

/// The frame of the nearest enclosing `tallyTooltipAnchorRow()`, in the tooltip layer's space.
private struct TallyTooltipRowFrameKey: EnvironmentKey {
    static let defaultValue: CGRect? = nil
}

/// Every seam (top and bottom edge of a row, heading or title line) the nearest enclosing
/// `tallyTooltipSeams()` collected, in the tooltip layer's space.
private struct TallyTooltipSeamsKey: EnvironmentKey {
    static let defaultValue: [CGFloat] = []
}

/// The edges published by `tallyTooltipSeam()` and `tallyTooltipAnchorRow()`, on their way up to
/// the `tallyTooltipSeams()` that hands them back down.
private struct TallyTooltipSeamPreference: PreferenceKey {
    static let defaultValue: [CGFloat] = []
    static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) { value += nextValue() }
}

/// Where a card's labels and controls sit, in the card's own space (`tallyTooltipObstacles()`), for
/// a callout that goes beside its target (`TooltipPlacement.besideSlot`).
private struct TallyTooltipObstacleKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

private struct TallyTooltipObstaclesKey: EnvironmentKey {
    static let defaultValue: [CGRect] = []
}

extension TallyTooltip {
    /// The space a card's obstacles are measured in. Not the surface's: those frames shift with
    /// every scroll step and would re-render the whole card, these only move when the card does.
    static let cardSpace = "tallyTooltipCard"
}

extension EnvironmentValues {
    var tallyTooltipObstacles: [CGRect] {
        get { self[TallyTooltipObstaclesKey.self] }
        set { self[TallyTooltipObstaclesKey.self] = newValue }
    }

    var tallyTooltipRowFrame: CGRect? {
        get { self[TallyTooltipRowFrameKey.self] }
        set { self[TallyTooltipRowFrameKey.self] = newValue }
    }

    var tallyTooltipSeams: [CGFloat] {
        get { self[TallyTooltipSeamsKey.self] }
        set { self[TallyTooltipSeamsKey.self] = newValue }
    }
}

extension View {
    /// Publishes this row's frame to the callouts inside it that pass `hugsRow: true`, so they
    /// clear the rows above and below rather than the hovered figure's own, shorter, edges.
    func tallyTooltipAnchorRow() -> some View {
        modifier(TallyTooltipAnchorRow())
    }

    /// Publishes this line's top and bottom edges as seams a hugging callout's far edge may stop on
    /// (`TooltipPlacement.farEdgeStretch`), for the lines in a table that are not rows (its headings,
    /// the title above it). Rows publish theirs through `tallyTooltipAnchorRow()`.
    func tallyTooltipSeam() -> some View {
        background(GeometryReader { proxy in
            let rect = proxy.frame(in: .named(TallyTooltip.space))
            Color.clear.preference(key: TallyTooltipSeamPreference.self, value: [rect.minY, rect.maxY])
        })
    }

    /// Marks this view's frame as something a beside-the-target callout must not cover.
    func tallyTooltipObstacle() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: TallyTooltipObstacleKey.self,
                                   value: [proxy.frame(in: .named(TallyTooltip.cardSpace))])
        })
    }

    /// A card: measures its obstacles in its own space and hands them to the callouts inside it.
    func tallyTooltipObstacles() -> some View {
        modifier(TallyTooltipObstacles())
    }

    /// Collects the seams published inside this view and hands them to the callouts inside it.
    func tallyTooltipSeams() -> some View {
        modifier(TallyTooltipSeams())
    }
}

private struct TallyTooltipSeams: ViewModifier {
    @State private var seams: [CGFloat] = []

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(TallyTooltipSeamPreference.self) { seams = $0 }
            .environment(\.tallyTooltipSeams, seams)
    }
}

private struct TallyTooltipObstacles: ViewModifier {
    @State private var obstacles: [CGRect] = []

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: TallyTooltip.cardSpace)
            .onPreferenceChange(TallyTooltipObstacleKey.self) { obstacles = $0 }
            .environment(\.tallyTooltipObstacles, obstacles)
    }
}

private struct TallyTooltipAnchorRow: ViewModifier {
    @State private var frame: CGRect?

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { proxy in
                let rect = proxy.frame(in: .named(TallyTooltip.space))
                Color.clear
                    .preference(key: TallyTooltipSeamPreference.self, value: [rect.minY, rect.maxY])
                    .onAppear { frame = rect }
                    .onChange(of: rect) { _, new in frame = new }
            })
            .environment(\.tallyTooltipRowFrame, frame)
    }
}
