import Foundation

// CLOSING A WINDOW, WHICH IS A DIFFERENT ACT FROM TYPING THE WORDS `/clear`.
//
// WHY A VERB OF ITS OWN, and this is the decision to understand before changing anything here
// (Albert, 2026-08-18). `tally session send` is a public command of an open source product, and what
// it promises is a dumb pipe: the bytes you name are the bytes that are typed. The moment the
// supervisor starts reading that text and acting on what it FINDS in it - "this one says /clear, so
// I may restart the child on another account instead" - the pipe has stopped being dumb, and every
// external caller who types those six characters for their own reasons inherits an account decision
// nobody asked for. So the semantics live in a verb that exists to carry them. `send` never sets the
// field below; a `/clear` typed through it is typed, nothing more, and the existing window repick
// (WindowRepick.swift) remains its safety net exactly as before.
//
// WHAT THIS BUYS OVER THAT SAFETY NET. The repick arms on a `/clear` reaching the composer and then
// waits for Claude Code to report a different conversation, which is a fact channel and a good one -
// but the window it opens is 60 seconds, and a hand-over session is woken by its own next turn well
// inside that (a wake-on-handoff prompt lands seconds after the clear, and the arm is dropped the
// moment the window shows a turn). Measured on this machine 2026-08-18: a session whose account was
// at 10% of its five-hour window cleared and came back on the SAME account, which is the case the
// whole preventive family exists for - "the session that most needs moving is the one least likely
// to be moved". Deciding at the landing instead removes the race: nothing has to be observed
// afterwards, because the move is what closes the window.
//
// AND WHAT IT DELIBERATELY DOES NOT CHANGE: a manual `/clear` typed by a person, and a `/clear` sent
// through `session send`, still go through the repick. This adds a door, it does not replace one.

/// The intent a request carries when `tally session clear` wrote it.
///
/// A STRING ON THE REQUEST rather than a second directory or a flag on the wire: the channel is
/// additive-only by rule (`SessionInputRequest`), and a supervisor too old to know this field reads
/// the request as the plain send it is otherwise identical to - which types `/clear` and closes the
/// window the old way. Degrading to the previous behaviour is the whole reason the authority travels
/// as a field rather than as a different file.
let sessionClearIntent = "clear"

/// Whether this request may re-ask the account question at the moment it lands.
///
/// FOUR CONDITIONS, and each of them is a decision rather than a formality:
///
///   - IT CAME FROM THE CLEAR VERB. Nothing a `session send` writes can move an account, whatever
///     its text says (the header states why that boundary is the product's rather than this file's).
///   - THE TEXT REALLY CLOSES A WINDOW. The verb only ever writes `/clear`, so this is a check on a
///     document that any process running as this user can write: a forged request naming this intent
///     with some other text would otherwise get a relaunch out of a supervisor for free.
///   - THE SESSION IS NOT WAITING ON A PERSON. `blocked` means a prompt is on screen - a permission
///     request, a plan approval, a question - and a relaunch would answer it by destroying it, with
///     no trace for the person who was about to decide. Typing is safe there in a way that
///     restarting is not: a line that a prompt eats moves nothing, and the repick's "the id did not
///     change, so nothing happened" is the check that catches it (WindowRepick.swift). That
///     asymmetry is the reason this row exists - the safety of the typing path does not carry over
///     to a path that never types.
///   - NOBODY IS PROBABLY MID-DRAFT IN IT. The typing path protects a half-written prompt by moving
///     it into the composer's kill buffer and putting it back afterwards (SessionInputDraft.swift),
///     and that protection has no equivalent here for a structural reason: the kill buffer lives in
///     the child, and this ending is a SIGTERM. So a suspected draft sends the clear back down the
///     path that can save it, at the cost of clearing on the account it stands on. The account
///     question is preventive and comes round every time this session's window closes; the draft
///     does not come round at all.
func sessionClearMovesAccounts(request: SessionInputRequest, state: SupervisedState,
                               draft: SessionInputDraftGuard) -> Bool {
    request.intent == sessionClearIntent && sessionInputClearsContext(request.text)
        && state != .blocked && !draft.suspected
}

/// What the caller is told when the window was closed by moving the session instead of typing into
/// it. Pure, so the wording is assertable; `detail` on the receipt and the audit line share it.
///
/// IT NAMES THE ACCOUNT, because that is the one thing the reader cannot find out afterwards from
/// inside the session: the conversation that asked is gone by the time this is written, and what
/// comes up in its place is a fresh window on a machine with several accounts on it.
func sessionClearMovedDetail(to target: Snapshot.Account, agents: Int?) -> String {
    let killed = agents.map { ", " + sessionInputAgentsNote($0) } ?? ""
    return "reopened on \(target.label) instead of typing\(killed)"
}

