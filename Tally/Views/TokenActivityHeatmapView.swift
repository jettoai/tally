import SwiftUI

/// One project's past year of daily token activity, drawn as a GitHub-style contribution graph.
///
/// A single `Canvas` rather than 371 shape views: several rows can be expanded at once, and a few
/// thousand live view nodes inside a popover that re-lays out on every hover is exactly the cost
/// this graph is not worth. The pointer is answered by reversing the same grid arithmetic instead
/// of by per-square hover targets.
struct TokenActivityHeatmapView: View {
    private let cells: [TokenActivityHeatmap.Cell]
    private let monthLabels: [MonthLabel]
    private let weekdayLabels: [WeekdayLabel]
    private let caption: String
    private let geometry: Geometry
    /// How a hovered square names its day. Held rather than rebuilt per hover, and a value type
    /// rather than a `DateFormatter`, so the renderer stays free of reference state.
    private let dateStyle: Date.FormatStyle

    @State private var hovered: TokenActivityHeatmap.Cell?

    private static let labelFontSize: CGFloat = 8

    /// - Parameter hoverPeak: start with the window's heaviest day hovered, ring and callout and
    ///   all, for a design capture (`TokenGraphPreview.hoversPeak` decides; the flag's reasoning is
    ///   there). It seeds the same state a pointer writes, so the first real hover replaces it and
    ///   leaving the graph clears it, which is what keeps this to one hover path instead of two.
    init(dailyTotals: [Int: Int64], today: Int, width: CGFloat, hoverPeak: Bool = false) {
        let cells = TokenActivityHeatmap.cells(dailyTotals: dailyTotals, today: today)
        self.cells = cells
        geometry = Geometry(width: width)
        let peak = cells.max { $0.total < $1.total }
        _hovered = State(initialValue: hoverPeak && (peak?.total ?? 0) > 0 ? peak : nil)

        // UTC, because the day integers are already local calendar days (see
        // `TokenActivityHeatmap.date(forDay:)`), and the app's language rather than the system's,
        // which is the rule the rest of the app's dates follow (`AppLocale.shortDateTime`).
        let zone = TimeZone(secondsFromGMT: 0) ?? .current
        let locale = AppLocale.current
        dateStyle = Date.FormatStyle(date: .abbreviated, timeZone: zone).locale(locale)
        let monthStyle = Date.FormatStyle(locale: locale, timeZone: zone).month(.abbreviated)

        monthLabels = Self.months(cells: cells, style: monthStyle)
        weekdayLabels = geometry.showsWeekdayLabels
            ? [WeekdayLabel(row: 0, text: L("Mon")), WeekdayLabel(row: 2, text: L("Wed")),
               WeekdayLabel(row: 4, text: L("Fri"))]
            : []
        let total = TokenActivityHeatmap.windowTotal(dailyTotals: dailyTotals, today: today)
        caption = String(localized: "Past year: \(UsageFormat.compactCount(total)) tokens",
                         bundle: AppLocale.bundle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            grid
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(caption))
    }

    private var grid: some View {
        // Every value the renderer reads is copied out first: the closure outlives this body pass,
        // and handing it plain values keeps it off the view (and off the main actor's state).
        let cells = self.cells
        let geometry = self.geometry
        let months = monthLabels
        let weekdays = weekdayLabels
        let hovered = self.hovered
        return Canvas { context, _ in
            Self.render(context: &context, cells: cells, geometry: geometry,
                        months: months, weekdays: weekdays, hovered: hovered)
        }
        .frame(height: geometry.height)
        .onContinuousHover { phase in
            if case .active(let point) = phase { self.hovered = cell(at: point) }
            else { self.hovered = nil }
        }
        // The callout is a zero-size target parked on the hovered square rather than a target per
        // square: the pointer is already being tracked above, and 371 hover-tracking views is the
        // cost the Canvas exists to avoid. `forced` is what lets a target publish without owning
        // the hover, and the dwell is dropped with it, which is what a graph wants anyway - the
        // pointer sweeps across squares and a delay would answer the one it just left.
        .overlay(alignment: .topLeading) { calloutAnchor }
    }

    @ViewBuilder
    private var calloutAnchor: some View {
        if let hovered {
            Color.clear
                .frame(width: geometry.cell, height: geometry.cell)
                .tallyTooltip(TokenActivityHeatmap.date(forDay: hovered.day).formatted(dateStyle),
                              detail: String(localized: "\(UsageFormat.compactCount(hovered.total)) tokens",
                                             bundle: AppLocale.bundle),
                              forced: true)
                // Padding rather than an offset: the callout positions itself against the frame the
                // target reports, so the target has to be LAID OUT on the square rather than drawn
                // there by a transform.
                .padding(.leading, geometry.x(column: hovered.column))
                .padding(.top, geometry.y(row: hovered.row))
                .allowsHitTesting(false)
        }
    }

    /// Which square the pointer is over, or nil for the labels, the gaps at the edges, and the days
    /// of the current week that have not happened yet.
    ///
    /// A square's position IS its index, because the grid is built column-major and dense with only
    /// the tail of the current week missing (asserted in `tests/run-tokenheatmap-tests.sh`), so the
    /// pointer is answered by arithmetic rather than by a second copy of the grid keyed by position.
    private func cell(at point: CGPoint) -> TokenActivityHeatmap.Cell? {
        let x = point.x - geometry.leftLabel
        let y = point.y - geometry.topLabel
        guard x >= 0, y >= 0 else { return nil }
        let column = Int(x / geometry.pitch)
        let row = Int(y / geometry.pitch)
        guard column >= 0, column < TokenActivityHeatmap.weekColumns,
              row >= 0, row < TokenActivityHeatmap.weekdays else { return nil }
        let index = column * TokenActivityHeatmap.weekdays + row
        return index < cells.count ? cells[index] : nil
    }

