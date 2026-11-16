import SwiftUI

/// The pool ring of a provider card: the arc is the share shown (left or used), the figure sits in
/// the middle with a one-word caption under it. A thick round-capped arc on
/// a faint groove, both in the state's colours from the one meter palette; a spent ring has no arc and a red groove.
struct PoolRingView: View {
    var size: CGFloat = PanelStyle.ringSize
    /// 0...1, the share of the ring that is drawn.
    var fraction: Double
    /// The state the ring is in; its arc, groove and figure all read the one meter palette.
    var severity: MetricSeverity
    /// The figure with its percent sign ("58%"); the sign is drawn small and raised.
    var figure: String
    var caption: String? = nil
    /// The groove is drawn dashed: the ring has no figure to show (a pool that cannot be combined).
    var dashed = false

    var body: some View {
        let width = PanelStyle.ringStroke
        let inset = width / 2 + 0.5
        ZStack {
            Circle().inset(by: inset)
                .stroke(severity.groove, style: StrokeStyle(lineWidth: width, dash: dashed ? [3, 4] : []))
            if fraction > 0 {
                Circle().inset(by: inset)
                    .trim(from: 0, to: min(1, fraction))
                    .stroke(severity.color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 2) {
                figureText
                    .foregroundStyle(severity.figureInk ?? PanelStyle.text)
                if let caption {
                    Text(caption)
                        .font(PanelStyle.font(9, 600))
                        .tracking(0.4)
                        .foregroundStyle(severity == .exhausted ? TallyColor.alarmInk : PanelStyle.text2)
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
