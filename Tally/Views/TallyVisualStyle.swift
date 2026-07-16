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
    static let critical = Color(red: 0.86, green: 0.31, blue: 0.29)  // softened red, not alarm-siren
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

/// A neutral, adaptive card surface: a subtle raised fill + a hairline border + a continuous radius,
/// no drop shadow. Works over both the window background and the popover's vibrancy.
private struct TallyCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: TallyMetrics.cardRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: TallyMetrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: TallyMetrics.hairline)
            )
    }
}

extension View {
    func tallyCard() -> some View { modifier(TallyCard()) }
}
