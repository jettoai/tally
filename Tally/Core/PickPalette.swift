import CoreGraphics
import Foundation

// WHAT THE PICK PANEL DRAWS, as a list of items rather than as a view. The panel is two sections and
// a filter now (PickSection states why both axes are on one surface), and all three of the things
// that used to be simple stop being simple at once:
//
//   - WHICH ROWS ARE THERE depends on what has been typed, so it cannot be `request.rows`.
//   - WHAT IS PINNED under the list is the FOCUS section's release row, so it cannot be "the last
//     row" either: the other section's release row is one of its own rows, inline, where it means
//     "hand this axis back" rather than "hand back the axis you came here for".
//   - HOW TALL IT IS has to agree with what was drawn to the point, which is the property the
//     height family was rebuilt around after a panel came up as a message with nothing under it
//     (PickPanelMetrics.swift carries that incident).
//
// So the drawing and the arithmetic read ONE structure, built here, in the file both can be
// asserted against without a screen. The view walks `items` and draws them; the arithmetic sums the
// same items; the keyboard walks `choices`. Nothing recomputes any of it a second way.

/// One entry in the drawn list: a section's name, or a row.
struct PickPaletteItem: Equatable, Sendable {
    enum Body: Equatable, Sendable {
        case heading(String)
        case row(PickRow)
    }

    let body: Body
    /// Which section this came from: what choosing it answers with, and which axis a heading names.
    let kind: PickKind
    /// The space above this item, decided once (`pickRowGap`) so the drawing and the sum agree.
    let gapAbove: CGFloat
    /// Whether that space carries a rule: the way out of a section, set apart from its choices.
    let ruled: Bool
    /// Where this row sits in the keyboard's walk, or nil for a heading, which is not a choice.
    let choiceIndex: Int?

    var row: PickRow? {
        if case .row(let row) = body { return row }
        return nil
    }

    var heading: String? {
        if case .heading(let text) = body { return text }
        return nil
    }

    /// How tall this item is drawn, which is what the arithmetic adds up.
    var height: CGFloat { row.map(pickRowHeight) ?? pickSectionHeadingHeight }
}

/// A row and the section it came from: everything choosing it decides.
struct PickChoice: Equatable, Sendable {
    let kind: PickKind
    let row: PickRow

    /// What the app writes when this row is chosen. The kind travels with it, because the CLI has
    /// two apply paths and the value alone does not say which one this is (`PickAnswer.kind`).
    var answer: PickAnswer { PickAnswer(value: row.value, effort: row.effort, kind: kind) }
}

/// The whole surface: what scrolls, what is pinned under it, and what the keyboard walks.
struct PickPalette: Equatable, Sendable {
    /// Everything in the scrolling region, in draw order.
    let items: [PickPaletteItem]
    /// The FOCUS section's release row, pinned below the scrolling region and outside the filter.
    ///
    /// OUTSIDE THE FILTER ON PURPOSE: it is the way out of the question that was asked, so a query
    /// matching nothing must still leave it reachable. A person who typed four letters that hit no
    /// row would otherwise be left with an empty panel and Escape.
    let sticky: PickPaletteItem?
    /// The rows a keyboard walks, in the order it walks them: the scrolling rows, then the pinned
    /// one. One flat array, so the arrow keys need no special case at the boundary.
    let choices: [PickChoice]
}

/// The gap between one section and the next, above its heading. Wider than the gap between two
/// subjects inside a section (`pickRowGroupSpacing`), because it separates two questions rather
/// than two answers to one.
let pickSectionGap: CGFloat = 14

/// How tall a section heading is drawn, its air underneath included. Drawn at exactly this height
/// (`PickPanelView.heading`) rather than measured, so the sum below cannot drift from the layout.
let pickSectionHeadingHeight: CGFloat = 20

/// What the search field says before anything has been typed.
let pickSearchPlaceholder = "Type to filter"

/// How tall that field is drawn, its own padding included.
let pickSearchFieldHeight: CGFloat = 26

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
    guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
    let needle = query.lowercased()
    let fields = [pickPanelLabel(row), row.label, row.effort, pickPanelDetail(row)]
    return fields.compactMap { $0 }.contains { $0.lowercased().contains(needle) }
}

/// The palette a request draws, filtered by what has been typed.
func pickPalette(_ request: PickRequest, filter: String = "") -> PickPalette {
    pickPalette(sections: pickRequestSections(request), focus: request.kind, filter: filter)
}

/// The palette one list of rows draws: the single-section shape, which is what a request from
/// before the palette IS and what the height family's fixtures are written in. The kind it is given
/// decides nothing here, since a lone section is drawn without a heading and answers with whatever
/// the request said it was.
func pickPalette(rows: [PickRow]) -> PickPalette {
    pickPalette(sections: [PickSection(kind: .model, heading: "", rows: rows)], focus: .model,
                filter: "")
}

/// The sections a request draws: the ones it carries, or the single section an older CLI's request
/// is. Focus first either way (`pickSectionsFocusFirst`).
func pickRequestSections(_ request: PickRequest) -> [PickSection] {
    guard let sections = request.sections, !sections.isEmpty else {
        return [PickSection(kind: request.kind, heading: pickSectionHeading(request.kind),
                            rows: request.rows)]
    }
    return pickSectionsFocusFirst(sections, focus: request.kind)
}

