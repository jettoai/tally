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
    /// The second line the PANEL adds to this row, as the key its translations are filed under
    /// (`pickPanelNote`): what a model named with no depth does. Nil for every row that already
    /// says what it does, and the height arithmetic reads the same answer (`PickPaletteItem`).
    var note: String?

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
                        PickEffortChip(effort: effort, lit: isCircled)
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
                } else if let note {
                    // WHAT THIS ROW DOES TO THE OTHER AXIS, drawn rather than sent (`pickPanelNote`
                    // says why the wire does not carry it, and what a bare model row read as before
                    // it was here). Quieter than a detail line: it is the same sentence on every one
                    // of these rows, so it must not compete with the names beside it.
                    Text(L(note))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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

/// THE DEPTH BESIDE A MODEL'S NAME: a chip in the same capsule the tags wear, tinted by how deep it
/// is (`pickEffortHeat`).
///
/// WHY IT IS TINTED AT ALL. Both drawn depths used to be the one accent purple, so `high` and
/// `xhigh` read as two interchangeable words and nothing on the panel said which of them spends the
/// paid window faster (Albert, on the panel). The whole axis is drawn now
/// (`pickerExpandedEfforts`), which makes the ramp the thing that keeps six words readable.
struct PickEffortChip: View {
    let effort: String
    /// Whether the row it sits on is circled, which is the same two fills the tags beside it use: a
    /// chip on the circled row is drawn a shade stronger so the row reads as one object.
    var lit = false

    private var color: Color { pickEffortColor(effort) }

    var body: some View {
        Text(verbatim: effort)
            .font(.caption2)
            .fontWeight(pickEffortWeight(effort))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: TallyMetrics.calloutRadius, style: .continuous)
                    .fill(color.opacity(lit ? 0.22 : 0.14)))
    }
}

/// THE ONE PLACE A DEPTH BECOMES A COLOUR, so the chip on a row and the same word in the bar under
/// the columns cannot end up two different colours. The ranking itself is pure and asserted without
/// a screen (`pickEffortHeat`); this is only the palette it is read through.
///
/// THE APP'S OWN TONES RATHER THAN A RAMP INVENTED HERE: the accent purple for the ordinary depth,
/// and the meters' amber and red past it, which are the two warm tones this palette has and are
/// already what "this is the costly end" looks like everywhere else in the app (`TallyColor`). The
/// shallow end is no colour at all, because there is nothing to warn about down there.
func pickEffortColor(_ effort: String) -> Color {
    switch pickEffortHeat(effort) {
    case .shallow: return Color.secondary
    case .standard: return TallyColor.ai
    // `ultracode` runs AT this depth, so it is drawn in this depth's colour and told apart by the
    // weight below rather than by a hue that would rank it past `max`.
    case .deep, .mode: return TallyColor.warning
    case .deepest: return TallyColor.critical
    }
}

/// The one thing on the chip that is not the ramp: a mode is set in the depth it runs at, and said
/// slightly louder because it is doing something else as well (`PickEffortHeat.mode`).
func pickEffortWeight(_ effort: String) -> Font.Weight {
    pickEffortHeat(effort) == .mode ? .semibold : .regular
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
    /// What would be submitted, in the order the columns stand. Empty on a panel that would submit
    /// nothing, which is what draws no sentence and no button.
    let changes: [PickChoice]
    let apply: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let summary = pickPendingSummary(changes) {
                sentence
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

    /// THE SAME SENTENCE `pickPendingSummary` WRITES, in pieces so the depth in it carries the
    /// colour its chip carries in the row above (`pickEffortColor`): one word, one colour, wherever
    /// this panel says it. Assembled from `pickChangeParts`, which is what the joined form is built
    /// from too, so the drawn line and the line read aloud are the same words in the same order.
    private var sentence: Text {
        changes.enumerated().reduce(Text(verbatim: pickPendingLead)) { line, pair in
            let parts = pickChangeParts(pair.element)
            let separated = pair.offset == 0 ? line : line + Text(verbatim: pickEffortSeparator)
            let named = separated + Text(verbatim: parts.label)
            guard let effort = parts.effort else { return named }
            return named + Text(verbatim: " ")
                + Text(verbatim: effort).foregroundStyle(pickEffortColor(effort))
                    .fontWeight(pickEffortWeight(effort))
        }
    }
}
