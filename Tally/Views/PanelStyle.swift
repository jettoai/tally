import SwiftUI
import AppKit

/// The Detailed panel's look in one place: sizes, the five type levels and the colour tokens of the
/// panel/card/row hierarchy. Every colour is a dynamic `NSColor`, so a light/dark switch repaints a
/// panel that is already open. Nothing here reads data; views ask for a token by name.
enum PanelStyle {
    // MARK: Geometry (the numbers live in `PanelMetrics` so a test can print them)
    static let bodyPadH = PanelMetrics.bodyPadH
    static let bodyPadTop = PanelMetrics.bodyPadTop
    static let bodyPadBottom = PanelMetrics.bodyPadBottom
    static let cardGap = PanelMetrics.cardGap
    static let cardRadius = PanelMetrics.cardRadius
    static let ringSize = PanelMetrics.ringSize
    static let colHeadHeight = PanelMetrics.colHeadHeight
    static let rowHeight = PanelMetrics.rowHeight
    static let rowPadH = PanelMetrics.rowPadH
    static let meterGap = PanelMetrics.meterGap
    static let barHeight = PanelMetrics.barHeight
    static let wallBarWidth = PanelMetrics.wallBarWidth
    static let hairline = PanelMetrics.hairline
    static let panelRadius = PanelMetrics.panelRadius
    static let cardPadH = PanelMetrics.cardPadH
    static let rowInsetH = PanelMetrics.rowInsetH
    static let rowRadius = PanelMetrics.rowRadius
    static let ringStroke = PanelMetrics.ringStroke
    static let chipSize = PanelMetrics.chipSize
    static let headerHeight = PanelMetrics.headerHeight

    static func meterCellWidth(columns: Int) -> CGFloat { PanelMetrics.meterCellWidth(columns: columns) }
    static func meterBlockWidth(columns: Int) -> CGFloat { PanelMetrics.meterBlockWidth(columns: columns) }

    // MARK: Colours
    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// A skin colour in both appearances, read from the same `PanelPalette.Skin` numbers the contrast
    /// test asserts (B-4169).
    static func skinTone(_ get: @escaping (PanelPalette.Skin) -> PanelPalette.Tone) -> Color {
        dynamic(dark: toneColor(get(PanelPalette.dark.skin)), light: toneColor(get(PanelPalette.light.skin)))
    }

    static func skinHex(_ get: @escaping (PanelPalette.Skin) -> UInt32) -> Color {
        dynamic(dark: rgb(get(PanelPalette.dark.skin)), light: rgb(get(PanelPalette.light.skin)))
    }

    private static func toneColor(_ tone: PanelPalette.Tone) -> NSColor { rgb(tone.hex, CGFloat(tone.alpha)) }

    private static func white(_ alpha: CGFloat) -> NSColor { NSColor(white: 1, alpha: alpha) }
    private static func black(_ alpha: CGFloat) -> NSColor { NSColor(white: 0, alpha: alpha) }

    /// Main, secondary and tertiary text. Opaque on purpose (a translucent grey follows the desktop
    /// behind the glass), and not the design draft's values: see `PanelPalette`. The tertiary level is
    /// for words nobody has to read (the grip, the version, the credit); anything a person reads
    /// takes `text2`. `tests/panelcontrast` holds both the numbers and that rule.
    static let text = dynamic(dark: rgb(PanelPalette.dark.text), light: rgb(PanelPalette.light.text))
    static let text2 = dynamic(dark: rgb(PanelPalette.dark.text2), light: rgb(PanelPalette.light.text2))
    static let text3 = dynamic(dark: rgb(PanelPalette.dark.text3), light: rgb(PanelPalette.light.text3))
    /// The panel's own colour laid over the glass, which is what keeps a word's background from
    /// following the desktop (`PanelBackdrop`).
    static let glassTint = dynamic(
        dark: rgb(PanelPalette.dark.panelSolid, CGFloat(PanelPalette.dark.glassAlpha)),
        light: rgb(PanelPalette.light.panelSolid, CGFloat(PanelPalette.light.glassAlpha)))
    static let ink = dynamic(dark: white(0.78), light: black(0.62))
    static let green = dynamic(dark: rgb(0x41D37A), light: rgb(0x1F9D54))
    static let amber = dynamic(dark: rgb(0xF5AE42), light: rgb(0xC97A0C))
    static let red = dynamic(dark: rgb(0xFF6A5F), light: rgb(0xE0443A))
    /// The groove under a bar or a ring, the line over the column titles, the hot row's wash.
    static let track = skinTone { $0.track }
    static let line = skinTone { $0.colHeadLine }
    static let hotRow = skinTone { $0.hotRow }
    /// The segmented switch (track, edge, selected thumb, the thumb's top light, words) and its dot.
    static let seg = skinTone { $0.seg }
    static let segEdge = skinTone { $0.segEdge }
    static let segOn = skinTone { $0.segOn }
    static let segOnTop = skinTone { $0.segOnTop }
    static let segText = skinHex { $0.segText }
    static let segOnText = skinHex { $0.segOnText }
    static let tabDot = skinHex { $0.tabDot }
    /// The round buttons, a figure under 20% left, a card head's off-pace line.
    static let chipFill = skinTone { $0.chip }
    static let chipEdge = skinTone { $0.chipEdge }
    static let chipInk = skinHex { $0.chipInk }
    static let lowInk = skinHex { $0.lowInk }
    static let paceWarn = skinHex { $0.paceWarn }
    /// The card over a glass panel (a fill of the skin, so the glass shows through it), its 1pt edge,
    /// the highlight along its top edge, and over an opaque panel the solid fill below.
    static let cardGlass = skinTone { $0.card }
    static let cardEdge = skinTone { $0.cardEdge }
    static let cardTop = skinTone { $0.cardTop }
    static let cardShadow = skinTone { $0.cardShadow }
    static let footerFill = skinTone { $0.footer }
    static let footerEdge = skinTone { $0.footerEdge }
    static let rimOuter = skinTone { $0.rimOuter }
    static let rimInner = skinTone { $0.rimInner }
    static let rimTop = skinTone { $0.rimTop }
    /// The panel's own opaque colour, under the cards when glass is off.
    static let panelSolid = dynamic(dark: rgb(PanelPalette.dark.panelSolid), light: rgb(PanelPalette.light.panelSolid))
    static let cardSolid = dynamic(dark: rgb(0x272729), light: rgb(0xEBEBED))

