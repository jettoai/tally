import SwiftUI

// The palette itself. One row is one whole decision, so there is no Accept: the click IS the submit,
// and the keyboard path is Enter on the row the arrow keys are resting on.
//
// THE RESTING ROW IS WHERE THE SESSION ALREADY IS (`PickRow.isCurrent`), not the top of the list.
// That is what makes the keyboard path short for the change people actually make: one arrow from
// "the model I am on at the depth I am on" is the same model one level deeper.
//
// TWO SECTIONS AND A FILTER, and what does not change with them is the point: the axis that was
// asked for is on top with its way out pinned under the list exactly as before, the other axis is
// underneath, and a row still decides everything about itself. What the structure IS lives in
// PickPalette.swift, which is where it can be asserted without a screen; this file draws it.

struct PickPanelView: View {
    let request: PickRequest
    /// nil is a cancellation. One closure for both, because the panel above treats them as one
    /// event: something happened and the panel is done. The choice carries its SECTION, since the
    /// two sections are applied by different paths at the far end (`PickChoice.answer`).
    let choose: (PickChoice?) -> Void

    /// What has been typed. The filter is the only state the panel keeps besides the cursor.
    @State private var query = ""
    @State private var selection: Int
    @FocusState private var focused: Bool
    /// What the rows actually laid out at, or zero before the first pass. Read through
    /// `pickPaletteHeight`, which is where "zero is not a measurement" is decided.
    @State private var rowsHeight: CGFloat = 0

    init(request: PickRequest, choose: @escaping (PickChoice?) -> Void) {
        self.request = request
        self.choose = choose
        _selection = State(initialValue: pickPaletteSelection(pickPalette(request), filtering: false))
    }

    private var palette: PickPalette { pickPalette(request, filter: query) }

