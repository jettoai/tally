import AppKit
import SwiftUI

/// The Settings window's surfaces (B-1355): a sidebar one step darker than the page, a page one
/// step darker than the white cards on it, section headers that run a hairline to the edge. Values
/// follow Jetto Voice's settings so the two apps read as one family.
enum SettingsChrome {
    static let sidebarWidth: CGFloat = 200
    /// The pages' rhythm (B-2526, Voice's values): the gap between sections, a section title to its
    /// card, a row's insets and floor, and the identity card's inset.
    static let sectionGap: CGFloat = 18
    static let headerToCard: CGFloat = 8
    static let rowInsetH: CGFloat = 16
    static let rowInsetV: CGFloat = 9
    static let rowMinHeight: CGFloat = 44
    static let heroInset: CGFloat = 20
    /// A row's icon slot and the gap after it.
    static let rowIconSlot: CGFloat = 20
    static let rowIconGap: CGFloat = 12
    /// Where a row's divider starts: under the title column (inset + icon slot + gap), or at the
    /// inset when the row has no icon.
    static var dividerInsetIcon: CGFloat { rowInsetH + rowIconSlot + rowIconGap }
    static var dividerInsetPlain: CGFloat { rowInsetH }
    /// The sidebar's rhythm: its outer inset, a row's padding and icon slot, the gap between rows.
    static let sidebarInset: CGFloat = 8
    static let sidebarRowPadV: CGFloat = 6
    static let sidebarRowPadH: CGFloat = 8
    static let sidebarRowSpacing: CGFloat = 4
    static let sidebarIconSlot: CGFloat = 20
    /// The page's inset inside the scroll view, and the content column it sits in: window content
    /// width = sidebar + column, the column being a card plus two insets (the card is
    /// `AccountTableStyle.cardWidth` wide).
    static let paneInsetH: CGFloat = 24
    static let paneInsetTop: CGFloat = 18
    static let paneInsetBottom: CGFloat = 20
    static var contentWidth: CGFloat { AccountTableStyle.current.cardWidth + 2 * paneInsetH }
    static let sidebar = adaptive(light: 0xEBEBED, dark: 0x28282A)
    static let page = adaptive(light: 0xF3F3F5, dark: 0x1C1C1E)
    /// The "Sign in again" chip: a dark red on a pale wash in light mode, a pale red on a deep one in
    /// dark. 6.4:1 and 7.5:1 (WCAG AA wants 4.5:1); the severity red over its own 15% wash, which
    /// this replaced, measured 3.3:1 and 3.0:1.
    static let signInText = adaptive(light: 0xA31F1A, dark: 0xFFB4AE)
    static let signInFill = adaptive(light: 0xFDE7E5, dark: 0x5C1E1B)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255,
                           green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// The Settings window's type scale (B-3747), measured against System Settings side by side:
/// row titles and the sidebar at 13 like it, descriptions one step down, the page title at 20.
enum SettingsType {
    static let pageTitle: CGFloat = 20
    static let pageSubtitle: CGFloat = 12
    static let sectionTitle: CGFloat = 13
    static let sectionIcon: CGFloat = 12
    static let count: CGFloat = 11
    static let rowTitle: CGFloat = 13
    static let rowSubtitle: CGFloat = 11
    static let rowIcon: CGFloat = 15
    static let body: CGFloat = 12
    static let badge: CGFloat = 11
    static let info: CGFloat = 11
    static let noticeTitle: CGFloat = 12
    static let noticeMessage: CGFloat = 11
    static let noticeIcon: CGFloat = 13
    static let action: CGFloat = 12
    static let actionIcon: CGFloat = 11
    static let sidebar: CGFloat = 13
}

/// A grouped card: white on the page in light mode with a faint shadow, a 6% white wash in dark.
struct SettingsCardSurface: ViewModifier {
    var cornerRadius: CGFloat = 12
    /// A raised card under the pointer (a page-level action button), one step brighter.
    var highlighted = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = scheme == .dark
        content
            .background(shape.fill(dark ? Color.white.opacity(highlighted ? 0.09 : 0.06) : Color.white)
                .shadow(color: .black.opacity(dark ? 0 : (highlighted ? 0.09 : 0.05)),
                        radius: highlighted ? 5 : 3, y: 1))
            .overlay(shape.strokeBorder(Color.primary.opacity(dark ? 0.09 : 0.08), lineWidth: 0.5))
    }
}
