import SwiftUI

/// The account table's type scale, row height and column widths (B-2526 G14, B-2617, B-4474), one
/// value so the table's text and columns are sized together.
///
/// The steps: a name (`name`), secondary text such as the address and the reserve line
/// (`secondary`), the usage figures (`figure`), and the header and order number (`header`). Row
/// and header heights, the card's inset and its width come from the page skeleton (card C).
enum AccountTableStyle {
    case standard

    static let current = AccountTableStyle.standard

    var name: CGFloat { 13 }
    var secondary: CGFloat { 12 }
    var figure: CGFloat { 12 }
    var header: CGFloat { 11 }
    var rowHeight: CGFloat { PageSkeleton.tableRowHeight }
    var headerHeight: CGFloat { PageSkeleton.tableHeaderHeight }
    /// The card is as wide as the content column; the columns below add up to it (the address flexes).
    var cardWidth: CGFloat { SettingsChrome.skeleton.contentWidth }

    var lead: CGFloat { 16 }
    var nameColumn: CGFloat { 92 }
    var plan: CGFloat { 58 }
    var cell: CGFloat { 60 }
    var share: CGFloat { 40 }
    /// The "Sharing" name may stand this far past its column on each side: Turkish "Paylaşım" is 47
    /// points wide at 11 and the column 40; the gap to either neighbour (6) still leaves 2.
    var shareBleed: CGFloat { 4 }
    var toggle: CGFloat { 44 }
    var actions: CGFloat { 14 }
    var handle: CGFloat { 10 }
    var gap: CGFloat { 6 }
    /// Inside the card, left and right of the whole row.
    var inset: CGFloat { PageSkeleton.rowInsetH }

    var usage: CGFloat { cell * 2 + gap }
    var status: CGFloat { plan + gap + usage }
    /// Where the account's name starts, for the lines that hang under it (login health, row dividers).
    var nameLeading: CGFloat { inset + lead + gap }
    /// Where the address starts, for the reserve line under a row.
    var addressLeading: CGFloat { nameLeading + nameColumn + gap }
}