    var body: some View {
        let palette = self.palette
        VStack(alignment: .leading, spacing: 0) {
            header
            // THREE SIZES, THREE JOBS: the header is the anchor, this is the situation it is
            // answering, and the rows are the answer. Everything was one weight of grey before, so
            // the panel read as two paragraphs with a list under them.
            Text(request.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, TallyMetrics.headerToCard + 4)
            searchField
            ScrollViewReader { proxy in
                ScrollView {
                    // EAGER, and that is a sizing decision rather than a performance one: what the
                    // list is told to be tall is what these rows MEASURE (`rowsHeightReporter`), and
                    // a lazy stack only measures the rows it has materialized. The lists here are a
                    // fleet and an effort table, tens of rows at the outside.
                    //
                    // SPACED BY THE RULE RATHER THAN EVENLY (`pickRowGap`), which is why the stack
                    // itself has none: one model and its two depths belong together, and an even 2
                    // points made ten rows read as ten unrelated ones.
                    VStack(spacing: 0) {
                        ForEach(Array(palette.items.enumerated()), id: \.offset) { _, item in
                            entry(item)
                        }
                    }
                    .padding(.vertical, pickRowsPadding)
                    .background(rowsHeightReporter)
                }
                // TOLD, NOT ASKED. A ScrollView has no ideal height along its scroll axis, so a
                // panel sized by its content (`PickPanelController` leaves `sizingOptions` the only
                // size authority) used to get nothing back and come up as a message with no rows
                // under it. The height comes from the palette now, measured or computed, and
                // `pickPaletteHeight` is where both live.
                .frame(height: pickPaletteHeight(measured: rowsHeight, palette: palette))
                .onChange(of: selection) { _, now in
                    // Only what scrolls can be scrolled to: the pinned row is not in this region,
                    // and it does not need to be brought into view because it never leaves.
                    guard palette.sticky?.choiceIndex != now else { return }
                    withAnimation(.linear(duration: 0.08)) { proxy.scrollTo(now, anchor: .center) }
                }
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
            // PINNED UNDER THE LIST, not in it: the row that releases the pin is what a person
            // reaches for when the list is not what they wanted, and a long fleet used to scroll it
            // out of sight. Still a member of `palette.choices`, so the arrow keys walk onto it from
            // the last scrolling row and Enter takes it like any other.
            if let sticky = palette.sticky { entry(sticky) }
        }
        // THE PANEL'S OWN CONTENT LINE, which is the popover's and the pinned panel's
        // (`PanelGeometry.contentPadding`): this surface used to keep a wider margin of its own, so
        // two windows of the same app started their text at two different x.
        .padding(.horizontal, PanelGeometry.contentPadding)
        .padding(.vertical, PanelGeometry.contentPadding)
        .frame(width: 460)
        // Borderless, like the pinned panel, so the surface is drawn rather than inherited: same
        // backdrop, same 12pt continuous corner (PinnedPanelController). The titled panel this
        // replaced spent 32 points on a titlebar it kept empty, which is the dead space at the top
        // Albert saw.
        .background(PanelBackdrop(settings: .shared))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        // ONE HANDLER FOR THE WHOLE KEYBOARD, because typing is now one of the things the keyboard
        // does here and a filter cannot be spelled as a list of named keys. What each press MEANS is
        // decided by `pickKeyAction`, which is pure and asserted without a screen; this only
        // translates SwiftUI's vocabulary into that one.
        .onKeyPress(phases: .down) { press in handle(press) }
    }

    /// THE SAME HEADER THE REST OF THE APP HAS, which is the whole of this decision: the popover
    /// and the pinned panel open with the wordmark on the content line, so this one does too rather
    /// than inventing a third way to say the app's own name (`PopoverRootView.header`). Two attempts
    /// at something of its own were rejected on sight, and the reason is that they were something of
    /// its own.
    ///
    /// The wordmark is laid out by its INK rather than its frame (`PanelGeometry.brandLead`): the
    /// glyph draws wider than the box it is given, so a frame padded to the content line puts the
    /// mark left of everything under it. The lead is shared with the popover, not copied from it.
    private var header: some View {
        HStack(spacing: 6) {
            TallyWordmarkView(glyphHeight: 13)
                .padding(.leading, PanelGeometry.brandLead - PanelGeometry.contentPadding)
            Spacer(minLength: 8)
            // Which of the two this was opened as, said once and quietly: the palette offers both
            // axes, and this is the one the command asked for.
            Text(pickPanelKindName(request.kind))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tally, \(pickPanelKindName(request.kind))")
    }

    /// What has been typed, and what to do with it.
    ///
    /// A DRAWN FIELD RATHER THAN A `TextField`, deliberately. A real text field takes the first
    /// responder, and with it the arrow keys and Enter that this panel answers with: the keyboard
    /// path here was rebuilt three times around a focus that had to stay on the panel
    /// (`pickGraceVerdict` carries that family), and putting an editable field in the middle of it
    /// buys a caret and an insertion point at the cost of the two keys the surface exists for. So
    /// the panel keeps the focus, every printable key lands in the query (`pickKeyAction`), and this
    /// draws the result. What is given up is stated rather than discovered: no caret, no paste, and
    /// no input method, which the vocabulary here (model names and account labels, all ASCII) does
    /// not ask for.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? pickSearchPlaceholder : query)
                .font(.body)
                .foregroundStyle(query.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(1)
            Spacer(minLength: 8)
            if !query.isEmpty {
                // The way back, said where the state it undoes is: Escape clears this before it
                // closes anything (`pickKeyAction`).
                Text("esc to clear")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: pickSearchFieldHeight)
        .padding(.horizontal, TallyMetrics.cardPaddingH)
        .background(
            RoundedRectangle(cornerRadius: TallyMetrics.cardRadius, style: .continuous)
                .fill(.quaternary.opacity(0.25)))
        .padding(.bottom, 6)
        .accessibilityLabel("Filter")
        .accessibilityValue(query)
    }

    /// One item, wherever it is drawn. Shared by the scrolling region and the pinned row so the two
    /// cannot grow different behaviour: the same click, the same hover, the same resting mark.
    @ViewBuilder private func entry(_ item: PickPaletteItem) -> some View {
        separator(above: item)
        if let heading = item.heading {
            Text(heading)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: pickSectionHeadingHeight, alignment: .bottom)
                .padding(.horizontal, TallyMetrics.cardPaddingH)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let row = item.row, let index = item.choiceIndex {
            PickRowView(row: row, isSelected: index == selection)
                .id(index)
                .contentShape(Rectangle())
                // ONE CLICK, no second confirmation. The cost of a mis-click is a pin to the wrong
                // account, which the same panel undoes in one more click; the cost of an Accept key
                // is one extra action on every correct pick, for ever.
                .onTapGesture { choose(PickChoice(kind: item.kind, row: row)) }
                .onHover { if $0 { selection = index } }
        }
    }

    /// What goes above an item: the rule that sets a way out apart from the choices, or plain space.
    /// Both are the height the palette said they are, which is what keeps the drawing and the
    /// arithmetic the same thing.
    @ViewBuilder private func separator(above item: PickPaletteItem) -> some View {
        if item.ruled {
            Divider()
                .opacity(0.5)
                .padding(.vertical, pickRowGroupSpacing)
        } else if item.gapAbove > 0 {
            Color.clear.frame(height: item.gapAbove)
        }
    }

    /// The rows' own laid-out height, reported upward. Same shape as the surface the panel and the
    /// popover are sized by (`PopoverRootView.sizeReporter`), and for the same reason: a rendered
    /// size is a fact, while a size asked of a scrolling container is a preference it does not have.
    private var rowsHeightReporter: some View {
        GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                rowsHeight = height
            }
        }
    }

