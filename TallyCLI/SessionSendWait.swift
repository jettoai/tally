import Foundation

// WHAT THE CALLER DOES WHILE ITS LINE IS ON ITS WAY, and what it is told when it is not.
//
// Split from SessionInputCommand.swift, which keeps the grammar, the addressing and the order of
// business; this is the half that runs after the request is on disk. Every wording here is a pure
// function for the same reason the ones next door are: nothing can call `runSessionSend` in a suite
// without writing into the developer's own live conversation, so what CAN be asserted is every
// sentence it prints and every code it exits on.
//
// THE ONE RULE THIS FILE EXISTS TO KEEP (Albert, 2026-08-17): a caller either gets its line
// delivered, or is told why not, promptly. It may wait for a turn to end - that is what the whole
// feature is for - but it may not sit in silence for minutes and then be told nothing useful. The
// two shapes that broke that rule are answered here: a wait whose end is already decided (the
// supervisor is gone), and a wait that CANNOT end because the caller is the reason it cannot.
//
// QUEUEING IS THE ANSWER, WAITING IS THE EXCEPTION (2026-08-18). Both halves of this command used to
// be built around collecting a delivery report, and a request now waits for its session up to
// `sessionInputQueuedLife` - so a caller that stayed for the report would be a caller sitting on a
// line that is doing exactly what it should. Every caller therefore leaves after a short grace with
// `queued` and exit 0, and what became of the line is recorded rather than returned
// (`~/.tally/logs/input.log`).

/// How long an answer nobody said anything about is somebody's to collect.
///
/// A COMPATIBILITY FALLBACK RATHER THAN A WAIT ANYBODY MAKES, since the rework above: a request
/// written by a CLI that predates `SessionInputRequest.waitSeconds` says nothing about how long its
/// caller will be there, and 150s is what every answer was charged before that field existed. It is
/// deliberately the longest number here, because the failure it avoids is one-sided - an answer
/// judged too short is deleted out from under a caller still polling for it, while one judged too
/// long only holds the address until it expires.
let sessionInputWaitSeconds: TimeInterval = 150

/// How long a caller stays for an answer before it says the line is queued and leaves.
///
/// SIX SECONDS, and the reason it is not 150 is a deadlock rather than a preference. A command run
/// inside a conversation runs as a tool call, and a tool call that has not returned is an OPEN TURN:
/// the supervisor reads that turn in the transcript and (rightly) refuses to type into a session
/// that is mid-turn, so a caller blocking until the turn ends is blocking on itself. Measured on
/// this machine 2026-08-17: three self-sends held their own tool call for 120.2s each and were
/// killed by Claude Code's own timeout, and two thirds of every send in the preceding day expired
/// unserved (`~/.tally/logs/input.log`).
///
/// THE SAME NUMBER FOR A SEND INTO ANOTHER SESSION, which it was not before. That caller is not
/// holding anything open, so waiting was free for it - but what it would now be waiting for is a
/// line that may legitimately sit queued for a quarter of an hour, and a wait that ends in "nobody
/// answered" about a request that is alive and pending is the same lie this rework removed from the
/// supervisor's side.
///
/// What the six seconds still buy, since the honest answer would otherwise be zero: a session that
/// is ALREADY blocked or idle when the request lands is served on the next 2s tick, which is the
/// case a send from a background task or from another session hits. That answer arrives inside this
/// window and is reported exactly as any other.
let sessionInputGraceSeconds: TimeInterval = 6

/// How often to look for it. A quarter second is well inside the 2s tick that writes it, so the
/// answer is read within one interval of being published.
let sessionInputPollInterval: TimeInterval = 0.25

/// How a wait ended, in the three ways that want different things said and different codes returned.
enum SessionInputAnswer: Equatable {
    /// The supervisor answered. Whether that answer is a delivery or a refusal is the result's own
    /// business.
    case answered(SessionInputResult)
    /// It will never be answered, and this is why. Distinct from a timeout because the two are
    /// opposite advice: a timeout may mean "it is still coming", this means "stop waiting".
    case abandoned(String)
    /// Nobody answered inside the grace this caller gives it, which is the ordinary ending rather
    /// than a failure: the request is queued and the caller says so and leaves.
    case timedOut
}

/// Wait for the answer to this request.
///
/// Matched on the EPOCH, which is the whole reason a result carries one: a husk from an earlier
/// request can still be sitting at that path (a caller killed mid-wait, a wait that timed out), and
/// reading somebody else's outcome as this one's is a fire-and-forget channel's one silent failure.
///
/// `abandon` IS ASKED ON EVERY PASS, and it is what turns one class of silent timeout into a prompt
/// failure: the only thing that ever writes an answer is that session's supervisor, so a supervisor
/// that has exited is a wait with a known ending. Answering the question early costs one `kill(pid,
/// 0)` per quarter second and saves the caller up to 150 seconds of waiting for a process that is
/// not there. It defaults to "carry on", so a caller that has nothing to check for stays as it was.
///
/// The clock and the reads are injectable so the suite can exercise every ending without spending
/// one.
func awaitSessionInputResult(sessionKey: String, epoch: Int, timeout: TimeInterval,
                             interval: TimeInterval = sessionInputPollInterval,
                             now: () -> Date = Date.init,
                             sleep: (TimeInterval) -> Void = { usleep(useconds_t($0 * 1_000_000)) },
                             abandon: () -> String? = { nil },
                             read: (String) -> SessionInputResult? = {
                                 readSessionInputResult(sessionKey: $0)
                             }) -> SessionInputAnswer {
    let deadline = now().addingTimeInterval(timeout)
    while true {
        if let result = read(sessionKey), result.epoch == epoch { return .answered(result) }
        // AFTER the read, never before it: a supervisor that wrote the answer and then exited has
        // answered, and asking about the process first would throw that answer away in favour of a
        // sentence about a pid.
        if let why = abandon() { return .abandoned(why) }
        guard now() < deadline else { return .timedOut }
        sleep(interval)
    }
}

