import Foundation

// `tally switch <account>` - move THIS conversation onto a named account, and the live pin switch it
// shares a shape with. Both are the same instruction from different surfaces ("run this session over
// there"), so they are decided in one place, in one order, with one rule about what happens when
// they disagree.
//
// The whole feature is assembled from parts that already existed: the request is a file a supervisor
// reads on its poll tick (ReloadRequest.swift's shape), the move is the cap handoff's relaunch with
// a target chosen by hand (`RelaunchPlan`), and the account name is resolved by the matcher
// `tally claude --account` and `tally project set --account` already share (AccountPick.swift). What
// is new is only the addressing: a reload speaks to EVERY session, this speaks to ONE.
//
// How a request reaches ONE session (the file, and the two ways a session is identified) is next
// door in SwitchRequest.swift; what a supervisor DOES about one is here.
//
// ONE-SHOT, deliberately. It moves this conversation now and changes nothing else: no pin is
// written, no project profile is touched, and once the session is over there, automatic handoff
// carries on exactly as before (a cap still moves it, a nearly dry account still rebalances it).
// "This project always runs on that account" is a different instruction with a home of its own,
// `tally project set --account`.

// MARK: - Supervisor-side decision

/// The quiet bar the moves in this file wait for: the short "no turn is streaming" gap
/// `tally reload --now` settles for, rather than the 120s "left alone" bar the preference changes
/// use. The user acted a second ago, so there is nothing to be careful about EXCEPT the turn in
/// flight. It is the bar the pin switch has always used (`isQuiet`'s own default), named here
/// because the switch has to use the same one and a shared bar should be one value, not two 5s.
///
/// And there almost always is one. The command's main caller is the agent inside the session,
/// running it as a tool call, so at the moment the request lands the session is by definition
/// mid-turn - the call itself is an unanswered `tool_use` and `TranscriptWatcher.isQuiet` reports
/// the session busy for exactly that reason (OpenTurn.swift). So the short bar shortens the IDLE
/// WAIT and nothing else: the turn that asked for the switch finishes, the assistant says what it
/// was going to say, and the move happens in the gap after it.
let manualMoveIdleSeconds = reloadNowIdleSeconds

/// What the fleet says about the account a request names, read at the tick that could act on it.
///
/// The distinction between the last two is the same one `pinnedAccountIsSignedOut` draws for a pin
/// (AccountPick.swift), and for a sharper reason here. An account id is derived from its config
/// home's name, so a removed `~/.claude3` that is recreated and logged into IS `claude:.claude3`
/// again (AccountRemovals.swift says so, and builds its tombstone expiry on it). A request held
/// against an id that has left the fleet is therefore not waiting for its account to come back: it
/// is waiting for ANY account to claim that name, and it would then resume the conversation onto a
/// login the user never named.
enum SwitchTargetState: Equatable {
    /// There and logged in.
    case launchable(Snapshot.Account)
    /// Listed with no launch home: Tally is publishing "this one is dormant", so the login is gone
    /// and the account is not. Waiting is exactly right - renewing it makes the switch happen.
    case signedOut
    /// This snapshot does not list the account at all. Tally publishes every account it discovers,
    /// so an id missing from a snapshot we can read is one that has left the fleet.
    case removed
    /// No snapshot to judge by (the app has not run, or the file is unreadable). Says nothing about
    /// the account, so it can only mean wait - reading it as "removed" would cancel every pending
    /// switch on the machine the moment the snapshot went missing.
    case unreadable

    /// The account to launch, when there is one. Both readers below want the same thing out of the
    /// launchable case, and neither wants to spell the pattern match to get it.
    var account: Snapshot.Account? {
        guard case .launchable(let account) = self else { return nil }
        return account
    }
}

/// Pure classification, so the three ways an account can fail to be launchable stay testable and
/// stay distinct. `accounts` is nil when there is no readable snapshot, which is NOT the same as an
/// empty one: an empty snapshot really does list no accounts.
func switchTargetState(_ accountID: String, provider: String,
                       accounts: [Snapshot.Account]?) -> SwitchTargetState {
    guard let accounts else { return .unreadable }
    let named = accounts.filter { $0.id == accountID && $0.provider == provider }
    guard !named.isEmpty else { return .removed }
    guard let launchable = named.first(where: { $0.launchHome != nil }) else { return .signedOut }
    return .launchable(launchable)
}

