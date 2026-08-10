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
/// The languages Tally ships, spelled here because `AppLocale` is an app-only file this suite
/// does not compile (it reaches UserDefaults and Bundle). Kept in step by the check below, which
/// fails the moment the catalogue stops carrying one of them.
let AppLocaleSupported = ["zh-Hant", "zh-Hans", "ja", "ko"]

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
        case .pick: _ = mcpPickTally(input: input, world: world, ask: ask)
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

    let models = PickSection(kind: .model, rows: [PickRow(value: "opus", effort: "high", label: "opus · high"),
                                    PickRow(value: mcpModelAutoValue, label: "auto")])
    let accounts = PickSection(kind: .account, rows: [PickRow(value: "claude:.claude2", label: "Claude 2"),
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
    check("…and what it draws is the focus section, not a mixture", legacy?.rows == models.rows)
    // The other skew: a session still running the CLI it launched with writes no sections at all.
    let older = #"{"id":"abc","kind":"model","message":"m","rows":"#
        + #"[{"value":"opus","label":"opus","tags":[],"isCurrent":false},"#
        + #"{"value":"auto","label":"auto","tags":[],"isCurrent":true}]}"#
    let read = decodePick(PickRequest.self, from: Data(older.utf8))
    check("a request from before the palette is still readable, and says it has no sections",
          read?.sections == nil && read?.rows.count == 2)
    let single = read.map { pickPalette($0) }
    check("…and draws as ONE column, at the width this panel has always had",
          single?.columns.map(\.kind) == [.model] && single?.isSingleColumn == true
              && single.map(pickPanelWidth) == 2 * PanelGeometry.contentPadding
                  + pickLoneColumnWidth)
    check("…with its way out pinned under it exactly as before",
          single?.columns.first?.items.count == 1
              && single?.columns.first?.sticky?.row.value == "auto")
    check("…and the cursor still resting where the session already is",
          single?.columns.first.map { pickColumnSelection($0) } == 1)

    // MARK: - 37d. Two columns, and everything one axis has inside its own

    // The two lists as they really come: a fleet whose rows carry three windows and a tag, and a
    // model table of pairs. Both end in the way out of their own axis, which is what the columns
    // pin.
    let fleet = PickSection(kind: .account, rows: [
        PickRow(value: "claude:.claude", label: "Claude", detail: "fable 54% · session 86%",
                tags: [switchCurrentSessionTag], isCurrent: true),
        PickRow(value: "claude:.claude2", label: "Claude 2", detail: "fable 91% · session 74%",
                tags: [switchRecommendedTag]),
        PickRow(value: "claude:.claude3", label: "Claude 3", detail: "fable 12% · session 40%"),
        PickRow(value: switchAutoRequest, label: pickAutoLabel),
    ])
    var depthRows: [PickRow] = []
    for model in ["fable", "opus", "sonnet"] {
        depthRows.append(PickRow(value: model, label: model))
        depthRows.append(PickRow(value: model, effort: "high", label: "\(model) · high"))
    }
    depthRows.append(PickRow(value: mcpModelAutoValue, label: "auto"))
    let depths = PickSection(kind: .model, rows: depthRows)
    let request = PickRequest(id: "p", kind: .model, message: "m", rows: depths.rows,
                              sections: [depths, fleet])
    let both = pickPalette(request)
    // THE ORDER DOES NOT MOVE. The request is written focus-first for the sake of an older app's
    // `rows` field; this surface is accounts-left, models-right whichever command opened it, so a
    // person is not re-reading the panel every time.
    check("the fleet is the left column and the models the right, whichever command opened it",
          both.columns.map(\.kind) == [.account, .model])
    check("…including the account command, whose request leads with the other section",
          pickPalette(PickRequest(id: "p", kind: .account, message: "m", rows: fleet.rows,
                                  sections: [fleet, depths])).columns.map(\.kind)
              == [.account, .model])
    check("each column is named for a person to read",
          both.columns.map { pickColumnHeadingKey($0.kind) } == ["Accounts", "Models"])
    // EACH COLUMN'S OWN WAY OUT, at its own foot: this is what the stacked shape could not do, and
    // where its two release rows were a divider apart with only their wording to tell them apart.
    check("each column pins its own way out, and neither is in the other's list",
          both.column(.account)?.sticky?.row.value == switchAutoRequest
              && both.column(.model)?.sticky?.row.value == mcpModelAutoValue
              && both.columns.allSatisfy { column in
                  !column.items.contains { $0.row.value == column.sticky?.row.value }
              })
    check("…and it is last in that column's own walk, wherever it is drawn",
          both.columns.allSatisfy { $0.choices.last?.row.value == $0.sticky?.row.value }
              && both.column(.model)?.stickyIndex == both.column(.model)?.items.count)
    check("a choice carries the column it came from, which is the axis it answers",
          both.column(.account)?.choices.allSatisfy { $0.kind == .account } == true
              && both.column(.model)?.choices.allSatisfy { $0.kind == .model } == true)

    // MARK: - 37d2. Each column filters only itself

    let typedLeft = pickPalette(request, filters: [.account: "claude 2"])
    check("a query in one column narrows that column",
          typedLeft.column(.account)?.items.map(\.row.value) == ["claude:.claude2"])
    check("…and leaves the other one exactly as it was",
          typedLeft.column(.model)?.items == both.column(.model)?.items)
    check("…and says which of them is filtered, since that is what Escape acts on",
          typedLeft.column(.account)?.filtering == true
              && typedLeft.column(.model)?.filtering == false)
    let typedRight = pickPalette(request, filters: [.model: "opus"])
    check("the same holds the other way round",
          typedRight.column(.model)?.items.map(\.row.value) == ["opus", "opus"]
              && typedRight.column(.account)?.items == both.column(.account)?.items)
    // A COLUMN IS NEVER REMOVED FOR HAVING NO HITS: the two columns would swap places under the
    // pointer, and the way out of that axis would go with it.
    let missed = pickPalette(request, filters: [.model: "zzzz"])
    check("a query that hits nothing leaves the column standing, and says so",
          missed.columns.map(\.kind) == [.account, .model]
              && missed.column(.model)?.items.isEmpty == true
              && missed.column(.model)?.isEmptyOfMatches == true)
    check("…with its way out still reachable",
          missed.column(.model)?.sticky?.row.value == mcpModelAutoValue
              && missed.column(.model)?.choices.count == 1)
    check("a column nobody typed into is not empty of matches, it is just empty of a query",
          both.column(.model)?.isEmptyOfMatches == false)
    // WHAT IS MATCHED: what the row is CALLED. The name, the depth beside it, the tags beside that,
    // and not the line of percentages underneath. The detail here is the shape the CLI really
    // writes, three windows, because that is what makes the digit case below able to go wrong.
    let account = PickRow(value: "claude:.claude2", label: "Claude 2",
                          detail: "fable 91% · session 74% · weekly 63%",
                          tags: [switchRecommendedTag])
    check("a row is matched by its name, whatever the case",
          pickRowMatches(account, query: "claude") && pickRowMatches(account, query: "CLAUDE 2"))
    check("…by the depth drawn beside it",
          pickRowMatches(PickRow(value: "opus", effort: "xhigh", label: "opus · xhigh"),
                         query: "xhigh"))
    // AND NOT BY THE LINE UNDER IT, which is the correction of the first reading (Albert, live,
    // 2026-08-10). That line is an account's three windows and so is nearly all digits: typing "3"
    // for Claude 3 also matched every account whose percentages held a 3, which on a real fleet is
    // most of them. The fixture is built so this can actually fail: the detail really does carry
    // the digit, and the name really does not.
    let third = PickRow(value: "claude:.claude3", label: "Claude 3",
                        detail: "fable 12% · session 40% · weekly 22%")
    // The control is a digit THIS row has in its own percentages ("session 40%") and not in its
    // name, so it fails the moment the second line is matched again.
    check("a digit typed as a name answers the account whose NAME carries it",
          pickRowMatches(third, query: "3") && !pickRowMatches(third, query: "4"))
    check("…and not the account that merely has it in a percentage",
          !pickRowMatches(account, query: "3") && account.detail?.contains("3") == true)
    check("…nor is a row reachable by the words of its own second line",
          !pickRowMatches(account, query: "session 74") && !pickRowMatches(account, query: "weekly"))
    // THE TAGS ARE ON THE SCREEN, so they are matched too: typing what you can read and watching
    // that very row vanish is the filter telling you it is broken (codex review, 2026-08-10).
    check("…and by the tags drawn beside it, which are words a person can read",
          pickRowMatches(account, query: "most headroom")
              && pickRowMatches(PickRow(value: "a", label: "A", tags: [switchCurrentSessionTag]),
                                query: "this session"))
    check("a row that answers none of it is not offered", !pickRowMatches(account, query: "gpt"))
    check("nothing typed matches everything, and so does a query of only spaces",
          pickRowMatches(account, query: "") && pickRowMatches(account, query: "   "))
    // The gap above a row is decided against what is drawn above it, not what was listed there: a
    // filter that removed the rows in between must not leave their spacing behind.
    // The last model in the table, so the rows it was grouped after are gone: the first row drawn
    // is at the top of the list whatever its position in the section was.
    let onlySonnet = pickPalette(request, filters: [.model: "sonnet"]).column(.model)
    check("a filtered list keeps no gaps for the rows it dropped",
          onlySonnet?.items.count == 2 && onlySonnet?.items.first?.gapAbove == 0
              && onlySonnet?.items.last?.gapAbove == pickRowSpacing)

    // MARK: - 37d3. Which column the keyboard is in

    check("the left and right arrows step between the columns",
          pickColumnFocus(both, from: .account, step: 1) == .model
              && pickColumnFocus(both, from: .model, step: -1) == .account)
    // Clamped rather than wrapped, like the walk down a column: a held arrow key comes to rest.
    check("…and stop at the ends rather than wrapping round",
          pickColumnFocus(both, from: .model, step: 1) == .model
              && pickColumnFocus(both, from: .account, step: -1) == .account)
    check("a single-column palette has nowhere sideways to go",
          single.map { pickColumnFocus($0, from: .model, step: -1) } == .model)
    // WHERE THE CURSOR LANDS ON ARRIVAL: what it was left on, the row the session is on when there
    // is nothing to return to, and the first hit while that column is filtered.
    let left = both.column(.account)!
    check("the cursor rests on the row the session is already on",
          pickColumnSelection(left) == 0
              && left.choices[0].row.tags.contains(switchCurrentSessionTag))
    check("…returns to where it was left when the focus comes back",
          pickColumnSelection(left, remembered: 2) == 2)
    check("…and a remembered row the filter has removed is not restored",
          pickColumnSelection(typedLeft.column(.account)!, remembered: 5) == 0)
    check("a filtered column rests on its first hit, because the query is the aim",
          pickColumnSelection(typedRight.column(.model)!) == 0)

    // A HOVER AT THE MOMENT THE PANEL APPEARS IS NOT A CHOICE. The panel is centred on the screen
    // the pointer is on, so it often lands under it, and the first capture of this surface came up
    // with the accounts column lit for a `/tally-model` nobody had touched.
    let raised = Date(timeIntervalSince1970: 1_800_000_000)
    check("a hover in the moment the panel was raised decides nothing",
          !pickHoverMovesFocus(shownAt: raised,
                               now: raised.addingTimeInterval(pickPanelActivationGrace / 2)))
    check("…and one after that is a person moving the pointer",
          pickHoverMovesFocus(shownAt: raised,
                              now: raised.addingTimeInterval(pickPanelActivationGrace + 0.01)))

    // MARK: - 37e. The arithmetic sums exactly what was drawn

    check("a column's height is what its rows add up to, gaps included",
          pickColumnSeedHeight(both.column(.model)!, cap: 1000)
              == both.column(.model)!.items.reduce(pickRowsPadding * 2) {
                  $0 + $1.gapAbove + $1.height
              })
    // ONE HEIGHT FOR BOTH SCROLLING REGIONS: the taller of the two, so the two ways out line up
    // along the foot of the panel and a filter emptying one column does not make the panel jump.
    let tallest = max(pickColumnSeedHeight(both.column(.account)!),
                      pickColumnSeedHeight(both.column(.model)!))
    check("both columns scroll at the same height, which is the taller one's",
          pickPaletteListHeight(both) == tallest && tallest > 0)
    check("…and that height does not move when one column is emptied by its filter",
          pickPaletteListHeight(pickPalette(request, filters: [.account: "zzzz"]))
              == pickPaletteListHeight(both))
    // A measured column replaces ITS OWN seed and nothing else, so the pair is still the taller of
    // what each column now says about itself.
    // THE PANEL DOES NOT MOVE WHILE IT IS BEING TYPED INTO. The shared height is read off the
    // UNFILTERED lists for as long as the panel is up: a filter narrows what is in a column, never
    // how tall it is, or four letters would resize the window four times under the hands typing
    // them (codex review, 2026-08-10).
    check("typing does not move the panel",
          pickPanelListHeight(request, filters: [.model: "zzzz"])
              == pickPanelListHeight(request)
              && pickPanelListHeight(request, filters: [.model: "opus", .account: "claude 2"])
                  == pickPanelListHeight(request))
    check("…and what it keeps is what the whole lists asked for",
          pickPanelListHeight(request) == pickPaletteListHeight(both))
    // …which is strictly more than the filtered reading would have given, so the check above is
    // watching a difference that really exists.
    check("…which the filtered reading would not have kept",
          pickPaletteListHeight(pickPalette(request, filters: [.model: "zzzz",
                                                              .account: "zzzz"]))
              < pickPanelListHeight(request))
    check("a measurement still wins over the arithmetic, and zero is still not one",
          pickPanelListHeight(request, measured: [.model: 900]) == pickRowsMaxHeight
              && pickPanelListHeight(request, measured: [.model: 0])
                  == pickPanelListHeight(request))

    check("a measured column is what wins once there is one, and zero is not one",
          pickPaletteListHeight(both, measured: [.model: 120])
              == max(pickColumnSeedHeight(both.column(.account)!), 120)
              && pickPaletteListHeight(both, measured: [.model: 0]) == tallest)
    check("…capped however tall the rows turned out to be",
          pickPaletteListHeight(both, measured: [.model: 900]) == pickRowsMaxHeight)
    // A column emptied by its filter still draws the line that says so, and it is measured like any
    // other row: an empty region and a broken one look the same otherwise.
    check("a column with no matches is one line tall, not nothing",
          pickColumnSeedHeight(missed.column(.model)!)
              == pickRowsPadding * 2 + pickPlainRowHeight)
    check("…while a column with no rows at all is nothing",
          pickColumnSeedHeight(pickColumn(PickSection(kind: .model, rows: []))) == 0)
    check("the pinned block is the rule plus the row it sets apart, filter or no filter",
          pickColumnStickyHeight(both.column(.model)!)
              == pickColumnStickyHeight(missed.column(.model)!)
              && pickColumnStickyHeight(both.column(.model)!)
                  == pickRowGroupSpacing * 2 + pickRowDividerHeight
                      + pickRowHeight(depths.rows[depths.rows.count - 1]))
    // ITS NAME IS INSIDE ITS FIELD, so there is no heading line in the sum any more: the column is
    // the box (which says what it narrows), the rows, and the way out pinned under them.
    check("a column is its own field, its rows and its way out",
          pickColumnHeight(both.column(.model)!, listHeight: 200)
              == pickSearchBlockHeight + 200 + pickColumnStickyHeight(both.column(.model)!))
    check("…and the columns come to the tallest of them",
          pickPaletteColumnsHeight(both)
              == both.columns.map { pickColumnHeight($0, listHeight: pickPaletteListHeight(both)) }
                  .max())
    // THE WIDTH IS ARITHMETIC, not a number in the view: two lists of different shapes, the gap
    // between them, and the content line either side.
    check("the panel is as wide as its columns, its gap and its margins",
          pickPanelWidth(both) == pickColumnWidth(.account) + pickColumnWidth(.model)
              + pickColumnGap + 2 * PanelGeometry.contentPadding)
    check("the fleet column is the wider of the two, since its rows carry three windows and a tag",
          pickColumnWidth(.account) > pickColumnWidth(.model)
              && pickColumnWidth(.account) >= 372)
    check("…and one column on its own keeps the width this panel has always had",
          pickColumnWidth(.model, alone: true) == pickLoneColumnWidth
              && pickColumnWidth(.account, alone: true) == pickLoneColumnWidth)

    // MARK: - 37f. The keyboard, which now has typing and two columns in it

    // THE CARET IS PLACED IN THE UNITS AN NSRange COUNTS, which is not what a person calls
    // characters: a query holding an emoji or a composed syllable would put the caret short of the
    // end, and the next keystroke into the middle of the query.
    check("the caret lands at the end of a plain query", pickCaretEnd("opus") == 4)
    // The two shapes that break a count of what a person calls characters: one grapheme made of two
    // UTF-16 units, and one made of a surrogate pair.
    check("…and at the end of a composed one, which is two units and one character",
          pickCaretEnd("e\u{301}") == 2 && "e\u{301}".count == 1)
    check("…and at the end of one carrying a surrogate pair",
          pickCaretEnd("opus \u{1F680}") == 7 && "opus \u{1F680}".count == 6)
    check("an empty query puts it at the start", pickCaretEnd("") == 0)

    check("the up and down arrows move the cursor in the column it is in",
          pickKeyAction(.up, query: "") == .move(-1) && pickKeyAction(.down, query: "") == .move(1))
    // SIDEWAYS IS THE OTHER COLUMN AND NOTHING ELSE, whatever is typed (Albert, 2026-08-10). The
    // reading this replaces asked the query and handed the key back to walk a caret with once there
    // was one, which changed what the key meant under the person and, on the path with no field to
    // hand anything to, let the press fall through to the panel's typing handler.
    check("the left and right arrows move between the columns",
          pickKeyAction(.left, query: "") == .moveColumn(-1)
              && pickKeyAction(.right, query: "") == .moveColumn(1))
    check("…and still do once something is typed, rather than turning into a caret step",
          pickKeyAction(.left, query: "op") == .moveColumn(-1)
              && pickKeyAction(.right, query: "op") == .moveColumn(1))
    // TAB IS THE OTHER WAY ACROSS, and the one that does not ask what is typed: it means "the next
    // field" everywhere on the machine and never means a caret step, so it has no second reading to
    // choose between. THE DEFECT IT IS HERE FOR (Albert, live, 2026-08-10): unclaimed, Tab fell
    // through to AppKit's key-view loop, which moved the first responder while the panel went on
    // believing the column it had chosen was focused - and the first keystroke after that was pulled
    // back into the column that had been left behind.
    check("Tab moves to the next column, and Shift-Tab back",
          pickKeyAction(.tab, query: "") == .moveColumn(1)
              && pickKeyAction(.backtab, query: "") == .moveColumn(-1))
    check("…and it still changes columns with a query typed, which is where the arrows hand back",
          pickKeyAction(.tab, query: "op") == .moveColumn(1)
              && pickKeyAction(.backtab, query: "op") == .moveColumn(-1))
    // Where it LANDS is the same clamped walk the arrows take, so a held Tab comes to rest at an end
    // rather than lapping the two columns.
    check("…landing where the arrows land, at rest on the ends",
          pickColumnFocus(both, from: .account, step: 1) == .model
              && pickColumnFocus(both, from: .model, step: 1) == .model)
    check("Enter takes what the cursor is on", pickKeyAction(.enter, query: "op") == .commit)
    // ESCAPE HAS TWO ANSWERS, and the order is the point: losing the whole panel to a stray Escape
    // means retyping the command, while a filter is a state people want out of far more often.
    check("Escape clears the focused column's query before it closes anything",
          pickKeyAction(.escape, query: "op") == .edit(""))
    check("…and closes the panel once there is nothing left to clear",
          pickKeyAction(.escape, query: "") == .cancel)
    check("typing goes into the filter", pickKeyAction(.text("s"), query: "op") == .edit("ops"))
    check("backspace takes the last character back, and does nothing on an empty query",
          pickKeyAction(.delete, query: "op") == .edit("o")
              && pickKeyAction(.delete, query: "") == .ignore)
    // A control character in the query would narrow the list to nothing with no way to see why.
    check("a control character is not typing",
          pickKeyAction(.text("\u{1B}"), query: "") == .ignore
              && pickKeyAction(.text(""), query: "") == .ignore)
    // AND NEITHER IS AN ARROW KEY WEARING A CHARACTER, which is the defect Albert caught live
    // (2026-08-10): AppKit spells the arrows and the whole function row as private-use scalars, so
    // a press that reached a TEXT handler carried something no general test of a character turns
    // away, and eight presses put eight empty boxes in the models filter with "No matches" under
    // them. All four arrows, since it was one key of the four that was reported and all four arrive
    // the same way.
    for arrow in ["\u{F700}", "\u{F701}", "\u{F702}", "\u{F703}"] {
        check("an arrow key's own character is not typing",
              !pickIsTypable(arrow) && pickKeyAction(.text(arrow), query: "op") == .ignore)
    }
    // The ends of the block AppKit reserves, so the guard is a range rather than four constants: the
    // function row, Home, End and the rest live in here too.
    check("…nor anything else in the block AppKit spells its function keys in",
          !pickIsTypable("\u{F704}") && !pickIsTypable("\u{F8FF}")
              && pickFunctionKeyScalars == 0xF700...0xF8FF)
    // AND THE GUARD STILL LETS A PERSON TYPE, which is the half a guard is easy to lose: an account
    // is called whatever somebody typed into Settings, so what passes has to include the scripts a
    // fleet actually holds and the scalars either side of the reserved block.
    check("what a person can see is typing, in any script the fleet holds",
          pickIsTypable("o") && pickIsTypable(" ") && pickIsTypable("Claude 2")
              && pickIsTypable("克勞德") && pickIsTypable("\u{1F680}")
              && pickIsTypable("\u{F6FF}") && pickIsTypable("\u{F900}"))
}
