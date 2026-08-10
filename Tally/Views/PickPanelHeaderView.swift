import SwiftUI

/// The pick panel's top line: who is asking, which of the two axes was asked for, and the way out.
///
/// SPLIT OUT WHEN IT GAINED THE WAY OUT, the way PickRowView.swift was split off when the row gained
/// its circle: the panel file is the columns and the keyboard, and this is one small object with a
/// hover state of its own.
///
/// THE SAME HEADER THE REST OF THE APP HAS, which is the whole of that decision: the popover and the
/// pinned panel open with the wordmark on the content line, so this one does too rather than
/// inventing a third way to say the app's own name (`PopoverRootView.header`). Two attempts at
/// something of its own were rejected on sight, and the reason is that they were something of its
/// own.
///
/// The wordmark is laid out by its INK rather than its frame (`PanelGeometry.brandLead`): the glyph
/// draws wider than the box it is given, so a frame padded to the content line puts the mark left of
/// everything under it. The lead is shared with the popover, not copied from it.
struct PickPanelHeaderView: View {
    /// Which of the two commands raised this panel. Both axes are on it either way; this is the one
    /// that was asked for.
    let kind: PickKind
    /// Close without answering, which is what the ✕ and Escape both do.
    let close: () -> Void

    /// Whether the pointer is on the way out, so the ✕ can answer a hover before it is clicked.
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                TallyWordmarkView(glyphHeight: 13)
                    .padding(.leading, PanelGeometry.brandLead - PanelGeometry.contentPadding)
                // The same tag the popover header wears, in the same place beside the wordmark: two
                // instances of this panel can be on one machine, and answering the one belonging to
                // a build nobody installed is exactly what the claim stand-down exists to prevent
                // (`pickMayBeClaimed`). A person deserves to see which is which before they click.
                if BuildVariant.isDev {
                    TallyDevTagView()
                }
                Spacer(minLength: 8)
                // Which of the two this was opened as, said once and quietly: the panel offers both
                // axes, and this is the one the command asked for.
                Text(L(pickPanelKindName(kind)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // The identity is ONE element to a screen reader, and the way out is its own: combining
            // the whole row would fold the button below into the app's name, and a way out a screen
            // reader cannot reach is the same defect as one nobody can see.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tally, \(pickPanelKindName(kind))")
            closeButton
        }
        .padding(.bottom, 7)
    }

    /// THE WAY OUT, DRAWN. Escape has always closed this panel and still does, but a panel that no
    /// longer answers when it loses focus has to show how it IS answered: nothing on screen said so,
    /// and the only visible way out was choosing something the person may not have wanted
    /// (`PickPanelController`'s fourth rule carries the change and what it was costing).
    ///
    /// ONE REGISTER, which is the decision the search boxes are under as well: this panel says "here"
    /// with a single change at a time, because the loudest marks on it belong to the circles a press
    /// acts on. So the glyph rests at the quietest weight there is and steps to the loudest under the
    /// pointer, with no second fill saying it again.
    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(hovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                // A glyph this small is a target nobody can hit, so the target is the square around
                // it rather than the ink.
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The field keeps the keyboard, exactly as the Apply button leaves it (`PickApplyBar`): a
        // control that took the responder would send the next keystroke somewhere the filter cannot
        // see it.
        .focusable(false)
        .onHover { hovered = $0 }
        .accessibilityLabel(L("Close"))
    }
}
