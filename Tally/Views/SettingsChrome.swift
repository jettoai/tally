import AppKit
import SwiftUI

/// The Settings window's surfaces (B-1355): a sidebar one step darker than the page, a page one
/// step darker than the white cards on it, section headers that run a hairline to the edge. Values
/// follow Jetto Voice's settings so the two apps read as one family.
enum SettingsChrome {
    static let sidebarWidth: CGFloat = 220
    /// The pages' rhythm (B-2526, Voice's values): the gap between sections, a section title to its
    /// card, a row's insets and floor, and the identity card's inset.
    static let sectionGap: CGFloat = 28
    static let headerToCard: CGFloat = 10
    static let rowInsetH: CGFloat = 20
    static let rowInsetV: CGFloat = 10
    static let rowMinHeight: CGFloat = 52
    static let heroInset: CGFloat = 20
    /// Where a row's divider starts: under the title column (20 inset + 24 icon + 12 gap), or at the
    /// inset when the row has no icon.
    static let dividerInsetIcon: CGFloat = 56
    static let dividerInsetPlain: CGFloat = 20
    /// The page's inset inside the scroll view, and the content column it sits in: window content
    /// width = sidebar 220 + column, the column being a card plus two insets (the card is 732
    /// wide, `AccountTableStyle`, so the column is 788).
    static let paneInsetH: CGFloat = 28
    static let paneInsetTop: CGFloat = 30
    static let paneInsetBottom: CGFloat = 32
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
