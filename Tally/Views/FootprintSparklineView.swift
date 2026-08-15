import SwiftUI

/// ONE METRIC'S LAST QUARTER HOUR, drawn at the size of a word.
///
/// A LINE RATHER THAN A CHART. Everything a chart brings - axes, ticks, a legend, a scale to
/// configure - is furniture this figure has no room for and no reader for either: what is being
/// asked here is "has it been like this for a while", which is a shape, and the numbers that answer
/// it precisely are already printed beside it (the current value on the line above, the peak on the
/// line's own right). So the geometry is a dozen lines of arithmetic next door
/// (`FootprintSparkline`), stated where an assertion harness can read it, and this only strokes it.
///
/// TWO DOTS, AND THEY MEAN DIFFERENT THINGS. The brighter one is the newest reading, which is the
/// value the card states above; the quieter one is the highest, which is the value stated to the
/// right of the line. Neither is decoration: they are what tie the shape to the two figures a
/// reader can act on. A flat line carries only the first, because a series that never moved is at
/// its maximum everywhere and a dot on the earliest of those would point at an arbitrary moment.
struct FootprintSparklineView: View {
    let values: [Double]

    /// MEASURED AGAINST THE NARROWEST CARD, which is the only width that constrains it: three of
    /// these, their three gaps and three peak figures have to fit the 235pt a 263pt card gives its
    /// content, and at 44pt they did not - every memory peak on a two-column board was drawn as
    /// "4.2 G…" (measured 2026-08-15 on a live board). At 32 the row fits with room for a
    /// three-digit CPU peak beside it, and the shape survives the loss: these are 90 readings in a
    /// figure a centimetre wide either way, read for their outline rather than point by point.
    ///
    /// The height is the caption's own line box less its leading, so the line sits inside the row
    /// rather than setting the card's height.
    static let size = CGSize(width: 32, height: 11)
    private static let stroke: CGFloat = 1
    private static let peakDot: CGFloat = 2
    private static let currentDot: CGFloat = 3

    var body: some View {
        let points = FootprintSparkline.points(values, in: Self.size, inset: Self.stroke / 2)
        ZStack(alignment: .topLeading) {
            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
            }
            .stroke(.tertiary, style: StrokeStyle(lineWidth: Self.stroke, lineCap: .round,
                                                  lineJoin: .round))
            if let index = FootprintSparkline.peakIndex(values), points.indices.contains(index) {
                dot(at: points[index], diameter: Self.peakDot).foregroundStyle(.secondary)
            }
            if let last = points.last {
                dot(at: last, diameter: Self.currentDot).foregroundStyle(.primary)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // The line says nothing a reader who cannot see it can use; the figures beside it do, and
        // the row states them in words (`SessionCardView.spokenTrends`).
        .accessibilityHidden(true)
    }

    /// A mark on the line, positioned by its centre. The stack is top-leading, so a point is an
    /// offset from the same origin the geometry is measured in.
    private func dot(at point: CGPoint, diameter: CGFloat) -> some View {
        Circle()
            .frame(width: diameter, height: diameter)
            .offset(x: point.x - diameter / 2, y: point.y - diameter / 2)
    }
}
