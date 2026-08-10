import SwiftUI

// The palette itself. A click CIRCLES a row in its column, Enter or Apply submits every axis whose
// circle has moved off what is already the case (PickPalette.swift owns that grammar and says why a
// click stopped being the whole submit: two columns exist so both axes can move at once, and a
// surface that answers on the first click can only ever carry the first of the two).
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
// THE RESTING CIRCLE IS WHERE THE SESSION ALREADY IS (`PickRow.isCurrent`), not the top of a column.
// That is what makes the keyboard path short for the change people actually make: one arrow from
// "the model I am on at the depth I am on" is the same model one level deeper. A column with no
// current row to rest on circles NOTHING, which is the same statement: no change on that axis.

struct PickPanelView: View {
    let request: PickRequest
    /// What the panel answers with, nil being a cancellation. One closure for both, because the
    /// panel above treats them as one event: something happened and the panel is done. The answer
    /// can name BOTH axes, since the two are applied by different paths at the far end
    /// (`pickSubmission`).
    let choose: (PickAnswer?) -> Void

    /// Which column the keyboard is in. The command decides where it starts; the arrow keys, a
    /// hover and a click on a field all move it.
    @State private var focus: PickKind
    /// What has been typed, per column. Each column filters only itself, which is the whole reason
    /// there are two fields rather than one.
    @State private var queries: [PickKind: String] = [:]
    /// WHAT EACH COLUMN HAS CIRCLED, which is what a submit sends. An index into that column's own
    /// walk, or absent for "leave this axis alone" (`pickColumnSelection` says why absent is a real
    /// answer rather than a gap to be filled with row zero).
    @State private var selections: [PickKind: Int] = [:]
    /// What the pointer is over, per column, so a row can say it is clickable without that being
    /// mistaken for the circle. Only the drawing reads it: hovering changes nothing that gets sent.
    @State private var hovered: [PickKind: Int] = [:]
    @FocusState private var focused: Bool
    /// What each column's rows actually laid out at, or zero before the first pass. Read through
    /// `pickPaletteListHeight`, which is where "zero is not a measurement" is decided.
    @State private var listHeights: [PickKind: CGFloat] = [:]
    /// When this panel went up, which is what separates a person moving the pointer onto a row from
    /// the panel having been raised underneath one (`pickHoverMovesFocus`).
    @State private var shownAt = Date()

    init(request: PickRequest, choose: @escaping (PickAnswer?) -> Void) {
        self.request = request
        self.choose = choose
        _focus = State(initialValue: request.kind)
        // A column with nothing to circle contributes no entry at all, which is how "no change on
        // this axis" is spelled here: an absent key rather than an index standing in for one.
        _selections = State(initialValue: Dictionary(
            uniqueKeysWithValues: pickPalette(request).columns.compactMap { column in
                pickColumnSelection(column).map { (column.kind, $0) }
            }))
    }

    private var palette: PickPalette { pickPalette(request, filters: queries) }

