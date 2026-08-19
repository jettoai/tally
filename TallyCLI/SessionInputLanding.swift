import Foundation

// THE MOMENT A LINE LANDS: the last thing that happens between a request clearing every gate and the
// bytes going onto the terminal.
//
// Split from SessionInput.swift, which keeps the gate table and the tick around it, along a seam
// that is about WHEN rather than about size: everything here runs at the one instant the decision
// has already been made, and nothing here decides whether the line may be typed at all. Two things
// need that instant.
//
//   - WHAT THE LINE COSTS. A `/clear` ends the conversation's context and takes the subagents it
//     dispatched with it, and how many those are is only true at the instant it lands: a roster read
//     when the request was written describes a session that has had minutes to change (a request now
//     waits up to `sessionInputQueuedLife`). Albert's rule stands unchanged - an agent running is
//     not a reason a window cannot be cleared - so this reports rather than refuses.
//   - WHETHER THE WINDOW SHOULD CLOSE HERE OR SOMEWHERE ELSE. A `tally session clear` may be
//     answered by restarting the child on a healthier account rather than by typing anything, and
//     this is the instant that question has to be asked: a relaunch IS a clear, so the cheapest
//     moment in a session's life to leave a dying account is the moment it was going to be emptied
//     anyway (SessionClear.swift owns the rule, this file owns the timing).
//
// SO THE TWO ANSWERS ARE ONE TYPE, and the caller cannot get one without having considered the
// other: a landing either typed something or moved the session, never both and never neither.

/// What one landing came to.
enum SessionInputLanding: Equatable {
    /// The bytes went to the terminal, and this is what it made of them.
    case typed(SessionInputInjection, agents: Int?)
    /// Nothing was typed: the window is being closed by moving this session to that account, and
    /// the agents named went with the child that is about to be replaced.
    case moved(Snapshot.Account, agents: Int?)

    /// The subagents this landing ended, when it ended any worth reporting. nil is "nothing to say",
    /// which covers all of its causes: none were running, this session's Claude Code does not
    /// publish a roll call (`SessionAgentsRecord.reportable` is fail-closed for the reason stated
    /// there, and inventing a number is exactly what it refuses), or nothing happened at all
    /// because the terminal refused the write.
    ///
    /// ONE NUMBER RATHER THAN A NUMBER AND A SENTENCE: the receipt prints the sentence and the audit
    /// log records the number, and both are this read twice (`sessionInputAgentsNote`).
    var agents: Int? {
        switch self {
        case .typed(let injection, let agents): return injection == .done ? agents : nil
        case .moved(_, let agents): return agents
        }
    }
}

/// Whether this line clears the conversation's context.
///
/// THE FIRST WORD ONLY, and compared rather than searched for: `/clear` is a slash command Claude
/// Code runs, so it is the whole of what the composer is given, while a line that merely MENTIONS
/// it ("say /clear when you are done") is a prompt and ends nothing. Leading whitespace is trimmed
/// because a caller quoting a line in a shell can leave some; anything after the word is left alone,
/// since a future `/clear <something>` is still a clear.
///
/// `/compact` IS NOT ONE, deliberately, and it is the near miss worth naming: it rewrites the
/// context and keeps the conversation, so the agents under it are not ended and a note saying they
/// were would be a lie about the one thing this reports.
func sessionInputClearsContext(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespaces).split(separator: " ").first
        .map { $0 == windowClearCommand } ?? false
}

/// What a landing says about the agents it ended.
///
/// PAST TENSE, because that is what it is: this is written after the bytes are on the terminal (or
/// after the move that replaces the child has been decided), and what it describes has already
/// happened. A warning before the fact was weighed and refused - the caller that would read it is
/// the session being cleared, it wrote its hand-over before asking, and a line it cannot act on at
/// the moment it is typed is a line that would only teach it to hesitate.
///
/// It is only ever asked about a landing that ended some, since "nothing to say" is said by there
/// being no count at all (`SessionInputLanding.agents`) rather than by a sentence about zero.
func sessionInputAgentsNote(_ count: Int) -> String {
    "killed \(count) live agent\(count == 1 ? "" : "s")"
}

/// Carry out a request that has cleared every gate: type it, or close its window by moving the
/// session instead.
///
/// THE ORDER INSIDE IS THE WHOLE OF THE CORRECTNESS. The roster is read FIRST, because both endings
/// destroy the thing it counts - the `/clear` tears the agents down, and so does the SIGTERM behind
/// a move - so a count taken afterwards is a count of what survived. The boundary question is asked
/// SECOND, before anything reaches the terminal, because its whole point is to type nothing.
///
/// `draft` IS CARRIED THROUGH RATHER THAN DECIDED HERE, and it reaches both endings for different
/// reasons: the typing one hands it to the writer, which stashes the composer and puts it back
/// (SessionInputDraft.swift), and the moving one is REFUSED by it - a session that may be holding an
/// unsent draft is not restarted away from it, because a SIGTERM takes the kill buffer with the
/// child and there is nothing left to restore (`sessionClearMovesAccounts`).
///
/// `agents`, `boundary` and `inject` are injectable so a suite can drive every ending without a
/// terminal, a roster on disk or a snapshot. The roster is read ONLY for a line that clears the
/// context, and the boundary is asked ONLY for a request that carries the authority to move
/// accounts: every other send is a file read and a decision this does not make.
func landSessionInput(_ request: SessionInputRequest, sessionKey: String, state: SupervisedState,
                      draft: SessionInputDraftGuard,
                      agents: (String) -> Int? = { readSessionAgents(pid: $0)?.reportable },
                      boundary: () -> Snapshot.Account? = { nil },
                      inject: (String, SessionInputDraftGuard) -> SessionInputInjection)
    -> SessionInputLanding {
    let clearing = sessionInputClearsContext(request.text)
    // Read before either ending, and normalised here so both of them report it the same way: a
    // roster of none and a roster that cannot be believed are one answer, "nothing to say".
    let count = clearing ? agents(sessionKey).flatMap({ $0 > 0 ? $0 : nil }) : nil
    if sessionClearMovesAccounts(request: request, state: state, draft: draft),
       let target = boundary() {
        return .moved(target, agents: count)
    }
    return .typed(inject(request.text, draft), agents: count)
}
