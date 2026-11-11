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
        /// The gradient glass, halos, pills and controls (B-4169); the draft's other numbers.
        var skin: Skin = .dark
    }

    /// A colour and how much of it is laid on what is below.
    struct Tone {
        var hex: UInt32
        var alpha: Double = 1
    }

    /// Two ends of a brand gradient (left to right on a bar, top-left to bottom-right on the ring).
    struct Gradient {
        var from: UInt32
        var to: UInt32
    }

    /// A pill: its fill laid over the card, its word, and the dot some of them carry.
    struct Pill {
        var fill: Tone
        var ink: UInt32
        var dot: UInt32? = nil
    }

    /// Every colour of the re-skinned panel, per appearance, taken from the Opus draft's CSS and JS
    /// (panel.css / panel.js). Views read these through `PanelStyle` and the contrast test reads the
    /// same numbers, so what is asserted is what is drawn. Kept free of AppKit for that reason.
    ///
    /// Inks that did not clear their contrast on the worst flat desktop with a halo at its peak were
    /// moved away from their background by the least that passes (dark: the plan, status and
    /// suggestion pill words, `lowInk`, `text2`, `text3`, the Claude mark, the violet and red bar
    /// starts; light: the violet pill's word and the unselected switch word). Opacities were not touched.
    struct Skin {
        /// The glass: a 165 degree gradient of three stops, each laid at `alpha` over the blurred desktop.
        var stops: [UInt32]
        var alpha: Double
        /// The colour haloes behind the cards: first provider, second provider, violet (bottom left).
        var halos: [Tone]
        /// The panel's outer rim: a ring (light only), a ring, and a highlight along the top edge.
        var rimOuter: Tone
        var rimInner: Tone
        var rimTop: Tone
        /// The card over the panel, its edge, its top highlight and its soft shadow (light only).
        var card: Tone
        var cardEdge: Tone
        var cardTop: Tone
        var cardShadow: Tone
        /// The footer bar over the panel and its edge.
        var footer: Tone
        var footerEdge: Tone
        /// The line over the column titles, the groove under a bar or a ring, the hot row's wash.
        var colHeadLine: Tone
        var track: Tone
        var hotRow: Tone
        /// Gradients and inks per brand and per severity.
        var claude: Gradient
        var codex: Gradient
        var violet: Gradient
        var amber: Gradient
        var red: Gradient
        var inkClaude: UInt32
        var inkCodex: UInt32
        var inkSpark: UInt32
        var inkWarn: UInt32
        /// A figure under 20% left, and the second line of a card head when its pace is off.
        var lowInk: UInt32
        var paceWarn: UInt32
        var violetPill: Pill
        var planClaude: Pill
        var planCodex: Pill
        var amberPill: Pill
        var greenPill: Pill
        var redPill: Pill
        var idlePill: Pill
        /// The segmented switch: track, its edge, the selected thumb, the thumb's top light, words.
        var seg: Tone
        var segEdge: Tone
        var segOn: Tone
        var segOnTop: Tone
        var segText: UInt32
        var segOnText: UInt32
        var tabDot: UInt32
        /// The round buttons and their icon.
        var chip: Tone
        var chipEdge: Tone
        var chipInk: UInt32
        /// The tile behind a machine group's icon (140 degrees).
        var tile: Gradient

        static let dark = Skin(
            stops: [0x302848, 0x201C32, 0x181626], alpha: 0.93,
            halos: [Tone(hex: 0xEC7C54, alpha: 0.22), Tone(hex: 0x20C8A0, alpha: 0.15),
                    Tone(hex: 0x8C78FF, alpha: 0.22)],
            rimOuter: Tone(hex: 0xFFFFFF, alpha: 0), rimInner: Tone(hex: 0xFFFFFF, alpha: 0.13),
            rimTop: Tone(hex: 0xFFFFFF, alpha: 0.22),
            card: Tone(hex: 0xFFFFFF, alpha: 0.045), cardEdge: Tone(hex: 0xFFFFFF, alpha: 0.08),
            cardTop: Tone(hex: 0xFFFFFF, alpha: 0.10), cardShadow: Tone(hex: 0x000000, alpha: 0),
            footer: Tone(hex: 0xFFFFFF, alpha: 0.045), footerEdge: Tone(hex: 0xFFFFFF, alpha: 0.07),
            colHeadLine: Tone(hex: 0xFFFFFF, alpha: 0.08), track: Tone(hex: 0x000000, alpha: 0.30),
            hotRow: Tone(hex: 0xFF6E60, alpha: 0.07),
            claude: Gradient(from: 0xF8946A, to: 0xFFBA96), codex: Gradient(from: 0x22C9A0, to: 0x74EAC6),
            violet: Gradient(from: 0xA99BFF, to: 0xB8A9FF), amber: Gradient(from: 0xF0A23A, to: 0xFFC870),
            red: Gradient(from: 0xFF8378, to: 0xFF948A),
            inkClaude: 0xF18F66, inkCodex: 0x3FD6AE, inkSpark: 0xB9A6FF, inkWarn: 0xFFB45C,
            lowInk: 0xFFC6C0, paceWarn: 0xFFC56B,
            violetPill: Pill(fill: Tone(hex: 0x9680FF, alpha: 0.20), ink: 0xD9D0FF),
            planClaude: Pill(fill: Tone(hex: 0xEC7C54, alpha: 0.16), ink: 0xFFD4C2),
            planCodex: Pill(fill: Tone(hex: 0x22C9A0, alpha: 0.16), ink: 0xA6F0DA),
            amberPill: Pill(fill: Tone(hex: 0xF7B446, alpha: 0.17), ink: 0xFFE5BC, dot: 0xFFC15C),
            greenPill: Pill(fill: Tone(hex: 0x46D682, alpha: 0.16), ink: 0xAFF1C8, dot: 0x5BE095),
            redPill: Pill(fill: Tone(hex: 0xFF6E60, alpha: 0.16), ink: 0xFFD2CD, dot: 0xFF8A7E),
            idlePill: Pill(fill: Tone(hex: 0xFFFFFF, alpha: 0.08), ink: 0xE3E0EB, dot: 0xA8A2B8),
            seg: Tone(hex: 0x0A0814, alpha: 0.30), segEdge: Tone(hex: 0xFFFFFF, alpha: 0.07),
            segOn: Tone(hex: 0xFFFFFF, alpha: 0.16), segOnTop: Tone(hex: 0xFFFFFF, alpha: 0.16),
            segText: 0xD2CDDF, segOnText: 0xFFFFFF, tabDot: 0xFF7A6E,
            chip: Tone(hex: 0xFFFFFF, alpha: 0.08), chipEdge: Tone(hex: 0xFFFFFF, alpha: 0.08),
            chipInk: 0xE4DFF0,
            tile: Gradient(from: 0x8E7BFF, to: 0x5B45D6))

        static let light = Skin(
            stops: [0xFCF9FD, 0xF4F3FB, 0xEEF0FA], alpha: 0.91,
            halos: [Tone(hex: 0xFFA880, alpha: 0.30), Tone(hex: 0x50D6B2, alpha: 0.20),
                    Tone(hex: 0xA08CFF, alpha: 0.24)],
            rimOuter: Tone(hex: 0x3C286E, alpha: 0.10), rimInner: Tone(hex: 0xFFFFFF, alpha: 0.75),
            rimTop: Tone(hex: 0xFFFFFF, alpha: 0),
            card: Tone(hex: 0xFFFFFF, alpha: 0.60), cardEdge: Tone(hex: 0xFFFFFF, alpha: 0.90),
            cardTop: Tone(hex: 0xFFFFFF, alpha: 0), cardShadow: Tone(hex: 0x281E50, alpha: 0.06),
            footer: Tone(hex: 0xFFFFFF, alpha: 0.50), footerEdge: Tone(hex: 0xFFFFFF, alpha: 0.90),
            colHeadLine: Tone(hex: 0x3C286E, alpha: 0.08), track: Tone(hex: 0x3C286E, alpha: 0.09),
            hotRow: Tone(hex: 0xDC3C28, alpha: 0.07),
            claude: Gradient(from: 0xA8441F, to: 0xBC5430), codex: Gradient(from: 0x096A52, to: 0x0B785D),
            violet: Gradient(from: 0x5234C2, to: 0x6649D6), amber: Gradient(from: 0x8A5000, to: 0x9C5C00),
            red: Gradient(from: 0xA21F14, to: 0xB92A1E),
            inkClaude: 0xA8441F, inkCodex: 0x096A52, inkSpark: 0x5E3FD0, inkWarn: 0x985600,
            lowInk: 0xB4271C, paceWarn: 0x8A4E00,
            violetPill: Pill(fill: Tone(hex: 0x6E50E6, alpha: 0.12), ink: 0x5032B6),
            planClaude: Pill(fill: Tone(hex: 0xC85A32, alpha: 0.12), ink: 0x9A3F1C),
            planCodex: Pill(fill: Tone(hex: 0x0B785D, alpha: 0.12), ink: 0x0A5440),
            amberPill: Pill(fill: Tone(hex: 0xDC8C14, alpha: 0.15), ink: 0x7E4600, dot: 0xB86E00),
            greenPill: Pill(fill: Tone(hex: 0x1E9650, alpha: 0.12), ink: 0x11643A, dot: 0x1E9150),
            redPill: Pill(fill: Tone(hex: 0xDC3C28, alpha: 0.12), ink: 0x9E1F14, dot: 0xC42B20),
            idlePill: Pill(fill: Tone(hex: 0x3C286E, alpha: 0.07), ink: 0x4F4A60, dot: 0x6E6880),
            seg: Tone(hex: 0x3C286E, alpha: 0.07), segEdge: Tone(hex: 0x3C286E, alpha: 0),
            segOn: Tone(hex: 0xFFFFFF), segOnTop: Tone(hex: 0xFFFFFF, alpha: 0),
            segText: 0x504C61, segOnText: 0x1C1828, tabDot: 0xC42B20,
            chip: Tone(hex: 0xFFFFFF, alpha: 0.70), chipEdge: Tone(hex: 0x3C286E, alpha: 0.08),
            chipInk: 0x3E3A4E,
            tile: Gradient(from: 0x7B63F2, to: 0x4B33C2))

        /// The classic skin: the same glass, rims, cards and brand colours, with the violet taken out.
        /// The glass is the neutral grey the panel had before B-4169, no halo is drawn, and the
        /// switch, the round buttons, the idle and violet pills and the machine tile are greys.
        static let darkClassic: Skin = {
            var skin = Skin.dark
            skin.stops = [0x242428, 0x1E1E22, 0x1A1A1D]
            skin.halos = skin.halos.map { Tone(hex: $0.hex, alpha: 0) }
            skin.card = Tone(hex: 0xFFFFFF, alpha: 0.055)
            skin.violetPill = Pill(fill: Tone(hex: 0xFFFFFF, alpha: 0.10), ink: 0xE4E4E8)
            skin.idlePill = Pill(fill: Tone(hex: 0xFFFFFF, alpha: 0.08), ink: 0xE4E4E8, dot: 0xA8A8B0)
            skin.seg = Tone(hex: 0x000000, alpha: 0.30)
            skin.segText = 0xD0D0D6
            skin.chipInk = 0xE4E4E8
            skin.inkSpark = 0xC4C4CC
            skin.tile = Gradient(from: 0x6E6E76, to: 0x48484E)
            skin.violet = Gradient(from: 0xB8B8B8, to: 0x929292)
            return skin
        }()

        static let lightClassic: Skin = {
            var skin = Skin.light
            skin.stops = [0xF8F8F9, 0xF4F4F6, 0xEFEFF2]
            skin.halos = skin.halos.map { Tone(hex: $0.hex, alpha: 0) }
            skin.rimOuter = Tone(hex: 0x000000, alpha: 0.10)
            skin.cardShadow = Tone(hex: 0x000000, alpha: 0.06)
            skin.colHeadLine = Tone(hex: 0x000000, alpha: 0.08)
            skin.track = Tone(hex: 0x000000, alpha: 0.09)
            skin.violetPill = Pill(fill: Tone(hex: 0x000000, alpha: 0.07), ink: 0x3E3E44)
            skin.idlePill = Pill(fill: Tone(hex: 0x000000, alpha: 0.07), ink: 0x4F4F57, dot: 0x6E6E76)
            skin.seg = Tone(hex: 0x000000, alpha: 0.07)
            skin.segText = 0x505058
            skin.segOnText = 0x1B1B1E
            skin.chipEdge = Tone(hex: 0x000000, alpha: 0.08)
            skin.chipInk = 0x3E3E44
            skin.inkSpark = 0x55555C
            skin.tile = Gradient(from: 0x6E6E76, to: 0x48484E)
            skin.violet = Gradient(from: 0x666666, to: 0x4C4C4C)
            return skin
        }()
    }

    /// The text levels are the skin's own (B-4169 Opus draft): a violet-leaning white and ink, not the
    /// neutral greys the first design draft used. The levels stay opaque on purpose (a translucent
    /// grey follows the desktop behind the glass), the secondary one is the draft's muted colour and
    /// the tertiary level (words nobody has to read) is derived to clear 3:1 (tests/panelcontrast).
    /// `panelSolid` and `glassAlpha` describe the FLAT tint that the pick panel and the view-options
    /// card still lay over their glass; the skin's gradient glass is `Skin.stops` / `Skin.alpha`.
    static let dark = Appearance(text: 0xF6F4FB, text2: 0xD6D1E2, text3: 0xAAA5B9,
                                 panelSolid: 0x1E1E22, glassAlpha: 0.92,
                                 cardFill: 0xFFFFFF, cardAlpha: 0.045, skin: .dark)
    static let light = Appearance(text: 0x1C1828, text2: 0x575269, text3: 0x6E6880,
                                  panelSolid: 0xF4F4F6, glassAlpha: 0.92,
                                  cardFill: 0xFFFFFF, cardAlpha: 0.60, skin: .light)

    /// The classic panel (Settings > General > Classic panel): the neutral greys and text levels the
    /// panel had before B-4169 (0.85.84), on the classic skin. Off by default.
    static let darkClassic = Appearance(text: 0xF4F4F6, text2: 0xB8B8C0, text3: 0x93939B,
                                        panelSolid: 0x1E1E22, glassAlpha: 0.92,
                                        cardFill: 0xFFFFFF, cardAlpha: 0.055, skin: .darkClassic)
    static let lightClassic = Appearance(text: 0x1B1B1E, text2: 0x5C5C64, text3: 0x72727A,
                                         panelSolid: 0xF4F4F6, glassAlpha: 0.92,
                                         cardFill: 0xFFFFFF, cardAlpha: 0.60, skin: .lightClassic)

    /// Whether the panel draws the classic skin. Set from `SettingsStore.classicPanelSkin` on the main
    /// thread; read by `PanelStyle`'s dynamic colours whenever they resolve.
    private static let classicLock = NSLock()
    nonisolated(unsafe) private static var classicValue = false
    static var classic: Bool {
        get {
            classicLock.lock()
            defer { classicLock.unlock() }
            return classicValue
        }
        set {
            classicLock.lock()
            defer { classicLock.unlock() }
            classicValue = newValue
        }
    }

    /// The appearance the panel draws now.
    static func current(dark isDark: Bool) -> Appearance {
        isDark ? (classic ? darkClassic : dark) : (classic ? lightClassic : light)
    }

    /// Desktops the panel can sit on: dark, middle grey, pale, and the two extremes (the worst a flat
    /// colour can be; a blurred pattern only lands between them).
    static let wallpapers: [(name: String, hex: UInt32)] = [("dark", 0x202020), ("mid", 0x808080),
                                                            ("pale", 0xE8E8E8), ("white", 0xFFFFFF),
                                                            ("black", 0x000000)]

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

    // MARK: Skin arithmetic

    static func rgb(_ tone: Tone) -> RGB { rgb(tone.hex) }

    /// The panel's glass at one of its three stops over a flat desktop, then optionally one halo at
    /// its peak (the worst place under a halo is its centre).
    static func skinPanel(_ mode: Appearance, wallpaper: UInt32, stop: Int, halo: Int? = nil) -> RGB {
        let glass = over(rgb(mode.skin.stops[stop]), mode.skin.alpha, rgb(wallpaper))
        guard let halo else { return glass }
        let tone = mode.skin.halos[halo]
        return over(rgb(tone.hex), tone.alpha, glass)
    }

    /// A card over that panel.
    static func skinCard(_ mode: Appearance, wallpaper: UInt32, stop: Int, halo: Int? = nil) -> RGB {
        over(rgb(mode.skin.card), mode.skin.card.alpha, skinPanel(mode, wallpaper: wallpaper, stop: stop, halo: halo))
    }

    /// The footer bar over that panel.
    static func skinFooter(_ mode: Appearance, wallpaper: UInt32, stop: Int, halo: Int? = nil) -> RGB {
        over(rgb(mode.skin.footer), mode.skin.footer.alpha, skinPanel(mode, wallpaper: wallpaper, stop: stop, halo: halo))
    }

    /// Lay a tone over a background.
    static func over(_ tone: Tone, _ below: RGB) -> RGB { over(rgb(tone.hex), tone.alpha, below) }
}
