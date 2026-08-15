import CoreGraphics

/// The usage surface's width arithmetic: how wide the panel is at a given column count, how many
/// columns a display can actually seat, and what one card ends up being. Pure numbers, kept out of
/// the view so all three surfaces share one answer and so it can be checked without AppKit
/// (tests/panelwidth).
///
/// It is the width twin of `ScreenFitStack`: that one keeps the surface from growing past the
/// display it opens on by handing the excess height to a scroll region. Width cannot be scrolled
/// away without hiding a whole column, so here the COUNT is what gives - a chosen column count is
/// honoured as far as the display can seat it and no further. A panel wider than its display is not
/// a wide panel, it is a panel with a piece missing: the popover hangs off the status item, so what
/// falls off is the right-hand column and everything in it.
enum PanelGeometry {
    /// 12pt of content padding each side of the grid, and the gutter between columns. The list uses
    /// the same pair (see `AccountListRowView.columnGap`), so both densities divide space alike.
    static let contentPadding: CGFloat = 12
    static let columnGap: CGFloat = 10

    /// How far the wordmark's INK reaches left of the frame it is laid out in. The glyph is given a
    /// height and left to find its own width, and it draws the letterform larger than the box that
    /// ends up around it - measured off a window capture, the mark's first ink sat 1.5pt from the
    /// panel edge while the frame it belongs to started at 12.
    static let brandInkOverhang: CGFloat = 10.5

    /// Where a brand cluster's frame starts, so that its INK starts on the content line - the same x
    /// the session strip, the fleet rows, the cards and the footer controls all begin at. Padding
    /// the frame to that line instead is what left the logo reading as pinned to the edge with
    /// everything below it beginning 12pt in.
    ///
    /// Here rather than in the header that first needed it, because the pick panel now speaks the
    /// same visual language and a second copy of 10.5 is two numbers free to drift apart.
    static let brandLead = contentPadding + brandInkOverhang

    /// The card width the multi-column panel widths below were laid out from. Nominal: the widths
    /// are rounded to whole points, so a card lands within half a point of this (see `cardWidth`).
    static let cardColumnWidth: CGFloat = 263

    /// The panel width for a card layout. One column is a reading width rather than a card width -
    /// a lone 263pt card in a 287pt panel reads as a fragment - so it does not come from the same
    /// arithmetic as the rest.
    static func cardPanelWidth(columns: Int) -> CGFloat {
        switch columns {
        case ..<2: return 380
        case 2: return 560
        case 3: return 834    // 24 padding + 3x263 cards + 2x10 gaps
        default: return 1108  // 24 padding + 4x263 cards + 3x10 gaps
        }
    }

    /// The panel width for a list of comfortable rows: content padding each side, a row per column,
    /// and the gutter between them.
    static func listPanelWidth(columns: Int, rowWidth: CGFloat) -> CGFloat {
        let count = CGFloat(max(1, columns))
        return 2 * contentPadding + count * rowWidth + (count - 1) * columnGap
    }

    /// How many columns of `columnWidth` a display of `usableWidth` can seat. Never fewer than one:
    /// on a display too narrow even for a single column the panel overflows a little rather than
    /// showing nothing at all, the same floor `ScreenFitStack.minFlexibleHeight` keeps on the other
    /// axis. Nothing on sale is that narrow; the floor is here so the arithmetic cannot return zero.
    static func seats(columnWidth: CGFloat, in usableWidth: CGFloat) -> Int {
        let step = columnWidth + columnGap
        guard step > 0, usableWidth.isFinite else { return 1 }
        return max(1, Int((usableWidth - 2 * contentPadding + columnGap) / step))
    }

    /// A column count, honoured as far as the display can seat it. Both densities pass their number
    /// through this one place - the chosen one and the automatic one alike, because a count the
    /// display cannot seat is off the screen whoever picked it.
    static func seated(_ columns: Int, columnWidth: CGFloat, in usableWidth: CGFloat) -> Int {
        min(max(1, columns), seats(columnWidth: columnWidth, in: usableWidth))
    }

    /// HOW MANY COLUMNS A GRID INSIDE THE PANEL LAYS ITSELF OUT IN: what the user asked for, bounded
    /// by what the width can actually hold, or nothing at all when they asked for nothing.
    ///
    /// WHAT YOU PICKED IS WHAT YOU GET, which the session board did not do. The panel's own width
    /// comes from the usage page's column count, and that board laid its cards out adaptively
    /// instead - so a panel one comfortable ROW wide (about 480pt) seated two 210pt session cards
    /// while the picker beside them read "1". A count is a promise about what is on screen, and a
    /// page that answers it with a different number is the picker lying (Albert, 2026-08-15).
    ///
    /// `nil` IS AUTO AND MEANS ADAPTIVE, not "one". Auto is the mode that delegates the layout to
    /// the system, exactly as it does for the cards on the usage page, so the caller keeps its
    /// adaptive grid and this says only "the user did not pick".
    ///
    /// THE PANEL'S WIDTH IS NEVER WHAT GIVES. It is the usage page's to decide, and a session board
    /// that widened the surface would make switching tabs resize the window; so a count the width
    /// cannot seat steps DOWN to what fits, the same direction `seated` steps for the same reason.
    ///
    /// - Parameters:
    ///   - chosen: an explicit count, or nil for auto.
    ///   - width: the grid's own width, padding already taken off.
    ///   - minimum: the narrowest a card may be laid out at.
    ///   - gap: the gutter between two columns.
    static func gridColumns(chosen: Int?, in width: CGFloat, minimum: CGFloat,
                            gap: CGFloat) -> Int? {
        guard let chosen, chosen >= 1 else { return nil }
        let step = minimum + gap
        // A width that is not a number yet (the first layout pass) honours the choice rather than
        // inventing a bound from it: the next pass corrects it, and one frame at the asked-for
        // count is better than one frame at a number nothing measured.
        guard step > 0, width.isFinite, width > 0 else { return chosen }
        return min(chosen, max(1, Int((width + gap) / step)))
    }

    /// What one card comes out at inside a grid of `width`: the columns divide up what is left of it
    /// after the content padding and the gutters. The panel widths above are chosen so this lands on
    /// `cardColumnWidth`, which is why a card stays the same size as columns are added and only the
    /// panel grows.
    static func cardWidth(inGridOf width: CGFloat, columns: Int) -> CGFloat {
        let count = CGFloat(max(1, columns))
        return (width - 2 * contentPadding - columnGap * (count - 1)) / count
    }
}
