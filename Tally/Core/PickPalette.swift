import CoreGraphics
import Foundation

// WHAT THE PICK PANEL DRAWS: two columns, accounts on the left and models on the right, each one a
// whole picker in its own right (PickSection says why both axes are on one surface at all).
//
// SIDE BY SIDE RATHER THAN STACKED, which is the correction of the first attempt at this. Stacked,
// the two axes ran together: one scrolling region held both lists, one filter narrowed both, and the
// two ways out ("release the model pin" and "release the account pin") were a divider apart with
// nothing but their own wording to tell them apart. Read as columns, they cannot be confused,
// because everything one axis has is inside its own column: its name, its filter, its scrolling
// region, and the row that hands that axis back, pinned at its foot.
//
// THE ORDER IS FIXED and the command does not move it: accounts left, models right, whichever of
// the two was typed. A surface that reshuffles itself by how it was opened has to be re-read every
// time; what the command decides is only which column the keyboard starts in.
//
// SO THE STRUCTURE IS: a palette is columns, a column is rows and the one pinned under them, and the
// filter is a property of the column rather than of the panel. The arithmetic sums exactly these
// (PickPanelMetrics.swift), the view draws exactly these, and both can be asserted without a screen.
//
// CIRCLING, THEN SUBMITTING, which is the correction of the first two-column panel. A click was the
// whole answer there, and that made the one thing the columns were built for impossible: "move me to
// Claude 2 AND run opus" is two decisions, and the surface could only ever carry the first one to be
// clicked. So a click now CIRCLES a row in its column and nothing leaves the panel until Enter or
// Apply, which submits every axis whose circle is not already where it is (`pickSubmission`). Each
// column has exactly one circle and it always has a value: the row the session is on, some other
// row, or nothing at all - and the first and last of those mean the same thing, no change on this
// axis.

/// One row as the panel draws it: the row itself, and the space above it.
struct PickPaletteItem: Equatable, Sendable {
    let row: PickRow
    /// The space above this row, decided once (`pickRowGap`) so the drawing and the sum agree.
    let gapAbove: CGFloat
    /// Whether that space carries a rule: the way out of the column, set apart from its choices.
    let ruled: Bool

    /// How tall this row is drawn, which is what the arithmetic adds up.
    var height: CGFloat { pickRowHeight(row) }
}

/// A row and the column it came from: everything circling it decides.
struct PickChoice: Equatable, Sendable {
    let kind: PickKind
    let row: PickRow

    /// This choice as one axis of an answer. The kind travels with it, because the CLI has two
    /// apply paths and the value alone does not say which one this is (`PickAnswer.kind`).
    var axis: PickAxisAnswer { PickAxisAnswer(value: row.value, effort: row.effort, kind: kind) }

    /// What the app writes when this row is the only thing that changed.
    var answer: PickAnswer { PickAnswer(axes: [axis]) }
}

/// One column: one axis, answered on its own.
struct PickColumn: Equatable, Sendable {
    let kind: PickKind
    /// What scrolls, in draw order, after this column's own filter.
    let items: [PickPaletteItem]
    /// The way out of this axis, pinned under the scrolling region.
    ///
    /// NEVER FILTERED AWAY, and never the other column's: it is how a person hands back the axis
    /// they are looking at, so a query matching nothing still has to leave it reachable, and it
    /// belongs to the column whose rows sit above it rather than to the panel.
    let sticky: PickPaletteItem?
    /// Whether this column's own field has something in it.
    let filtering: Bool

    /// Every row the keyboard walks here, in order: what scrolls, then what is pinned under it.
    var rows: [PickPaletteItem] { items + (sticky.map { [$0] } ?? []) }

    /// The same walk as choices, which is what a selection in this column indexes into.
    var choices: [PickChoice] { rows.map { PickChoice(kind: kind, row: $0.row) } }

    /// Where the pinned row sits in that walk, or nil when there is nothing pinned.
    var stickyIndex: Int? { sticky == nil ? nil : items.count }