    /// The skin's three glass stops, each at the glass opacity (or opaque, for the solid panel).
    static func glassStops(opaque: Bool) -> [Color] {
        (0..<3).map { i in
            dynamic(dark: rgb(PanelPalette.dark.skin.stops[i], opaque ? 1 : CGFloat(PanelPalette.dark.skin.alpha)),
                    light: rgb(PanelPalette.light.skin.stops[i], opaque ? 1 : CGFloat(PanelPalette.light.skin.alpha)))
        }
    }

    /// A provider's colour on the panel (its mark, its plan pill's word), or the neutral ink for one
    /// without its own.
    static func brand(_ providerID: String) -> Color {
        switch providerID {
        case "claude": return skinHex { $0.inkClaude }
        case "codex": return skinHex { $0.inkCodex }
        default: return ProviderBrand.panelHex(for: providerID).map { Color(nsColor: rgb($0)) } ?? ink
        }
    }

    /// The two ends of a bar or ring in a provider's colour while healthy, amber under half left and
    /// red under a fifth (`MetricSeverity.fromUsedPercent`, the same cut the draft's `level()` has).
    static func brandGradient(_ providerID: String, severity: MetricSeverity) -> [Color] {
        func pair(_ get: @escaping (PanelPalette.Skin) -> PanelPalette.Gradient) -> [Color] {
            [skinHex { get($0).from }, skinHex { get($0).to }]
        }
        switch severity {
        case .warning: return pair { $0.amber }
        case .critical: return pair { $0.red }
        case .normal, .unknown:
            switch providerID {
            case "claude": return pair { $0.claude }
            case "codex": return pair { $0.codex }
            default: return pair { $0.violet }
            }
        }
    }

    /// The severity ramp as the panel draws it: ink while healthy, then amber, then red.
    static func tint(_ severity: MetricSeverity) -> Color {
        switch severity {
        case .normal: return ink
        case .warning: return amber
        case .critical: return red
        case .unknown: return text3
        }
    }

    // MARK: Type
    /// CSS weights 650 and 750 have no SwiftUI name; the in-between `NSFont.Weight` values do.
    static func font(_ size: CGFloat, _ weight: CGFloat = 400) -> Font {
        let value: CGFloat
        switch weight {
        case ..<450: value = NSFont.Weight.regular.rawValue
        case ..<550: value = NSFont.Weight.medium.rawValue
        case ..<625: value = NSFont.Weight.semibold.rawValue
        case ..<700: value = 0.35
        case ..<775: value = 0.47
        default: value = NSFont.Weight.heavy.rawValue
        }
        return Font(NSFont.systemFont(ofSize: size, weight: NSFont.Weight(rawValue: value)) as CTFont)
    }
}

/// Whether a status chip reads as a good, cautioning or bad state.
enum PanelChipState {
    case green, amber, red

    var color: Color {
        switch self {
        case .green: return PanelStyle.green
        case .amber: return PanelStyle.amber
        case .red: return PanelStyle.red
        }
    }
}

/// The status pill beside a provider's name.
struct StatusChip: View {
    let text: String
    let state: PanelChipState

    var body: some View {
        PanelPill(text: text, tone: state.pillTone, size: .large)
    }
}

/// The plan pill beside an account's name, in its provider's colour.
struct PlanBadge: View {
    let text: String
    let providerID: String

    var body: some View {
        PanelPill(text: text.uppercased(), tone: .plan(providerID), size: .badge)
    }
}

/// The card surface of the Detailed panel: a fill that follows the glass/solid choice the surface
/// already made (`tallyCardStyle`), a 1pt inner edge, the highlight along its top edge (dark), the
/// soft shadow under it (light) and the continuous 18pt corner.
private struct PanelCard: ViewModifier {
    @Environment(\.tallyCardStyle) private var style

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: PanelStyle.cardRadius, style: .continuous)
        content
            .background(shape.fill(style == .solid ? PanelStyle.cardSolid : PanelStyle.cardGlass))
            .clipShape(shape)
            .overlay(PanelEdge(cornerRadius: PanelStyle.cardRadius, outer: .clear,
                               inner: PanelStyle.cardEdge, top: PanelStyle.cardTop))
            .background(PanelCardShadow(cornerRadius: PanelStyle.cardRadius))
    }
}

extension View {
    func panelCard() -> some View { modifier(PanelCard()) }
}

/// The hairline that separates a card's header, column titles and rows.
struct PanelHairline: View {
    var body: some View {
        Rectangle().fill(PanelStyle.line).frame(height: PanelStyle.hairline)
    }
}