/// What one poll tick does about the switch request it just read.
enum SwitchDecision: Equatable {
    case none          // no request, or one this supervisor has already served
    case unavailable   // the account it names cannot be launched right now: hold it, and say so
    case cancelled     // the account it names has left the fleet: drop the request, and say why
    case alreadyThere  // the session is on that account already (a handoff got there first)
    case relaunch      // move now
    case queued        // the session is mid-turn: hold the request until it goes quiet
}

/// Pure decision, so the bookkeeping is testable without a child. A request fires exactly once (it
/// must be strictly newer than the stamp this supervisor captured at startup, which is what stops a
/// leftover file addressed to a REUSED pid from moving an unrelated session), and a busy session
/// holds it rather than losing it.
///
/// ORDER IS PART OF THE CONTRACT: what the target IS gets asked before whether the session is
/// quiet, because those are different waits and the badge has to name the right one.
///
/// A dormant or unknowable target is HELD: the wait is visible (the status line badge below), the
/// account coming back is a state the next tick simply reads, and dropping it would be a decision
/// made on the user's behalf about an instruction they gave by hand. A REMOVED one is cancelled
/// instead, and that is not a change of heart about holding: the id can be re-earned by a different
/// login (`SwitchTargetState`), so holding stops meaning "wait for that account" and starts meaning
/// "resume this conversation onto whoever takes the name next".
func switchDecision(served: Int, request: SwitchRequest, target: SwitchTargetState, onTarget: Bool,
                    isQuiet: Bool) -> SwitchDecision {
    guard request.epoch > served else { return .none }
    switch target {
    case .removed: return .cancelled
    case .signedOut, .unreadable: return .unavailable
    case .launchable:
        if onTarget { return .alreadyThere }
        return isQuiet ? .relaunch : .queued
    }
}

/// What the supervisor remembers about the moves its user has asked for by hand. Held across
/// relaunches, like the recovery fuse and the quarantine.
struct ManualMoveState {
    /// This session's address: the supervisor's own pid, the same key the request file is named for.
    let sessionKey: String
    /// The newest switch stamp this supervisor has served.
    var servedEpoch: Int
    /// The pin this session was moved OFF by hand, so the live pin switch below stops dragging it
    /// back. Scoped to that exact pin: moving the pin somewhere NEW in the panel afterwards is a
    /// fresh instruction and takes effect as it always did.
    var overriddenPin: String?
    /// Why a request is being held rather than served, for the status line's badge; nil when nothing
    /// is being held for a reason worth showing. Re-derived every tick from live state, like every
    /// other badge (PendingNotice.swift), so it disappears the moment the reason does.
    var waiting: PendingBadge?
    /// A request this supervisor CANCELLED, which is news rather than a state: the thing it
    /// describes is gone by the time it is read, so nothing re-derives it and it has to be held
    /// until something about switching happens again. Cleared by the next request (below) and
    /// carried no further than that.
    var cancelled: PendingBadge?

    /// The one badge the status line gets from this session's manual moves: a live wait outranks
    /// old news, because it is the thing that is still true.
    var badge: PendingBadge? { waiting ?? cancelled }

    /// `servedEpoch` defaults to whatever is pending right now, so a request written before this
    /// supervisor existed is never replayed (the file is addressed by pid, and pids come round
    /// again). A test supplies it directly, and so does the ONE caller for which that default is
    /// wrong: a self-update exec keeps the pid and IS the same session, so a request written
    /// moments before it was written for this conversation and would be swallowed by the seed
    /// (`resumed`, Supervisor.swift).
    ///
    /// `overriddenPin` is likewise handed over across that exec (`--pin-override`, SelfUpdate.swift):
    /// in memory only, and a new image that started without it would hand the session back to the
    /// pin its user had just moved it off.
    init(sessionKey: String, servedEpoch: Int? = nil, overriddenPin: String? = nil,
         dir: URL = switchRequestDir) {
        self.sessionKey = sessionKey
        self.servedEpoch = servedEpoch
            ?? (readSwitchRequest(sessionKey: sessionKey, dir: dir)?.epoch ?? 0)
        self.overriddenPin = overriddenPin
    }

    func pinOverridden(_ pinnedAccountID: String) -> Bool { pinnedAccountID == overriddenPin }
}

