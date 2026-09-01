import Foundation

// Asking for the move: the CLI half of `tally switch`, split from SessionSwitch.swift (which keeps
// the supervisor-side decision) so neither file outgrows the size cap. The division is the one the
// feature already had: this side decides WHAT WAS ASKED and writes the request, that side decides
// what a poll tick does about one, and SwitchRequest.swift addresses it to a session.
//
// Two surfaces come through here and must get the same answer: `tally switch` typed (or run as a
// tool call) inside the session, and the `/tally-account` prompt hook, which reports back without a
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

/// What one invocation asks for. Three shapes for two instructions, because a target can arrive
/// already resolved: pin this session to an account NAMED (a query to match against the fleet), pin
/// it to an account IDENTIFIED (a row the user selected, which needs no matching), or hand it back
/// to automatic selection.
///
/// The middle one is not a convenience. `accountMatching` answers a NAME, which may be ambiguous and
/// is then refused; a caller that already knows exactly which account it means has nothing to gain
/// from that and something to lose to it (`switchMenuPick`, SwitchMenu.swift, states both halves).
/// An id cannot go through the matcher at all either: an id is `<provider>:<config-dir name>` while
/// the matcher compares the label and the config dir's own name, neither of which carries the
/// provider prefix - so "just pass the id instead" would have matched nothing.
enum SwitchIntent: Equatable {
    case pin(String)
    case pinAccount(String)
    case auto
}

