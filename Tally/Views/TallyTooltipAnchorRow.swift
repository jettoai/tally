import SwiftUI

/// The frame of the nearest enclosing `tallyTooltipAnchorRow()`, in the tooltip layer's space.
private struct TallyTooltipRowFrameKey: EnvironmentKey {
    static let defaultValue: CGRect? = nil
}

extension EnvironmentValues {
    var tallyTooltipRowFrame: CGRect? {
        get { self[TallyTooltipRowFrameKey.self] }
        set { self[TallyTooltipRowFrameKey.self] = newValue }
    }
}

extension View {
    /// Publishes this row's frame to the callouts inside it that pass `hugsRow: true`, so they
    /// clear the rows above and below rather than the hovered figure's own, shorter, edges.
    func tallyTooltipAnchorRow() -> some View {
        modifier(TallyTooltipAnchorRow())
    }
}

private struct TallyTooltipAnchorRow: ViewModifier {
    @State private var frame: CGRect?

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { proxy in
                let rect = proxy.frame(in: .named(TallyTooltip.space))
                Color.clear
                    .onAppear { frame = rect }
                    .onChange(of: rect) { _, new in frame = new }
            })
            .environment(\.tallyTooltipRowFrame, frame)
    }
}