/// The bookkeeping a PLANNED switch owes, carried from the decision to the execution point and
/// written only once the relaunch is certain.
///
/// Recording it while planning is what the unresolved-fork hold turns into a lost request: the tick
/// stands the relaunch down, and a stamp already marked served makes every later tick read the
/// request as one it has handled (StandDown.swift, where a `tally reload` proved it). Nothing here
/// is undone on a stand-down because nothing has been written yet.
struct PendingSwitchConsumption {
    let epoch: Int
    let pinOverride: String?
    let dir: URL

    /// The file is unlinked only when it still holds the request that was SERVED. Between planning
    /// and here the child is terminated, and a second `tally switch` typed in that window overwrites
    /// the same path with a newer stamp: an unconditional unlink would delete an instruction nobody
    /// has carried out, and the millisecond stamps exist precisely so that two switches in quick
    /// succession are two switches. A newer stamp left on disk fires on the next tick, because
    /// `servedEpoch` records the epoch this consumption served rather than "whatever is pending".
    ///
    /// Not airtight, and knowingly so: a write landing between the read and the unlink is still
    /// lost. Closing that needs an atomic compare-and-unlink the filesystem does not offer for this
    /// shape, and the window shrinks from "the whole relaunch" (a child terminated, a transcript
    /// located and shared, a process spawned) to two syscalls.
    func commit(_ state: inout ManualMoveState) {
        state.servedEpoch = epoch
        state.overriddenPin = pinOverride
        state.waiting = nil
        if readSwitchRequest(sessionKey: state.sessionKey, dir: dir)?.epoch == epoch {
            clearSwitchRequest(sessionKey: state.sessionKey, dir: dir)
        }
    }
}

// MARK: - Poll-loop wiring

/// One poll tick's handling of the moves the user asked for by hand, in priority order: a
/// `tally switch` they just typed, then the pin they moved in the panel. Both are explicit human
/// acts, so neither counts against the recovery fuse, and both outrank every automatic reason to
/// move (cap, degradation, rebalance) by running first - the loop's later planners are all gated on
/// `plan == nil`.
///
/// The switch wins over the pin when they disagree, and keeps winning: it is the newer and the more
/// specific of the two ("move THIS conversation", against "new sessions go there"), and without the
/// override a pinned project would drag the session home on the very next tick, which is the one
/// outcome that would make the command useless to the person most likely to want it.
///
/// `accounts` is a closure because the snapshot read behind it is one most ticks do not need;
/// `request` is one because a default argument cannot name `state.sessionKey`, and the file it
/// reads is what every tick is polling for anyway. Both are also the seam that makes this testable
/// without a home directory or a snapshot.
func applyManualMoves(plan: inout RelaunchPlan?, state: inout ManualMoveState,
                      record: inout PendingSwitchConsumption?,
                      account: Snapshot.Account, providerID: String, policy: LaunchPolicy,
                      watcher: inout TranscriptWatcher, childAge: TimeInterval,
                      keyboardIdle: (TimeInterval) -> Bool,
                      dir: URL = switchRequestDir,
                      request: (String) -> SwitchRequest? = {
                          readSwitchRequest(sessionKey: $0)
                      },
                      accounts: @escaping () -> [Snapshot.Account]? = {
                          loadSnapshot().0?.accounts
                      }) {
    applySwitchRequest(plan: &plan, state: &state, record: &record, account: account,
                       providerID: providerID, policy: policy, watcher: &watcher,
                       childAge: childAge, keyboardIdle: keyboardIdle, dir: dir,
                       request: request(state.sessionKey), accounts: accounts)
    guard plan == nil else { return }
    applyPinSwitch(plan: &plan, state: state, account: account, providerID: providerID,
                   policy: policy, watcher: &watcher, keyboardIdle: keyboardIdle,
                   accounts: accounts)
}

/// The account an id names, when it is one this session could actually be launched on. Through the
/// same classifier the switch decision uses, so "launchable" means one thing here: the pin has no
/// use for WHY a target is unusable (it simply waits, as it always has), and asking the one question
/// twice in two shapes is how the two would come to disagree about it.
private func launchableAccount(_ id: String?, provider: String,
                               in accounts: () -> [Snapshot.Account]?) -> Snapshot.Account? {
    guard let id else { return nil }
    return switchTargetState(id, provider: provider, accounts: accounts()).account
}

