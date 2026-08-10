import Foundation

// THE PANEL DRAWS WHAT THE RULES SAY IT DRAWS, and every word on it is translated. Split from
// pickpalettechecks.swift the way pickheightchecks.swift was split from pickerchecks.swift, and for
// the same reason: this is one decision of its own, with its own two incidents behind it.
//
// WHY ANY OF IT IS LOCKED BY SOURCE. The layout needs a screen, and a pure rule nobody calls is the
// defect this feature has been bitten by twice: the first two-column panel came up with the wrong
// column listening, and the first filter field dropped backspace in silence. Neither is reachable
// from an assertion suite, so what CAN be asserted is that the view is wired to the rules that were.
//
// The honest limit, recorded rather than glossed: a source scan proves the call is written, not that
// AppKit delivers the event. That last step is a person pressing the key (the live keyboard run,
// 2026-08-10).
func runPickSurfaceChecks() {
    // MARK: - 37g. The panel draws what this file says it draws

    // The layout itself needs a screen, so the wiring is carried by the source: the same lock the
    // height suite uses, for the same reason (a pure rule nobody calls is the defect this feature
    // has been bitten by before).
    let view = (try? String(contentsOfFile: "Tally/Views/PickPanelView.swift", encoding: .utf8)) ?? ""
    check("the panel view is readable from this suite", !view.isEmpty)
    check("the columns are drawn side by side, in the order the palette put them",
          view.contains("HStack(alignment: .top, spacing: pickColumnGap)")
              && view.contains("ForEach(palette.columns, id: \\.kind)"))
    check("…each at its own width, and the panel at the sum of them",
          view.contains("pickColumnWidth(column.kind, alone: alone)")
              && view.contains(".frame(width: pickPanelWidth(palette))"))
    check("each column lists its own rows and pins its own way out",
          view.contains("ForEach(Array(column.items.enumerated())")
              && view.contains("if let sticky = column.sticky"))
    check("…both scrolling at the height the rule above decides, filter or no filter",
          view.contains("pickPanelListHeight(request, filters: queries, measured: listHeights)")
              && view.contains(".frame(height: listHeight)") && !view.contains(".frame(maxHeight:"))
    check("…measured off an EAGER stack, which is the only kind that measures whole",
          view.contains("VStack(spacing: 0)") && !view.contains("LazyVStack"))
    check("each column is typed into on its own",
          view.contains("queries[column.kind]") && view.contains("filters: queries"))
    check("…and the column being typed into says so",
          view.contains("isFocused ? AnyShapeStyle(TallyColor.ai)")
              && view.contains("stroke(TallyColor.ai.opacity(0.35)"))
    // The other half of the frozen height: a filtered stack measures only what survived the query,
    // so believing it would resize the panel from underneath.
    check("…and a measurement taken while a column is filtered is not believed",
          view.contains(#"guard !pickIsFiltering(queries[kind] ?? "") else { return }"#))
    // A DETAIL LINE THAT WRAPS IS A ROW THE ARITHMETIC CANNOT SEE, so the row refuses to wrap: a
    // real fleet at 100% across three windows plus a tag did exactly that on the first live run.
    check("a row's second line is held to one line, which is what the height family assumes",
          view.contains(".lineLimit(1)"))
    check("a column its filter emptied says that rather than showing a gap",
          view.contains("column.isEmptyOfMatches") && view.contains(#"L("No matches")"#))
    check("every keypress is decided by the rule this file asserts",
          view.contains("pickKeyAction(key, query: queries[focus] ?? \"\")")
              && view.contains("pickColumnFocus(palette, from: focus, step: step)"))
    check("the pointer moves the keyboard's column with it, once the panel is really up",
          view.contains("focus = column.kind")
              && view.contains("guard inside, pickHoverMovesFocus(shownAt: shownAt)"))
    check("a chosen row carries the column it came from",
          view.contains("choose(PickChoice(kind: column.kind, row: item.row))"))
    // THE DEV TAG, which is why it is on this panel at all: two instances of it can be on one
    // machine, and a build nobody installed must be tellable from the installed one BEFORE a click
    // moves somebody's conversation. Reused from the popover's header rather than drawn again.
    check("a dev build says so on this panel, in the popover's own badge",
          view.contains("if BuildVariant.isDev") && view.contains("TallyDevTagView()"))
    let popover = (try? String(contentsOfFile: "Tally/Views/PopoverHeaderView.swift",
                               encoding: .utf8)) ?? ""
    check("…which is the one the popover wears, rather than a second capsule",
          popover.contains("TallyDevTagView()")
              && !popover.contains(#"Text(verbatim: "DEV")"#))
    let brand = (try? String(contentsOfFile: "Tally/Views/ProviderIconShape.swift",
                             encoding: .utf8)) ?? ""
    check("…and it is one style in one place",
          brand.contains("struct TallyDevTagView"))
    // MARK: - 37g2. The field is a real one, and the words on it are translated

    // WHY THIS IS LOCKED BY SHAPE: an account nickname is whatever somebody typed into Settings, so
    // a fleet can hold names in scripts that have to be COMPOSED, and raw keypresses cannot compose
    // anything. Only a real field has marked text, a caret, paste and a backspace that works, and
    // the last of those is the defect that started this (`PickSearchField`).
    check("each column's filter is a real text field",
          view.contains("PickSearchField(text: query"))
    let field = (try? String(contentsOfFile: "Tally/Views/PickSearchField.swift",
                             encoding: .utf8)) ?? ""
    check("…wrapping AppKit's own, which is what makes an input method work at all",
          field.contains("NSViewRepresentable") && field.contains("NSTextField"))
    for selector in ["moveUp", "moveDown", "moveLeft", "moveRight", "insertNewline",
                     "cancelOperation"] {
        check("…handing the panel the keys it answers with: \(selector)",
              field.contains("#selector(NSResponder.\(selector)(_:))"))
    }
    // AND NOTHING ELSE, which is the half that fixes backspace: every editing key reaches the field
    // editor untouched, so deleting, composing and pasting are AppKit's rather than ours.
    check("…and taking none of the editing ones, backspace first among them",
          !field.contains("deleteBackward") && !field.contains("deleteForward")
              && field.contains("default: return false"))
    // THE STATE IT WAS JUST GIVEN IS NOT READ BACK: a query written from a callback is not promised
    // to be visible on the next line, and the panel showed it (clearing a filter left the cursor on
    // the first row rather than walking back to the session's own).
    check("the cursor is placed against the column the edit makes, not the one state still holds",
          view.contains("var filters = queries") && view.contains("filters[kind] = typed"))
    check("the caret is placed in the units an NSRange counts, not in what a person calls one",
          field.contains("pickCaretEnd(field.stringValue)")
              && !field.contains("stringValue.count"))
    check("a click in the other column's field moves the panel's focus with it",
          field.contains("controlTextDidBeginEditing") && view.contains("onFocus: { focus ="))

    // EVERY WORD THIS SURFACE ADDED IS IN THE CATALOGUE, in all four translations: the app ships
    // five languages, and a string that reaches a person in English on a Japanese machine is a
    // missing translation nobody notices until they see it.
    let catalogue = (try? Data(contentsOf: URL(fileURLWithPath:
        "Tally/Resources/Localizable.xcstrings")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    let strings = catalogue?["strings"] as? [String: Any] ?? [:]
    check("the string catalogue is readable from this suite", !strings.isEmpty)
    for word in ["Accounts", "Models", "Type to filter", "esc to clear", "No matches", "Filter",
                 "Account", "Model"] {
        let entry = strings[word] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any] ?? [:]
        check("\(word) is translated into every language Tally ships",
              AppLocaleSupported.allSatisfy { localizations[$0] != nil })
    }
    check("…and the panel asks for them through the app's own language rather than the main bundle",
          view.contains("L(pickColumnHeadingKey(column.kind))")
              && view.contains(#"L("Type to filter")"#)
              && view.contains("L(pickPanelKindName(request.kind))"))
    check("the column names the panel draws are the keys the catalogue is written in",
          pickColumnHeadingKey(.account) == "Accounts" && pickColumnHeadingKey(.model) == "Models")

    // …and the answer written from a choice names the column, which is the field the CLI routes on.
    // Pure, so it is asserted rather than read.
    check("the answer a choice becomes names its own section",
          PickChoice(kind: .account, row: PickRow(value: "claude:.claude2", label: "Claude 2"))
              .answer == PickAnswer(value: "claude:.claude2", effort: nil, kind: .account))
    let controller = (try? String(contentsOfFile: "Tally/MenuBar/PickPanelController.swift",
                                  encoding: .utf8)) ?? ""
    check("…and the panel writes exactly that answer",
          controller.contains("finish(with: choice?.answer ?? .cancelled)"))
    check("a request with rows in any section is drawn rather than refused",
          controller.contains("!request.everyRow.isEmpty"))
    check("the dev preview shows the whole palette, which is what a person actually sees",
          controller.contains("sections: [accounts, models]")
              && controller.contains("sections: [models, accounts]"))
}
