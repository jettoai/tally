import CoreGraphics
import Foundation

// The pure half of the Ledger and Tray preview layouts (B-3461): which pool a heading draws from, what
// a window is called, and the widths the two layouts are laid out at. Kept out of UsageLayout.swift
// (the flag reader, which tests/usagelayout/flag.swift compiles alone) and out of the SwiftUI files so
// tests/usagelayout can compile it and assert on the numbers the views actually use.

extension UsageLayout {
    /// The summary a ledger heading (`tier` nil: the whole, unsplit provider) or one plan's row (a tier;
    /// a nil-named tier is the unknown plan, never "any plan") draws its pool from.
    static func poolSummary(_ summaries: [FleetSummary], providerID: String,
                            tier: FleetSummary.Tier?) -> FleetSummary? {
        summaries.first { $0.providerID == providerID && $0.planTier == tier }
    }

    /// The short window name a layout prints for a window or pool of `kind`, the same words as the
    /// ledger's column heads, so a flagship pool is never labelled as the week.
    static func windowName(_ kind: MetricKind) -> String {
        switch kind {
        case .session: return L("5h")
        case .weeklyModel: return L("Flagship")
        default: return L("Week")
        }
    }

    /// The narrowest account region a layout is drawn into: one card column, less its padding.
    static let regionWidth = PanelGeometry.cardPanelWidth(columns: 1) - 2 * PanelGeometry.contentPadding

    /// The ledger row: name, three bars, the tightest number, a badge, all in `regionWidth`.
    enum Ledger {
        static let nameWidth: CGFloat = 76
        static let numberWidth: CGFloat = 30
        static let badgeWidth: CGFloat = 16
        static let gap: CGFloat = 10
        /// The panel's own horizontal padding around the ledger, each side.
        static let inset: CGFloat = 2
        /// What is left for the three bars once everything else in the row is laid out.
        static var barWidth: CGFloat {
            floor((regionWidth - 2 * inset - nameWidth - numberWidth - badgeWidth - 5 * gap) / 3)
        }
        static var rowWidth: CGFloat {
            2 * inset + nameWidth + 3 * barWidth + numberWidth + badgeWidth + 5 * gap
        }
    }

    /// How far a binding window's ring stands outside its bar (LayoutBar), in every layout.
    static let ringOutset: CGFloat = 1.5

    /// The tray tile grid: as many tiles per row as fit in `regionWidth`.
    enum Tray {
        static let tileWidth: CGFloat = 110
        static let tileHeight: CGFloat = 34
        static let gap: CGFloat = 8
        static var columns: Int { max(1, Int((regionWidth + gap) / (tileWidth + gap))) }
        static var rowWidth: CGFloat { CGFloat(columns) * tileWidth + CGFloat(columns - 1) * gap }

        // Inside a tile (B-3461): a top row (upright bars, name, number) over the week's bar.
        static let inset: CGFloat = 6
        static let topInset: CGFloat = 7
        static let rowHeight: CGFloat = 15
        static let rowGap: CGFloat = 4
        static let weekThickness: CGFloat = 3
        static let bottomInset: CGFloat = 5
        static let rowSpacing: CGFloat = 5
        static let uprightLength: CGFloat = 14
        static let uprightThickness: CGFloat = 4
        static let uprightSpacing: CGFloat = 2
        /// Budgets for the name and the number beside the upright bars; the screenshot is the proof.
        static let nameFloor: CGFloat = 50
        static let numberAllowance: CGFloat = 16

        static var contentWidth: CGFloat { tileWidth - 2 * inset }
        static var stackHeight: CGFloat { topInset + rowHeight + rowGap + weekThickness + bottomInset }
        static func uprightWidth(_ count: Int) -> CGFloat {
            CGFloat(count) * uprightThickness + CGFloat(max(0, count - 1)) * uprightSpacing
        }
    }
}

/// The three windows an account can report, in the order both layouts read them (5h, week,
/// flagship). A window the plan does not have is nil, which draws differently from an empty one.
/// Lives here, not beside the views, so tests/usagelayout can assert on which windows a tile draws.
struct LayoutWindows {
    let session: UsageMetric?
    let weekly: UsageMetric?
    let flagship: UsageMetric?

    init(_ usage: AccountUsage) {
        let columns = UsageMetric.columns(usage.metrics)
        session = columns.session
        weekly = columns.weekly
        flagship = usage.headline.flatMap { $0.isModelScoped ? $0 : nil }
    }

    /// The column names, in that order. Computed, not stored: the app language can change at runtime.
    static var names: [String] { [MetricKind.session, .weeklyAll, .weeklyModel].map(UsageLayout.windowName) }

    var all: [(name: String, metric: UsageMetric?)] {
        zip(Self.names, [session, weekly, flagship]).map { (name: $0, metric: $1) }
    }

    /// The windows the plan reports, in the same order.
    var present: [(name: String, metric: UsageMetric?)] { all.filter { $0.metric != nil } }

    /// The windows a tray tile stands upright at its left, only those the plan reports, 5h before
    /// flagship. The week is not among them: it lies along the tile's bottom (B-3461).
    var upright: [(name: String, metric: UsageMetric)] {
        [(Self.names[0], session), (Self.names[2], flagship)].compactMap { name, metric in
            metric.map { (name: name, metric: $0) }
        }
    }

    /// Whether `metric` is the account's binding window. A missing window never is, even when the
    /// account has no binding window either (two nil ids are not a match).
    static func isBinding(_ metric: UsageMetric?, _ binding: UsageMetric?) -> Bool {
        metric != nil && metric?.id == binding?.id
    }
}