/// The `tally switch` half. Consumes nothing on the branch that plans a relaunch (see
/// `PendingSwitchConsumption`); the two branches that plan NOTHING consume immediately, because
/// there is no execution point to hang the bookkeeping on and a request about a vanished account
/// would otherwise be re-read forever.
private func applySwitchRequest(plan: inout RelaunchPlan?, state: inout ManualMoveState,
                                record: inout PendingSwitchConsumption?,
                                account: Snapshot.Account, providerID: String,
                                policy: LaunchPolicy,
                                watcher: inout TranscriptWatcher, childAge: TimeInterval,
                                keyboardIdle: (TimeInterval) -> Bool,
                                dir: URL, request: SwitchRequest?,
                                accounts: () -> [Snapshot.Account]?) {
    // No request, or one this supervisor has already served. The staleness rule is answered here as
    // well as inside the decision below, because everything between costs a snapshot read and a
    // transcript tail: `isQuiet` locates and tails the file, which is not free per tick.
    guard let request, request.epoch > state.servedEpoch else { return }
    /// Consume without moving anything: whatever pin override stands, stands - nothing here took
    /// this session off a pin.
    func consume() {
        PendingSwitchConsumption(epoch: request.epoch, pinOverride: state.overriddenPin, dir: dir)
            .commit(&state)
    }
    // A request this supervisor has not served yet supersedes whatever was said about the last one:
    // the cancellation badge describes a request that no longer exists, and this is the moment it
    // stops being the news.
    state.cancelled = nil
    let target = switchTargetState(request.accountID, provider: providerID, accounts: accounts())
    let named = target.account
    let quiet = reloadQuiet(transcriptQuiet: watcher.isQuiet(manualMoveIdleSeconds),
                            hasTranscript: watcher.file != nil, childAge: childAge,
                            bar: manualMoveIdleSeconds,
                            keyboardQuiet: keyboardIdle(manualMoveIdleSeconds))
    switch switchDecision(served: state.servedEpoch, request: request, target: target,
                          onTarget: named?.id == account.id, isQuiet: quiet) {
    case .none, .queued:
        // Queued raises nothing at all: the wait is at most the rest of the turn that asked for the
        // switch, and what the person who typed it needs to know was printed by the command itself.
        // Nothing may be said on the TERMINAL either - the child is drawing this very turn there
        // (PendingNotice.swift: only a message that precedes a tear-down may use it).
        state.waiting = nil
    case .unavailable:
        // The one wait worth a badge: it can outlast the turn, and nobody has been told. Held rather
        // than announced for the same reason - the child is alive, so a line here would land in the
        // input box it is drawing. The badge is re-derived every tick, so it goes when the login
        // comes back, and the switch then happens on its own.
        state.waiting = PendingBadge(
            "switch: signed out",
            detail: "the account `tally switch` named has no login right now; staying on "
                + "\(account.label) until it is renewed")
    case .cancelled:
        // Not a wait, so not a `waiting` badge: there is nothing left to happen. An account id is
        // its config home's name, so holding this would eventually resume the conversation onto
        // whatever new login claims that name (`SwitchTargetState`).
        state.waiting = nil
        consume()
        state.cancelled = PendingBadge(
            "switch: account removed",
            detail: "the account `tally switch` named is no longer in the fleet, so the move was "
                + "cancelled rather than held for a different login with the same name")
    case .alreadyThere:
        consume()
    case .relaunch:
        guard let named else { return }
        warn("switching to \(named.label) as asked")
        plan = RelaunchPlan(target: named, reason: "switch", countsFuse: false)
        record = PendingSwitchConsumption(epoch: request.epoch,
                                          pinOverride: policy.pinnedAccountID, dir: dir)
    }
}

