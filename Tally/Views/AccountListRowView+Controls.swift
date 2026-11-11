import SwiftUI

/// The list row's badge slot and pin toggle, split out of AccountListRowView for file size.
extension AccountListRowView {
    /// Always the same width, badge or no badge: the pin circles have to stand in one column, and a
    /// slot that collapses when the smart pick moves would shuffle every row beside it.
    var badgeSlot: some View {
        ZStack {
            // Something real has to hold the slot open: a branch that matches nothing resolves to an
            // EmptyView, which is layout-transparent - a `.frame` on it reserves nothing at all, and
            // the rows carrying a badge sat a badge's width left of the rest (seen on screen,
            // 2026-08-04).
            Color.clear.frame(width: Self.badgeWidth, height: Self.badgeWidth)
            if facts.launchMode == .manual, facts.isPinnedActive {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.orange)
                    .tallyTooltip(L("Manual: every new session uses this account."))
                    .accessibilityLabel(L("Pinned"))
            } else if facts.launchMode == .auto, isAutoPick ?? facts.isAutoPick {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                    .foregroundStyle(TallyColor.ai)
                    .tallyTooltip(facts.smartPickTooltip, forced: facts.forcesSmartTooltip)
                    .accessibilityLabel(L("Smart"))
            }
        }
        .frame(width: Self.badgeWidth)
        // Air between the last figure and the glyph: without it "61%" and the sparkle touched.
        .padding(.leading, 3)
    }

    var pinToggle: some View {
        Button { facts.togglePin() } label: {
            Image(systemName: facts.isPinnedActive ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(facts.isPinnedActive ? Color.orange : PanelStyle.text2)
        }
        .buttonStyle(.plain)
        .disabled(!facts.canTogglePin)
        .tallyTooltipAroundControl(facts.pinToggleHelp)
        .accessibilityLabel(L("Set as launch account"))
    }
}

/// A name that truncates before anything beside it does. Its ideal width is `floor` (or the text,
/// if shorter), so a `ViewThatFits` asking "does the name plus the plan pill fit" is answering for
/// the shortest the name may get; handed a real width it takes the text's own width up to that.
struct TruncatingName: Layout {
    var floor: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let natural = view.sizeThatFits(.unspecified)
        guard let width = proposal.width, width.isFinite else {
            return CGSize(width: min(floor, natural.width), height: natural.height)
        }
        return CGSize(width: min(natural.width, max(width, 0)), height: natural.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
