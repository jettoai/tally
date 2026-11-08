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
    static let track = dynamic(dark: white(0.10), light: black(0.08))
    static let ink = dynamic(dark: white(0.78), light: black(0.62))
    static let green = dynamic(dark: rgb(0x41D37A), light: rgb(0x1F9D54))
    static let amber = dynamic(dark: rgb(0xF5AE42), light: rgb(0xC97A0C))
    static let red = dynamic(dark: rgb(0xFF6A5F), light: rgb(0xE0443A))
    static let line = dynamic(dark: white(0.08), light: black(0.07))
    static let cardEdge = dynamic(dark: white(0.09), light: black(0.06))
    static let seg = dynamic(dark: white(0.07), light: black(0.06))
    static let segOn = dynamic(dark: white(0.16), light: rgb(0xFFFFFF))
    /// The card over a glass panel, and over an opaque one (the panel's own solid colour with 4% of
    /// the text colour mixed in).
    static let cardGlass = dynamic(
        dark: rgb(PanelPalette.dark.cardFill, CGFloat(PanelPalette.dark.cardAlpha)),
        light: rgb(PanelPalette.light.cardFill, CGFloat(PanelPalette.light.cardAlpha)))
    /// The panel's own opaque colour, under the cards when glass is off.
    static let panelSolid = dynamic(dark: rgb(PanelPalette.dark.panelSolid), light: rgb(PanelPalette.light.panelSolid))
    static let cardSolid = dynamic(dark: rgb(0x272729), light: rgb(0xEBEBED))

    /// A provider's colour on the panel, or the neutral ink for one without its own.
    static func brand(_ providerID: String) -> Color {
        ProviderBrand.panelHex(for: providerID).map { Color(nsColor: rgb($0)) } ?? ink
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
        Text(text)
            .font(PanelStyle.font(10.5, 600))
            .foregroundStyle(state.color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(state.color.opacity(0.15)))
    }
}

/// The plan pill beside an account's name, in its provider's colour.
struct PlanBadge: View {
    let text: String
    let providerID: String

    var body: some View {
        let brand = PanelStyle.brand(providerID)
        Text(text.uppercased())
            .font(PanelStyle.font(8.5, 750))
            .tracking(0.5)
            .foregroundStyle(brand)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(brand.opacity(0.15)))
            .fixedSize()
    }
}

/// The card surface of the Detailed panel: a fill that follows the glass/solid choice the surface
/// already made (`tallyCardStyle`), a 0.5pt inner edge and the continuous 12pt corner.
private struct PanelCard: ViewModifier {
    @Environment(\.tallyCardStyle) private var style

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: PanelStyle.cardRadius, style: .continuous)
        content
            .background(shape.fill(style == .solid ? PanelStyle.cardSolid : PanelStyle.cardGlass))
            .clipShape(shape)
            .overlay(shape.strokeBorder(PanelStyle.cardEdge, lineWidth: PanelStyle.hairline))
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
