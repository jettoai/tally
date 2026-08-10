import Foundation

// CIRCLING, THEN SUBMITTING: what the pick palette answers with, and when it answers with nothing.
//
// WHAT CHANGED AND WHY THIS SUITE EXISTS. A click used to be the whole answer, which made the one
// thing two columns were built for impossible: "move me to Claude 2 AND run opus" is two decisions,
// and a surface that answers on the first click can only ever carry the first of them. So a click
// circles a row in its column, Enter or Apply submits every axis whose circle is not already where
// it is, and the sentence under the columns says what that will be.
//
// Every check here is about a property that can go wrong SILENTLY, which is the same rule the rest
// of this family is written under:
//
//   - a column that circles nothing, or circles the row the session is already on, must submit
//     NOTHING on that axis. Both readings exist because both states are real (an account column
//     rests on the current account; a model column frequently has no current row at all), and a
//     panel that read either as a change would move somebody's conversation for opening it.
//   - the answer has to carry TWO axes without breaking a reader that knows about one, which is the
//     same live skew `PickRequest.sections` carries one direction over.
//   - Enter on a panel nobody changed has to mean the same thing Escape does, or the person is told
//     something happened when nothing did.
func runPickCircleChecks() {
    // The two lists as they really come: a fleet whose current account is marked, and a model table
    // whose current pair is. Both end in the row that hands their own axis back.
    let fleet = PickSection(kind: .account, rows: [
        PickRow(value: "claude:.claude", label: "Claude", detail: "fable 54% · session 86% (2h14m)",
                tags: [switchCurrentSessionTag], isCurrent: true),
        PickRow(value: "claude:.claude2", label: "Claude 2", detail: "fable 91% · session 74% (46m)",
                tags: [switchRecommendedTag]),
        PickRow(value: switchAutoRequest, label: pickAutoLabel),
    ])
    var depthRows: [PickRow] = []
    for model in ["fable", "opus"] {
        depthRows.append(PickRow(value: model, label: model))
        for effort in ["high", "xhigh"] {
            depthRows.append(PickRow(value: model, effort: effort, label: "\(model) · \(effort)",
                                     isCurrent: model == "fable" && effort == "high"))
        }
    }
    depthRows.append(PickRow(value: mcpModelAutoValue, label: "auto"))
    let depths = PickSection(kind: .model, rows: depthRows)
    let request = PickRequest(id: "p", kind: .model, message: "m", rows: depths.rows,
                              sections: [depths, fleet])
    let palette = pickPalette(request)
    let accounts = palette.column(.account)!
    let models = palette.column(.model)!

    // MARK: - 38a. Where the circles rest when the panel opens

    check("a column with a current row opens circled on it",
          pickColumnSelection(accounts) == 0
              && accounts.choices[0].row.tags.contains(switchCurrentSessionTag))
    check("…and so does the model table, on the pair the session is running",
          pickColumnSelection(models) == 1 && models.choices[1].row.effort == "high")
    // A COLUMN WITH NOTHING CURRENT CIRCLES NOTHING, which is the same statement as circling the
    // current row: no change on this axis. Row zero would have been a change nobody asked for.
    let strangers = pickColumn(PickSection(kind: .model, rows: [
        PickRow(value: "opus", label: "opus"), PickRow(value: "sonnet", label: "sonnet"),
        PickRow(value: mcpModelAutoValue, label: "auto"),
    ]))
    check("a column with no current row circles nothing at all",
          pickColumnSelection(strangers) == nil)
    check("…which submits nothing, exactly as circling the current row does",
          pickPendingChanges(PickPalette(columns: [strangers]), selections: [:]).isEmpty)
    // A query circles its first hit, because typing three letters and pressing Enter is the fast
    // path and it has to send what the query narrowed to.
    let typed = pickPalette(request, filters: [.account: "claude 2"]).column(.account)!
    check("a filtered column circles its first hit", pickColumnSelection(typed) == 0
              && typed.choices[0].row.value == "claude:.claude2")
    // …and a query that hit nothing circles NOTHING rather than the pinned row underneath, which
    // would arm a release of the axis for a word that matched no account.
    let missed = pickPalette(request, filters: [.account: "zzzz"]).column(.account)!
    check("a query that hits nothing circles nothing, not the way out pinned under it",
          pickColumnSelection(missed) == nil && missed.choices.count == 1
              && missed.choices[0].row.value == switchAutoRequest)

    // MARK: - 38b. What one press would do

    check("a panel nobody has touched submits nothing",
          pickPendingChanges(palette, selections: [.account: 0, .model: 1]).isEmpty
              && pickSubmission(palette, selections: [.account: 0, .model: 1],
                                command: .model) == nil)
    check("…and Enter on it is a cancellation, which is what the CLI already has a sentence for",
          pickSubmission(palette, selections: [:], command: .model) == nil)
    // ONE AXIS: the commonest pick there is.
    let oneAxis = pickPendingChanges(palette, selections: [.account: 0, .model: 5])
    check("circling another row in one column submits that axis and only it",
          oneAxis.map(\.kind) == [.model] && oneAxis.first?.row.effort == "xhigh")
    // BOTH AXES AT ONCE, which is the whole reason the columns are on one panel.
    let bothAxes = pickPendingChanges(palette, selections: [.account: 1, .model: 5])
    check("circling a row in each column submits both, in the order the columns stand",
          bothAxes.map(\.kind) == [.account, .model]
              && bothAxes.map(\.row.value) == ["claude:.claude2", "opus"])
    // THE WAY OUT IS A CHANGE. Handing an axis back is something that happens, and the release row
    // is never the current one, so nothing special has to be said for it.
    let released = pickPendingChanges(palette, selections: [.account: 2, .model: 1])
    check("circling the way out of an axis is a change like any other",
          released.map(\.row.value) == [switchAutoRequest])
    check("a circle pointing at nothing in the column is not a change",
          pickPendingChanges(palette, selections: [.account: 99, .model: 1]).isEmpty)

    // MARK: - 38c. The answer both axes travel in

    let submitted = pickSubmission(palette, selections: [.account: 1, .model: 5], command: .model)
    // THE COMMAND'S AXIS FIRST, because the three fields every reader has can only carry one axis:
    // the one the person typed the command about is the one that survives a skew.
    check("a two-axis submit puts the COMMAND'S axis in the fields every reader has",
          submitted?.value == "opus" && submitted?.effort == "xhigh" && submitted?.kind == .model)
    check("…and the other one beside it, whole",
          submitted?.also == PickAxisAnswer(value: "claude:.claude2", effort: nil, kind: .account))
    let fromAccount = pickSubmission(palette, selections: [.account: 1, .model: 5], command: .account)
    check("…the other way up when the other command opened the panel",
          fromAccount?.value == "claude:.claude2" && fromAccount?.kind == .account
              && fromAccount?.also?.value == "opus" && fromAccount?.also?.effort == "xhigh")
    check("a one-axis submit carries no second axis at all",
          pickSubmission(palette, selections: [.account: 0, .model: 5], command: .model)?.also == nil)
    check("neither answer is a cancellation, and one carrying only the second axis would not be",
          submitted?.isCancelled == false
              && PickAnswer(also: PickAxisAnswer(value: "opus", kind: .model)).isCancelled == false
              && PickAnswer.cancelled.isCancelled)

    // WHAT AN OLDER CLI READS OFF THE WIRE: three fields and nothing else, which is one axis - the
    // one the command was about. A DIFFERENT TYPE ON PURPOSE, since decoding the new one would only
    // prove the new one decodes.
    struct LegacyPickAnswer: Decodable, Equatable {
        let value: String?
        let effort: String?
        let kind: PickKind?
    }
    let onTheWire = encodePick(submitted)
    let legacy = decodePick(LegacyPickAnswer.self, from: onTheWire)
    check("a CLI from before the second axis reads the command's own and stops",
          legacy == LegacyPickAnswer(value: "opus", effort: "xhigh", kind: .model))
    // WHAT THE OTHER CHOICE OF AXIS WOULD COST, spelled out because it is silent (codex review of
    // c283a85): the panel used to name the axis its KEYBOARD was in, and the keyboard moves on its
    // own - a hover, an arrow key, a Tab. So a `/tally-model` whose focus had drifted to the
    // accounts column wrote this, and an older CLI applies the three fields and ignores the rest:
    // the move happens, the model change the command was about is dropped, and nothing says so.
    let drifted = pickSubmission(palette, selections: [.account: 1, .model: 5], command: .account)
    check("naming the wrong axis first is a change an older CLI drops in silence",
          decodePick(LegacyPickAnswer.self, from: encodePick(drifted))
              == LegacyPickAnswer(value: "claude:.claude2", effort: nil, kind: .account)
              && drifted?.also?.value == "opus")
    check("…and this one reads back exactly what it wrote",
          decodePick(PickAnswer.self, from: onTheWire) == submitted)
    // The other skew: an answer written by an app that never heard of two axes.
    let older = #"{"value":"claude:.claude2","kind":"account"}"#
    let read = decodePick(PickAnswer.self, from: Data(older.utf8))
    check("an answer from before the second axis is still one axis, and says so",
          read?.also == nil && read?.value == "claude:.claude2" && read?.kind == .account)

    // MARK: - 38d. What the far end does with two axes

    let offer = MCPPickOffer(kind: .model, message: "", sections: [depths, fleet], schema: [:])
    check("both axes come back under their own fields, in one map",
          offer.content(for: submitted!)
              == [mcpModelField: "opus", mcpEffortField: "xhigh",
                  mcpAccountField: "claude:.claude2"])
    // A STRANGER'S AXIS IS DROPPED ON ITS OWN, so it cannot cancel one we really did offer: the
    // panel is another process, and this whole claim-and-seal family exists for a stale one.
    check("an axis naming a row nobody drew is dropped, and the real one survives it",
          offer.content(for: PickAnswer(value: "opus", effort: "high", kind: .model,
                                        also: PickAxisAnswer(value: "claude:.claude9",
                                                             kind: .account)))
              == [mcpModelField: "opus", mcpEffortField: "high"])
    check("…and an answer whose every axis is a stranger's is nothing chosen",
          offer.content(for: PickAnswer(value: "gpt", kind: .model,
                                        also: PickAxisAnswer(value: "x", kind: .account))).isEmpty)

    // END TO END: a person who typed /tally-model, circled an account AND a model, and pressed
    // Enter. BOTH have to happen, and they have to be reported as two things.
    var moved: [SwitchIntent] = []
    var pinned: [ModelIntent] = []
    let channel = PickChannelDouble()
    channel.answers = [submitted]
    let answered = runPick(channel.channel, tool: .pickModel,
                           world: pickWorld(applied: { moved.append($0) },
                                            model: { pinned.append($0) }))
    check("one submit carrying both axes moves the conversation AND pins the pair",
          moved == [.pinAccount("claude:.claude2")]
              && pinned == [.pin(model: "opus", effort: "xhigh")])
    check("…and says both, one line each, rather than reporting one event",
          answered.decision.contains("queued the move")
              && answered.decision.contains("queued the pair")
              && !answered.decision.contains(mcpNothingChanged))
    // …and a submit that names neither axis is still the one sentence it always was.
    var untouched: [SwitchIntent] = []
    let empty = PickChannelDouble()
    empty.answers = [PickAnswer.cancelled]
    let nothing = runPick(empty.channel, tool: .pickModel,
                          world: pickWorld(applied: { untouched.append($0) }))
    check("a cancellation queues nothing and says nothing was changed",
          untouched.isEmpty && nothing.decision.contains(mcpNothingChanged))

    // MARK: - 38e. The circle under the keyboard, and under a query

    check("an arrow key moves the circle and comes to rest rather than wrapping",
          pickMovedSelection(from: 0, step: 1, count: 3) == 1
              && pickMovedSelection(from: 2, step: 1, count: 3) == 2
              && pickMovedSelection(from: 0, step: -1, count: 3) == 0)
    // FROM NOTHING IT LANDS ON THE END IT CAME FROM: stepping from an imagined -1 would skip the
    // very row somebody pressing Down is aiming at.
    check("…and from a column circling nothing it lands on the first row going down",
          pickMovedSelection(from: nil, step: 1, count: 3) == 0)
    check("…on the last going up",
          pickMovedSelection(from: nil, step: -1, count: 3) == 2)
    check("a column with no rows has nothing to circle",
          pickMovedSelection(from: nil, step: 1, count: 0) == nil
              && pickMovedSelection(from: 1, step: 1, count: 0) == nil)
    // A FILTER MUST NOT UNDO A CHOICE: somebody who circled Claude 2 and then typed in the same
    // field still has Claude 2 circled when the query clears.
    let circled = accounts.choices[1].row
    check("a circle survives a query that still shows the row it is on",
          pickReselected(pickPalette(request, filters: [.account: "claude"]).column(.account)!,
                         keeping: circled) == 1)
    check("…and moves to the first hit when the query took that row away",
          pickReselected(pickPalette(request, filters: [.account: "claude 2"]).column(.account)!,
                         keeping: accounts.choices[0].row) == 0)
    check("…and back to the current row when nothing is typed and the circle is gone",
          pickReselected(accounts, keeping: PickRow(value: "gone", label: "gone")) == 0)

    // MARK: - 38f. The sentence under the columns

    check("the bar says nothing on a panel that would submit nothing",
          pickPendingSummary([]) == nil)
    check("one axis reads as the row does, the depth beside the name",
          pickPendingSummary(oneAxis) == "→ opus xhigh")
    check("…and both axes read as one line, in the order the columns stand",
          pickPendingSummary(bothAxes) == "→ Claude 2 · opus xhigh")
    check("a row with no depth says only its name",
          pickChangeSummary(PickChoice(kind: .account, row: fleet.rows[1])) == "Claude 2")
    // The release row's sentence is on its own line in the list, so the bar takes the name alone
    // rather than repeating a paragraph inside a summary.
    check("the way out reads as its name, not as its explanation",
          pickChangeSummary(PickChoice(kind: .account, row: fleet.rows[2]))
              == "automatic selection")

    // MARK: - 38g. The panel is wired to exactly these rules

    // The layout needs a screen; what can be asserted here is that the view calls the rules that
    // were asserted above, which is the same lock the height and surface suites are under.
    let view = (try? String(contentsOfFile: "Tally/Views/PickPanelView.swift", encoding: .utf8)) ?? ""
    check("the panel view is readable from this suite", !view.isEmpty)
    check("a click circles a row rather than answering the panel",
          view.contains(".onTapGesture { selections[column.kind] = index }")
              && !view.contains("choose(PickChoice"))
    // …AND IT NAMES THE AXIS THE COMMAND WAS ABOUT, not the one the keyboard drifted into. The
    // panel passed `focus` here, which a hover or a Tab moves; the check above says what that costs
    // at the far end, and this is the half a source scan can hold.
    check("Enter submits every circle, by the rule this file asserts",
          view.contains("choose(pickSubmission(palette, selections: selections, "
              + "command: request.kind))")
              && !view.contains("focus: focus"))
    check("…and the arrow keys move the circle by theirs",
          view.contains("pickMovedSelection(from: selections[kind], step: step,"))
    check("a query moves the circle only when it took the circled row away",
          view.contains("pickReselected(column, keeping: circled)"))
    let row = (try? String(contentsOfFile: "Tally/Views/PickRowView.swift", encoding: .utf8)) ?? ""
    check("the bar draws what one press would do, from the same rule",
          view.contains("PickApplyBar(changes: pending)")
              && row.contains("pickPendingSummary(changes)"))
    check("the circled row is marked in the app's own pin language",
          row.contains(#"Image(systemName: isCircled ? "checkmark.circle.fill" : "circle")"#))
    check("…and a hover is drawn as something else, so the two cannot be confused",
          row.contains("isHovered ? AnyShapeStyle(.quaternary.opacity(0.18))"))
    check("the bar keeps its space whether or not it says anything",
          row.contains(".frame(height: pickApplyBarHeight)"))
    // The button and the key do the same thing, which is what makes the keyboard path discoverable.
    check("Apply is a word the catalogue carries, and the key beside it",
          row.contains(#"Text(L("Apply"))"#) && row.contains(#"Text(verbatim: "\u{21A9}")"#))
}
