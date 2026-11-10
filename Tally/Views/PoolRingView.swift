import SwiftUI

/// The pool ring of a provider card: the arc is the share shown (left or used), the figure sits in
/// the middle with a one-word caption under it. A thick round-capped arc in a two-colour gradient on
/// a faint groove; the gradient is handed in by the caller (brand while healthy, amber or red when low).
struct PoolRingView: View {
    var size: CGFloat = PanelStyle.ringSize
    /// 0...1, the share of the ring that is drawn.
    var fraction: Double
    var gradient: [Color]
    /// The figure with its percent sign ("58%"); the sign is drawn small and raised.
    var figure: String
    var caption: String? = nil

    var body: some View {
        let width = PanelStyle.ringStroke
        let inset = width / 2 + 0.5
        // The arc is stroked first and turned afterwards, so the gradient turns with it.
        let arc = LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
        ZStack {
            Circle().inset(by: inset).stroke(PanelStyle.track, lineWidth: width)
            Circle().inset(by: inset)
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(arc, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                figureText
                    .foregroundStyle(PanelStyle.text)
                if let caption {
                    Text(caption)
                        .font(PanelStyle.font(9, 600))
                        .tracking(0.4)
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

    /// "58" at 17pt with a 9pt "%" raised beside it.
    private var figureText: Text {
        let digitsFont = PanelStyle.font(17, 650).monospacedDigit()
        guard figure.hasSuffix("%") else { return Text(verbatim: figure).font(digitsFont) }
        return Text(verbatim: String(figure.dropLast())).font(digitsFont)
            + Text(verbatim: "%").font(PanelStyle.font(9, 600)).baselineOffset(6)
    }
}
