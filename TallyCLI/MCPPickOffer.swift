import Foundation

// ONE OFFER, AND WHAT AN ANSWER TO IT DOES. The pickers themselves are MCPPicker.swift; what is here
// is the thing they hand to whichever channel can draw it, and the routing on the way back.
//
// TWO RENDERINGS OF ONE OFFER, carried together rather than derived at the far end, because the
// thing that must never differ between them is WHICH options the person is being given. A picker
// that offered a different fleet depending on which channel answered would be worse than either.
//
// AND TWO WAYS BACK IN, since the palette put both axes on one panel: a click that moved the
// conversation to another account and a click that changed what answers it arrive on the same
// channel, and only the answer's own `kind` separates them.

/// What the person did with the dialog. Escape, Decline and a transport that went away are ONE
/// answer here, deliberately: the design draws no difference between refusing and cancelling
/// (nothing was changed either way), and inventing one would be two sentences for one event.
enum MCPPickReply: Equatable {
    case accepted([String: String])
    case declined
}

/// One offer, in BOTH shapes it can be drawn in.
///
/// The rows are the one-step list Tally.app draws: every row is a whole decision, so choosing one IS
/// the answer and there is nothing left to confirm. The schema is the same offer as an elicitation
/// form, which is what Claude Code draws when the app is not there to draw anything - two axes and a
/// submit button, exactly as before.
///
/// TWO RENDERINGS OF ONE OFFER, carried together rather than derived at the far end, because the
/// thing that must never differ between them is WHICH options the person is being given. A picker
/// that offered a different fleet depending on which channel answered would be worse than either.
struct MCPPickOffer {
    /// Which command raised this, and so which section leads and which axis the form asks about.
    let kind: PickKind
    let message: String
    /// Every section the panel draws, focus first (`mcpPickSections`).
    let sections: [PickSection]
    let schema: [String: Any]
    /// WHICH SESSION IS ASKING, as the directory the hook reported for THIS prompt
    /// (`MCPHookInput.sessionDirectory`). Carried on the offer rather than read where the panel is
    /// raised, because the process that raises it is a long-lived child of Claude Code and its own
    /// working directory is whatever that session was launched in - right until the session moves,
    /// and quietly wrong after (`MCPPicker.swift` states the rule the other four answers on this
    /// call already follow; codex review of 46b09ec).
    ///
    /// NOT OPTIONAL, and no default: every caller has the hook's reading in hand, and a default
    /// would be this process's own directory wearing the same label as the answer.
    let directory: String

    init(kind: PickKind, message: String, sections: [PickSection], schema: [String: Any],
         directory: String) {
        self.kind = kind
        self.message = message
        self.sections = sections
        self.schema = schema
        self.directory = directory
    }

    /// One section, which is the whole of what an offer was before the palette. Kept because the
    /// form has one axis whatever the panel draws, and because a fixture with one list is still the
    /// clearest way to assert a rule about one list.
    init(kind: PickKind, message: String, rows: [PickRow], schema: [String: Any],
         directory: String) {
        self.init(kind: kind, message: message,
                  sections: [PickSection(kind: kind, rows: rows)], schema: schema,
                  directory: directory)
    }

    /// The focus section's rows, which is what the request carries for an app that predates the
    /// palette (`PickRequest.rows`).
    var rows: [PickRow] { sections.first?.rows ?? [] }

    /// What a chosen row comes back as, in the shape the form's answer already had: the callers
    /// below read `content[mcpModelField]` and friends, and they do not care which channel filled
    /// it in.
    ///
    /// WHICH AXIS WAS ANSWERED comes from the answer when it names one, because one palette offers
    /// both and the same submit can move a conversation, change what answers it, or do BOTH. An
    /// answer that names no kind is from an app that only ever drew the focus section, so that IS
    /// what it means (`PickAnswer.kind`), and reading it any other way would silently repoint older
    /// apps' picks.
    ///
    /// BOTH AXES LAND IN ONE DICTIONARY, which is why the form's shape survived the change: the two
    /// axes were always different KEYS, so a submit carrying both is the same map with one more
    /// entry in it, and every caller below reads the key it cares about exactly as before.
    ///
    /// AND EVERY VALUE HAS TO BE A ROW WE OFFERED THERE. The panel is another process, and the case
    /// this whole seal-and-claim family exists for is a stale one answering on somebody's behalf
    /// (`pickMayBeClaimed`): a value naming no row we drew, or naming a row from the other section
    /// than the kind claims, is not a pick and is dropped rather than acted on. Dropped one axis at
    /// a time, so a stranger's second axis cannot cancel a first one we did offer.
    func content(for answer: PickAnswer) -> [String: String] {
        answer.axes(focus: kind).reduce(into: [:]) { content, axis in
            guard sections.contains(where: { section in
                section.kind == axis.kind && section.rows.contains { $0.value == axis.value }
            }) else { return }
            switch axis.kind {
            case .account:
                content[mcpAccountField] = axis.value
            case .model:
                content[mcpModelField] = axis.value
                // An effort the row did not name stays ABSENT rather than empty, which is the third
                // state this axis has and the one the form expresses by leaving the field unfilled.
                if let effort = axis.effort { content[mcpEffortField] = effort }
            }
        }
    }
}

