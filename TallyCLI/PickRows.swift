import Foundation

// The one-step list: what a native picker draws, derived from the same offer the form is built from
// (MCPPicker.swift owns the offer, PickContract.swift owns the row shape the app reads).
//
// WHAT MAKES IT ONE STEP is that a row is a whole decision. The form asks per AXIS - a model field
// and an effort field, then a submit - so the model picker is three actions and cannot be fewer,
// because the protocol has no way to say "this field alone is the answer" (the design's §1). A list
// whose rows already carry both axes has nothing left to confirm: the click IS the submit.
//
// SO THE MODEL LIST IS FLATTENED HERE, not at the far end. Each model appears once on its own (which
// changes the model and leaves the depth alone, the third state `ModelIntent.pin(model:effort:)`
// exists for) and once per effort it can be run at. The alternative - draw the models, then draw the
// efforts - is two-step selection with the Accept renamed, which is the thing being removed.
//
// AND `auto` IS A ROW THAT CANNOT CARRY AN EFFORT. The grammar refuses that pair outright
// (`modelIntent`: "auto hands this session back to the layers below, so it cannot carry an effort of
// its own"), and the form can still express it - a person really can fill in `auto` and `xhigh` and
// press Accept, and be told no afterwards, which is a real defect somebody hit. In a list the pair
// is not refused, it is UNDRAWABLE: `auto` is one row, with no effort on it, and there is no second
// field to disagree with it.

/// The account rows, derived from the options the form is offered so the two channels cannot list
/// different fleets: same inclusion rule, same order, same recommendation.
///
/// `ranked` is where the tags come from, which is also what says which row the session is already
/// on: the keyboard path opens there, so the commonest correction (a mis-typed account, a session
/// that should not have moved) starts one keypress from where it is.
func mcpAccountPickRows(_ accounts: [Snapshot.Account], ranked rows: [SwitchFleetRow]) -> [PickRow] {
    let tags = Dictionary(rows.map { ($0.id, $0.tags) }, uniquingKeysWith: { first, _ in first })
    return accounts.compactMap { account -> PickRow? in
        // The ranking decides who is offered at all (a listed account with no launch home is not),
        // so an account it left out is left out here: asked once, answered once.
        guard let carried = tags[account.id] else { return nil }
        return PickRow(value: account.id, effort: nil, label: account.label,
                       detail: mcpAccountWindows(account), tags: carried,
                       isCurrent: carried.contains(switchCurrentSessionTag))
    } + [PickRow(value: switchAutoRequest, effort: nil, label: mcpAccountAutoLabel)]
}

/// THE PALETTE BOTH COMMANDS RAISE: the axis that was asked for, and the other one under it.
///
/// ONE SURFACE FOR TWO COMMANDS, because they are two halves of one sentence: `/tally-model` and
/// `/tally-account` decide what runs this conversation and where it runs, and somebody who opened
/// one and wanted the other had to escape it and type the second command. Nothing about a row
/// changes - each still decides everything about itself, and choosing one is still the whole answer.
///
/// FOCUS FIRST, and `PickRequest.rows` is that section's rows, so a copy of Tally from before the
/// palette draws exactly the list it always drew rather than a request it cannot read
/// (`PickRequest.sections`).
///
/// A SECTION WITH NO ROWS IS NOT DRAWN AT ALL: a machine with one account has nothing to offer on
/// that axis, and a heading over an empty list is a promise the panel is not keeping.
func mcpPickSections(focus: PickKind, model: [PickRow], account: [PickRow]) -> [PickSection] {
    let sections = [PickSection(kind: .model, heading: pickSectionHeading(.model), rows: model),
                    PickSection(kind: .account, heading: pickSectionHeading(.account),
                                rows: account)]
    return pickSectionsFocusFirst(sections.filter { !$0.rows.isEmpty }, focus: focus)
}

/// The two depths the list expands. NOT the whole enumeration, and that is a judgement about this
/// surface rather than about the axis: a picker whose reason to exist is "see it all, click once"
/// stops being that at four models times seven depths, where every choice starts with a scroll. The
/// other levels are not lost, they are TYPED (`/tally-model opus low`), which the grammar has always
/// accepted and which is the faster path for somebody who already knows what they want.
///
/// The form fallback still offers every level, so nothing is unreachable when the app is not there
/// to draw this at all.
let pickerExpandedEfforts = ["high", "xhigh"]

/// The model rows: every model on its own, then that model at the depths above, then the release.
///
/// THE RESTING ROW is the pair the session is running now, not the first row: an arrow key from
/// there is "the same model, one level deeper", which is the change people actually make. A session
/// whose effort nothing has read yet rests on the model's own row.
func mcpModelPickRows(_ status: ModelStatus, efforts: [String] = pickerExpandedEfforts) -> [PickRow] {
    let options = mcpModelOptions(status)
    let runningEffort = status.running?.effort?.lowercased()
    var rows: [PickRow] = []
    // Whether the depth this session is at is one of the ones drawn below. When it is NOT - a
    // session on `low`, or one whose depth nothing has read yet - the row that means "leave the
    // depth alone" IS where the session is, and marking anything else would leave the whole list
    // with no resting row and the cursor on an unrelated model (review of ee77152).
    let depthIsDrawn = runningEffort.map { effort in
        efforts.contains { $0.lowercased() == effort }
    } ?? false
    for option in options where option.value != mcpModelAutoValue {
        let isRunningModel = modelsAgree(option.value, status.running?.model)
        // The model on its own: changes what answers, leaves the depth where it is.
        rows.append(PickRow(value: option.value, effort: nil, label: option.label,
                            isCurrent: isRunningModel && !depthIsDrawn))
        for effort in efforts {
            rows.append(PickRow(value: option.value, effort: effort,
                                label: "\(option.value) · \(effort)",
                                isCurrent: isRunningModel && runningEffort == effort.lowercased()))
        }
    }
    // Last, and alone: the one row that hands both axes back, which is why it carries no effort.
    if let auto = options.first(where: { $0.value == mcpModelAutoValue }) {
        rows.append(PickRow(value: auto.value, effort: nil, label: auto.label))
    }
    return rows
}