/// The same attempt from a surface that has only a NAME to hand over: the `/tally-account` hook
/// passes whatever followed the command straight through (SwitchHook.swift). The flag is recognised
/// here, so both surfaces answer `--auto` the same way and nobody has to keep two mappings in step -
/// and no account can be shadowed by it, since a label is matched against what `tally status` prints
/// and none of those starts with a dash.
func attemptSwitch(name: String, cwd: String = FileManager.default.currentDirectoryPath,
                   marker: SessionMarkerTrust = .trusted(liveSessionMarker())) -> SwitchAttempt {
    attemptSwitch(name == switchAutoRequest ? .auto : .pin(name), cwd: cwd, marker: marker)
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
///
/// `cwd` identifies the session, and is this process's own directory for every surface a person
/// types into. It is a parameter for the MCP server behind the native picker (MCPServe.swift),
/// which is a long-lived child of Claude Code and so has to be told which directory the prompt came
/// from rather than reading its own.
func attemptSwitch(_ intent: SwitchIntent,
                   cwd: String = FileManager.default.currentDirectoryPath,
                   marker: SessionMarkerTrust = .trusted(liveSessionMarker())) -> SwitchAttempt {
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
        switch accountMatching(name, provider: provider.id, in: snapshot) {
        case .one(let match):
            target = match
        case .none:
            return .refusal("no claude account matches \"\(name)\" - try `tally status`",
                            notes: notes)
        case .several(let candidates):
            // Nothing is queued and nothing is guessed. This command MOVES a live conversation, so
            // acting on the first of several accounts that merely contain the word is the failure
            // the exact stages exist to prevent - and it would report success while doing it.
            return .refusal(accountMatchAmbiguity(name, provider: provider.id,
                                                  candidates: candidates), notes: notes)
        }
    case .pinAccount(let id):
        // By id, exactly, and with a launch home: the caller picked this account off a listing of
        // the fleet, so there is nothing to match and nothing to guess. The snapshot is read again
        // here (the menu read its own), so the account can have gone in between - said plainly
        // rather than falling back to the name, which is the very step this case exists to skip.
        guard let match = snapshot?.accounts.first(where: {
            $0.id == id && $0.provider == provider.id && $0.launchHome != nil
        }) else {
            return .refusal("the account that row named (\(id)) is not in the fleet snapshot any "
                                + "more - try `tally status`", notes: notes)
        }
        target = match
    }
    let sessionKey: String
    switch marker.resolve(here: supervisorsInDirectory(cwd)) {
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
    // The marker as the resolution ACTUALLY used it, nil when the directory answered instead. A
    // corroborated marker that was dropped describes some other session, so neither the "am I
    // inside it" question below nor the supervisor-version check may be answered from it
    // (`SessionMarkerTrust.adopted`, SwitchRequest.swift).
    let adopted = marker.adopted(sessionKey)
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
        sessionAccountID(sessionKey: sessionKey, isThisSession: adopted != nil,
                         provider: provider, accounts: snapshot?.accounts ?? []) == $0.id
    } ?? false
    // Whether anything will read the request (SwitchRequest.swift states when it can be judged).
    let honourability = liveRequestHonourability(marker: adopted)
    if honourability == .tooOld {
        return .refusal(
            "this session's supervisor predates `tally account` and would never read the request, "
                + "so nothing was queued. Restart this session once (exit, then launch again with "
                + "`tally claude`) and it can be switched from then on.",
            notes: notes)
    }
    // Said, not refused: naming an account is an instruction, and its quota is the user's business
    // (the same reading a pin gets - `tally claude` launches a pinned account that is out too).
    if let target, headroom(target) <= 0 {
        notes.append("\(target.label) is out of quota - pinning anyway (you asked). A hard cap "
            + "drops the session to the declared fallback model there, and hands it on (clearing "
            + "the pin) when this account cannot comfortably serve any of them, or when a `tally "
            + "model` pin outranks the change. Short of that it waits: about two minutes for a "
            + "fresh reading of this account, and for as long as it takes if Tally has stopped "
            + "publishing the snapshot or its own pin leaves this session nowhere to go")
    }
    sweepDeadSessionRequests(dir: switchRequestDir)
    do {
        // The conversation this was typed into, when the surface knows it: a hook and the native
        // picker are told by Claude Code, a person's shell is not. It is what lets the supervisor
        // act on a session that has just been `/clear`ed instead of holding the request until the
        // session ends (RequestTranscript.swift states the deadlock in full).
        try writeSwitchRequest(accountID: target?.id ?? switchAutoRequest, sessionKey: sessionKey,
                               transcriptID: marker.promptTranscriptID)
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
        // WHAT THE RELEASE ACTUALLY DID, read rather than assumed. The reading is the session's own
        // published one, which is the only place a pin this command did not set is visible from
        // here (SessionContext.swift).
        let reading = readSessionContext(pid: sessionKey)
        return SwitchAttempt(
            result: .queued,
            message: switchReleaseMessage(
                hadSessionPin: reading.map { $0.sessionPin != nil },
                scope: reading?.pinScope.flatMap(SessionPinScope.init(rawValue:))),
            notes: notes)
    }
    if alreadyThere {
        return SwitchAttempt(
            result: .alreadyThere,
            message: "already on \(target.label), and now pinned to it for this session - "
                + "automatic selection will not move it away. `tally account --auto` to follow "
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
            + "until a hard cap forces a move; `tally account --auto` to follow automatic picks "
            + "again",
        notes: notes)
}

/// What `tally account --auto` says it did, which used to be one sentence for three situations.
///
/// THE SENTENCE THAT WAS WRONG (owner report, 2026-09-01): "session pin cleared" was printed
/// whether or not there was a pin to clear. Run in a session that had never been pinned it
/// announced an event that did not happen, and run in a session held by a PROJECT profile or by the
/// app's own pin it was worse than untrue - it said the pin was gone while the session went on
/// being held, by a scope this command does not reach.
///
/// `hadSessionPin` is nil when it cannot be read at all: a session that has not published a reading
/// yet (no turn with usage in it). Said as "cannot tell" rather than guessed, because both guesses
/// are a sentence about the user's own instruction.
///
/// The request is written on every one of these branches regardless. `--auto` is idempotent, and a
/// session with no pin consumes it as the no-op it is (`SwitchDecision.unpin`); what changes here is
/// only what the person is told.
func switchReleaseMessage(hadSessionPin: Bool?, scope: SessionPinScope?) -> String {
    let follows = "automatic account selection (this project's profile, then the app's pin or "
        + "smart pick)"
    guard let hadSessionPin else {
        return "following \(follows) from now on. Whether this session carried a pin of its own "
            + "cannot be read yet - it has published no reading - so nothing here says one was "
            + "cleared"
    }
    if hadSessionPin {
        return "session pin cleared: this session follows \(follows) again. It stays where it is "
            + "unless that selection says otherwise"
    }
    switch scope {
    case .project:
        return "nothing to clear: this session had no pin of its own. It is on this account "
            + "because this project's profile pins it - `tally project set --account auto` here is "
            + "what releases that"
    case .fleet:
        return "nothing to clear: this session had no pin of its own. It is on this account "
            + "because the app's own pin holds the whole fleet there - unpin in Settings, Accounts"
    case .session, .none:
        return "nothing to clear: this session had no pin of its own and was already following "
            + "\(follows). It stays where it is unless that selection says otherwise"
    }
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

/// Which of the command's three surfaces an invocation lands on.
enum SwitchEntry: Equatable {
    /// A name (or `--auto`) was given: do it, do not ask.
    case act(SwitchIntent)
    /// Bare, with a terminal to draw on: offer the fleet.
    case menu
    /// Bare in a pipe, or arguments this command cannot act on.
    case usage
}

/// Whether a bare invocation may open the arrow-key menu: a human at the keyboard AND a terminal to
/// answer on. BOTH, because either alone is a pipeline blocked on a keypress nobody will make.
///
/// Named for the menu rather than for this command: `tally model` asks the identical question of the
/// identical pair of file descriptors (ModelCommand.swift), and the answer must not be allowed to
/// differ between two commands a user types in the same shell.
///
/// `tally switch | cat`, run from an interactive shell, still has a tty on stdin - so a stdin-only
/// test opened the menu, drew it on /dev/tty (which is not the pipe, so the reader sees nothing) and
/// waited. Reading stdout is how `shouldSupervise` decides the same kind of question
/// (LaunchFlags.swift), for the same reason it gives: the redirection is a property of the shell
/// line rather than of anything the user typed, so it is invisible unless it is asked about.
func menuIsAvailable(stdinIsTTY: Bool, stdoutIsTTY: Bool) -> Bool {
    stdinIsTTY && stdoutIsTTY
}

/// The routing, pure, so it is testable without a terminal: the menu needs one, and "does a script
/// still get the usage text" is exactly the question a test has to be able to ask.
///
/// `interactive` is `menuIsAvailable` above. A pipeline gets what it has always got, because a
/// script that suddenly meets an arrow-key menu hangs.
func switchEntry(_ args: [String], interactive: Bool) -> SwitchEntry {
    if let intent = switchIntent(args) { return .act(intent) }
    // Only a TRULY bare invocation opens the menu. `--auto "Claude 4"` and a two-name line are
    // refusals with something to say (`switchIntent`), and answering them with a menu would hide
    // the mistake instead of naming it.
    return args.isEmpty && interactive ? .menu : .usage
}

/// `tally switch <account>`: pin the session this command was run in to the named account, moving it
/// there at the end of the turn that asked for it. `tally switch --auto` releases that pin. Bare, in
/// a terminal, it asks (SwitchMenu.swift).
func runSwitch(args: [String]) -> Int32 {
    let chosen: SwitchIntent?
    switch switchEntry(args, interactive: menuIsAvailable(
        stdinIsTTY: isatty(STDIN_FILENO) == 1, stdoutIsTTY: isatty(STDOUT_FILENO) == 1)) {
    case .act(let intent):
        chosen = intent
    case .menu:
        switch pickSwitchTarget() {
        // The id the chosen row carried, not its label: the pick is already unambiguous
        // (`switchMenuPick`, SwitchMenu.swift).
        case .picked(let id): chosen = .pinAccount(id)
        case .cancelled: return 1        // they said no; saying it back to them adds nothing
        case .unavailable: chosen = nil  // no menu to draw: the usage text says what to type
        }
    case .usage:
        chosen = nil
    }
    guard let intent = chosen else {
        warn("""
        usage: tally account <account>   (label or config-dir name, as `tally status` lists them)
               tally account --auto

        <account> pins THIS session there: it moves at the end of the current turn and STAYS,
        overriding automatic account selection for the rest of the session. A hard cap is answered
        inside that decision where it can be: the session keeps the account and drops to the
        fallback model Settings declares, provided this account can still serve one COMFORTABLY (a
        window with a few percent left does not count). Otherwise it is handed on, which clears the
        pin and says so - unless `tally model` has pinned the model too (that pin wins: the model is
        kept, the account is not), or the numbers to decide on are missing, in which case it waits:
        about two minutes for a fresh reading of this account, and for as long as it takes if Tally
        has stopped publishing the snapshot or its own pin leaves this session nowhere to go.
        --auto releases the pin, handing the session back to automatic selection (this project's
        profile, then the app's pin or smart pick). It takes no account name.
        Run it bare in a terminal and it lists the fleet to pick from with the arrow keys; in a pipe
        (or with nothing to list) you get this text instead.
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
