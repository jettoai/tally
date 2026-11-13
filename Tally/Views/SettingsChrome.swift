import AppKit
import SwiftUI

/// The Settings window's surfaces (B-1355): a sidebar one step darker than the page, a page one
/// step darker than the white cards on it, section headers that run a hairline to the edge. Values
/// follow Jetto Voice's settings so the two apps read as one family.
enum SettingsChrome {
    static let sidebarWidth: CGFloat = 200
    /// The window's height on EVERY pane, title bar included (macOS System Settings is 625 on the
    /// same Mac; CleanShot X, Aqua Voice and Typeless also keep one size across their sidebars). A
    /// pane taller than this scrolls inside the window; a display too short for it caps it
    /// (`ResizeAnchor.fittedWindowHeight`).
    static let windowHeight: CGFloat = 700
    /// The window's width, fixed like its height (B-4474): the 200 sidebar and a 780 pane holding the
    /// 700 content column between two 40 insets.
    static let windowWidth: CGFloat = 980
    /// The right-hand pane: header and scroll view of the page in front.
    static var contentWidth: CGFloat { windowWidth - sidebarWidth }
    /// The skeleton's numbers for this window (`PageSkeleton`, SettingsSkeleton.swift).
    static let skeleton = PageSkeleton(windowWidth: windowWidth, windowHeight: windowHeight, sidebarWidth: sidebarWidth)
    /// The pages' rhythm, forwarded from the skeleton so the panes keep their spellings.
    static let sectionGap: CGFloat = PageSkeleton.sectionGap
    static let headerToCard: CGFloat = PageSkeleton.sectionTitleToCard
    static let rowInsetH: CGFloat = PageSkeleton.rowInsetH
    static let rowInsetV: CGFloat = PageSkeleton.rowInsetV
    static let rowMinHeight: CGFloat = PageSkeleton.rowMinHeight
    static let heroInset: CGFloat = PageSkeleton.rowInsetH
    static let rowIconSlot: CGFloat = PageSkeleton.rowIconSlot
    static let rowIconGap: CGFloat = PageSkeleton.rowIconGap
    static var dividerInsetIcon: CGFloat { PageSkeleton.dividerInsetIcon }
    static var dividerInsetPlain: CGFloat { PageSkeleton.dividerInsetPlain }
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

/// The Settings window's type scale (B-4474): the design spec's sizes, one step above the old ones.
enum SettingsType {
    static let pageTitle: CGFloat = PageType.pageTitle
    static let pageSubtitle: CGFloat = PageType.pageSubtitle
    static let sectionTitle: CGFloat = PageType.sectionTitle
    static let sectionIcon: CGFloat = PageType.sectionIcon
    static let count: CGFloat = PageType.count
    static let rowTitle: CGFloat = 14
    static let rowSubtitle: CGFloat = 12
    static let rowIcon: CGFloat = 18
    static let body: CGFloat = 13
    static let badge: CGFloat = 12
    static let info: CGFloat = 12
    static let noticeTitle: CGFloat = 13
    static let noticeMessage: CGFloat = 12
    static let noticeIcon: CGFloat = 14
    static let action: CGFloat = PageType.pageButton
    static let actionIcon: CGFloat = PageType.pageButtonIcon
    static let sidebar: CGFloat = PageType.sidebar
}

/// The card face the panes already spell this way; the one definition is `CardSurface`.
typealias SettingsCardSurface = CardSurface
