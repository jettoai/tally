import Foundation

// THE MOMENT A LINE LANDS: the last thing that happens between a request clearing every gate and the
// bytes going onto the terminal.
//
// Split from SessionInput.swift, which keeps the gate table and the tick around it, along a seam
// that is about WHEN rather than about size: everything here runs at the one instant the decision
// has already been made, and nothing here decides whether to type. Two things need that instant.
//
//   - WHAT THE LINE COSTS. A `/clear` ends the conversation's context and takes the subagents it
//     dispatched with it, and how many those are is only true at the instant it lands: a roster read
//     when the request was written describes a session that has had minutes to change (a request now
//     waits up to `sessionInputQueuedLife`). Albert's rule stands unchanged - an agent running is
//     not a reason a window cannot be cleared - so this reports rather than refuses.
//   - THE PLACE THE NEXT PIECE OF WORK PLUGS IN. The clear-boundary account move (the second half of
//     this rework, ledger 2026-08-18) asks, at exactly this instant, whether the session about to be
//     cleared should be moved to a healthier account instead: a relaunch IS a clear, so a `/clear`
//     that is going to be typed is the cheapest moment in a session's life to leave a dying account.
//     That decision belongs in front of the injection below, and it is one function rather than a
//     branch buried in a switch so that the whole of the answer ("typed, or replaced instead") can
//     be returned from one place to the tick.

/// What became of a line that cleared every gate.
struct SessionInputLanding: Equatable {
    /// What the terminal made of it.
    var injection: SessionInputInjection
    /// The subagents this line ended, when it was a line that ends them, the count could be
    /// believed, and it was not zero. nil is "nothing to say", which covers all three: none were
    /// running, or this session's Claude Code does not publish a roll call
    /// (`SessionAgentsRecord.reportable` is fail-closed for the reason stated there, and inventing
    /// a number is exactly what it refuses), or nothing reached the terminal at all.
    ///
    /// ONE FIELD RATHER THAN A COUNT AND A SENTENCE: the receipt prints the sentence and the audit
    /// log records the number, and both are this one number read twice (`sessionInputAgentsNote`).
    var agents: Int?
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
    text.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map { $0 == "/clear" }
        ?? false
}

/// What a landing says about the agents it ended.
///
/// PAST TENSE, because that is what it is: this is written after the bytes are on the terminal, and
/// what it describes has already happened. A warning before the fact was weighed and refused - the
/// caller that would read it is the session being cleared, it wrote its hand-over before asking, and
/// a line it cannot act on at the moment it is typed is a line that would only teach it to hesitate.
///
/// It is only ever asked about a landing that ended some, since "nothing to say" is said by there
/// being no count at all (`SessionInputLanding.agents`) rather than by a sentence about zero.
func sessionInputAgentsNote(_ count: Int) -> String {
    "killed \(count) live agent\(count == 1 ? "" : "s")"
}

/// Type a line that has cleared every gate, and say what it cost.
///
/// `agents` and `inject` are injectable so a suite can drive this without a terminal and without a
/// roster on disk. The roster is read ONLY for a line that clears the context: every other send
/// leaves the agents where they are, and a file read per injection to report nothing is a cost with
/// no reader.
func landSessionInput(_ text: String, sessionKey: String,
                      agents: (String) -> Int? = { readSessionAgents(pid: $0)?.reportable },
                      inject: (String) -> SessionInputInjection) -> SessionInputLanding {
    // ASKED BEFORE THE BYTES rather than after them, and that is the whole of why it is here: the
    // roster this reports is the one the `/clear` is about to end, and by the time the injection
    // returns Claude Code has already begun tearing those agents down.
    let clearing = sessionInputClearsContext(text)
    let count = clearing ? agents(sessionKey) : nil
    let injection = inject(text)
    // Nothing is claimed about a line that never reached the terminal: a write the terminal refused
    // ended no agents. Nor about a roster of none, which is the ordinary send and has nothing to
    // report by definition.
    guard injection == .done, let count, count > 0 else {
        return SessionInputLanding(injection: injection, agents: nil)
    }
    return SessionInputLanding(injection: injection, agents: count)
}