    var body: some View {
        let palette = self.palette
        let listHeight = pickPanelListHeight(request, filters: queries, measured: listHeights)
        let pending = pickPendingChanges(palette, selections: selections)
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
            // WHAT ONE PRESS WOULD DO, said before it is pressed. Its space is kept whether or not
            // it has anything in it (`pickApplyBarHeight`): a panel that grew when a row was circled
            // would move every row under the pointer that just circled it.
            PickApplyBar(changes: pending) { submit() }
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
        // Tab is the panel's on this path too, for the reason it is the field's: left to AppKit it
        // walks the key-view loop, and a responder moved behind the panel's back is the disagreement
        // this whole family of defects comes out of. Shift is what tells the two directions apart,
        // since both arrive as the same key.
        .onKeyPress(.tab, phases: [.down, .repeat]) { press in
            act(press.modifiers.contains(.shift) ? .backtab : .tab)
        }
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

    /// One column: its field (which is also where its name is), its rows, and the way out of its
    /// axis.
    ///
    /// THE NAME MOVED INTO THE FIELD, which is what took a line off the top of every column: a
    /// heading sitting one line above its own search box read as a label FOR the box rather than as
    /// the name of the column, and the two were close enough to be one object anyway (Albert, on the
    /// first capture of this panel). As a scope prefix inside the box there is no ambiguity left:
    /// what is typed there narrows the thing the prefix names.
    private func columnView(_ column: PickColumn, listHeight: CGFloat, alone: Bool) -> some View {
        let isFocused = column.kind == focus
        return VStack(alignment: .leading, spacing: 0) {
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
                            // Said in the middle of the space the column keeps, because it keeps it:
                            // the rows are hidden by the query rather than gone, and the panel does
                            // not resize while somebody is typing into it (`pickPanelListHeight`).
                            Text(L("No matches"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity,
                                       minHeight: max(0, listHeight - pickRowsPadding * 2),
                                       alignment: .center)
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

    /// What this column is filtered by, and what it is called. A real field, for the two reasons
    /// PickSearchField.swift gives (an account can be called anything, and a key with no character
    /// has to be named); what stays the panel's is the handful of keys that answer it.
    ///
    /// THE NAME IS A SCOPE PREFIX INSIDE THE BOX, in place of the magnifying glass rather than
    /// beside it: the glass says "you can type here", which is what the placeholder already says in
    /// words, while the name says WHAT typing here narrows - and that was the thing the panel had
    /// spent a whole line on. Drawn as a sibling of the field rather than inset into the
    /// `NSTextField` itself, deliberately: a prefix drawn inside the text view's own area has to
    /// move with the caret and the marked text an input method is composing, and this panel exists
    /// partly because an account can be called anything in any script (`PickSearchField`).
    ///
    /// AND IT CARRIES THE FOCUS, so the box no longer needs a ring around it: the prefix is accented
    /// in the column the keyboard is in and quiet in the other, which is one signal in one place
    /// rather than a name, a fill and an outline all saying "here". The loudest accent on this panel
    /// belongs to the circles, which are what a press will act on.
    private func searchField(_ column: PickColumn, isFocused: Bool) -> some View {
        let query = queries[column.kind] ?? ""
        return HStack(spacing: 8) {
            Text(L(pickColumnHeadingKey(column.kind)))
                .font(.caption)
                .foregroundStyle(isFocused ? AnyShapeStyle(TallyColor.ai) : AnyShapeStyle(.secondary))
                .fixedSize()
            // The hairline that keeps a name from reading as the first word of the query.
            Rectangle()
                .fill(.quaternary)
                .frame(width: TallyMetrics.hairline, height: 12)
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
        // WHICH COLUMN IS LISTENING, in two quiet registers rather than three: this fill, and the
        // accent on the name at its head. The outline that used to be here as well went with the
        // heading line - a box that is named, filled and ringed is three ways of saying one thing,
        // and it was competing with the circles, which are the marks a press acts on.
        .background(
            RoundedRectangle(cornerRadius: TallyMetrics.cardRadius, style: .continuous)
                .fill(.quaternary.opacity(isFocused ? 0.4 : 0.15)))
        .padding(.bottom, pickSearchFieldGap)
        .accessibilityLabel("\(L("Filter")) \(L(pickColumnHeadingKey(column.kind)))")
        .accessibilityValue(query)
    }

    /// One row, wherever it is drawn. Shared by the scrolling region and the pinned row so the two
    /// cannot grow different behaviour: the same click, the same hover, the same circle.
    private func rowView(_ column: PickColumn, _ item: PickPaletteItem, index: Int,
                         isFocused: Bool) -> some View {
        PickRowView(row: item.row, isCircled: selections[column.kind] == index,
                    isHovered: hovered[column.kind] == index, isFocusedColumn: isFocused,
                    // The line the column decided this row gets, drawn from the same item the
                    // arithmetic measured, so what is on screen and what was summed are one answer
                    // (`PickPaletteItem.note`).
                    note: item.note)
            .id(index)
            .contentShape(Rectangle())
            // A CLICK CIRCLES, IT DOES NOT SUBMIT. The panel exists to carry both axes at once, and
            // a click that answered could only ever carry the first of them; what it costs is one
            // press at the end, which is also the press that makes a mis-click harmless.
            // Clicking the circled row again leaves it circled: this column always has an answer,
            // and "no change" is said by the row the session is on, not by an empty column.
            .onTapGesture { selections[column.kind] = index }
            // The pointer moves the keyboard's column with it, so typing goes where the person is
            // looking. UNLESS THE PANEL WAS JUST RAISED UNDER A POINTER THAT NEVER MOVED, which is
            // not somebody choosing anything and used to take the command's own column away before
            // it was ever seen (`pickHoverMovesFocus` carries the capture).
            .onHover { inside in
                guard pickHoverMovesFocus(shownAt: shownAt) else { return }
                guard inside else {
                    // Only if it is still ours: the pointer enters the next row before it leaves
                    // this one, so an unconditional clear would put out the light it just lit.
                    if hovered[column.kind] == index { hovered[column.kind] = nil }
                    return
                }
                focus = column.kind
                hovered[column.kind] = index
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
                // A MEASUREMENT ONLY COUNTS WHILE THE COLUMN IS SHOWING EVERYTHING. A filtered stack
                // measures the rows that survived the query, and believing it would resize the panel
                // on every keystroke - which is the defect `pickPanelListHeight` is the other half
                // of. The last full measurement stands until the query is cleared.
                guard !pickIsFiltering(queries[kind] ?? "") else { return }
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
            // Where an arrow key lands, including from a column circling nothing, is the rule this
            // panel is asserted by rather than arithmetic written here (`pickMovedSelection`).
            selections[focus] = pickMovedSelection(from: selections[focus], step: step,
                                                   count: column.rows.count)
        case .moveColumn(let step):
            let landed = pickColumnFocus(palette, from: focus, step: step)
            focus = landed
            if let next = palette.column(landed) {
                selections[landed] = pickColumnSelection(next, remembered: selections[landed])
            }
        case .commit:
            submit()
        case .cancel:
            choose(nil)
        case .edit(let typed):
            edited(typed, in: focus)
        case .ignore:
            return false
        }
        return true
    }

    /// EVERYTHING THE PANEL ANSWERS WITH goes through here: both circles, the COMMAND'S axis first,
    /// and nil when neither has moved off what is already the case (`pickSubmission`, which is where
    /// "Enter on an unchanged panel is a cancellation" is decided and asserted).
    ///
    /// `request.kind` RATHER THAN `focus`, which is what this used to pass and is a bug an older CLI
    /// reads as a dropped change: the focused column moves on its own (a hover, an arrow key, a
    /// Tab), while which command raised this panel does not. `pickSubmission` carries the trace.
    private func submit() {
        choose(pickSubmission(palette, selections: selections, command: request.kind))
    }

    /// The query changed, either because it was typed into or because Escape cleared it.
    ///
    /// THE CIRCLE FOLLOWS THE TYPING, in the column that was typed into, unless the row it is on
    /// survived the new query: an index into a list the query has rewritten would otherwise point at
    /// whatever now sits in that position, while a circle that IS still on screen is a choice
    /// somebody made and clearing a filter must not undo it (`pickReselected`).
    ///
    /// THE COLUMN IS BUILT FROM THE VALUE, NOT FROM THE STATE THAT WAS JUST GIVEN IT. Reading
    /// `queries` back here is reading state written a line earlier from a callback, which SwiftUI
    /// does not promise is visible yet, and the panel showed exactly that: clearing a filter left
    /// the cursor on the first row instead of walking back to the row the session is on, because
    /// the column it asked about was still the FILTERED one (live keyboard check, 2026-08-10).
    private func edited(_ typed: String, in kind: PickKind) {
        let circled = palette.column(kind)?.choice(at: selections[kind])?.row
        queries[kind] = typed
        var filters = queries
        filters[kind] = typed
        if let column = pickPalette(request, filters: filters).column(kind) {
            selections[kind] = pickReselected(column, keeping: circled)
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
