import Foundation

// Asking for the move: the CLI half of `tally switch`, split from SessionSwitch.swift (which keeps
// the supervisor-side decision) so neither file outgrows the size cap. The division is the one the
// feature already had: this side decides WHAT WAS ASKED and writes the request, that side decides
// what a poll tick does about one, and SwitchRequest.swift addresses it to a session.
//
// Two surfaces come through here and must get the same answer: `tally switch` typed (or run as a
// tool call) inside the session, and the `/tally-switch` prompt hook, which reports back without a
// model turn ever running (SwitchHook.swift).

/// What asking to move this session came to, decided but not yet said: one decision, one wording,
/// two printers (the header above names them).
struct SwitchAttempt: Equatable {
    enum Result: Equatable {
        /// A request is on disk; the supervisor performs the move at the next quiet moment.
        case queued
        /// The session is on that account already, which is not a failure and not a move.
        case alreadyThere
        /// Nothing was queued, and `message` says why.
        case refused
    }

    let result: Result
    /// The one sentence answering "what happened", written to stand ALONE: a surface with a single
    /// line to spend (the hook's stderr) shows this and nothing else.
    let message: String
    /// Worth saying alongside it, never instead of it: a snapshot problem, a drained target, a
    /// supervisor that has to replace itself before it can act.
    var notes: [String] = []

    var exitCode: Int32 { result == .refused ? 1 : 0 }

    /// Named because most of the ways `attemptSwitch` can end are this one: nothing was queued, and
    /// the sentence handed in says why.
    static func refusal(_ message: String, notes: [String]) -> SwitchAttempt {
        SwitchAttempt(result: .refused, message: message, notes: notes)
    }
}

/// What one invocation asks for. Two shapes, because the command has two: pin this session to an
/// account, or hand it back to automatic selection.
enum SwitchIntent: Equatable {
    case pin(String)
    case auto
}

/// The same attempt from a surface that has only a NAME to hand over: the `/tally-switch` hook
/// passes whatever followed the command straight through (SwitchHook.swift). The flag is recognised
/// here, so both surfaces answer `--auto` the same way and nobody has to keep two mappings in step -
/// and no account can be shadowed by it, since a label is matched against what `tally status` prints
/// and none of those starts with a dash.
func attemptSwitch(name: String) -> SwitchAttempt {
    attemptSwitch(name == switchAutoRequest ? .auto : .pin(name))
}