    /// What is at that place in the walk, when there is one there. Takes an OPTIONAL index because
    /// every caller has one: a column's circle is "some row or none at all" (`pickColumnSelection`),
    /// and a filter can leave an index pointing past the end of the list it was taken from.
    func choice(at index: Int?) -> PickChoice? {
        guard let index, choices.indices.contains(index) else { return nil }
        return choices[index]
    }

    /// Whether the query emptied this column. A column is never removed for having no hits (the two
    /// columns would then swap places under the pointer), so this is what the panel says instead.
    var isEmptyOfMatches: Bool { items.isEmpty && filtering }
}

/// The whole surface: the columns, left to right.
struct PickPalette: Equatable, Sendable {
    let columns: [PickColumn]

    func column(_ kind: PickKind) -> PickColumn? { columns.first { $0.kind == kind } }

    /// Whether this palette is the single list an older CLI's request draws (`PickRequest.sections`
    /// carries both skews).
    var isSingleColumn: Bool { columns.count < 2 }
}

/// Left to right, and it does not move: the fleet first, because moving a conversation is the
/// heavier of the two decisions and the wider of the two lists.
let pickColumnOrder: [PickKind] = [.account, .model]

/// What a column is called, as the English key its translations are filed under
/// (`Localizable.xcstrings`). A KEY rather than a finished string, because this file is compiled
/// into the assertion suite as well as the app, and the suite has no bundle to resolve against: the
/// panel is where `L(...)` turns it into the language the person set.
///
/// Plural, because it names a run of rows rather than the panel's axis (`pickPanelKindName` names
/// that, once, on the identity line).
func pickColumnHeadingKey(_ kind: PickKind) -> String {
    switch kind {
    case .model: return "Models"
    case .account: return "Accounts"
    }
}

/// Whether a row answers what has been typed.
///
/// MATCHED ON WHAT IS ON SCREEN, and on the raw label besides: a person filtering by "high" is
/// reading the chip beside a name, and one filtering by "opus · high" is reading the pair the way
/// the CLI wrote it. Case-insensitive substring rather than anything cleverer, because the
/// vocabulary is a dozen model names and a handful of account labels.
///
/// A blank query matches everything, whitespace included: a space is a character in "Claude 2", but
/// a query that is ONLY spaces is somebody who has not started typing yet.
func pickRowMatches(_ row: PickRow, query: String) -> Bool {
    guard pickIsFiltering(query) else { return true }
    let needle = query.lowercased()
    // THE TAGS ARE MATCHED TOO, because they are words on the screen: "most headroom" and "this
    // session" are drawn beside the name, and a person typing what they can see and watching that
    // very row disappear is being told the filter is broken (codex review, 2026-08-10).
    let fields = [pickPanelLabel(row), row.label, row.effort, pickPanelDetail(row)] + row.tags
    return fields.compactMap { $0 }.contains { $0.lowercased().contains(needle) }
}

/// Whether a query is one at all. One place, because "is this column filtered" decides three
/// different things: what it lists, where its cursor rests, and what Escape does.
func pickIsFiltering(_ query: String) -> Bool {
    !query.trimmingCharacters(in: .whitespaces).isEmpty
}

/// The palette a request draws, each column narrowed by its own query.
func pickPalette(_ request: PickRequest, filters: [PickKind: String] = [:]) -> PickPalette {
    pickPalette(sections: pickRequestSections(request), filters: filters)
}

/// One list of rows as a column: the single-column shape, which is what a request from before the
/// palette IS and what the height family's fixtures are written in.
func pickColumn(rows: [PickRow], filter: String = "") -> PickColumn {
    pickColumn(PickSection(kind: .model, rows: rows), filter: filter)
}

/// The palette that one column makes.
func pickPalette(rows: [PickRow]) -> PickPalette {
    PickPalette(columns: [pickColumn(rows: rows)])
}

/// The sections a request draws: the ones it carries, or the single section an older CLI's request
/// is.
func pickRequestSections(_ request: PickRequest) -> [PickSection] {
    guard let sections = request.sections, !sections.isEmpty else {
        return [PickSection(kind: request.kind, rows: request.rows)]
    }
    return sections
}

