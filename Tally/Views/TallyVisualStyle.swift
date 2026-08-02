import SwiftUI

/// Shared visual language so Settings, the popover, and the dashboard read as one product instead of
/// three separately-improvised screens. Spacing/surface/colour live here as the single source; views
/// reference these constants rather than sprinkling ad-hoc numbers.
enum TallyMetrics {
    static let cardRadius: CGFloat = 12          // continuous corner radius for every surface
    static let cardPaddingH: CGFloat = 14
    static let cardPaddingV: CGFloat = 12
    static let sectionSpacing: CGFloat = 16      // gap between setting sections / cards
    static let headerToCard: CGFloat = 4         // caption header → its card
    static let rowSpacingV: CGFloat = 9          // vertical padding inside a control row
    static let pagePaddingH: CGFloat = 20
    static let pagePaddingV: CGFloat = 16
    static let hairline: CGFloat = 0.5
}

/// Semantic meter colours: a 3-stop traffic-light ramp (safe → caution → danger). Amber (not blue) is
/// the middle so the ramp reads at a glance with zero learning; the green is a calm, desaturated tone
/// rather than a saturated "game HUD" green, so a healthy account looks quiet, not loud.
enum TallyColor {
    static let normal = Color(red: 0.36, green: 0.66, blue: 0.42)    // calm sage green
    static let warning = Color(red: 0.93, green: 0.66, blue: 0.20)   // amber (legible light + dark)
    /// Electric purple, the industry's AI accent (Copilot / Gemini / Notion AI vocabulary) -
    /// marks the smart pick as "the machine chose this", distinct from the human's orange pin.
    static let ai = Color(red: 0.55, green: 0.36, blue: 0.96)
    static let critical = Color(red: 0.86, green: 0.31, blue: 0.29)  // softened red, not alarm-siren
    /// The Relay T's shoulder green: Tally's own identity colour, not a severity. Anything drawing
    /// the brand (the glyph, the baton beneath it) reads it from here, so the family cannot drift
    /// by having the same literal typed twice.
    static let brand = Color(red: 0.19, green: 0.82, blue: 0.35)
}

extension MetricSeverity {
    /// The bar's fill colour. The bar is the single carrier of urgency now, so this ramp is what the
    /// eye reads first; the numeral itself stays neutral (`.primary`).
    var color: Color {
        switch self {
        case .normal: return TallyColor.normal
        case .warning: return TallyColor.warning
        case .critical: return TallyColor.critical
        case .unknown: return Color.secondary
        }
    }
}

/// How a card's surface is filled. Solid is the baseline and the only readable option over an opaque
/// host (the dashboard window, Settings): a within-window blur there just samples that window's own
/// grey. The glass variants belong to the hosts that actually have glass under the card - the
/// popover's vibrancy and the pinned panel's behind-window blur.
enum TallyCardStyle {
    case solid
    /// Within-window material: the card samples the panel glass beneath it, so the desktop's colour
    /// reaches the card through a second layer of frost.
    case material
    /// The neutral card fill at low opacity: flatter than `material` and steadier over busy
    /// wallpaper, because the tint stays the same colour no matter what shows through.
    case tint
    /// The system's own Liquid Glass (macOS 26+): refraction, specular rim and all, rendered by the
    /// platform rather than approximated with a blur. Falls back to `material` below macOS 26 - the
    /// app still ships to macOS 14, so this variant can never be the unconditional path.
    case liquid

    /// Which glass variant the panels use, from the volatile `-TallyCardStyle material|tint|liquid`
    /// launch argument (the argument domain, same as `-TallyDemoData`, so a normal launch always
    /// gets the default). Several variants because glass is judged on screen, not in a diff.
    /// Resolved once: a launch argument cannot change while the app runs, and this is read on every
    /// card's layout pass.
    static let glassVariant: TallyCardStyle = {
        switch UserDefaults.standard.string(forKey: "TallyCardStyle") {
        case "tint": return .tint
        case "liquid": return .liquid
        default: return .material
        }
    }()
}

private struct TallyCardStyleKey: EnvironmentKey {
    static let defaultValue: TallyCardStyle = .solid
}

extension EnvironmentValues {
    /// The card fill for this subtree. Hosts set it once at their root, so a card never has to know
    /// which window it landed in.
    var tallyCardStyle: TallyCardStyle {
        get { self[TallyCardStyleKey.self] }
        set { self[TallyCardStyleKey.self] = newValue }
    }
}

/// A neutral, adaptive card surface: a fill from the environment's style + a hairline border + a
/// continuous radius, no drop shadow. Works over the window background, the popover's vibrancy and
/// the pinned panel's glass.
private struct TallyCard: ViewModifier {
    @Environment(\.tallyCardStyle) private var style

    @ViewBuilder
    func body(content: Content) -> some View {
        // Liquid Glass is not a fill: the system renders the surface, including its own specular
        // rim. So it takes the whole surface over rather than joining the fill switch, and it drops
        // the hairline - our border would sit ON that rim and read as a second, duller edge.
        // Reasoned from the material's own lighting, not measured; the two live side by side under
        // `-TallyCardStyle liquid|material` precisely so the call gets made on screen.
        if style == .liquid, #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(fill)
                .overlay(
                    shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: TallyMetrics.hairline)
                )
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: TallyMetrics.cardRadius, style: .continuous)
    }

    @ViewBuilder
    private var fill: some View {
        switch style {
        case .solid: shape.fill(Color(nsColor: .controlBackgroundColor))
        // `liquid` lands here only below macOS 26, where the system material is the closest thing
        // the platform can draw.
        case .material, .liquid: shape.fill(.ultraThinMaterial)
        // 0.55: a starting point, not a measured value - enough card to keep the meters' track
        // distinct from the glass behind it, little enough to still read as glass.
        case .tint: shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        }
    }
}

extension View {
    func tallyCard() -> some View { modifier(TallyCard()) }

    /// Wraps a group of sibling `tallyCard()` surfaces so the system renders their Liquid Glass in
    /// one pass instead of one per card (Apple's guidance for several glass shapes on a layer - a
    /// panel of eight cards is exactly that case). `spacing: 0` because the container's spacing is
    /// the distance at which neighbouring shapes fuse into one blob: the cards are a grid of
    /// separate objects, so only overlap should ever merge them, and the 10pt gutters must not.
    /// A no-op for every other style, so the flat and grouped layouts stay one code path.
    @ViewBuilder
    func tallyCardGroup(_ style: TallyCardStyle) -> some View {
        if style == .liquid, #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { self }
        } else {
            self
        }
    }
}