/// Resolve the account, find the session, and write the request. Everything the command does except
/// print, so both surfaces share it.
///
/// Unconfirmed, like `tally reload`: asking IS the intent. It returns as soon as the request is
/// written - the supervisor acts on it - so it never blocks the turn it was run in, which matters
/// because that turn has to END before the move can happen.
///
/// `--auto` goes through every step here except the account resolution: it addresses the same
/// session, needs the same supervisor to be listening, and is written to the same file (as the
/// reserved id `switchAutoRequest`). What it does NOT do is wait for a turn - it moves nothing.
func attemptSwitch(_ intent: SwitchIntent) -> SwitchAttempt {
    let (snapshot, problem) = loadSnapshot()
    var notes: [String] = []
    if let problem { notes.append(problem) }
    // Claude only for now, exactly as the supervisor is: codex launches are a plain exec with
    // nothing resident to act on a request.
    let provider = providers[0]
    // nil IS the release: everything below reads "no account named" as `--auto`, which keeps the
    // one difference between the two intents in one place instead of branching per step.
    let target: Snapshot.Account?
    switch intent {
    case .auto:
        target = nil
    case .pin(let name):
        guard let match = accountMatching(name, provider: provider.id, in: snapshot) else {
            return .refusal("no claude account matches \"\(name)\" - try `tally status`",
                            notes: notes)
        }
        target = match
    }
    let sessionKey: String
    let marker = liveSessionMarker()
    switch sessionLookup(envPid: marker,
                         here: supervisorsInDirectory(FileManager.default.currentDirectoryPath)) {
    case .session(let key):
        sessionKey = key
    case .none:
        return .refusal(
            "this session is not supervised, so there is nothing here to move it: it was launched "
                + "bare, with --no-handoff, or with an --account pin. Sessions started with "
                + "`tally claude` can be switched.",
            notes: notes)
    case .ambiguous(let pids):
        return .refusal(
            "\(pids.count) supervised sessions are running in this directory, so this command "
                + "cannot tell which one you mean (pids \(pids.joined(separator: ", "))). Run it "
                + "inside the session you want to move - or ask the agent in that session to run "
                + "it.",
            notes: notes)
    }
    // Already there? Asked of the SESSION being moved, not of this shell. The two are the same
    // process tree only on the main path; through the directory fallback the shell is somebody
    // else's terminal, and its `CLAUDE_CONFIG_DIR` describes whatever launched IT (often nothing at
    // all, which reads as the default home and would announce "already on <the default account>"
    // for a session running somewhere else entirely).
    //
    // It changes what is SAID and no longer whether anything is written, which is the sticky pin's
    // doing: the request still has to reach the supervisor, because the pin is the half of this
    // instruction that has not happened yet. Returning early here would make "pin me to the account
    // I am on" the one way to ask for a pin and not get one.
    let alreadyThere = target.map {
        sessionAccountID(sessionKey: sessionKey, isThisSession: marker == sessionKey,
                         provider: provider, accounts: snapshot?.accounts ?? []) == $0.id
    } ?? false
    // Whether anything will read the request, asked only when the session named ITSELF: the
    // environment carries that session's supervisor build, and a directory match carries nothing.
    let honourability = marker == nil ? SwitchHonourability.honoured
        : switchHonourability(supervisorVersion:
                                ProcessInfo.processInfo.environment["TALLY_SUPERVISOR_VERSION"],
                              installedVersion: supervisorBuildVersion())
    if honourability == .tooOld {
        return .refusal(
            "this session's supervisor predates `tally switch` and would never read the request, "
                + "so nothing was queued. Restart this session once (exit, then launch again with "
                + "`tally claude`) and it can be switched from then on.",
            notes: notes)
    }
    // Said, not refused: naming an account is an instruction, and its quota is the user's business
    // (the same reading a pin gets - `tally claude` launches a pinned account that is out too).
    if let target, headroom(target) <= 0 {
        notes.append("\(target.label) is out of quota - pinning anyway (you asked). A hard cap "
            + "still hands the session on, and clears the pin when it does")
    }
    sweepDeadSwitchRequests()
    do {
        try writeSwitchRequest(accountID: target?.id ?? switchAutoRequest, sessionKey: sessionKey)
    } catch {
        return .refusal("cannot write \(switchRequestFile(sessionKey: sessionKey).path): "
                            + "\(error.localizedDescription)",
                        notes: notes)
    }
    if honourability == .afterSelfUpdate {
        notes.append("this session runs a supervisor from another build: it replaces itself with "
            + "the installed one at the next idle moment, and the switch happens after that")
    }
    guard let target else {
        return SwitchAttempt(
            result: .queued,
            message: "session pin cleared: this session follows automatic account selection again "
                + "(this project's profile, then the app's pin or smart pick). It stays where it "
                + "is unless that selection says otherwise",
            notes: notes)
    }
    if alreadyThere {
        return SwitchAttempt(
            result: .alreadyThere,
            message: "already on \(target.label), and now pinned to it for this session - "
                + "automatic selection will not move it away. `tally switch --auto` to follow "
                + "again",
            notes: notes)
    }
    // The timing, spelled out, because the caller is usually an agent that has to relay it: the
    // move waits for the turn making this tool call to finish (OpenTurn.swift), so the session
    // stays exactly where it is until the answer is delivered, and comes back on the other account
    // with the conversation intact. What it does NOT wait for is the pin, which is the part that
    // makes the move stick past the next idle rebalance.
    return SwitchAttempt(
        result: .queued,
        message: "pinned this session to \(target.label), overriding automatic selection: it moves "
            + "there when the current turn ends and the conversation continues. It stays there "
            + "until a hard cap forces a move; `tally switch --auto` to follow automatic picks "
            + "again",
        notes: notes)
}

// MARK: - CLI entry

/// What a command line asks for, or nil when it asks for something this command cannot act on.
/// Pure, so the one rule worth stating - the two intents are MUTUALLY EXCLUSIVE - is testable.
///
/// Both together is refused rather than resolved: `tally switch --auto "Claude 4"` is one
/// instruction under either reading, the two readings are opposites (pin here / follow whatever the
/// fleet decides), and there is no answer that is safe to guess at. A bare invocation is refused for
/// the older reason: this command moves a live conversation, so it never acts on an empty argument.
func switchIntent(_ args: [String]) -> SwitchIntent? {
    let named = args.filter { $0 != switchAutoRequest }
    if args.contains(switchAutoRequest) { return named.isEmpty ? .auto : nil }
    // A leading dash is a flag this command does not have, never an account: labels are matched
    // case-insensitively against what `tally status` prints, and nothing there starts with one.
    guard named.count == 1, let name = named.first, !name.hasPrefix("-") else { return nil }
    return .pin(name)
}

/// `tally switch <account>`: pin the session this command was run in to the named account, moving it
/// there at the end of the turn that asked for it. `tally switch --auto` releases that pin.
func runSwitch(args: [String]) -> Int32 {
    guard let intent = switchIntent(args) else {
        warn("""
        usage: tally switch <account>   (label or config-dir name, as `tally status` lists them)
               tally switch --auto

        <account> pins THIS session there: it moves at the end of the current turn and STAYS,
        overriding automatic account selection for the rest of the session. Only a hard cap moves it
        after that, and that handoff clears the pin and says so.
        --auto releases the pin, handing the session back to automatic selection (this project's
        profile, then the app's pin or smart pick). It takes no account name.
        To make every launch in this project land on one account, use `tally project set --account`.
        """)
        return 2
    }
    let attempt = attemptSwitch(intent)
    // The one line that answers the command goes to stdout when it worked, so a script can read it;
    // a refusal is stderr, like every other failure here. The notes are always stderr: they qualify
    // the answer rather than being it.
    if attempt.result == .refused { warn(attempt.message) } else { print(attempt.message) }
    for note in attempt.notes { warn(note) }
    return attempt.exitCode
}
