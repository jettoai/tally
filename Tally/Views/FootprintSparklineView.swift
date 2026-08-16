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
/// TWO DOTS, AND THEY ARE THE TWO FIGURES PRINTED BESIDE THE LINE. The brighter, larger one is the
/// last reading, which is the current value in its own group; the quieter, smaller one is the
/// highest, which is the `↑` figure. Neither is decoration: they are what tie the shape to the two
/// numbers a reader can act on (`SessionCardView.sessionFootprintTrends`). A warning turns BOTH of
/// them amber along with the line, and the pairing survives the change of colour as a difference in
/// weight: the current one is the full warning colour and the peak a step down from it, which is the
/// same order of loudness the primary and secondary greys draw on a calm card.
///
/// THE BRIGHT ONE IS ONLY HONEST BECAUSE THE CALLER PUTS THE LIVE READING IN. The newest reading
/// the ring has KEPT is up to a bucket old (`FootprintTrendSeries`), so drawn from the ring alone
/// this dot marked 20% on a session whose card said 400% (measured on a live board, 2026-08-15).
/// The row therefore hands over the kept readings with this instant's own reading appended, drawn
/// and never stored, and the last step of the line is worth less time than the others: that is the
/// price of the two figures agreeing, and it is paid on the one step nobody reads for its slope.
///
/// A flat line carries no peak dot at all, because a series that never moved is at its maximum
/// everywhere and a dot on the earliest of those would point at an arbitrary moment.
struct FootprintSparklineView: View {
    let values: [Double]
    /// Whether the reading this shape belongs to is the one worth somebody's eye, which this whole
    /// figure says by turning amber: the line, the peak dot and the current dot together, so the
    /// group reads as one warned block rather than as a marked piece beside unmarked ones.
    ///
    /// AND NOTHING ELSE, WHICH IS A DEPARTURE FROM THE ROW ABOVE. That row carries a triangle as
    /// well as the colour, because a warning is not a colour to a reader who cannot separate amber
    /// from grey (`SessionCardView.sessionFootprint`). It cannot be carried HERE: the smallest
    /// triangle that is still a triangle renders about eleven points wide, which is nearly half of
    /// this twenty-four point frame, and wherever it is put it covers readings - drawn over the
    /// line it hides the oldest forty per cent of the window along with the peak dot that most
    /// often sits in it, and drawn under it the shape is read across a filled amber wedge. A mark
    /// that destroys the thing it is marking is not a second channel. What carries the meaning
    /// instead, at this size: the amber has a luminance step from both greys it replaces (the
    /// primary current dot and the tertiary line), so the change is visible without the hue; and
    /// the condition itself is SAID rather than drawn for the reader who gets neither
    /// (`SessionCardView.spokenTrends`, which names it in words). Warned sparkline cells recolour
    /// their marks everywhere this convention appears, for the same reason. (Albert, 2026-08-16,
    /// having seen both the mark in the text flow and the mark on the shape.)
    var alert = false

    /// MEASURED AGAINST THE NARROWEST CARD, which is the only width that constrains it, and
    /// re-measured every time the row around it gains a field. It was 44pt when the row held three
    /// shapes and three peaks, and 32 when that would not fit ("4.2 G…" on every two-column board).
    /// The row now holds the CURRENT FIGURES as well, which is what it is for, so three shapes,
    /// three figures, a unit word and one peak have to fit the 236pt a 264pt card gives its
    /// content: at 32pt that measures 247pt and the peak is dropped, at 24pt it is 223pt and the
    /// peak stays (measured 2026-08-15 at 10pt against this app's own metrics). The shape survives
    /// the loss - these are 90 readings in a figure under a centimetre wide either way, read for
    /// their outline rather than point by point - and the peak is a number that cannot be inferred
    /// from any width of line at all.
    ///
    /// The height is the caption's own line box less its leading, so the line sits inside the row
    /// rather than setting the card's height.
    static let size = CGSize(width: 24, height: 11)
    private static let stroke: CGFloat = 1
    private static let peakDot: CGFloat = 2
    private static let currentDot: CGFloat = 3
    /// How far the peak dot is stepped down from the current one when both are amber. The calm line
    /// gets the same order of loudness from the primary and secondary greys, which a single named
    /// colour has no second rank of.
    private static let quietAlert: Double = 0.6

    var body: some View {
        let points = FootprintSparkline.points(values, in: Self.size, inset: Self.stroke / 2)
        ZStack(alignment: .topLeading) {
            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
            }
            .stroke(tone(calm: .tertiary),
                    style: StrokeStyle(lineWidth: Self.stroke, lineCap: .round, lineJoin: .round))
            if let index = FootprintSparkline.peakIndex(values), points.indices.contains(index) {
                dot(at: points[index], diameter: Self.peakDot)
                    .foregroundStyle(tone(calm: .secondary,
                                          warned: TallyColor.warning.opacity(Self.quietAlert)))
            }
            if let last = points.last {
                dot(at: last, diameter: Self.currentDot)
                    .foregroundStyle(tone(calm: .primary))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // The line says nothing a reader who cannot see it can use; the figures beside it do, and
        // the row states them in words (`SessionCardView.spokenTrends`).
        .accessibilityHidden(true)
    }

    /// What one piece of this figure is drawn in: the grey it has on a calm card, or the warning
    /// colour. Every piece asks the same question, which is what makes a warned figure read as one
    /// block - the line, the peak dot and the current dot change together or not at all.
    private func tone(calm: some ShapeStyle, warned: Color = TallyColor.warning) -> AnyShapeStyle {
        alert ? AnyShapeStyle(warned) : AnyShapeStyle(calm)
    }

    /// A mark on the line, positioned by its centre. The stack is top-leading, so a point is an
    /// offset from the same origin the geometry is measured in.
    private func dot(at point: CGPoint, diameter: CGFloat) -> some View {
        Circle()
            .frame(width: diameter, height: diameter)
            .offset(x: point.x - diameter / 2, y: point.y - diameter / 2)
    }
}