/// Build the columns, in the order they are drawn rather than the order they arrived in: the request
/// is written focus-first for the sake of an older app's `rows` field, and this surface is not.
func pickPalette(sections: [PickSection], filters: [PickKind: String] = [:]) -> PickPalette {
    PickPalette(columns: pickColumnOrder.compactMap { kind in
        sections.first { $0.kind == kind }
            .map { pickColumn($0, filter: filters[kind] ?? "") }
    })
}

/// One column, after its own filter.
func pickColumn(_ section: PickSection, filter: String = "") -> PickColumn {
    // LAST IS THE TEST, because last is what the release row is: every builder appends it after
    // everything else and says so (`pickRowIsRelease`).
    let release = section.rows.indices.last.flatMap {
        pickRowIsRelease(index: $0, of: section.rows) ? $0 : nil
    }
    var items: [PickPaletteItem] = []
    var previous: PickRow?
    for index in section.rows.indices where index != release {
        let row = section.rows[index]
        guard pickRowMatches(row, query: filter) else { continue }
        // Grouped against the row ABOVE IT AS DRAWN, not as listed: a filter that removed the two
        // rows in between must not leave the gap that belonged to them.
        items.append(PickPaletteItem(row: row,
                                     gapAbove: pickRowGap(above: row, after: previous, ruled: false,
                                                          atTop: items.isEmpty),
                                     ruled: false))
        previous = row
    }
    let sticky = release.map { index in
        PickPaletteItem(row: section.rows[index],
                        gapAbove: pickRowGap(above: section.rows[index], after: nil, ruled: true,
                                             atTop: false),
                        ruled: true)
    }
    return PickColumn(kind: section.kind, items: items, sticky: sticky,
                      filtering: pickIsFiltering(filter))
}

// MARK: - What is circled, and what that comes to

/// WHAT A COLUMN HAS CIRCLED, or nil for "leave this axis alone".
///
/// NIL IS A REAL ANSWER AND THE COMMONEST ONE. A person who opened the palette to change the model
/// is not also moving their conversation, so the accounts column has to have a resting state that
/// means NO CHANGE. There are two of them and they are the same thing: circled on the row the
/// session is already on (an account column, where one row says `isCurrent`), and circled on nothing
/// at all (a model column, which frequently has no current row to rest on). Falling back to the
/// first row instead - which is what the cursor did while a click was the whole submit - would
/// arm a change nobody asked for the moment the panel came up.
///
/// WHAT IT WAS LEFT ON, if that row is still there, so stepping across to the other column and back
/// returns to where somebody was. ON THE FIRST HIT while something is typed, because the query IS
/// the aim: typing three letters and pressing Enter is the fast path, and it has to circle what the
/// query narrowed to. A query that hit nothing circles NOTHING rather than the pinned row underneath
/// - that row hands the axis back, and typing a word that matches no account must not arm a release.
func pickColumnSelection(_ column: PickColumn, remembered: Int? = nil) -> Int? {
    if let remembered, column.rows.indices.contains(remembered) { return remembered }
    guard !column.filtering else { return column.items.isEmpty ? nil : 0 }
    return column.choices.firstIndex { $0.row.isCurrent }
}

/// Where a column's circle lands after its own query changed.
///
/// ON THE SAME ROW WHENEVER THE NEW LIST STILL HOLDS IT, which is what keeps a filter from quietly
/// undoing a choice: somebody who clicked "Claude 2" and then typed into the same field to look for
/// something else, and cleared it again, still has Claude 2 circled. Only when the row they circled
/// is gone does the column rest where a fresh one would.
func pickReselected(_ column: PickColumn, keeping circled: PickRow?) -> Int? {
    if let circled, let index = column.choices.firstIndex(where: { $0.row == circled }) {
        return index
    }
    return pickColumnSelection(column)
}

/// Where the circle lands when an arrow key moves it.
///
/// FROM NOTHING IT LANDS ON THE END IT CAME FROM - the first row going down, the last going up -
/// rather than one row in: a column circling nothing has no position to step from, and stepping
/// from an imagined -1 would skip the row the person is aiming at. Clamped rather than wrapped, so
/// a held arrow key comes to rest instead of lapping the fleet.
func pickMovedSelection(from circled: Int?, step: Int, count: Int) -> Int? {
    guard count > 0 else { return nil }
    guard let circled else { return step < 0 ? count - 1 : 0 }
    return min(max(circled + step, 0), count - 1)
}

