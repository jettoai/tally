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

    /// The tray tile grid: as many tiles per row as fit in `regionWidth`.
    enum Tray {
        static let tileWidth: CGFloat = 110
        static let tileHeight: CGFloat = 34
        static let gap: CGFloat = 8
        static var columns: Int { max(1, Int((regionWidth + gap) / (tileWidth + gap))) }
        static var rowWidth: CGFloat { CGFloat(columns) * tileWidth + CGFloat(columns - 1) * gap }
    }
}
