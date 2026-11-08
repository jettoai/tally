import SwiftUI

/// The pool ring of a provider card: the arc is the share shown (left or used), the figure sits in
/// the middle with a one-word caption under it. Round caps, a faint track, the colour handed in by
/// the caller (brand while healthy, the status colour when low).
struct PoolRingView: View {
    var size: CGFloat = PanelStyle.ringSize
    /// 0...1, the share of the ring that is drawn.
    var fraction: Double
    var tint: Color
    var figure: String
    var caption: String? = nil

    var body: some View {
        let width = max(2.5, size * 0.085)
        let inset = width / 2 + 0.5
        ZStack {
            Circle().inset(by: inset).stroke(PanelStyle.track, lineWidth: width)
            Circle().inset(by: inset)
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text(figure)
                    .font(Font(NSFont.monospacedDigitSystemFont(ofSize: size * 0.27, weight: .bold) as CTFont))
                    .foregroundStyle(PanelStyle.text)
                if let caption {
                    Text(caption)
                        .font(PanelStyle.font(size * 0.13, 600))
                        .foregroundStyle(PanelStyle.text2)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, width + 2)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([figure, caption].compactMap { $0 }.joined(separator: " "))
    }
}