/// WHAT THIS PANEL WOULD SUBMIT: every column whose circle is on something other than what is
/// already the case, in the order the columns are drawn.
///
/// A ROW THAT SAYS `isCurrent` IS NOT A CHANGE, which is the whole of the test: circling the account
/// the session is already on and circling nothing at all are two ways of saying the same thing, and
/// both have to come out of here empty. The release row is never current, so circling it IS a change
/// (handing that axis back is a thing that happens).
func pickPendingChanges(_ palette: PickPalette, selections: [PickKind: Int]) -> [PickChoice] {
    palette.columns.compactMap { column in
        guard let choice = column.choice(at: selections[column.kind]), !choice.row.isCurrent
        else { return nil }
        return choice
    }
}

/// THE ANSWER A SUBMIT WRITES, or nil when nothing was circled that is not already the case.
///
/// NIL IS A CANCELLATION and that is deliberate rather than a gap: Enter on a panel nobody changed
/// means the person looked and left, and the CLI already has one sentence for that ("nothing was
/// changed"). Inventing a second state for "submitted, but empty" would be a second sentence saying
/// the same thing.
///
/// FOCUS FIRST, because the three fields every reader has can only carry one axis and an older CLI
/// applies exactly them: the axis the person typed the command about is the one that survives the
/// skew (`PickAnswer`).
func pickSubmission(_ palette: PickPalette, selections: [PickKind: Int],
                    focus: PickKind) -> PickAnswer? {
    let changes = pickPendingChanges(palette, selections: selections)
    let ordered = changes.filter { $0.kind == focus } + changes.filter { $0.kind != focus }
    guard !ordered.isEmpty else { return nil }
    return PickAnswer(axes: ordered.map(\.axis))
}

/// HOW ONE PENDING CHANGE READS in the bar under the columns: the name, and the depth when the row
/// carries one. The panel's own reading of the row rather than the wire's, so a model row does not
/// say its depth twice (`pickPanelLabel`).
func pickChangeSummary(_ choice: PickChoice) -> String {
    let label = pickPanelLabel(choice.row)
    return choice.row.effort.map { "\(label) \($0)" } ?? label
}

/// WHAT THE BAR SAYS, or nil when there is nothing to say and it draws nothing.
///
/// One line for what one press will do, in the order the columns stand, because the whole point of
/// putting both axes on one panel is that both can move at once and a person about to press Enter
/// deserves to see both.
func pickPendingSummary(_ changes: [PickChoice]) -> String? {
    guard !changes.isEmpty else { return nil }
    return "→ " + changes.map(pickChangeSummary).joined(separator: pickEffortSeparator)
}

/// WHETHER A HOVER IS A PERSON MOVING THE POINTER, or the panel having been raised underneath one
/// that never moved.
///
/// THE DEFECT THIS EXISTS FOR (seen on the first two-column capture, 2026-08-10): `/tally-model`
/// came up with the ACCOUNTS column lit and listening. The panel is centred on the screen the
/// pointer is on (`centerOnPointerScreen`), so it frequently appears under the pointer, and SwiftUI
/// reports a hover the instant a row lands beneath it. The pointer had not moved and the person had
/// not looked yet, and the command's own choice of column was already gone.
///
/// So a hover inside the window the panel was raised in decides nothing. It is THE SAME WINDOW the
/// dismissal judgement uses and the same reasoning: a panel that has just been raised is not yet
/// being used, and what it reports about itself in that moment describes the raising rather than
/// the person.
func pickHoverMovesFocus(shownAt: Date, now: Date = Date()) -> Bool {
    pickDismissalIsFromPerson(shownAt: shownAt, now: now)
}

