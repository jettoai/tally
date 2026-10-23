import SwiftUI

/// The account table's type scale, row height and column widths (B-2526 G14, B-2617), one value
/// so the table's text and columns are sized together.
///
/// The three steps: a name (`name`), secondary text such as the address, plan, headers and
/// the order number (`secondary`), and the usage figures (`figure`).
enum AccountTableStyle {
    case standard

    static let current = AccountTableStyle.standard

    var name: CGFloat { 14 }
    var secondary: CGFloat { 12 }
    var figure: CGFloat { 13 }
    var rowHeight: CGFloat { 30 }
    /// The card is 732 wide; the content column adds the page's two insets.
    /// Sized so a full "100%" fits a figure column, a 21-character address shows whole, and the English
    /// headers "Sharing", "Menu bar" and "Enabled" keep 8pt between them (measured at 13pt).
    var cardWidth: CGFloat { 732 }

    var lead: CGFloat { 24 }
    var nameColumn: CGFloat { 104 }
    var plan: CGFloat { 76 }
    var cell: CGFloat { 46 }
    var share: CGFloat { 56 }
    var toggle: CGFloat { 60 }
    var actions: CGFloat { 16 }
    var handle: CGFloat { 12 }
    var gap: CGFloat { 4 }
    /// Inside the card, left and right of the whole row.
    var inset: CGFloat { 12 }

    var usage: CGFloat { cell * 2 + gap }
    var status: CGFloat { plan + gap + usage }
    /// Where the account's name starts, for the lines that hang under it (login health, reserve).
    var nameLeading: CGFloat { inset + lead + gap }
}
