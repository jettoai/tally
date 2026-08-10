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
    /// WHERE THE KEYBOARD JUST SENT THE CIRCLE, per column, and nothing the pointer does is written
    /// here. It is what tells the column's scrolling region that a circle moved by a key has to be
    /// brought into view while one moved by a click must not be (`pickScrollFollowsKeyboard`, which
    /// carries the defect and why a destination is recorded rather than a flag raised).
    @State private var keyboardLanded: [PickKind: Int] = [:]
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
            // The identity line and the way out (PickPanelHeaderView), which is also where "closed
            // explicitly, never by looking away" is said on screen.
            PickPanelHeaderView(kind: request.kind) { choose(nil) }
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
        // AN ARROW WEARING A MODIFIER IS THE MACHINE'S, not this panel's (`pickPressIsElsewhere`):
        // Control-Left and Control-Right move between desktops, and answering them here meant the
        // panel changed column while the desktop stayed where it was (Albert, 2026-08-10).
        .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in act(press, as: .up) }
        .onKeyPress(.downArrow, phases: [.down, .repeat]) { press in act(press, as: .down) }
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { press in act(press, as: .left) }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { press in act(press, as: .right) }
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
                    // THE LIST FOLLOWS THE KEYBOARD AND NEVER THE POINTER, which is the whole rule
                    // (`pickScrollFollowsKeyboard` carries the defect: a clicked row is already on
                    // screen, so re-centring it slid the column out from under the pointer that had
                    // just landed on it). Consumed here whether or not it fires, so a request the
                    // keyboard left standing cannot outlive one move.
                    let asked = keyboardLanded[column.kind]
                    keyboardLanded[column.kind] = nil
                    guard pickScrollFollowsKeyboard(asked: asked, landedOn: now) else { return }
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

    /// ONE DECISION FOR EVERY KEY, whichever way it arrived: the field hands up the eight it does
    /// not own (PickSearchField), and the handlers above are the backstop for a panel whose field
    /// never took the responder. Answers whether the panel took the key.
    ///
    /// FALSE IS NOT FREE, which the sideways keys are the lesson of (`pickKeyAction` carries what
    /// they cost): the field's path hands a declined key to its editor, but on the BACKSTOP path
    /// there is no editor and SwiftUI simply carries on to the next handler, the last of which is
    /// typing. What still answers false is a backspace with nothing to delete and a press with no
    /// ink in it, neither of which any handler further down would put on screen.
    private func apply(_ key: PickKey) -> Bool {
        let palette = self.palette
        // A FOCUS THAT NAMES NO COLUMN IS STILL A KEYBOARD SOMEWHERE, and it is reachable: the
        // request says where the keyboard starts (`request.kind`) while the sections say which
        // columns exist, and nothing on the wire makes the first one of the second. Refused here,
        // every key on the panel fell into the same hole the sideways keys did, so the state
        // converges on a column that is really drawn instead, and says so.
        guard let column = palette.column(focus) ?? palette.columns.first else { return false }
        let kind = column.kind
        if kind != focus { focus = kind }
        switch pickKeyAction(key, query: queries[kind] ?? "") {
        case .move(let step):
            // Where an arrow key lands, including from a column circling nothing, is the rule this
            // panel is asserted by rather than arithmetic written here (`pickMovedSelection`).
            circleFromKeyboard(pickMovedSelection(from: selections[kind], step: step,
                                                  count: column.rows.count), in: kind)
        case .moveColumn(let step):
            let landed = pickColumnFocus(palette, from: kind, step: step)
            focus = landed
            if let next = palette.column(landed) {
                circleFromKeyboard(pickColumnSelection(next, remembered: selections[landed]),
                                   in: landed)
            }
        case .commit:
            submit()
        case .cancel:
            choose(nil)
        case .edit(let typed):
            edited(typed, in: kind)
        case .ignore:
            return false
        }
        return true
    }

    /// MOVING A CIRCLE FROM THE KEYBOARD, which is the one door every such path uses: the arrows,
    /// the step across to the other column, and the reselection a query forces. What separates it
    /// from a click is the destination it records - that is what the column's scrolling region
    /// follows, and a click deliberately records none (`pickScrollFollowsKeyboard` carries why). One
    /// writer, so a path that moved a circle without telling the list cannot exist by oversight.
    private func circleFromKeyboard(_ index: Int?, in kind: PickKind) {
        keyboardLanded[kind] = index
        selections[kind] = index
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
    ///
    /// TYPING IS THE KEYBOARD, so the circle this leaves is one the list follows: a query narrowing
    /// thirty rows to twenty can push the circled row below the fold, and Enter on a row nobody can
    /// see is the thing worth avoiding here. Nothing is under the pointer being clicked while
    /// somebody types, which is the case the rule was written for (`pickScrollFollowsKeyboard`).
    private func edited(_ typed: String, in kind: PickKind) {
        let circled = palette.column(kind)?.choice(at: selections[kind])?.row
        queries[kind] = typed
        var filters = queries
        filters[kind] = typed
        if let column = pickPalette(request, filters: filters).column(kind) {
            circleFromKeyboard(pickReselected(column, keeping: circled), in: kind)
        }
    }

    /// The named-key path, for the backstop handlers.
    private func act(_ key: PickKey) -> KeyPress.Result { apply(key) ? .handled : .ignored }

    /// THE ONE DOOR EVERY PRESS ON THIS PATH COMES THROUGH: what the key MEANS was decided by the
    /// handler that caught it, and whether this panel may act on it at all is decided here, once.
    ///
    /// A press wearing a modifier belongs to the machine rather than to the panel
    /// (`pickPressIsElsewhere`, which carries the defect): the arrows are spelled the same way
    /// whether somebody means the next column or the next desktop, and only the modifiers tell the
    /// two apart. Asked in one place so the arrows and the typing below cannot come to different
    /// answers about the same press.
    private func act(_ press: KeyPress, as key: PickKey) -> KeyPress.Result {
        guard !pickPressIsElsewhere(command: press.modifiers.contains(.command),
                                    control: press.modifiers.contains(.control),
                                    option: press.modifiers.contains(.option))
        else { return .ignored }
        return act(key)
    }

    /// Anything the named handlers did not take, which is typing. Reached only when the field never
    /// became first responder; the field's own editor handles this otherwise.
    ///
    /// THIS IS THE LAST HANDLER ON THE PANEL, so everything anything above it declined arrives here
    /// wearing whatever character it happens to carry, and an arrow key carries one
    /// (`pickIsTypable`, which is where that press stops). A handler of last resort cannot be
    /// trusted to only see typing just because everything else was named first.
    private func typed(_ press: KeyPress) -> KeyPress.Result {
        act(press, as: .text(press.characters))
    }
}