/// Build the list, in the order it is drawn.
///
/// A SINGLE SECTION COMES OUT EXACTLY AS IT DID, which is what keeps the older request shape a
/// degradation rather than a difference: no heading is drawn (there is nothing to tell it apart
/// from), the gaps are the ones `pickRowGap` has always given, and the release row is pinned. The
/// pinned measurements the height suite carries (221 and 371 points, read off the window) are the
/// lock on that.
func pickPalette(sections: [PickSection], focus: PickKind, filter: String) -> PickPalette {
    // A heading is what tells two sections apart, so one section has nothing to say with one.
    let headed = sections.count > 1
    var items: [PickPaletteItem] = []
    var choices: [PickChoice] = []
    var stickyRow: (kind: PickKind, row: PickRow)?

    for (position, section) in sections.enumerated() {
        let release = section.rows.indices.last.flatMap {
            pickRowIsRelease(index: $0, of: section.rows) ? $0 : nil
        }
        // The focus section's way out is pinned rather than listed, and the other section's is a
        // row of its own: releasing the axis you did not come here for is a choice among that
        // section's choices, not the standing escape from the one you did.
        let pinned = position == 0 ? release : nil
        if let pinned { stickyRow = (section.kind, section.rows[pinned]) }
        let listed = section.rows.indices.filter { index in
            index != pinned && pickRowMatches(section.rows[index], query: filter)
        }
        // A section nothing matched hides whole, its name with it: a heading over no rows is a
        // promise the list is not keeping.
        guard !listed.isEmpty else { continue }
        if headed {
            items.append(PickPaletteItem(body: .heading(section.heading), kind: section.kind,
                                         gapAbove: items.isEmpty ? 0 : pickSectionGap,
                                         ruled: false, choiceIndex: nil))
        }
        var previous: PickRow?
        for index in listed {
            let row = section.rows[index]
            let ruled = index == release
            items.append(PickPaletteItem(
                body: .row(row), kind: section.kind,
                gapAbove: pickRowGap(above: row, after: previous, ruled: ruled,
                                     atTop: items.isEmpty),
                ruled: ruled, choiceIndex: choices.count))
            choices.append(PickChoice(kind: section.kind, row: row))
            previous = row
        }
    }

    // LAST IN THE WALK, wherever it is drawn: the arrow keys leave the last scrolling row and land
    // on the way out, which is where a list of escapes belongs.
    var sticky: PickPaletteItem?
    if let stickyRow {
        sticky = PickPaletteItem(body: .row(stickyRow.row), kind: stickyRow.kind,
                                 gapAbove: pickRowGap(above: stickyRow.row, after: nil, ruled: true,
                                                      atTop: false),
                                 ruled: true, choiceIndex: choices.count)
        choices.append(PickChoice(kind: stickyRow.kind, row: stickyRow.row))
    }
    return PickPalette(items: items, sticky: sticky, choices: choices)
}

/// Where the cursor rests.
///
/// ON THE ROW THE SESSION IS ALREADY ON while nothing has been typed, which is what makes the
/// keyboard path short for the change people actually make. ON THE FIRST HIT once something has,
/// which is what every filter box does: the query IS the aim, so Enter has to take what the typing
/// pointed at rather than something that scrolled off it.
func pickPaletteSelection(_ palette: PickPalette, filtering: Bool) -> Int {
    guard !filtering else { return 0 }
    return palette.choices.firstIndex { $0.row.isCurrent } ?? 0
}

// MARK: - The keyboard

/// One keypress, in the vocabulary this surface has. Named here rather than taken from SwiftUI so
/// the rule below can be asserted without a view (the same split the dismissal judgement is under,
/// `pickDismissalIsFromPerson`).
enum PickKey: Equatable, Sendable {
    case up
    case down
    case enter
    case escape
    case delete
    case text(String)
}

/// What a keypress does to the panel.
enum PickKeyAction: Equatable, Sendable {
    case move(Int)
    case commit
    case cancel
    /// The query, after this keypress. Covers typing, backspace and the clearing half of Escape.
    case edit(String)
    case ignore
}

/// THE WHOLE KEYBOARD, as one total function.
///
/// ESCAPE HAS TWO ANSWERS and the order is the point: a filter that is showing three rows out of
/// thirty is a state a person wants OUT of more often than they want the panel gone, and losing the
/// whole panel to a stray Escape means retyping the command. So the first Escape clears what was
/// typed and the second one closes, which is the same escalation a search field has anywhere else.
///
/// A MODIFIER MEANS SOMEBODY IS DOING SOMETHING ELSE (copying, switching windows), so those presses
/// are handed back untouched rather than typed into the filter; the caller decides what carries a
/// modifier, because that is the one part that is SwiftUI's to say.
func pickKeyAction(_ key: PickKey, query: String) -> PickKeyAction {
    switch key {
    case .up: return .move(-1)
    case .down: return .move(1)
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