/// How a tool asks. Injected all the way down so the pickers can be driven without a client.
typealias MCPAsk = (MCPPickOffer) -> MCPPickReply


// MARK: - What a chosen row does

/// Queue the model an answer names, or nil when it names none.
///
/// THE SENTENCE ONLY, not a whole decision: one submit can carry both axes now, so what comes back
/// from here is a line that may have another line beside it, and the block is written once around
/// the pair (`mcpQueuePick`). A dialog answering with one field is that pair with one line missing.
///
/// The one combination the grammar refuses that a dialog can produce is answered here rather than
/// guessed at: the release beside an effort is two opposite instructions (`modelIntent`).
func mcpQueueModel(_ content: [String: String], input: MCPHookInput,
                   world: MCPPickerWorld) -> String? {
    guard let model = content[mcpModelField] else { return nil }
    // An unfilled optional field arrives as an ABSENT KEY rather than as a null (measured in the
    // probe, 2026-08-07), which is exactly the third state this axis needs: nothing named leaves
    // the effort where it is.
    let effort = content[mcpEffortField]
    guard let intent = modelIntent([model] + (effort.map { [$0] } ?? [])) else {
        return "\(mcpModelAutoValue) hands this session back to the layers below, so it cannot carry "
            + "an effort of its own; nothing was queued. Pick \(mcpModelAutoValue) on its own, "
            + "or a model with the effort you want"
    }
    let attempt = world.applyModel(intent, input)
    return mcpAttemptText(attempt.message, notes: attempt.notes)
}

/// Queue the move an answer names, or nil when it names none. The sentence only, for the reason
/// above.
///
/// BY ID, not by name: the row already knows exactly which account it is, so the pick skips the
/// matcher entirely and cannot land on an account whose label merely shares a prefix.
func mcpQueueAccount(_ content: [String: String], input: MCPHookInput,
                     world: MCPPickerWorld) -> String? {
    guard let account = content[mcpAccountField] else { return nil }
    let attempt = world.applyAccount(account == switchAutoRequest ? .auto : .pinAccount(account),
                                     input)
    return mcpAttemptText(attempt.message, notes: attempt.notes)
}

/// WHATEVER WAS ANSWERED, applied. One answered palette can name either axis OR BOTH, so the two
/// commands share one way back in rather than each reading only for its own field: a `/tally` whose
/// person picked an account row must move the conversation, and one who circled a row in each
/// column must get both.
///
/// BOTH QUEUES RUN, and they are independent by construction: moving a conversation and changing
/// what answers it are two request files written by two paths that have never known about each
/// other (`MCPPickerWorld`). Neither result gates the other, so a model axis the grammar refuses
/// still leaves the move queued, and the person is told both things rather than one.
///
/// ONE LINE EACH, in the order the panel lists them (the fleet first, as the columns stand): the
/// reason IS the user-facing surface, and two events reported as one sentence read as one event.
///
/// The axes are told apart by the FIELD the answer arrived under, which is the shape `content(for:)`
/// already wrote by kind. An answer naming neither is nothing chosen, which is also what Escape,
/// a decline and an answer we could not read all come to.
func mcpQueuePick(_ content: [String: String], input: MCPHookInput,
                  world: MCPPickerWorld) -> String {
    let queued = [mcpQueueAccount(content, input: input, world: world),
                  mcpQueueModel(content, input: input, world: world)].compactMap { $0 }
    return mcpBlockDecision(queued.isEmpty ? mcpNothingChanged : queued.joined(separator: "\n"))
}