/// Live pin switch: pinning another account in the Tally panel moves the RUNNING session there. An
/// explicit human act, so no fuse; the pinned account is used even when capped (that is what pinning
/// means). Waits for a quiet transcript so an in-flight response is never cut mid-stream (the next
/// 2s poll retries) and a quiet keyboard so a prompt being typed survives too; both default to the
/// same 5s bar.
///
/// It stands down while the pin it names is the one a `tally switch` took this session off.
private func applyPinSwitch(plan: inout RelaunchPlan?, state: ManualMoveState,
                            account: Snapshot.Account, providerID: String, policy: LaunchPolicy,
                            watcher: inout TranscriptWatcher,
                            keyboardIdle: (TimeInterval) -> Bool,
                            accounts: () -> [Snapshot.Account]?) {
    guard policy.mode == "manual", let pinnedID = policy.pinnedAccountID, pinnedID != account.id,
          !state.pinOverridden(pinnedID), watcher.isQuiet(manualMoveIdleSeconds),
          keyboardIdle(manualMoveIdleSeconds),
          let target = launchableAccount(pinnedID, provider: providerID, in: accounts)
    else { return }
    warn("pinned in Tally → switching to \(target.label)")
    plan = RelaunchPlan(target: target, reason: "pin", countsFuse: false)
}

// MARK: - Asking for the move

/// What asking to move this session came to, decided but not yet said.
///
/// Split out of the command because there are now two surfaces asking the same question and they
/// must get the same answer: `tally switch` typed (or run as a tool call) inside the session, and
/// the `/tally-switch` prompt hook, which reports back without a model turn ever running
/// (SwitchHook.swift). One decision, one wording, two printers.
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

/// Resolve the account, find the session, and write the request. Everything the command does except
/// print, so both surfaces share it.
///
/// Unconfirmed, like `tally reload`: asking IS the intent. It returns as soon as the request is
/// written - the supervisor performs the move - so it never blocks the turn it was run in, which
/// matters because that turn has to END before the move can happen.
func attemptSwitch(name: String) -> SwitchAttempt {
    let (snapshot, problem) = loadSnapshot()
    var notes: [String] = []
    if let problem { notes.append(problem) }
    // Claude only for now, exactly as the supervisor is: codex launches are a plain exec with
    // nothing resident to act on a request.
    let provider = providers[0]
    guard let target = accountMatching(name, provider: provider.id, in: snapshot) else {
        return .refusal("no claude account matches \"\(name)\" - try `tally status`", notes: notes)
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
    if sessionAccountID(sessionKey: sessionKey, isThisSession: marker == sessionKey,
                        provider: provider, accounts: snapshot?.accounts ?? []) == target.id {
        return SwitchAttempt(result: .alreadyThere, message: "already on \(target.label)",
                             notes: notes)
    }
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
    if headroom(target) <= 0 {
        notes.append("\(target.label) is out of quota - switching anyway (you asked)")
    }
    sweepDeadSwitchRequests()
    do {
        try writeSwitchRequest(accountID: target.id, sessionKey: sessionKey)
    } catch {
        return .refusal("cannot write \(switchRequestFile(sessionKey: sessionKey).path): "
                            + "\(error.localizedDescription)",
                        notes: notes)
    }
    if honourability == .afterSelfUpdate {
        notes.append("this session runs a supervisor from another build: it replaces itself with "
            + "the installed one at the next idle moment, and the switch happens after that")
    }
    // The timing, spelled out, because the caller is usually an agent that has to relay it: the
    // move waits for the turn making this tool call to finish (OpenTurn.swift), so the session
    // stays exactly where it is until the answer is delivered, and comes back on the other account
    // with the conversation intact.
    return SwitchAttempt(
        result: .queued,
        message: "switch queued: this session moves to \(target.label) when the current turn ends, "
            + "and the conversation continues there",
        notes: notes)
}

// MARK: - CLI entry

/// `tally switch <account>`: move the session this command was run in onto the named account, at the
/// end of the turn that asked for it.
func runSwitch(args: [String]) -> Int32 {
    guard args.count == 1, let name = args.first, !name.hasPrefix("-") else {
        warn("usage: tally switch <account>   (label or config-dir name, as `tally status` lists " +
             "them). Moves THIS session to that account at the end of the current turn; to make a " +
             "project always launch there, use `tally project set --account`")
        return 2
    }
    let attempt = attemptSwitch(name: name)
    // The one line that answers the command goes to stdout when it worked, so a script can read it;
    // a refusal is stderr, like every other failure here. The notes are always stderr: they qualify
    // the answer rather than being it.
    if attempt.result == .refused { warn(attempt.message) } else { print(attempt.message) }
    for note in attempt.notes { warn(note) }
    return attempt.exitCode
}