    /// SwiftUI's vocabulary, translated into this panel's. A press carrying a command, control or
    /// option is somebody doing something else with the machine, so it is handed back rather than
    /// typed into the filter.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard !press.modifiers.contains(.command), !press.modifiers.contains(.control),
              !press.modifiers.contains(.option) else { return .ignored }
        let key: PickKey
        switch press.key.character {
        case KeyEquivalent.upArrow.character: key = .up
        case KeyEquivalent.downArrow.character: key = .down
        case KeyEquivalent.return.character: key = .enter
        case KeyEquivalent.escape.character: key = .escape
        case KeyEquivalent.delete.character: key = .delete
        default: key = .text(press.characters)
        }
        switch pickKeyAction(key, query: query) {
        case .move(let step):
            move(step)
        case .commit:
            commit()
        case .cancel:
            choose(nil)
        case .edit(let typed):
            query = typed
            // THE CURSOR FOLLOWS THE TYPING. What was selected is an index into a list the query has
            // just rewritten, so keeping it would leave the cursor on whatever happens to sit at
            // that position now.
            selection = pickPaletteSelection(palette, filtering: !typed.isEmpty)
        case .ignore:
            return .ignored
        }
        return .handled
    }

    private func move(_ step: Int) {
        let choices = palette.choices
        guard !choices.isEmpty else { return }
        // Clamped rather than wrapped: a list that jumps from the last row to the first turns a held
        // arrow key into a lap of the fleet.
        selection = min(max(selection + step, 0), choices.count - 1)
    }

    private func commit() {
        let choices = palette.choices
        guard choices.indices.contains(selection) else { return }
        choose(choices[selection])
    }
}

/// One row: what it is, what it costs, and what it is to this session.
struct PickRowView: View {
    let row: PickRow
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
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
                }
                if let detail = pickPanelDetail(row), !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            // The tags the CLI decided, drawn rather than restated: which account this session is on
            // and which one has the most headroom are one answer for every surface.
            ForEach(row.tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .foregroundStyle(tag == switchRecommendedTag ? TallyColor.normal : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: TallyMetrics.calloutRadius, style: .continuous)
                            .fill(.quaternary.opacity(isSelected ? 0.35 : 0.25)))
            }
        }
        .padding(.horizontal, TallyMetrics.cardPaddingH)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: TallyMetrics.cardRadius, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(.selection.opacity(0.55))
                      : AnyShapeStyle(Color.clear)))
    }
}