/// WHERE THE CARET GOES when a column takes the keyboard back: the end of what is already typed, so
/// coming back to a column adds to the query rather than replacing it.
///
/// UTF-16, BECAUSE THAT IS WHAT AN `NSRange` COUNTS. `String.count` counts what a person calls
/// characters, and the two disagree the moment a query holds an emoji or a composed syllable: an
/// offset measured in graphemes lands short of the end, and the next keystroke is inserted into the
/// middle of the query instead of after it (codex review, 2026-08-10). Nothing about the panel's
/// vocabulary rules those out - an account is called whatever somebody typed into Settings.
func pickCaretEnd(_ text: String) -> Int { text.utf16.count }

/// Which column the focus lands on when it is stepped sideways. Clamped rather than wrapped, like
/// the walk down a column: a held arrow key must come to rest somewhere rather than cycle.
func pickColumnFocus(_ palette: PickPalette, from kind: PickKind, step: Int) -> PickKind {
    guard let index = palette.columns.firstIndex(where: { $0.kind == kind }) else { return kind }
    let landed = min(max(index + step, 0), palette.columns.count - 1)
    return palette.columns[landed].kind
}

// MARK: - The keyboard

/// One keypress, in the vocabulary this surface has. Named here rather than taken from SwiftUI so
/// the rule below can be asserted without a view (the same split the dismissal judgement is under,
/// `pickDismissalIsFromPerson`).
enum PickKey: Equatable, Sendable {
    case up
    case down
    case left
    case right
    case enter
    case escape
    case delete
    case text(String)
}

/// What a keypress does to the panel.
enum PickKeyAction: Equatable, Sendable {
    /// Up or down the column the keyboard is in.
    case move(Int)
    /// Across to the next column.
    case moveColumn(Int)
    /// Submit everything both columns have circled (`pickSubmission`), which is nothing on a panel
    /// where neither circle has moved off what is already the case.
    case commit
    case cancel
    /// The FOCUSED column's query, after this keypress. Covers typing, backspace and the clearing
    /// half of Escape.
    case edit(String)
    case ignore
}

/// THE WHOLE KEYBOARD, as one total function.
///
/// SIDEWAYS IS FREE HERE, which is what pays for the columns: this field has no caret to walk, so
/// left and right can mean the only other thing a two-column surface needs them to mean. The cost is
/// stated rather than discovered: no caret means no editing in the middle of a query, only typing
/// and backspace, which is what a filter of a dozen model names is answered with anyway.
///
/// ENTER IS THE SUBMIT, WHEREVER THE CURSOR IS, because the circles are what it sends and they are
/// on the screen: the row it takes is not "the one under the cursor" any more, it is everything both
/// columns have circled. On a panel where nothing has been circled off the current state it sends
/// nothing, which is a cancellation and says so ("nothing was changed").
///
/// ESCAPE HAS TWO ANSWERS and the order is the point: a filter that is showing three rows out of
/// thirty is a state a person wants OUT of more often than they want the panel gone, and losing the
/// whole panel to a stray Escape means retyping the command. So the first Escape clears what was
/// typed IN THE COLUMN THE KEYBOARD IS IN, and the second one closes.
///
/// A MODIFIER MEANS SOMEBODY IS DOING SOMETHING ELSE (copying, switching windows), so those presses
/// are handed back untouched rather than typed into the filter; the caller decides what carries a
/// modifier, because that is the one part that is SwiftUI's to say.
func pickKeyAction(_ key: PickKey, query: String) -> PickKeyAction {
    switch key {
    case .up: return .move(-1)
    case .down: return .move(1)
    // SIDEWAYS MEANS TWO THINGS, and the query decides which: with something typed there is a
    // caret in the field and left and right walk it, which is what anybody who has just typed
    // expects; with the field empty there is no caret to walk, so they are free to mean the only
    // other thing a two-column surface needs (`.ignore` hands the key back to the field).
    case .left: return query.isEmpty ? .moveColumn(-1) : .ignore
    case .right: return query.isEmpty ? .moveColumn(1) : .ignore
    case .enter: return .commit
    case .escape: return query.isEmpty ? .cancel : .edit("")
    case .delete: return query.isEmpty ? .ignore : .edit(String(query.dropLast()))
    case .text(let characters):
        // Only what a person can see: a control character reaching the query would filter the list
        // down to nothing with no way to tell why.
        guard !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return .ignore }
        return .edit(query + characters)
    }
}
