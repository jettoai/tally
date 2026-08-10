import SwiftUI

// What the pick palette draws BELOW the level of a column: one row, and the bar kept under both
// columns. Split from PickPanelView.swift when the circling grammar arrived (PickPalette.swift):
// the panel is the state machine, these two are what that state looks like.

/// One row: what it is, what it costs, what it is to this session, and whether it is circled.
///
/// THE CIRCLE IS THE APP'S OWN PIN LANGUAGE, deliberately rather than a new mark invented here: a
/// hollow circle means "click to take this one" and a checked circle means "taken", which is exactly
/// what the account cards' pin toggle has always said (`AccountCardView.pinToggle`). One vocabulary
/// for one meaning, on the two surfaces that both decide where a session runs.
///
/// THREE STATES, AND THEY MUST NOT BE MISTAKEN FOR EACH OTHER, which is why the hover is drawn
/// differently in kind rather than merely more faintly: circled is a decision the panel will send,
/// hovered is where the pointer happens to be, and the focused COLUMN is where typing goes. The
/// circle carries a glyph the other two never draw, so the one that matters is the one that is
/// legible without comparing two rows.
struct PickRowView: View {
    let row: PickRow
    /// Whether this row is what its column will submit. Exactly one row per column ever is, and it
    /// may be the row the session is already on, which submits nothing (`pickPendingChanges`).
    let isCircled: Bool
    /// Whether the pointer is on it. Drawing only: nothing about a hover is sent.
    var isHovered = false
    /// Whether this row's column is the one the keyboard is in. Both columns keep a circle, so both
    /// draw one; the focused column's is drawn the stronger of the two.
    var isFocusedColumn = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            mark
            VStack(alignment: .leading, spacing: 1) {
                // THE TAGS RIDE THE NAME'S LINE rather than the whole row, which is what buys the
                // second line its full width: an account's windows carry their reset countdowns now
                // (`mcpAccountWindows`), and a tag standing beside the row squeezed that line into
                // about two thirds of it, where the last countdown truncated away.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // The name only. The depth is the chip beside it and the aside is the line
                    // below, so a label carrying either has that part taken off rather than saying
                    // it twice (`pickPanelLabel`).
                    Text(pickPanelLabel(row))
                        .font(.body)
                        .fontWeight(row.isCurrent ? .semibold : .regular)
                    if let effort = row.effort {
                        Text(effort)
                            .font(.caption)
                            .foregroundStyle(TallyColor.ai)
                    }
                    Spacer(minLength: 8)
                    // The tags the CLI decided, drawn rather than restated: which account this
                    // session is on and which one has the most headroom are one answer for every
                    // surface.
                    ForEach(row.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .foregroundStyle(tag == switchRecommendedTag ? TallyColor.normal
                                : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: TallyMetrics.calloutRadius,
                                                 style: .continuous)
                                    .fill(.quaternary.opacity(isCircled ? 0.35 : 0.25)))
                    }
                }
                if let detail = pickPanelDetail(row), !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        // ONE LINE, ALWAYS: the height family assumes a two-line row is exactly two
                        // lines (`pickDetailRowHeight`), so a detail that wraps is a row taller than
                        // anything computing this panel's size knows about.
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, TallyMetrics.cardPaddingH)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: TallyMetrics.cardRadius, style: .continuous)
                .fill(background))
    }

    /// THE SLOT IS ALWAYS THERE, whether or not anything is in it: a glyph that appears on hover and
    /// pushes the name sideways is a list that shifts under the pointer reading it. Same reason the
    /// account cards keep their drag handle resident and dim it instead.
    private var mark: some View {
        Image(systemName: isCircled ? "checkmark.circle.fill" : "circle")
            .font(.caption)
            .foregroundStyle(isCircled ? AnyShapeStyle(TallyColor.ai) : AnyShapeStyle(.tertiary))
            .opacity(isCircled ? 1 : (isHovered ? 0.55 : 0))
            .frame(width: pickRowMarkWidth, alignment: .leading)
            .accessibilityHidden(true)
    }

    /// The resting mark under the row: strong in the column the keyboard is in, quiet in the other
    /// one, and quieter still where the pointer merely happens to be.
    private var background: AnyShapeStyle {
        guard !isCircled else {
            return isFocusedColumn ? AnyShapeStyle(.selection.opacity(0.55))
                : AnyShapeStyle(.quaternary.opacity(0.3))
        }
        return isHovered ? AnyShapeStyle(.quaternary.opacity(0.18)) : AnyShapeStyle(Color.clear)
    }
}

/// THE BAR UNDER BOTH COLUMNS: what one press would do, and the button that does it.
///
/// WHY THERE IS ONE AT ALL. A click used to be the whole answer, so there was nothing to preview and
/// nothing to confirm. Circling costs that back and has to pay for it: a person who has circled two
/// rows cannot see what they are about to do anywhere else on the panel, because the two circles are
/// in two columns and one of them may be scrolled away.
///
/// SAID IN THE PANEL'S OWN TERMS, not the wire's: "Claude 2" and "opus high" are what the rows read
/// as, so the sentence is assembled from the same reading the rows are drawn from
/// (`pickChangeSummary`).
///
/// ITS SPACE IS KEPT EVEN WHEN IT SAYS NOTHING (`pickApplyBarHeight`), which is the same rule the
/// shared list height is under: the panel must not change size while somebody is working in it.
struct PickApplyBar: View {
    /// What will be submitted, or nil when nothing would be.
    let summary: String?
    let apply: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button(action: apply) {
                    HStack(spacing: 5) {
                        Text(L("Apply"))
                        // The key that does the same thing, beside the button that does it: the
                        // keyboard path is the fast one and a button alone hides it.
                        Text(verbatim: "\u{21A9}").opacity(0.7)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TallyColor.ai)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(TallyColor.ai.opacity(0.15)))
                }
                .buttonStyle(.plain)
                // The field keeps the keyboard: a button that took the responder would send the
                // next keystroke somewhere the filter cannot see it.
                .focusable(false)
                .accessibilityLabel("\(L("Apply")) \(summary)")
            }
        }
        .frame(height: pickApplyBarHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, pickApplyBarGap)
    }
}
