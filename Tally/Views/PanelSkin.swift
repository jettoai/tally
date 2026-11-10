import SwiftUI

// The panel's skin (B-4169): the gradient glass, the colour haloes, the rim and the card shadow, the
// pill and the round button. Everything here only DRAWS. No gesture, no tooltip, no animation and no
// hit area of its own: the layers that could sit over a control switch hit testing off, and
// tests/panelanchors holds that by counting this file's wiring tokens (zero, bar that one).

/// The panel's glass: a 165 degree gradient of three stops over the blur. Laid on the behind-window
/// vibrancy, it is what keeps a word's background from following the desktop.
struct PanelTintLayer: View {
    /// nil for a host whose window shape already clips it.
    var cornerRadius: CGFloat?
    /// The stops at full opacity, for a panel with no glass behind it.
    var opaque = false

    var body: some View {
        // CSS puts the 165 degree line through the box centre; these ends are that line on the
        // panel's roughly 452 x 600 proportions.
        let gradient = LinearGradient(colors: PanelStyle.glassStops(opaque: opaque),
                                      startPoint: UnitPoint(x: 0.37, y: 0), endPoint: UnitPoint(x: 0.63, y: 1))
        if let cornerRadius {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(gradient)
        } else {
            Rectangle().fill(gradient)
        }
    }
}

/// Three soft colour haloes over the glass, at fixed places on the panel (top left, right, bottom
/// left), as the draft has them. The first two take the colour of the first two providers shown;
/// the third, bottom left, is always violet. Never takes a press.
struct PanelHalos: View {
    /// Provider ids in the order their cards are shown.
    var brands: [String]

    /// Where each halo sits (share of the panel) and how far it reaches (share of the distance to the
    /// farthest corner, which is what CSS's `circle at x y` measures).
    private static let slots: [(x: CGFloat, y: CGFloat, reach: CGFloat)] = [
        (0.10, 0.14, 0.42), (0.96, 0.46, 0.40), (0.18, 0.96, 0.48),
    ]

    private func haloIndex(for providerID: String) -> Int? {
        switch providerID {
        case "claude": return 0
        case "codex": return 1
        default: return nil
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Array(halos().enumerated()), id: \.offset) { _, halo in
                    let slot = Self.slots[halo.slot]
                    let center = CGPoint(x: slot.x * proxy.size.width, y: slot.y * proxy.size.height)
                    let dx = max(center.x, proxy.size.width - center.x)
                    let dy = max(center.y, proxy.size.height - center.y)
                    let reach = slot.reach * (dx * dx + dy * dy).squareRoot()
                    Rectangle().fill(RadialGradient(colors: [halo.color, halo.color.opacity(0)],
                                                    center: UnitPoint(x: slot.x, y: slot.y),
                                                    startRadius: 0, endRadius: reach))
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }

    /// The haloes to draw: (slot, colour). A provider without a halo colour leaves its slot empty.
    private func halos() -> [(slot: Int, color: Color)] {
        var out: [(slot: Int, color: Color)] = []
        for (position, providerID) in brands.prefix(2).enumerated() {
            guard let index = haloIndex(for: providerID) else { continue }
            out.append((position, PanelStyle.skinTone { $0.halos[index] }))
        }
        out.append((2, PanelStyle.skinTone { $0.halos[2] }))
        return out
    }
}

extension PopoverRootView {
    /// The haloes behind the Detailed panel's cards, coloured by the providers in display order.
    @ViewBuilder var skinHalos: some View {
        if settings.panelDensity == .list { PanelHalos(brands: accountGroups.map(\.providerID)) }
    }
}

/// A rim drawn inside a rounded shape: an optional wider outer ring, a 1pt inner ring, and a 1pt
/// highlight that hugs the top edge and fades out down the corners.
struct PanelEdge: View {
    var cornerRadius: CGFloat
    var outer: Color
    var inner: Color
    var top: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.strokeBorder(outer, lineWidth: 1.5)
            shape.strokeBorder(inner, lineWidth: 1)
            shape.strokeBorder(top, lineWidth: 1)
                .mask(alignment: .top) {
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: cornerRadius)
                }
        }
        .allowsHitTesting(false)
    }
}

