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

extension EnvironmentValues {
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
