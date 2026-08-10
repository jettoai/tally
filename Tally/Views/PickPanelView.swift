import SwiftUI

// The palette itself. One row is one whole decision, so there is no Accept: the click IS the submit,
// and the keyboard path is Enter on the row the arrow keys are resting on.
//
// TWO COLUMNS, ACCOUNTS LEFT AND MODELS RIGHT (PickPalette.swift builds them and says why they are
// side by side rather than stacked). Everything one axis has is inside its own column: its name, its
// own filter, its own scrolling region and the row that hands that axis back, pinned at its foot. So
// the two questions cannot run together, and the two ways out cannot be mistaken for each other.
//
// THE COMMAND DECIDES WHERE THE KEYBOARD STARTS, not where anything is drawn: `/tally-account`
// starts in the left column and `/tally-model` in the right, and the left and right arrows move
// between them from there. The focused column is the one that is typed into, and it says so.
//
// THE RESTING ROW IS WHERE THE SESSION ALREADY IS (`PickRow.isCurrent`), not the top of a column.
// That is what makes the keyboard path short for the change people actually make: one arrow from
// "the model I am on at the depth I am on" is the same model one level deeper.

struct PickPanelView: View {
    let request: PickRequest
    /// nil is a cancellation. One closure for both, because the panel above treats them as one
    /// event: something happened and the panel is done. The choice carries its COLUMN, since the two
    /// axes are applied by different paths at the far end (`PickChoice.answer`).
    let choose: (PickChoice?) -> Void

    /// Which column the keyboard is in. The command decides where it starts; the arrow keys, a
    /// hover and a click on a field all move it.
    @State private var focus: PickKind
    /// What has been typed, per column. Each column filters only itself, which is the whole reason
    /// there are two fields rather than one.
    @State private var queries: [PickKind: String] = [:]
    /// Where the cursor is in each column, kept per column so stepping across and back returns to
    /// where somebody was.
    @State private var selections: [PickKind: Int] = [:]
    @FocusState private var focused: Bool
    /// What each column's rows actually laid out at, or zero before the first pass. Read through
    /// `pickPaletteListHeight`, which is where "zero is not a measurement" is decided.
    @State private var listHeights: [PickKind: CGFloat] = [:]
    /// When this panel went up, which is what separates a person moving the pointer onto a row from
    /// the panel having been raised underneath one (`pickHoverMovesFocus`).
    @State private var shownAt = Date()

    init(request: PickRequest, choose: @escaping (PickChoice?) -> Void) {
        self.request = request
        self.choose = choose
        _focus = State(initialValue: request.kind)
        _selections = State(initialValue: Dictionary(
            uniqueKeysWithValues: pickPalette(request).columns.map {
                ($0.kind, pickColumnSelection($0))
            }))
    }

    private var palette: PickPalette { pickPalette(request, filters: queries) }

