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

    /// WHAT ONE CARD COMES OUT AT IN A RUN THAT DIVIDES UP THE WIDTH IT IS GIVEN: the grid, less the
    /// gutters, split between the columns, then held between the narrowest the card may be laid out
    /// at and the widest it is worth reading.
    ///
    /// A COUNT IS A PROMISE ABOUT THE READING TOPOLOGY, NEVER ABOUT THE CARD'S WIDTH. It used to be
    /// both, because the board spent an explicit count at the width the ACCOUNT card ladder gives one
    /// (263pt, a figure that means nothing on this page: it is neither the narrowest a session card
    /// may be nor the widest it should be read at). A count of one in a 504pt panel therefore froze a
    /// 263pt card beside 217pt of nothing, which is the complaint this arithmetic answers (Albert,
    /// 2026-08-18). The cards take the room instead, up to `cap`, and what a cap leaves over stays
    /// empty on the trailing side rather than stretching one card into a band across the surface.
    ///
    /// The gap is asked for rather than assumed: the session board sits its cards 8pt apart where the
    /// account grid uses 10, and a run measured with the wrong gutter is a run that does not fit the
    /// grid it describes.
    static func flexibleCardWidth(inGridOf width: CGFloat, columns: Int, gap: CGFloat,
                                  minimum: CGFloat, cap: CGFloat) -> CGFloat {
        let count = CGFloat(max(1, columns))
        return min(cap, max(minimum, (width - gap * (count - 1)) / count))
    }

    /// How wide a run of those cards is laid out: the cards and the gutters between them. Not a panel
    /// width - it is what a page whose surface is another page's to size lays its board out at, so
    /// the board is capped to this and the rest of the panel stays empty
    /// (`PopoverRootView.sessionsBoardWidth`).
    static func flexibleRunWidth(inGridOf width: CGFloat, columns: Int, gap: CGFloat,
                                 minimum: CGFloat, cap: CGFloat) -> CGFloat {
        let count = CGFloat(max(1, columns))
        let card = flexibleCardWidth(inGridOf: width, columns: columns, gap: gap,
                                     minimum: minimum, cap: cap)
        return count * card + (count - 1) * gap
    }

    /// A remembered column count, read back into the range that is still on offer: a stored number
    /// past the highest tile comes back to that tile rather than to a count nothing can select, and
    /// anything that is not a count at all (zero, a negative, a key that was never written) is auto.
    ///
    /// Named once because the ranges move: the compact list used to go to four and now stops at
    /// three, and every stored count has to survive that without leaving a picker blank.
    static func storedColumns(_ stored: Int, max limit: Int) -> Int {
        stored > 0 ? min(stored, limit) : 0
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

    /// HOW MANY COLUMNS A BOARD INSIDE THE PANEL LAYS ITSELF OUT IN: as many as were asked for, or
    /// under auto as many as there are cards to seat, bounded either way by what the width can hold.
    ///
    /// AN EXPLICIT COUNT IS THE MOST COLUMNS THE BOARD WILL USE, not a guarantee of that many. The
    /// promise it can keep is about the reading topology - one column is read top to bottom, two are
    /// read side by side - and a width that seats fewer than were asked for is a fact about the
    /// surface rather than a broken promise. The picker says so in the words it offers the count in
    /// ("Up to 2 columns", `LayoutColumnPicker`), which is what stops a panel one comfortable row
    /// wide from highlighting "2" over a board laying out one (Albert, 2026-08-15 and 2026-08-18).
    ///
    /// AUTO IS RESOLVED HERE RATHER THAN LEFT ADAPTIVE, and what it resolves to is the number of
    /// cards the board was opened with: a lone session takes a column of its own instead of being
    /// squeezed into a fifth of a wide panel, and a board of five uses every column that fits. The
    /// count is frozen by the caller when the page appears (`PopoverRootView.sessionsAutoColumns`),
    /// so a session arriving behind the reader's back is appended rather than re-flowing the board
    /// they are in the middle of reading.
    ///
    /// THE PANEL'S WIDTH IS NEVER WHAT GIVES. It is the account pages' to decide and it is the same
    /// on every page, because a session board that widened the surface made switching tabs resize
    /// the window (shipped once, 2026-08-17, and reported the same day); so a count the width cannot
    /// seat steps DOWN to what fits, the same direction `seated` steps for the same reason. What a
    /// count buys instead is how the CARDS are laid out inside that panel
    /// (`PopoverRootView.sessionsBoardWidth`).
    ///
    /// - Parameters:
    ///   - chosen: an explicit count, or nil for auto.
    ///   - cards: how many cards the board is seating, which is what auto asks for.
    ///   - width: the grid's own width, padding already taken off.
    ///   - minimum: the narrowest a card may be laid out at.
    ///   - gap: the gutter between two columns.
    static func boardColumns(chosen: Int?, cards: Int, in width: CGFloat, minimum: CGFloat,
                             gap: CGFloat) -> Int {
        let wanted = max(1, chosen ?? cards)
        let step = minimum + gap
        // A width that is not a number yet (the first layout pass) honours the count rather than
        // inventing a bound from it: the next pass corrects it, and one frame at the asked-for
        // count is better than one frame at a number nothing measured.
        guard step > 0, width.isFinite, width > 0 else { return wanted }
        return min(wanted, max(1, Int((width + gap) / step)))
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
