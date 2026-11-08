import Foundation

/// The Detailed panel's text and surface numbers, kept free of AppKit so the contrast arithmetic
/// can be asserted without a window (tests/panelcontrast). `PanelStyle` builds its dynamic colours
/// from these, so the numbers asserted are the numbers drawn.
///
/// WHY THERE IS AN ARITHMETIC AT ALL: the glass panel shows the desktop through it, so a grey word
/// has no fixed background. The check is made on the WORST desktop each appearance can meet (a pale
/// one under the dark panel, a dark one under the light panel) after the panel's own tint and the
/// card's fill are laid over it, which is what the reader's eye actually gets.
enum PanelPalette {
    typealias RGB = (r: Double, g: Double, b: Double)

    struct Appearance {
        /// Main text, secondary text, and the tertiary level kept for words nobody needs to read.
        var text: UInt32
        var text2: UInt32
        var text3: UInt32
        /// The panel's opaque colour; the glass lays it over the desktop at `glassAlpha`.
        var panelSolid: UInt32
        var glassAlpha: Double
        /// The card's fill over the panel: a colour and how much of it.
        var cardFill: UInt32
        var cardAlpha: Double
    }

    /// Deliberately NOT the design draft's greys: the draft's secondary (#a6a6ae / #68686f) and tertiary
    /// (#6e6e76 / #a2a2a9) read 2.6 and 1.2 to 2.5 on a pale desktop (B-4208). The levels here are
    /// opaque colours, the secondary one step brighter (dark) or darker (light) than the draft's, the
    /// tertiary at least #92 on a dark card and at most #74 on a light one, and the glass is laid at
    /// 0.92 instead of 0.72 so a desktop behind it moves a word's background by a few points only.
    static let dark = Appearance(text: 0xF4F4F6, text2: 0xB8B8C0, text3: 0x93939B,
                                 panelSolid: 0x1E1E22, glassAlpha: 0.92,
                                 cardFill: 0xFFFFFF, cardAlpha: 0.055)
    static let light = Appearance(text: 0x1B1B1E, text2: 0x5C5C64, text3: 0x72727A,
                                  panelSolid: 0xF4F4F6, glassAlpha: 0.92,
                                  cardFill: 0xFFFFFF, cardAlpha: 0.72)

    /// Desktops the panel can sit on: dark, middle grey, and the palest a wallpaper gets.
    static let wallpapers: [(name: String, hex: UInt32)] = [("dark", 0x202020), ("mid", 0x808080),
                                                            ("pale", 0xE8E8E8)]

    /// The contrast each level has to reach on the worst desktop.
    static let minimumMain = 4.5
    static let minimumSecondary = 4.5
    static let minimumTertiary = 3.0

    static func rgb(_ hex: UInt32) -> RGB {
        (Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF))
    }

    static func over(_ top: RGB, _ alpha: Double, _ below: RGB) -> RGB {
        (top.r * alpha + below.r * (1 - alpha), top.g * alpha + below.g * (1 - alpha),
         top.b * alpha + below.b * (1 - alpha))
    }

    private static func linear(_ channel: Double) -> Double {
        let c = channel / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// WCAG relative luminance.
    static func luminance(_ c: RGB) -> Double {
        0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// What is behind a word on a card: the desktop, the panel's tint over it, the card's fill over that.
    static func cardBackground(_ mode: Appearance, wallpaper: UInt32) -> RGB {
        let panel = over(rgb(mode.panelSolid), mode.glassAlpha, rgb(wallpaper))
        return over(rgb(mode.cardFill), mode.cardAlpha, panel)
    }

    /// Main, secondary and tertiary contrast on the card, on one desktop.
    static func levels(_ mode: Appearance, wallpaper: UInt32) -> (main: Double, secondary: Double, tertiary: Double) {
        let bg = cardBackground(mode, wallpaper: wallpaper)
        return (contrast(rgb(mode.text), bg), contrast(rgb(mode.text2), bg), contrast(rgb(mode.text3), bg))
    }
}
