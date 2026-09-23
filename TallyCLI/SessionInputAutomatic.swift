import Foundation

// THE WRITERS NOBODY ASKED FOR: the gate they pass on top of the shared table, and the reading an
// input log line records beside whatever any writer typed.
//
// Split from SessionInput.swift on size. That file keeps the table every writer shares; this one
// holds the row only the automatic writers ask (the quota knock, the host-health knock, the cap
// resume and the limit reset), so a requested line can never be handed it by accident.

/// The gate every writer NOBODY ASKED FOR passes before it types: the shared table, then one row
/// of its own.
///
/// A LINE NOBODY ASKED FOR IS NEVER AN ANSWER. With a permission request, a plan approval or a
/// structured question on top of the composer, the first bytes typed close it or pick an option and
/// the rest become a prompt (issue #2: a host-health alert selected option 1 of an open question).
/// `sessionInputHold` lets `blocked` and `idle` through on purpose, because the requested line
/// exists partly to answer those dialogs, so the extra row lives here.
///
/// `dialogPossible` IS `SessionTick.dialogPossible`, NEVER `state == .blocked`: a soft
/// `idle_prompt` folds into `blocked` for every quiet session on a machine with the notification
/// hook installed, and holding on it would stop every automatic line there. It fails toward a hold:
/// an unknown notification type is hard, and a registry that cannot be read counts as a dialog.
///
/// THE SHARED TABLE COMES FIRST so its stated precedence is not reordered here; this row only
/// decides which word a hold carries when both apply.
func automaticSessionInputHold(state: SupervisedState, quiet: SessionQuiet, turnEnded: Bool,
                               keyboardIdle: Bool, relaunchPlanned: Bool,
                               dialogPossible: Bool) -> SessionInputHold? {
    if let hold = sessionInputHold(state: state, quiet: quiet, turnEnded: turnEnded,
                                   keyboardIdle: keyboardIdle, relaunchPlanned: relaunchPlanned) {
        return hold
    }
    return dialogPossible ? .dialog : nil
}

/// What an input log line records beside a line that went to a composer: the board's word, which
/// kind of wait stood behind it, and what Claude Code's registry said about a dialog. Three state
/// words, no text and nothing secret.
struct SessionInputSeen: Equatable {
    var state: SupervisedState
    var wait: UserWait?
    var registry: Bool?

    var fields: String {
        let waitWord: String
        switch wait {
        case .hard?: waitWord = "hard"
        case .soft?: waitWord = "soft"
        case nil: waitWord = "none"
        }
        let registryWord = registry.map { $0 ? "waiting" : "clear" } ?? "unread"
        return "state=\(state.rawValue) wait=\(waitWord) registry=\(registryWord)"
    }
}