/// The pinned panel's outer rim.
struct PanelRim: View {
    var cornerRadius: CGFloat

    var body: some View {
        PanelEdge(cornerRadius: cornerRadius, outer: PanelStyle.rimOuter, inner: PanelStyle.rimInner,
                  top: PanelStyle.rimTop)
    }
}

/// A card's soft shadow (light appearance only; dark's is clear), drawn OUTSIDE the card: the shadow
/// caster is cut out of its own shadow so a translucent card is not darkened from behind.
struct PanelCardShadow: View {
    var cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(Color.black).shadow(color: PanelStyle.cardShadow, radius: 1, x: 0, y: 1)
            shape.fill(Color.black).shadow(color: PanelStyle.cardShadow, radius: 10, x: 0, y: 8)
        }
        .mask {
            ZStack {
                Rectangle().padding(-40)
                shape.fill(Color.black).blendMode(.destinationOut)
            }
            .compositingGroup()
        }
        .allowsHitTesting(false)
    }
}

/// Which pill colours a pill wears.
enum PanelPillTone {
    case violet, planClaude, planCodex, amber, green, red, idle

    /// A plan pill in its provider's colour; a provider without one gets the neutral pill.
    static func plan(_ providerID: String) -> PanelPillTone {
        switch providerID {
        case "claude": return .planClaude
        case "codex": return .planCodex
        default: return .idle
        }
    }

    fileprivate func pill(_ skin: PanelPalette.Skin) -> PanelPalette.Pill {
        switch self {
        case .violet: return skin.violetPill
        case .planClaude: return skin.planClaude
        case .planCodex: return skin.planCodex
        case .amber: return skin.amberPill
        case .green: return skin.greenPill
        case .red: return skin.redPill
        case .idle: return skin.idlePill
        }
    }

    fileprivate var fill: Color { PanelStyle.skinTone { pill($0).fill } }
    fileprivate var ink: Color { PanelStyle.skinHex { pill($0).ink } }
    fileprivate var dot: Color { PanelStyle.skinHex { pill($0).dot ?? pill($0).ink } }
}

extension PanelChipState {
    var pillTone: PanelPillTone {
        switch self {
        case .green: return .green
        case .amber: return .amber
        case .red: return .red
        }
    }
}

/// The capsule behind a status, a plan, an edition or a suggestion: a tinted fill with the same
/// family's lighter word, optionally led by a dot.
struct PanelPill: View {
    enum Size { case badge, small, large }

    let text: String
    var tone: PanelPillTone
    var size: Size = .small
    var dot = false

    private var spec: (font: CGFloat, weight: CGFloat, tracking: CGFloat, h: CGFloat, v: CGFloat) {
        switch size {
        case .badge: return (9.5, 700, 0.06 * 9.5, 6, 2)
        case .small: return (10.5, 700, 0.06 * 10.5, 8, 3)
        case .large: return (11.5, 600, 0.01 * 11.5, 10, 4)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(tone.dot).frame(width: 6, height: 6) }
            Text(text)
                .font(PanelStyle.font(spec.font, spec.weight))
                .tracking(spec.tracking)
                .foregroundStyle(tone.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, spec.h)
        .padding(.vertical, spec.v)
        .background(Capsule().fill(tone.fill))
        // The head's large pill may give up its tail (one line, ellipsis) when a long verdict would
        // otherwise take the room of the provider's name and account count beside it.
        .fixedSize(horizontal: size != .large, vertical: true)
    }
}

/// The round, solid-looking button under an icon of the header and the footer. Only the disc and
/// its edge: the label keeps its own colour (`PanelStyle.chipInk` is the resting one), frame,
/// content shape and hit area.
private struct PanelChip: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Circle().fill(PanelStyle.chipFill))
            .overlay(Circle().strokeBorder(PanelStyle.chipEdge, lineWidth: 1).allowsHitTesting(false))
    }
}

extension View {
    func panelChip() -> some View { modifier(PanelChip()) }
}
