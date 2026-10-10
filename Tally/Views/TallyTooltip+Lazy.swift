import SwiftUI

// The text callout's lazy entry, kept out of TallyTooltip.swift for the 500-line rule.

extension View {
    /// The text callout, built only while somebody can be shown it, exactly as
    /// `tallyTooltip(lazyBlocks:)` builds its blocks. For a sentence that costs real work on every
    /// redraw of a target nobody is hovering (Sentry TALLY-23, the advisor row).
    func tallyTooltip(lazyText: @escaping () -> String, forced: Bool = false) -> some View {
        modifier(TallyTooltipTarget(resolve: { .lines(lazyText().components(separatedBy: "\n").filter { !$0.isEmpty }) },
                                    lazy: true, forced: forced))
    }
}