/// Why a wait for THIS session cannot be waited out, or nil when it can be.
///
/// Its own function so the sentence and the condition cannot drift, and so the suite can assert both
/// without a supervisor: `alive` is injected, the default is the same registry reader every other
/// per-session channel uses.
///
/// IT DOES NOT SAY THE LINE WAS NOT TYPED, and that restraint is the whole wording. A supervisor
/// types the bytes and writes the receipt afterwards (`applySessionInput`), so one that died
/// between the two leaves a terminal that HAS the line and an address with no answer on it - which
/// is indistinguishable from here from one that died before reading the request at all. Telling the
/// caller nothing was typed invites the retry that puts the line in twice, which is the one failure
/// this channel has always been built to avoid (codex review of 0c9798b). What the caller is given
/// instead is the file that does know.
func sessionInputAbandonment(sessionKey: String,
                             alive: (pid_t) -> Bool = { supervisorAlive($0) }) -> String? {
    guard let pid = pid_t(sessionKey), !alive(pid) else { return nil }
    return "session \(sessionKey) has exited, so nothing will ever answer the line queued for it. "
        + "Whether it was typed first is unknown from here: the supervisor types before it writes "
        + "the receipt. Read ~/.tally/logs/input.log rather than sending it again"
}

// MARK: - What the caller is told, and what it exits on

// MOVED HERE FROM SessionInputCommand.swift (2026-08-18), which is over the size a file in
// this repo may be: these two are the sentence and the code one ANSWER comes to, which is this
// file's subject, while that one keeps the grammar and the order of business.

/// What to tell the caller about an answer. Pure, so every wording is assertable.
///
/// An outcome this build does not recognise is REPORTED VERBATIM rather than flattened into a
/// generic failure: a CLI one version behind a supervisor is exactly the case where the word itself
/// is the only information there is.
func sessionInputMessage(_ result: SessionInputResult, sessionKey: String) -> String {
    // Appended to EVERY wording, the successes included. A delivery does not normally carry one, but
    // a supervisor from a later build may say something alongside an outcome this one already
    // understands, and dropping it because the news was good is how a channel loses exactly the
    // sentence somebody added for a reason.
    let detail = result.detail.map { " (\($0))" } ?? ""
    switch result.resolved {
    case .submitted: return "sent to session \(sessionKey)\(detail)"
    case .refusedTooLong: return "refused: too long\(detail)"
    case .refusedNotReporting:
        return "refused: session \(sessionKey) never reported what it was doing, so nothing was "
            + "typed into it\(detail)"
    case .refusedExpired:
        return "refused: session \(sessionKey) never reached a moment this could be typed at"
            + "\(detail)"
    case .failedTTY: return "failed: the session's terminal refused the write\(detail)"
    case nil: return "the supervisor answered \"\(result.outcome)\"\(detail)"
    }
}

/// The exit code one run ends on, for the one ending that has an answer to read: 0 it landed, 3 it
/// was refused with a reason. The other two are decided by the run itself - 4 the session is gone,
/// 1 something here broke - and usage errors are 2, as everywhere else in this binary.
///
/// A QUEUED LINE EXITS 0 WITHOUT A RESULT, which is the one thing this code says that no
/// `SessionInputResult` can: since 2026-08-18 every caller leaves after a short grace, so "did it
/// land" is normally unanswerable from where the caller stands (`sessionInputGraceSeconds`). Exit 0
/// therefore means "typed, or queued with nothing refusing it", and the line printed says which. A
/// code of its own was weighed and refused: every caller of this is a hand-over that reads non-zero
/// as "fall back to doing it by hand", and a queued line is not a failure to fall back from.
func sessionInputExitCode(_ result: SessionInputResult) -> Int32 {
    result.delivered ? 0 : 3
}

/// What a caller is told when the grace ends with no answer: the line is queued.
///
/// IT IS NOT A FAILURE AND IT DOES NOT PRETEND TO BE A DELIVERY, which is the whole of the wording.
/// The line is on disk, addressed, and the supervisor types it at the first quiet moment the session
/// is out of its turn - which is what the caller wanted and, for a caller inside that session,
/// cannot be told about: being told would mean still being here, and still being here is what keeps
/// the turn open (`sessionInputGraceSeconds` carries the measurement). So the sentence says exactly
/// that, names the one condition that can still lose it, and names the file that records what became
/// of it.
///
/// ONE SENTENCE FOR BOTH CALLERS, where there were two (a progress note before a long wait, and a
/// queued line after a short one). They now do the same thing, and `doing` is what the second of
/// those carried that this needed: what that session's own supervisor last published about it
/// (`SessionStateRecord.state`), which is the single most useful thing to say here - "working" tells
/// the caller its line is behind a turn, "idle" that the next tick should take it.
func sessionInputQueuedMessage(sessionKey: String, doing: String? = nil) -> String {
    let state = doing.map { " (it is \($0) right now)" } ?? ""
    return "queued for session \(sessionKey)\(state): it is typed at the first quiet moment that "
        + "session is out of its own turn, so nothing here waits for it - waiting from inside that "
        + "session would hold the turn open and the line would never be typed. It is dropped if no "
        + "such moment arrives within \(Int(sessionInputQueuedLife))s; either way "
        + "~/.tally/logs/input.log records what became of it"
}
