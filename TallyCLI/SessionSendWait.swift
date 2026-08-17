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

/// How long to wait for the supervisor's answer.
///
/// LONGER THAN THE REQUEST'S OWN LIFE (`sessionInputTTL`, 120s) on purpose: the supervisor answers
/// every request it reads, including by refusing an expired one, so the wait has to outlast the
/// thing it is waiting for or it would time out on requests that were about to be answered. The
/// margin is a poll tick's worth of slack many times over.
let sessionInputWaitSeconds: TimeInterval = 150

/// How long a caller waits for a line into ITS OWN session, which is a different question with a
/// different answer.
///
/// SIX SECONDS RATHER THAN 150, and the reason is a deadlock rather than a preference. A command run
/// inside a conversation runs as a tool call, and a tool call that has not returned is an OPEN TURN:
/// the supervisor reads that turn in the transcript and (rightly) refuses to type into a session
/// that is mid-turn, so a caller blocking until the turn ends is blocking on itself. Measured on
/// this machine 2026-08-17: three self-sends held their own tool call for 120.2s each and were
/// killed by Claude Code's own timeout, and two thirds of every send in the preceding day expired
/// unserved (`~/.tally/logs/input.log`).
///
/// What the six seconds still buy, since the honest answer would otherwise be zero: a session that
/// is ALREADY blocked or idle when the request lands is served on the next 2s tick, which is the
/// case a send run from a background task hits. That answer arrives inside this window and is
/// reported exactly as any other. Past it, the command says the line is queued and returns, which
/// is what lets the turn end - and the turn ending is the very thing the line is waiting for.
let sessionInputSelfWaitSeconds: TimeInterval = 6

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
    /// Nobody answered inside the time this caller was willing to give it.
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

/// The line a caller prints as it settles in to wait for another session, so a wait of up to two and
/// a half minutes is never a silence.
///
/// STDERR, like every other progress note here: the one line on stdout is the answer, and a script
/// reading this command's output must not have to filter progress out of it. `doing` is what that
/// session's own supervisor last published about it (`SessionStateRecord.state`), which is the
/// single most useful thing to say here - "working" tells the caller the wait is a turn ending, and
/// "unknown" tells it the wait may well end in a refusal.
func sessionInputWaitingLine(sessionKey: String, doing: String?, timeout: TimeInterval) -> String {
    let state = doing.map { " (it is \($0) right now)" } ?? ""
    return "queued for session \(sessionKey)\(state); waiting up to \(Int(timeout))s for it to be "
        + "typed"
}

/// What a caller sending into its OWN session is told when the short wait ends with no answer.
///
/// IT IS NOT A FAILURE AND IT DOES NOT PRETEND TO BE A DELIVERY. The line is on disk, addressed,
/// and the supervisor types it at the first quiet moment after this turn ends - which is what the
/// caller wanted and cannot be told about, because being told would mean still being here, and
/// still being here is what keeps the turn open (`sessionInputSelfWaitSeconds` carries the
/// measurement). So the sentence says exactly that, names the one condition that can still lose it,
/// and names the file that records what became of it.
func sessionInputQueuedMessage(sessionKey: String) -> String {
    "queued for session \(sessionKey): it is typed at the first quiet moment after this turn ends, "
        + "so nothing here waits for it - waiting would hold the turn open and the line would never "
        + "be typed. It is dropped if this turn has not ended within \(Int(sessionInputTTL))s; "
        + "either way ~/.tally/logs/input.log records what became of it"
}

/// What a caller waiting on ANOTHER session is told when nobody answered in time. The request is
/// still on disk, so the sentence says where it is and what the plausible reasons are.
func sessionInputTimeoutMessage(sessionKey: String, path: String, timeout: TimeInterval) -> String {
    "session \(sessionKey) has not answered in \(Int(timeout))s. The request is still at \(path); "
        + "its supervisor may be mid-restart, or running a build that does not read it yet"
}
