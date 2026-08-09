import CoreGraphics
import Foundation

// ONE PALETTE FOR BOTH COMMANDS: `/tally-model` and `/tally-account` raise the same panel, the axis
// that was asked for on top, and what has been typed narrows both (PickPalette.swift builds it,
// PickSection says why it is one surface).
//
// Every check here is about a property that can go wrong SILENTLY, which is what decides what is
// asserted and what is left to the eye:
//
//   - the request has to carry both shapes at once, because the app that reads it is whatever is
//     installed: a new CLI's request reaching an older Tally, and an older CLI's request reaching
//     this one, are both live skews (`PickRequest.sections`).
//   - an answer has to say WHICH section it came from, because the same click can move a
//     conversation or change what answers it, and the value alone does not say which.
//   - the filter has to be able to empty a section without emptying the way out of the panel.
//   - the arithmetic has to sum exactly what was drawn, which is the defect the height family was
//     rebuilt around (pickheightchecks carries that incident).
func runPickPaletteChecks() {
    /// The offer a bare command builds, without answering it.
    func offer(_ tool: PromptHookTool, world: MCPPickerWorld = pickWorld()) -> MCPPickOffer? {
        var captured: MCPPickOffer?
        let input = MCPHookInput(arguments: ["command_args": "", "cwd": "/tmp/work"])
        let ask: MCPAsk = { offer in
            captured = offer
            return .declined
        }
        switch tool {
        case .pickModel: _ = mcpPickModel(input: input, world: world, ask: ask)
        case .pickAccount: _ = mcpPickAccount(input: input, world: world, ask: ask)
        }
        return captured
    }

    // MARK: - 37a. Both axes, on one panel, in the order the command asked for

    let fromModel = offer(.pickModel)
    let fromAccount = offer(.pickAccount)
    check("a bare /tally-model offers the accounts too",
          fromModel?.sections.map(\.kind) == [.model, .account])
    check("…and a bare /tally-account offers the models, the other way up",
          fromAccount?.sections.map(\.kind) == [.account, .model])
    check("the section that leads is the one the command is about",
          fromModel?.sections.first?.kind == fromModel?.kind
              && fromAccount?.sections.first?.kind == fromAccount?.kind)
    // THE FIELD AN OLDER APP READS is the focus section, byte for byte the list it always drew.
    check("the request's own rows are the focus section's, which is all an older app can see",
          fromModel?.rows == fromModel?.sections.first?.rows
              && fromAccount?.rows == fromAccount?.sections.first?.rows)
    check("…and they really are that command's own rows, not the other section's",
          fromModel?.rows.contains { $0.value == mcpModelAutoValue } == true
              && fromAccount?.rows.contains { $0.value == switchAutoRequest } == true)
    check("each section is named for a person to read",
          fromModel?.sections.map(\.heading) == ["Models", "Accounts"])
    // A MACHINE WITH NOTHING ON THE OTHER AXIS DRAWS NO SECTION FOR IT. `mcpAccountPickRows` would
    // hand back a lone release row, and a heading over "release the account pin" alone is noise on
    // a panel somebody opened to change a model.
    var alone = pickWorld()
    alone.fleetRows = { _ in ([], nil, "no snapshot") }
    check("a machine with no fleet to offer draws one section, not an empty second one",
          offer(.pickModel, world: alone)?.sections.map(\.kind) == [.model])
    // …and the empty-fleet reading is the same answer as the unreadable one.
    var signedOut = pickWorld()
    signedOut.fleetRows = { _ in ([], [], nil) }
    check("…as does one whose ranking offers nothing",
          offer(.pickModel, world: signedOut)?.sections.map(\.kind) == [.model])

    // MARK: - 37b. Which section was answered, and what happens when nobody says

    let models = PickSection(kind: .model, heading: "Models",
                             rows: [PickRow(value: "opus", effort: "high", label: "opus · high"),
                                    PickRow(value: mcpModelAutoValue, label: "auto")])
    let accounts = PickSection(kind: .account, heading: "Accounts",
                               rows: [PickRow(value: "claude:.claude2", label: "Claude 2"),
                                      PickRow(value: switchAutoRequest, label: pickAutoLabel)])
    let palette = MCPPickOffer(kind: .model, message: "", sections: [models, accounts], schema: [:])
    check("a row answered from the other section comes back under that section's field",
          palette.content(for: PickAnswer(value: "claude:.claude2", kind: .account))
              == [mcpAccountField: "claude:.claude2"])
    check("…and one from the focus section under its own, both axes carried",
          palette.content(for: PickAnswer(value: "opus", effort: "high", kind: .model))
              == [mcpModelField: "opus", mcpEffortField: "high"])
    // AN ANSWER THAT NAMES NO KIND IS FROM AN APP THAT DREW ONE SECTION, so it means the section it
    // could see. Reading it any other way would silently repoint the picks of every Tally that
    // predates the palette.
    check("an answer from before the palette is read as the section that app drew",
          palette.content(for: PickAnswer(value: "opus")) == [mcpModelField: "opus"])
    // THE STRANGER'S ANSWER, which is the case the whole claim-and-seal family exists for: a value
    // naming no row we offered is not a pick, and a kind that disagrees with where the value lives
    // is not one either.
    check("a value nobody was offered is not a pick",
          palette.content(for: PickAnswer(value: "claude:.claude9", kind: .account)).isEmpty)
    check("…nor is one whose section says it came from somewhere it is not",
          palette.content(for: PickAnswer(value: "opus", kind: .account)).isEmpty)
    check("…nor an answer naming a section this offer never drew",
          MCPPickOffer(kind: .model, message: "", sections: [models], schema: [:])
              .content(for: PickAnswer(value: "claude:.claude2", kind: .account)).isEmpty)
    check("a cancellation still carries nothing at all",
          palette.content(for: .cancelled).isEmpty)

    // END TO END: a person who typed /tally-model, saw the fleet under the models and clicked an
    // account. The model command has to MOVE THE CONVERSATION, which is the whole point of putting
    // both axes on one panel.
    var moved: [SwitchIntent] = []
    var pinned: [ModelIntent] = []
    let crossed = PickChannelDouble()
    crossed.answers = [PickAnswer(value: "claude:.claude2", kind: .account)]
    let acrossSections = runPick(crossed.channel, tool: .pickModel,
                                 world: pickWorld(applied: { moved.append($0) },
                                                  model: { pinned.append($0) }))
    check("an account row picked from the model palette moves the conversation",
          moved == [.pinAccount("claude:.claude2")] && pinned.isEmpty)
    check("…and the answer says so rather than reporting that nothing was chosen",
          acrossSections.decision.contains("queued the move"))
    check("the published request carries both sections and the focus rows beside them",
          crossed.published.first?.sections?.map(\.kind) == [.model, .account]
              && crossed.published.first?.rows == crossed.published.first?.sections?.first?.rows)
    // …and the ordinary direction still works, with the kind the panel now writes.
    var samePinned: [ModelIntent] = []
    let within = PickChannelDouble()
    within.answers = [PickAnswer(value: "opus", effort: "xhigh", kind: .model)]
    _ = runPick(within.channel, tool: .pickModel, world: pickWorld(model: { samePinned.append($0) }))
    check("a model row still pins the pair it carried",
          samePinned == [.pin(model: "opus", effort: "xhigh")])
    // The other command, the other way across: /tally-account answered with a model row.
    var crossPinned: [ModelIntent] = []
    let other = PickChannelDouble()
    other.answers = [PickAnswer(value: "sonnet", effort: "high", kind: .model)]
    _ = runPick(other.channel, tool: .pickAccount,
                world: pickWorld(model: { crossPinned.append($0) }))
    check("a model row picked from the account palette pins the pair",
          crossPinned == [.pin(model: "sonnet", effort: "high")])

    // MARK: - 37c. What an app that never heard of sections reads, and what this one reads back

    /// The request as a build from before the palette decodes it: the four fields it knows about,
    /// and nothing else. A DIFFERENT TYPE ON PURPOSE - decoding the new one would prove nothing,
    /// because the new one is the thing that changed.
    struct LegacyPickRequest: Decodable, Equatable {
        let id: String
        let kind: PickKind
        let message: String
        let rows: [PickRow]
    }
    let onTheWire = PickRequest(id: "abc", kind: .model, message: "what runs this",
                                rows: models.rows, sections: [models, accounts])
    let encoded = encodePick(onTheWire)
    let legacy = decodePick(LegacyPickRequest.self, from: encoded)
    check("an older app decodes the request it always could",
          legacy == LegacyPickRequest(id: "abc", kind: .model, message: "what runs this",
                                      rows: models.rows))
    check("…and what it draws is the focus section, not a mixture",
          legacy?.rows == models.rows)
    // The other skew: a session still running the CLI it launched with writes no sections at all.
    let older = #"{"id":"abc","kind":"model","message":"m","rows":"#
        + #"[{"value":"opus","label":"opus","tags":[],"isCurrent":false},"#
        + #"{"value":"auto","label":"auto","tags":[],"isCurrent":true}]}"#
    let read = decodePick(PickRequest.self, from: Data(older.utf8))
    check("a request from before the palette is still readable, and says it has no sections",
          read?.sections == nil && read?.rows.count == 2)
    let single = read.map { pickPalette($0) }
    check("…and draws as one section: no heading, and the way out pinned exactly as before",
          single?.items.allSatisfy { $0.heading == nil } == true
              && single?.items.count == 1 && single?.sticky?.row?.value == "auto")
    check("…with the cursor still resting where the session already is",
          single.map { pickPaletteSelection($0, filtering: false) } == 1)

    // MARK: - 37d. The filter

    let both = pickPalette(PickRequest(id: "p", kind: .model, message: "m", rows: models.rows,
                                       sections: [models, accounts]))
    check("both sections are drawn, each under its own name",
          both.items.compactMap(\.heading) == ["Models", "Accounts"])
    check("…the focus section's way out is pinned, and the other section's is one of its rows",
          both.sticky?.row?.value == mcpModelAutoValue
              && both.items.last?.row?.value == switchAutoRequest)
    check("…and the pinned row is last in the keyboard's walk, wherever it is drawn",
          both.choices.last?.row.value == mcpModelAutoValue
              && both.choices.count == both.items.compactMap(\.row).count + 1)
    // THE ORDER IS PUT RIGHT AT THE DRAWING END TOO, not merely trusted: a request whose sections
    // arrived the other way round would otherwise pin the wrong section's way out under the list,
    // and the pinned row is the one a person reaches for when the list is not what they wanted.
    let backwards = pickPalette(PickRequest(id: "p", kind: .model, message: "m", rows: models.rows,
                                            sections: [accounts, models]))
    check("a request whose sections arrived out of order is drawn focus first anyway",
          backwards.items.compactMap(\.heading) == ["Models", "Accounts"]
              && backwards.sticky?.row?.value == mcpModelAutoValue)

    // A hit in one section only: the other one goes, its name with it.
    let filtered = pickPalette(PickRequest(id: "p", kind: .model, message: "m", rows: models.rows,
                                           sections: [models, accounts]), filter: "opus")
    check("a query that hits one section hides the other, heading and all",
          filtered.items.compactMap(\.heading) == ["Models"]
              && filtered.items.compactMap(\.row).map(\.value) == ["opus"])
    check("…while the way out of the panel is never filtered away",
          filtered.sticky?.row?.value == mcpModelAutoValue)
    // A query that hits nothing leaves the way out and nothing else, which is what stops a typo
    // from leaving a panel with no answer on it.
    let nothing = pickPalette(PickRequest(id: "p", kind: .model, message: "m", rows: models.rows,
                                          sections: [models, accounts]), filter: "zzzz")
    check("a query that hits nothing still leaves the way out reachable",
          nothing.items.isEmpty && nothing.choices.count == 1
              && nothing.sticky?.row?.value == mcpModelAutoValue)
    // WHAT IS MATCHED: the name, the depth beside it, and the second line under it.
    let account = PickRow(value: "claude:.claude2", label: "Claude 2",
                          detail: "fable 91% · session 74%", tags: [switchRecommendedTag])
    check("a row is matched by its name, whatever the case",
          pickRowMatches(account, query: "claude") && pickRowMatches(account, query: "CLAUDE 2"))
    check("…by the depth drawn beside it",
          pickRowMatches(PickRow(value: "opus", effort: "xhigh", label: "opus · xhigh"),
                         query: "xhigh"))
    check("…and by the line under it, which is where the percentages are",
          pickRowMatches(account, query: "session 74"))
    check("a row that answers none of it is not offered", !pickRowMatches(account, query: "gpt"))
    check("nothing typed matches everything, and so does a query of only spaces",
          pickRowMatches(account, query: "") && pickRowMatches(account, query: "   "))
    // THE CURSOR FOLLOWS THE TYPING: on the row the session is on while nothing has been typed, and
    // on the first hit once something has, because the query is the aim.
    let resting = pickPalette(PickRequest(id: "p", kind: .account, message: "m",
                                          rows: [PickRow(value: "a", label: "A"),
                                                 PickRow(value: "b", label: "B", isCurrent: true),
                                                 PickRow(value: switchAutoRequest, label: "auto")]))
    check("the cursor rests where the session already is", pickPaletteSelection(resting,
                                                                               filtering: false) == 1)
    check("…and on the first hit as soon as something is typed",
          pickPaletteSelection(resting, filtering: true) == 0)

    // MARK: - 37e. The arithmetic sums exactly what was drawn

    // THE SUM IS THE DRAWING, item for item: every heading, every row and every gap the panel puts
    // on screen, and nothing that is not on screen. Stated as the sum itself rather than as a
    // number, because the numbers that ARE fixtures live in the height suite, measured off a window.
    check("the height is what the items add up to, gaps and headings included",
          pickPaletteSeedHeight(both, cap: 1000)
              == both.items.reduce(pickRowsPadding * 2) { $0 + $1.gapAbove + $1.height })
    check("…and two sections are taller than the focus one on its own",
          pickPaletteSeedHeight(both, cap: 1000)
              > pickPaletteSeedHeight(pickPalette(rows: models.rows), cap: 1000))
    check("a heading is drawn at the height the sum gives it",
          both.items.first(where: { $0.heading != nil })?.height == pickSectionHeadingHeight)
    check("the second section is set apart by more than two rows of one section are",
          both.items.first(where: { $0.heading == "Accounts" })?.gapAbove == pickSectionGap
              && pickSectionGap > pickRowGroupSpacing)
    check("filtering a section away takes its height with it",
          pickPaletteSeedHeight(filtered, cap: 1000) < pickPaletteSeedHeight(both, cap: 1000))
    check("the pinned block is the rule plus the row it sets apart, filter or no filter",
          pickPaletteStickyHeight(both) == pickPaletteStickyHeight(nothing)
              && pickPaletteStickyHeight(both)
                  == pickRowGroupSpacing * 2 + pickRowDividerHeight
                      + pickRowHeight(models.rows[models.rows.count - 1]))
    // The cap is the cap however many sections there are: a palette is still a summoned dialog.
    let long = PickSection(kind: .account, heading: "Accounts",
                           rows: (0 ..< 30).map { PickRow(value: "a\($0)", label: "Account \($0)",
                                                          detail: "session 90%") })
    check("a palette long enough to need it still scrolls at the cap",
          pickPaletteSeedHeight(pickPalette(sections: [models, long], focus: .model, filter: ""))
              == pickRowsMaxHeight)
    check("a measurement is still what wins once there is one, and zero is not one",
          pickPaletteHeight(measured: 123, palette: both) == 123
              && pickPaletteHeight(measured: 0, palette: both)
                  == pickPaletteSeedHeight(both))

    // MARK: - 37f. The keyboard, which now has typing in it

    check("the arrow keys move the cursor",
          pickKeyAction(.up, query: "") == .move(-1) && pickKeyAction(.down, query: "") == .move(1))
    check("Enter takes what the cursor is on", pickKeyAction(.enter, query: "op") == .commit)
    // ESCAPE HAS TWO ANSWERS, and the order is the point: losing the whole panel to a stray Escape
    // means retyping the command, while a filter is a state people want out of far more often.
    check("Escape clears what was typed before it closes anything",
          pickKeyAction(.escape, query: "op") == .edit(""))
    check("…and closes the panel once there is nothing left to clear",
          pickKeyAction(.escape, query: "") == .cancel)
    check("typing goes into the filter", pickKeyAction(.text("s"), query: "op") == .edit("ops"))
    check("backspace takes the last character back, and does nothing on an empty query",
          pickKeyAction(.delete, query: "op") == .edit("o")
              && pickKeyAction(.delete, query: "") == .ignore)
    // A control character in the query would narrow the list to nothing with no way to see why.
    check("a control character is not typing", pickKeyAction(.text("\u{1B}"), query: "") == .ignore
              && pickKeyAction(.text(""), query: "") == .ignore)

    // MARK: - 37g. The panel draws what this file says it draws

    // The layout needs a screen, so the wiring is carried by the source: the same lock the height
    // suite uses, for the same reason (a pure rule nobody calls is the defect this feature has been
    // bitten by before).
    let view = (try? String(contentsOfFile: "Tally/Views/PickPanelView.swift", encoding: .utf8)) ?? ""
    check("the panel view is readable from this suite", !view.isEmpty)
    check("the list is the palette's own items, headings included",
          view.contains("ForEach(Array(palette.items.enumerated())"))
    check("…the pinned row is the palette's, drawn outside the scrolling region",
          view.contains("if let sticky = palette.sticky { entry(sticky) }"))
    check("…and its height comes from the palette rather than from the rows a second time",
          view.contains("pickPaletteHeight(measured: rowsHeight, palette: palette)")
              && !view.contains(".frame(maxHeight:"))
    check("what is typed reaches the palette as its filter",
          view.contains("pickPalette(request, filter: query)"))
    check("…and every keypress is decided by the rule this file asserts",
          view.contains("pickKeyAction(key, query: query)"))
    check("the field says what it is for before anything is typed",
          view.contains("pickSearchPlaceholder"))
    check("a chosen row carries the section it came from",
          view.contains("choose(PickChoice(kind: item.kind, row: row))"))
    // …and the answer written from that choice names the section, which is the field the CLI routes
    // on. Pure, so it is asserted rather than read.
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
