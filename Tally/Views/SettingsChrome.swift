import AppKit
import SwiftUI

/// The Settings window's surfaces (B-1355): a sidebar one step darker than the page, a page one
/// step darker than the white cards on it, section headers that run a hairline to the edge. Values
/// follow Jetto Voice's settings so the two apps read as one family.
enum SettingsChrome {
    static let sidebarWidth: CGFloat = 180
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
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let dark = scheme == .dark
        content
            .background(shape.fill(dark ? Color.white.opacity(0.06) : Color.white)
                .shadow(color: .black.opacity(dark ? 0 : 0.05), radius: 3, y: 1))
            .overlay(shape.strokeBorder(Color.primary.opacity(dark ? 0.09 : 0.08), lineWidth: 0.5))
    }
}

/// The line between two rows in a card.
struct SettingsCardDivider: View {
    var leading: CGFloat = 0

    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5).padding(.leading, leading)
    }
}

/// A section title over its card: line icon, 15pt semibold title, an optional count, a hairline
/// running to the trailing edge, then whatever controls belong to the section as a whole.
struct SettingsSectionHeader<Icon: View, Trailing: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var icon: Icon
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 18)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
            if let count {
                Text("\(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.tertiary)
            }
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5).padding(.horizontal, 2)
            trailing
        }
        .padding(.leading, 4)
    }
}