    // MARK: Rendering

    private static func render(context: inout GraphicsContext,
                               cells: [TokenActivityHeatmap.Cell],
                               geometry: Geometry,
                               months: [MonthLabel],
                               weekdays: [WeekdayLabel],
                               hovered: TokenActivityHeatmap.Cell?) {
        for label in weekdays {
            draw(text: label.text, in: &context,
                 at: CGPoint(x: 0, y: geometry.y(row: label.row) + geometry.cell / 2),
                 anchor: .leading)
        }

        // A month name is drawn only where the previous one has finished, so the narrow panel drops
        // every other month instead of overprinting twelve of them into a smear.
        var occupiedUntil: CGFloat = -.greatestFiniteMagnitude
        for label in months {
            let x = geometry.x(column: label.column)
            let width = measure(text: label.text, in: context).width
            guard x >= occupiedUntil, x + width <= geometry.width else { continue }
            draw(text: label.text, in: &context,
                 at: CGPoint(x: x, y: geometry.topLabel / 2), anchor: .leading)
            occupiedUntil = x + width + 3
        }

        for cell in cells {
            let rect = CGRect(x: geometry.x(column: cell.column), y: geometry.y(row: cell.row),
                              width: geometry.cell, height: geometry.cell)
            let path = Path(roundedRect: rect, cornerRadius: max(0.5, geometry.cell * 0.22))
            if cell.level == 0 {
                // The same track colour the share bars draw, so an empty day reads as the graph's
                // background rather than as a fifth level.
                context.fill(path, with: .style(.quaternary))
            } else {
                let opacity = TokenActivityHeatmap.levelOpacity[
                    min(cell.level, TokenActivityHeatmap.levelOpacity.count) - 1]
                context.fill(path, with: .color(Color.accentColor.opacity(opacity)))
            }
            if cell == hovered {
                // A ring rather than a lightened fill: the fill is the value being read, so the
                // pointer must not change it.
                context.stroke(path, with: .color(Color.primary.opacity(0.55)), lineWidth: 1)
            }
        }
    }

    private static func styled(_ text: String) -> Text {
        Text(text).font(.system(size: labelFontSize))
    }

    private static func measure(text: String, in context: GraphicsContext) -> CGSize {
        context.resolve(styled(text)).measure(in: CGSize(width: 200, height: 40))
    }

    private static func draw(text: String, in context: inout GraphicsContext,
                             at point: CGPoint, anchor: UnitPoint) {
        var resolved = context.resolve(styled(text))
        resolved.shading = .color(.secondary)
        context.draw(resolved, at: point, anchor: anchor)
    }

    /// One label per month change, at the column whose Monday opened that month.
    private static func months(cells: [TokenActivityHeatmap.Cell],
                               style: Date.FormatStyle) -> [MonthLabel] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        var labels: [MonthLabel] = []
        var previousMonth: Int?
        for cell in cells where cell.row == 0 {
            let date = TokenActivityHeatmap.date(forDay: cell.day)
            let month = calendar.component(.month, from: date)
            // The leftmost column carries no label: it is a partial month by construction, and a
            // name at the very edge would claim the space the first whole month needs.
            if let previousMonth, previousMonth != month {
                labels.append(MonthLabel(column: cell.column, text: date.formatted(style)))
            }
            previousMonth = month
        }
        return labels
    }

    // MARK: Layout

    private struct MonthLabel: Sendable {
        let column: Int
        let text: String
    }

    private struct WeekdayLabel: Sendable {
        let row: Int
        let text: String
    }

    /// Where everything sits at this width. Nothing here is a fixed square size: the tab is drawn
    /// at the panel's width, which ranges from a 380pt single column to a four-column window, and a
    /// hardcoded square would either overflow the narrow one or leave the wide one half empty.
    private struct Geometry: Sendable {
        let width: CGFloat
        let pitch: CGFloat
        let cell: CGFloat
        let leftLabel: CGFloat
        let topLabel: CGFloat
        let showsWeekdayLabels: Bool

        /// Room for the weekday column ("Mon" / "週一" at the label size, plus the gap to the grid).
        static let leftLabelWidth: CGFloat = 24
        /// The month-name strip above the grid.
        static let topLabelHeight: CGFloat = 11
        /// Below this the squares are thinner than the text beside them, so the weekday column
        /// stops earning its width and the grid takes it back.
        static let minPitchForWeekdayLabels: CGFloat = 4.5

        init(width: CGFloat) {
            self.width = max(width, 1)
            let columns = CGFloat(TokenActivityHeatmap.weekColumns)
            let withLabels = (self.width - Self.leftLabelWidth) / columns
            showsWeekdayLabels = withLabels >= Self.minPitchForWeekdayLabels
            leftLabel = showsWeekdayLabels ? Self.leftLabelWidth : 0
            topLabel = Self.topLabelHeight
            pitch = max(2, (self.width - leftLabel) / columns)
            // The gap is a share of the pitch rather than a constant: at the narrow panel a fixed
            // 2pt would be half the column, and the graph would read as gaps with squares in them.
            cell = max(1, pitch - min(2, pitch * 0.2))
        }

        var height: CGFloat { topLabel + pitch * CGFloat(TokenActivityHeatmap.weekdays) }
        func x(column: Int) -> CGFloat { leftLabel + CGFloat(column) * pitch }
        func y(row: Int) -> CGFloat { topLabel + CGFloat(row) * pitch }
    }
}