    var body: some View {
        let palette = self.palette
        let listHeight = pickPaletteListHeight(palette, measured: listHeights)
        VStack(alignment: .leading, spacing: 0) {
            header
            // THREE SIZES, THREE JOBS: the header is the anchor, this is the situation it is
            // answering, and the rows are the answer. Everything was one weight of grey before, so
            // the panel read as two paragraphs with a list under them. It stays one line across the
            // whole panel: what it says is about the session, which is what both columns are about.
            Text(request.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, TallyMetrics.headerToCard + 4)
            HStack(alignment: .top, spacing: pickColumnGap) {
                ForEach(palette.columns, id: \.kind) { column in
                    columnView(column, listHeight: listHeight, alone: palette.isSingleColumn)
                }
            }
        }
        // THE PANEL'S OWN CONTENT LINE, which is the popover's and the pinned panel's
        // (`PanelGeometry.contentPadding`): this surface used to keep a wider margin of its own, so
        // two windows of the same app started their text at two different x.
        .padding(.horizontal, PanelGeometry.contentPadding)
        .padding(.vertical, PanelGeometry.contentPadding)
        // The columns decide the width, so it is arithmetic rather than a number written here
        // (`pickPanelWidth`): two lists of different shapes, and the older single-list request keeps
        // the width this panel has always had.
        .frame(width: pickPanelWidth(palette))
        // Borderless, like the pinned panel, so the surface is drawn rather than inherited: same
        // backdrop, same 12pt continuous corner (PinnedPanelController). The titled panel this
        // replaced spent 32 points on a titlebar it kept empty, which is the dead space at the top
        // Albert saw.
        .background(PanelBackdrop(settings: .shared))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            shownAt = Date()
        }
        // THE BACKSTOP, not the usual path: the field is a real `NSTextField` and answers the
        // keyboard itself (PickSearchField), handing up only the keys the panel owns. These stay
        // for the case where it never became first responder (a panel that is not the key window,
        // which is how the dev preview is raised), so the surface is never dead to the keyboard.
        //
        // NAMED RATHER THAN SNIFFED, which is the shape of the defect Albert hit when this was the
        // only path: a catch-all handler had to recognise the special keys by the character they
        // carry, backspace does not arrive as the one `KeyEquivalent.delete` spells, and it was
        // dropped in silence. The phases matter for the same reason: a held key repeats as
        // `.repeat`, while Enter and Escape stay `.down` only, since a repeat there would commit or
        // cancel several times over.
        .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in act(.up) }
        .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in act(.down) }
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { _ in act(.left) }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { _ in act(.right) }
        // Both delete keys mean the same thing on this path, which has no caret to delete forward
        // from: it is reached only when there is no field editor to own them.
        .onKeyPress(.delete, phases: [.down, .repeat]) { _ in act(.delete) }
        .onKeyPress(.deleteForward, phases: [.down, .repeat]) { _ in act(.delete) }
        .onKeyPress(.return) { act(.enter) }
        .onKeyPress(.escape) { act(.escape) }
        // What is left is typing. What each press MEANS is decided by `pickKeyAction`, which is pure
        // and asserted without a screen; this only translates SwiftUI's vocabulary into that one.
        .onKeyPress(phases: [.down, .repeat]) { press in typed(press) }
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
            // The same tag the popover header wears, in the same place beside the wordmark: two
            // instances of this panel can be on one machine, and answering the one belonging to a
            // build nobody installed is exactly what the claim stand-down exists to prevent
            // (`pickMayBeClaimed`). A person deserves to see which is which before they click.
            if BuildVariant.isDev {
                TallyDevTagView()
            }
            Spacer(minLength: 8)
            // Which of the two this was opened as, said once and quietly: the panel offers both
            // axes, and this is the one the command asked for.
            Text(L(pickPanelKindName(request.kind)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tally, \(pickPanelKindName(request.kind))")
    }

    /// One column: its name, its own field, its rows, and the way out of its axis.
    private func columnView(_ column: PickColumn, listHeight: CGFloat, alone: Bool) -> some View {
        let isFocused = column.kind == focus
        return VStack(alignment: .leading, spacing: 0) {
            Text(L(pickColumnHeadingKey(column.kind)))
                .font(.caption)
                .foregroundStyle(isFocused ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(height: pickColumnHeadingHeight, alignment: .bottom)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TallyMetrics.cardPaddingH)
            searchField(column, isFocused: isFocused)
            ScrollViewReader { proxy in
                ScrollView {
                    // EAGER, and that is a sizing decision rather than a performance one: what the
                    // list is told to be tall is what these rows MEASURE (`heightReporter`), and a
                    // lazy stack only measures the rows it has materialized. The lists here are a
                    // fleet and an effort table, tens of rows at the outside.
                    //
                    // SPACED BY THE RULE RATHER THAN EVENLY (`pickRowGap`), which is why the stack
                    // itself has none: one model and its two depths belong together, and an even 2
                    // points made ten rows read as ten unrelated ones.
                    VStack(spacing: 0) {
                        if column.isEmptyOfMatches {
                            Text(L("No matches"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(height: pickPlainRowHeight, alignment: .center)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, TallyMetrics.cardPaddingH)
                        }
                        ForEach(Array(column.items.enumerated()), id: \.offset) { index, item in
                            separator(item)
                            rowView(column, item, index: index, isFocused: isFocused)
                        }
                    }
                    .padding(.vertical, pickRowsPadding)
                    .background(heightReporter(column.kind))
                }
                // TOLD, NOT ASKED. A ScrollView has no ideal height along its scroll axis, so a
                // panel sized by its content (`PickPanelController` leaves `sizingOptions` the only
                // size authority) used to get nothing back and come up as a message with no rows
                // under it. The height comes from the columns now, measured or computed, and
                // `pickPaletteListHeight` is where both live.
                .frame(height: listHeight)
                .onChange(of: selections[column.kind] ?? 0) { _, now in
                    // Only what scrolls can be scrolled to: the pinned row is not in this region,
                    // and it does not need to be brought into view because it never leaves.
                    guard now < column.items.count else { return }
                    withAnimation(.linear(duration: 0.08)) { proxy.scrollTo(now, anchor: .center) }
                }
                .onAppear { proxy.scrollTo(selections[column.kind] ?? 0, anchor: .center) }
            }
            // PINNED UNDER THE COLUMN, not in it: the row that releases this axis is what a person
            // reaches for when the list is not what they wanted, and a long fleet used to scroll it
            // out of sight. Still the last of `column.rows`, so the arrow keys walk onto it from the
            // last scrolling row and Enter takes it like any other.
            if let sticky = column.sticky {
                separator(sticky)
                rowView(column, sticky, index: column.stickyIndex ?? 0, isFocused: isFocused)
            }
        }
        .frame(width: pickColumnWidth(column.kind, alone: alone), alignment: .leading)
    }

    /// What this column is filtered by. A real field, for the two reasons PickSearchField.swift
    /// gives (an account can be called anything, and a key with no character has to be named);
    /// what stays the panel's is the handful of keys that answer it.
    private func searchField(_ column: PickColumn, isFocused: Bool) -> some View {
        let query = queries[column.kind] ?? ""
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(isFocused ? AnyShapeStyle(TallyColor.ai) : AnyShapeStyle(.tertiary))
            PickSearchField(text: query, placeholder: L("Type to filter"), isFocused: isFocused,
                            command: { apply($0) },
                            onEdit: { edited($0, in: column.kind) },
                            onFocus: { focus = column.kind })
                .frame(height: 18)
            if isFocused, !query.isEmpty {
                // The way back, said where the state it undoes is: Escape clears this column before
                // it closes anything (`pickKeyAction`).
                Text(L("esc to clear"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: pickSearchFieldHeight)
        .padding(.horizontal, TallyMetrics.cardPaddingH)
        .background(
            RoundedRectangle(cornerRadius: TallyMetrics.cardRadius, style: .continuous)
                .fill(.quaternary.opacity(isFocused ? 0.4 : 0.15)))
        // WHICH COLUMN IS LISTENING, said quietly and in one place: the same accent the depth chips
        // wear, as a hairline rather than a fill, so it reads as "here" without becoming the loudest
        // thing on the panel.
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: TallyMetrics.cardRadius, style: .continuous)
                    .stroke(TallyColor.ai.opacity(0.35), lineWidth: 1)
            }
        }
        .padding(.bottom, pickSearchFieldGap)
        .accessibilityLabel("\(L("Filter")) \(L(pickColumnHeadingKey(column.kind)))")
        .accessibilityValue(query)
    }

    /// One row, wherever it is drawn. Shared by the scrolling region and the pinned row so the two
    /// cannot grow different behaviour: the same click, the same hover, the same resting mark.
    private func rowView(_ column: PickColumn, _ item: PickPaletteItem, index: Int,
                         isFocused: Bool) -> some View {
        PickRowView(row: item.row, isSelected: selections[column.kind] == index,
                    isFocusedColumn: isFocused)
            .id(index)
            .contentShape(Rectangle())
            // ONE CLICK, no second confirmation, and it works in either column: the cost of a
            // mis-click is a pin to the wrong account, which the same panel undoes in one more
            // click; the cost of an Accept key is one extra action on every correct pick, for ever.
            .onTapGesture { choose(PickChoice(kind: column.kind, row: item.row)) }
            // The pointer moves the keyboard's column with it, so what Enter would take is always
            // what the pointer is over. UNLESS THE PANEL WAS JUST RAISED UNDER A POINTER THAT NEVER
            // MOVED, which is not somebody choosing anything and used to take the command's own
            // column away before it was ever seen (`pickHoverMovesFocus` carries the capture).
            .onHover { inside in
                guard inside, pickHoverMovesFocus(shownAt: shownAt) else { return }
                focus = column.kind
                selections[column.kind] = index
            }
    }

    /// What goes above a row: the rule that sets a way out apart from the choices, or plain space.
    /// Both are the height the column said they are, which is what keeps the drawing and the
    /// arithmetic the same thing.
    @ViewBuilder private func separator(_ item: PickPaletteItem) -> some View {
        if item.ruled {
            Divider()
                .opacity(0.5)
                .padding(.vertical, pickRowGroupSpacing)
        } else if item.gapAbove > 0 {
            Color.clear.frame(height: item.gapAbove)
        }
    }

    /// One column's own laid-out height, reported upward. Same shape as the surface the panel and
    /// the popover are sized by (`PopoverRootView.sizeReporter`), and for the same reason: a
    /// rendered size is a fact, while a size asked of a scrolling container is a preference it does
    /// not have.
    private func heightReporter(_ kind: PickKind) -> some View {
        GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                listHeights[kind] = height
            }
        }
    }

    /// ONE DECISION FOR EVERY KEY, whichever way it arrived: the field hands up the six it does not
    /// own (PickSearchField), and the modifiers below are the backstop for a panel whose field never
    /// took the responder. Answers whether the panel took the key; false leaves it to the field,
    /// which is how a caret step in a typed query stays a caret step.
    private func apply(_ key: PickKey) -> Bool {
        let palette = self.palette
        guard let column = palette.column(focus) else { return false }
        switch pickKeyAction(key, query: queries[focus] ?? "") {
        case .move(let step):
            // Clamped rather than wrapped: a list that jumps from the last row to the first turns a
            // held arrow key into a lap of the fleet.
            guard !column.rows.isEmpty else { break }
            selections[focus] = min(max((selections[focus] ?? 0) + step, 0), column.rows.count - 1)
        case .moveColumn(let step):
            let landed = pickColumnFocus(palette, from: focus, step: step)
            focus = landed
            if let next = palette.column(landed) {
                selections[landed] = pickColumnSelection(next, remembered: selections[landed])
            }
        case .commit:
            let choices = column.choices
            guard let index = selections[focus], choices.indices.contains(index) else { break }
            choose(choices[index])
        case .cancel:
            choose(nil)
        case .edit(let typed):
            edited(typed, in: focus)
        case .ignore:
            return false
        }
        return true
    }

    /// The query changed, either because it was typed into or because Escape cleared it.
    ///
    /// THE CURSOR FOLLOWS THE TYPING, in the column that was typed into: what was selected is an
    /// index into a list the query has just rewritten, so keeping it would leave the cursor on
    /// whatever happens to sit at that position now.
    ///
    /// THE COLUMN IS BUILT FROM THE VALUE, NOT FROM THE STATE THAT WAS JUST GIVEN IT. Reading
    /// `queries` back here is reading state written a line earlier from a callback, which SwiftUI
    /// does not promise is visible yet, and the panel showed exactly that: clearing a filter left
    /// the cursor on the first row instead of walking back to the row the session is on, because
    /// the column it asked about was still the FILTERED one (live keyboard check, 2026-08-10).
    private func edited(_ typed: String, in kind: PickKind) {
        queries[kind] = typed
        var filters = queries
        filters[kind] = typed
        if let column = pickPalette(request, filters: filters).column(kind) {
            selections[kind] = pickColumnSelection(column)
        }
    }

    /// The named-key path, for the backstop handlers.
    private func act(_ key: PickKey) -> KeyPress.Result { apply(key) ? .handled : .ignored }

    /// Anything the named handlers did not take, which is typing. Reached only when the field never
    /// became first responder; the field's own editor handles this otherwise. A press carrying a
    /// command, control or option is somebody doing something else with the machine, so it is handed
    /// back rather than typed into the filter.
    private func typed(_ press: KeyPress) -> KeyPress.Result {
        guard !press.modifiers.contains(.command), !press.modifiers.contains(.control),
              !press.modifiers.contains(.option) else { return .ignored }
        return act(.text(press.characters))
    }
}

/// One row: what it is, what it costs, and what it is to this session.
struct PickRowView: View {
    let row: PickRow
    let isSelected: Bool
    /// Whether this row's column is the one the keyboard is in. Both columns keep a cursor, so both
    /// draw one; only the focused column's is the one Enter would take, and it is the stronger mark.
    var isFocusedColumn = true

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
                .fill(background))
    }

    /// The resting mark: strong in the column the keyboard is in, quiet in the other one.
    private var background: AnyShapeStyle {
        guard isSelected else { return AnyShapeStyle(Color.clear) }
        return isFocusedColumn ? AnyShapeStyle(.selection.opacity(0.55))
            : AnyShapeStyle(.quaternary.opacity(0.3))
    }
}
