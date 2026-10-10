import SwiftUI

// The callout's lazy entries, kept out of TallyTooltip.swift for the 500-line rule.

extension View {
    /// `tallyTooltip(blocks:)`, with blocks that are built only while somebody can be shown them: under
    /// the pointer, held open for a capture, outside a layer (the system tooltip needs its text up
    /// front), or with VoiceOver on (the hint is how it hears them). For a callout whose figures
    /// cost real work on every redraw of a target nobody is hovering (Sentry TALLY-82).
    func tallyTooltip(lazyBlocks: @escaping () -> [TallyTooltipBlock], forced: Bool = false, hugsRow: Bool = false) -> some View {
        modifier(TallyTooltipTarget(resolve: { .blocks(lazyBlocks()) }, lazy: true, forced: forced, hugsRow: hugsRow))
    }

    /// The text callout, built only while somebody can be shown it, exactly as
    /// `tallyTooltip(lazyBlocks:)` builds its blocks. For a sentence that costs real work on every
    /// redraw of a target nobody is hovering (Sentry TALLY-23, the advisor row).
    func tallyTooltip(lazyText: @escaping () -> String, forced: Bool = false) -> some View {
        modifier(TallyTooltipTarget(resolve: { .lines(lazyText().components(separatedBy: "\n").filter { !$0.isEmpty }) },
                                    lazy: true, forced: forced))
    }
}
