import SwiftUI

/// The relay baton: Tally's brand motif for surfaces with room to spare.
///
/// This is not a second logo. The app's identity is the Relay T (`TallyGlyphView`), whose green
/// shoulder already says "progress passing through"; the baton is that shoulder unrolled into the
/// segments it stands for, one per account, lit left to right as the work moves between them. It
/// carries the glyph's exact accent green so the two read as one family, and it appears only where
/// density is free: an About surface, onboarding, marketing shots. Data rows keep
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
