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

    init(kind: PickKind, message: String, sections: [PickSection], schema: [String: Any]) {
        self.kind = kind
        self.message = message
        self.sections = sections
        self.schema = schema
    }

    /// One section, which is the whole of what an offer was before the palette. Kept because the
    /// form has one axis whatever the panel draws, and because a fixture with one list is still the
    /// clearest way to assert a rule about one list.
    init(kind: PickKind, message: String, rows: [PickRow], schema: [String: Any]) {
        self.init(kind: kind, message: message,
                  sections: [PickSection(kind: kind, rows: rows)], schema: schema)
    }

    /// The focus section's rows, which is what the request carries for an app that predates the
    /// palette (`PickRequest.rows`).
    var rows: [PickRow] { sections.first?.rows ?? [] }

    /// What a chosen row comes back as, in the shape the form's answer already had: the callers
    /// below read `content[mcpModelField]` and friends, and they do not care which channel filled
    /// it in.
    ///
    /// WHICH AXIS WAS ANSWERED comes from the answer when it names one, because one palette offers
    /// both and the same click can move a conversation or change what answers it. An answer that
    /// names no kind is from an app that only ever drew the focus section, so that IS what it means
    /// (`PickAnswer.kind`), and reading it any other way would silently repoint older apps' picks.
    ///
    /// AND THE VALUE HAS TO BE A ROW WE OFFERED THERE. The panel is another process, and the case
    /// this whole seal-and-claim family exists for is a stale one answering on somebody's behalf
    /// (`pickMayBeClaimed`): a value naming no row we drew, or naming a row from the other section
    /// than the kind claims, is not a pick and is answered as nothing chosen rather than acted on.
    func content(for answer: PickAnswer) -> [String: String] {
        guard let value = answer.value else { return [:] }
        let kind = answer.kind ?? self.kind
        guard sections.contains(where: { section in
            section.kind == kind && section.rows.contains { $0.value == value }
        }) else { return [:] }
        switch kind {
        case .account:
            return [mcpAccountField: value]
        case .model:
            var content = [mcpModelField: value]
            // An effort the row did not name stays ABSENT rather than empty, which is the third
            // state this axis has and the one the form expresses by leaving the field unfilled.
            if let effort = answer.effort { content[mcpEffortField] = effort }
            return content
        }
    }
}

/// How a tool asks. Injected all the way down so the pickers can be driven without a client.
typealias MCPAsk = (MCPPickOffer) -> MCPPickReply


// MARK: - What a chosen row does

/// Queue the model an answer names, or nil when it names none.
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
        return mcpBlockDecision(
            "\(mcpModelAutoValue) hands this session back to the layers below, so it cannot carry "
                + "an effort of its own; nothing was queued. Pick \(mcpModelAutoValue) on its own, "
                + "or a model with the effort you want")
    }
    let attempt = world.applyModel(intent, input)
    return mcpBlockDecision(mcpAttemptText(attempt.message, notes: attempt.notes))
}

/// Queue the move an answer names, or nil when it names none.
///
/// BY ID, not by name: the row already knows exactly which account it is, so the pick skips the
/// matcher entirely and cannot land on an account whose label merely shares a prefix.
func mcpQueueAccount(_ content: [String: String], input: MCPHookInput,
                     world: MCPPickerWorld) -> String? {
    guard let account = content[mcpAccountField] else { return nil }
    let attempt = world.applyAccount(account == switchAutoRequest ? .auto : .pinAccount(account),
                                     input)
    return mcpBlockDecision(mcpAttemptText(attempt.message, notes: attempt.notes))
}

/// WHATEVER WAS ANSWERED, applied. One answered palette can name either axis, so the two commands
/// share one way back in rather than each reading only for its own field: a `/tally` whose
/// person picked an account row must move the conversation, not report that nothing was chosen.
///
/// The two are told apart by the FIELD the answer arrived under, which is the shape `content(for:)`
/// already wrote by kind. An answer naming neither is nothing chosen, which is also what Escape,
/// a decline and an answer we could not read all come to.
func mcpQueuePick(_ content: [String: String], input: MCPHookInput,
                  world: MCPPickerWorld) -> String {
    mcpQueueAccount(content, input: input, world: world)
        ?? mcpQueueModel(content, input: input, world: world)
        ?? mcpBlockDecision(mcpNothingChanged)
}
