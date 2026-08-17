import SwiftUI

/// Shared visual language so Settings, the popover, and the dashboard read as one product instead of
/// three separately-improvised screens. Spacing/surface/colour live here as the single source; views
/// reference these constants rather than sprinkling ad-hoc numbers.
enum TallyMetrics {
    static let cardRadius: CGFloat = 12          // continuous corner radius for every surface
    static let calloutRadius: CGFloat = 7        // the same family, one size down: chips and tooltips
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
    /// THE STATE AXIS'S GREEN: something is alive and running, and nobody has to do anything about
    /// it. Bright and saturated on purpose, so it cannot be taken for `normal`'s calm sage. The two
    /// answer different questions and never share a surface: `normal` fills a meter (a continuous
    /// quantity, "how much is left"), this fills a small dot in a set of discrete categories ("what
    /// is it doing"). Keeping them different literals is what keeps that distinction honest.
    ///
    /// Not `brand` either. That one is the identity mark and asserts nothing about condition, and an
    /// identity colour standing in for a state is the overload this one was added to undo (the
    /// reasoning, and what it replaced, is at `stateDot` in SessionBoardView).
    static let live = Color(red: 0.17, green: 0.75, blue: 0.35)
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
    /// What this card's own EDGE is saying, or nothing for the ordinary hairline that is only
    /// defining a surface (see `View.tallyCard`).
    var accent: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        // Liquid Glass is not a fill: the system renders the surface, including its own specular
        // rim. So it takes the whole surface over rather than joining the fill switch, and it drops
        // the hairline - our border would sit ON that rim and read as a second, duller edge.
        // Reasoned from the material's own lighting, not measured; the two live side by side under
        // `-TallyCardStyle liquid|material` precisely so the call gets made on screen.
        //
        // AN ACCENT IS NOT DROPPED THERE, and that is the difference between an edge that defines a
        // surface and one that is carrying a fact: the rim already says where the card is, and
        // nothing on that rim says this is the card asking for somebody.
        if style == .liquid, #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape).overlay(accentEdge)
        } else {
            content.background(fill).overlay(edge)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: TallyMetrics.cardRadius, style: .continuous)
    }

    /// The card's edge: its accent if it has one, and the hairline that merely bounds the surface
    /// otherwise. The two never both draw, so an accented card has one edge rather than a coloured
    /// line laid over a grey one.
    @ViewBuilder
    private var edge: some View {
        if accent != nil {
            accentEdge
        } else {
            shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: TallyMetrics.hairline)
        }
    }

    @ViewBuilder
    private var accentEdge: some View {
        if let accent {
            shape.strokeBorder(accent.opacity(Self.accentOpacity), lineWidth: Self.accentWidth)
        }
    }

    /// Twice the hairline, which is what it takes for an edge to be a mark rather than a boundary:
    /// the hairline is a half point of eight per cent black and reads as "where this card ends",
    /// and a colour drawn at the same weight would read the same way.
    private static let accentWidth: CGFloat = 1
    /// AND NOT AT FULL STRENGTH, because a border is a long mark. The same red fills a seven point
    /// dot on the card's first line; run round the whole of a card it is far more of that colour on
    /// screen, and undimmed the edge shouts down the very words inside it that say what the card is
    /// waiting for. Held back far enough to read as a frame rather than as a fill. A starting point
    /// judged on screen rather than a measured value, the way this file's other opacity was arrived
    /// at (`TallyCardStyle.tint`).
    private static let accentOpacity: Double = 0.55

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
    /// - Parameter accent: draw this card's edge in a colour instead of the neutral hairline.
    ///
    /// A CARD'S EDGE IS THE ONE PART OF IT A READER FINDS WITHOUT LOOKING AT IT, which is what this
    /// is for and also why it is rationed. A board is read by sweeping down it for the one card
    /// that needs somebody, and everything a card says about that is inside it: a dot, a word, a
    /// line of red text, all of which have to be read card by card. An outline is a pre-attentive
    /// feature, so the card that has one is found before the grid is read at all.
    ///
    /// EXACTLY ONE CONDITION GETS IT, and the rationing is the feature (`SessionCardView.body`): a
    /// blocked session, which is the only state on this board where a person is what the session is
    /// waiting for. A second use would put the reader back to reading edges to find out which kind
    /// of edge this one is, which is the cost the outline was spent to avoid.
    func tallyCard(accent: Color? = nil) -> some View { modifier(TallyCard(accent: accent)) }

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