/// The audit tag a clear-boundary relaunch is logged under. Its own name because two files read it
/// (the plan below, and anything grepping `~/.tally/handoff.log` for why a session moved).
let clearBoundaryReason = "clear-boundary"

/// The relaunch a decided move becomes, or nil when the landing typed instead.
///
/// FRESH AND FUSED, which is the whole of what this adds to the target the decision chose:
///
///   - `fresh`, because the request was a clear. A relaunch that resumed the conversation would
///     deliver the opposite of what was asked for, on a different account (`performHandoff`).
///   - `countsFuse`, on the same terms as every other automatic cross-account move: three per ten
///     minutes per session, after which a session being restarted again has a problem no move cures.
///
/// It says so on the terminal for the same reason the repick does: this is a restart the person in
/// front of it did not ask for, and an unexplained one reads as a crash.
func clearBoundaryPlan(_ moveTo: Snapshot.Account?, from: Snapshot.Account,
                       primaryModel: String?) -> RelaunchPlan? {
    guard let moveTo else { return nil }
    warn("window cleared on \(from.label), nearly dry: reopening on \(moveTo.label) "
        + "(\(pickReason(moveTo, primaryModel: primaryModel)))")
    return RelaunchPlan(target: moveTo, reason: clearBoundaryReason, countsFuse: true, fresh: true)
}

// MARK: - The command

/// Which session `tally session clear [--session <pid>]` is aimed at, or nil when the words are not
/// a request this command can act on.
///
/// NO TEXT ARGUMENT AT ALL, which is the grammar saying what the verb is: the line is `/clear` by
/// definition, so a word here is a caller who meant `session send` and would otherwise have their
/// text silently discarded. `--` is not honoured either, for the same reason - there is nothing it
/// could escape.
///
/// Returns a nested optional flattened into a struct rather than a bare `String??`: "no --session"
/// and "not a request" are different answers and a caller reading them off nil-ness would confuse
/// them.
struct SessionClearRequest: Equatable {
    /// A session named on the command line, or nil for the one this command runs in.
    var session: String?
}

func sessionClearRequest(_ args: [String]) -> SessionClearRequest? {
    var session: String?
    var index = args.startIndex
    while index < args.endIndex {
        let word = args[index]
        index += 1
        guard word == "--session" else { return nil }
        guard index < args.endIndex, session == nil else { return nil }
        session = args[index]
        index += 1
    }
    return SessionClearRequest(session: session)
}

/// `tally session clear [--session <pid>]`: close a session's context window, from inside it or from
/// another one.
///
/// EVERYTHING ABOUT QUEUEING, ADDRESSING, REFUSING AND WAITING IS THE SEND'S, called rather than
/// copied (`queueSessionLine`): one address per session, one line in flight at a time, queued is
/// success, refusals are immediate. What this verb adds is the intent field and the sentence that
/// explains the second ending.
func runSessionClear(args: [String]) -> Int32 {
    guard let request = sessionClearRequest(args) else {
        warn(sessionClearUsage)
        return 2
    }
    return queueSessionLine(SessionSendIntent(text: windowClearCommand, session: request.session),
                            requestIntent: sessionClearIntent)
}

let sessionClearUsage = """
usage: tally session clear [--session <pid>]

Closes a session's context window: the same `/clear` a person would type, queued on the same terms
as `tally session send` (queued is success, one line in flight per session, refusals are immediate),
and typed at the first quiet moment that session is out of its own turn.

WHAT IT DOES THAT TYPING CANNOT. At the moment the line lands, this asks the question a cleared
window makes free: if the account under the session is nearly dry and a sibling has room, the
session is REOPENED on that sibling instead - restarted with no context, which is what a clear is -
rather than cleared where it stands. Nothing is lost either way; the receipt and
~/.tally/logs/input.log say which of the two happened. It stays put when the account still has room,
when the session is pinned to an account, and when it is waiting on a person (a prompt on screen is
not something to restart away).

Use `tally session send "/clear"` for the plain act of typing those six characters, which is what an
external caller usually wants: nothing about the account is decided there.

Subagents do not hold it, and a clear that lands while they are running ends them, whichever ending
it takes; the log records how many.

Exit codes: 0 typed, or queued with nothing refusing it; 3 refused, and nothing was queued (the
reason is printed); 4 that session has exited; 1 something went wrong.
"""
