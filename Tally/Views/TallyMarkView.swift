import SwiftUI

/// The relay baton: Tally's brand motif for surfaces with room to spare.
///
/// This is not a second logo. The app's identity is the Relay T (`TallyGlyphView`), whose green
/// shoulder already says "progress passing through"; the baton is that shoulder unrolled into the
/// segments it stands for, one per account, lit left to right as the work moves between them. It
/// carries the glyph's exact accent green so the two read as one family, and it appears only where
/// density is free: an empty panel, an About surface, onboarding, marketing shots. Data rows keep
/// naming providers with their own official marks and stay free of decoration.
struct TallyBatonView: View {
    /// Segments in the baton. Three reads as "a fleet" without becoming a barcode.
    var segments: Int = 3
    /// The lit segment, 0-based. Everything up to it is lit, like a relay already run.
    var carrying: Int = 1
    var width: CGFloat = 54
    var thickness: CGFloat = 5

    var body: some View {
        let gap = thickness * 0.7
        let segmentWidth = (width - gap * CGFloat(segments - 1)) / CGFloat(segments)
        HStack(spacing: gap) {
            ForEach(0 ..< segments, id: \.self) { index in
                Capsule()
                    .fill(index <= carrying ? TallyColor.brand : Color.secondary.opacity(0.22))
                    .frame(width: segmentWidth, height: thickness)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The app's mark for empty surfaces: the Relay T over its baton, the baton handing off on a slow
/// timer. One motion signature, deliberately unhurried so it never reads as a spinner, and still
/// under Reduce Motion.
struct TallyMarkView: View {
    /// Segments in the baton, held here because the handoff cycles through them.
    private static let segments = 3
    var glyphHeight: CGFloat = 30
    @State private var carrying = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: glyphHeight * 0.34) {
            TallyGlyphView()
                .frame(height: glyphHeight)
            TallyBatonView(segments: Self.segments, carrying: carrying, width: glyphHeight * 1.9,
                           thickness: max(3, glyphHeight * 0.16))
                .animation(.easeInOut(duration: 0.18), value: carrying)
        }
        // Keyed on Reduce Motion rather than reading it once: this tree never "disappears" in
        // SwiftUI's sense. A closed NSPopover (and an ordered-out panel) keeps its hosted content
        // alive and updating, so a plain `.task` is started once and never cancelled or re-run,
        // and a Reduce Motion toggle mid-session would go unseen for the rest of the process's
        // life. The id restarts the task whenever the setting changes, in both directions.
        // Decorative: the empty state's own text says everything this mark implies.
        .accessibilityHidden(true)
        .task(id: reduceMotion) {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1400))
                // `try?` swallows the cancellation error, so re-check before mutating: without
                // this, turning Reduce Motion on hands the baton over one last time on the way out.
                guard !Task.isCancelled else { break }
                carrying = (carrying + 1) % Self.segments
            }
        }
    }
}
