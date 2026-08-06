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
// door in SwitchRequest.swift, the command that writes one is in SwitchCommand.swift, and what one
// tick DECIDES about a request - purely, from the fleet and the disk - is in SwitchDecision.swift.
// What a supervisor DOES about that decision, against live state, is here.
//
// STICKY FOR THE SESSION, deliberately. It moves this conversation now AND pins it: the account it
// names is where this session stays, across every relaunch that follows (a self-update, a reload, a
// safeguard restore), until the user says otherwise. Naming an account is an instruction, and an
// instruction that quota reasoning may undo a minute later is not one - the session was moved back
// off the named account by the very next idle rebalance, which is the behaviour this replaced
// (owner report, 2026-08-06).
//
// So the three scopes are ordered, the same way the model axis already orders them: THIS SESSION's
// pin (here) > this project's profile (`tally project set --account`) > the fleet's own pin or
// smart pick (the app). The mechanism is one line - a session pin is presented to the rest of the
// poll loop AS a pin (`sessionPolicy` below) - so every gate that already yields to a pinned
// account yields to this one without being taught anything new.
//
// TWO WAYS OUT, and only two. `tally switch --auto` releases it, which is the user changing their
// mind. And a hard cap moves the session anyway, because a pinned session that cannot answer is
// worse than one that moved: that handoff CLEARS the pin and says so (`pinClearedByCap`), so the
// session does not silently drift back later. A nearly dry account is not a cap and does not
// qualify - the whole point of naming an account is that its quota is the user's business.
//
// "This project always runs on that account" is still a different instruction with a home of its
// own, `tally project set --account`: this one dies with the session, that one outlives it.

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

/// What the supervisor remembers about the moves its user has asked for by hand. Held across
/// relaunches, like the recovery fuse and the quarantine.
struct ManualMoveState {
    /// This session's address: the supervisor's own pid, the same key the request file is named for.
    let sessionKey: String
    /// The newest switch stamp this supervisor has served.
    var servedEpoch: Int
    /// The account a `tally switch` pinned THIS session to, for as long as the session lasts: the
    /// sticky half of the command (see the header). nil means automatic selection is in charge,
    /// which is where every session starts and where `tally switch --auto` puts it back.
    var sessionPin: String?
    /// LEGACY, and only ever handed in: the pin a session was moved off by a supervisor from a
    /// build before the pin above existed, carried across that build's self-update exec
    /// (`--pin-override`, SelfUpdate.swift). Nothing in this build writes it - a switch now records
    /// `sessionPin`, which outranks every pin rather than just the one it overrode - but a session
    /// upgrading mid-life arrives holding one, and dropping it would hand that session straight
    /// back to the pin its user had moved it off, minutes later, for no reason they can see.
    var overriddenPin: String?
    /// Why a request is being held rather than served, for the status line's badge; nil when nothing
    /// is being held for a reason worth showing. Re-derived every tick from live state, like every
    /// other badge (PendingNotice.swift), so it disappears the moment the reason does.
    var waiting: PendingBadge?
    /// A request this supervisor CANCELLED, which is news rather than a state: the thing it
    /// describes is gone by the time it is read, so nothing re-derives it and it has to be HELD.
    ///
    /// Which is exactly why it needs an end of its own. Every other badge on this track disappears
    /// when its condition does; this one has no condition left to watch, so until it was given the
    /// bound below it simply stayed - a "switch: account removed" was still on the status line long
    /// after the account was back, outliving even the app update that replaced the supervisor
    /// (2026-08-06; the file that carried it across that exec is PendingNotice.swift's half of the
    /// same report).
    var cancelled: PendingBadge?
    /// When that news was raised, so it can stop being news. nil whenever `cancelled` is.
    var cancelledAt: Date?

    /// The one badge the status line gets from this session's manual moves: a live wait outranks
    /// old news, because it is the thing that is still true.
    var badge: PendingBadge? { waiting ?? cancelled }

    /// The cancellation notice has been READ, so it stops being shown: the user has said something
    /// themselves since it was raised.
    ///
    /// THE USER, not the session. The obvious signal is the one the cap recovery uses - an assistant
    /// event newer than the thing being cleared (CapDetection.swift) - and it is wrong here for a
    /// reason specific to this command: `tally switch` is normally run BY the agent, as a tool call,
    /// from inside a turn. A tool call is followed by its result and by more assistant events within
    /// that same turn, so "an assistant event happened since" is true a second or two after the
    /// notice is raised, and the notice would come down while the user is still reading the answer
    /// it belongs to - never seen, which is the whole thing it exists to be (caught in review,
    /// 2026-08-06). Their next prompt is the first moment they demonstrably have.
    ///
    /// A prompt rather than a timer for the same reason a timer was refused before: it would expire
    /// unread on a session nobody is watching, and linger on one being worked in.
    ///
    /// `lastUserTurnAt` is per CHILD, so a relaunch resets it to nil: a notice that outlives a
    /// restart then waits for the first prompt after it, which is the same promise measured from
    /// the same place.
    mutating func expireCancellation(lastUserTurnAt: Date?) {
        guard let cancelledAt, let lastUserTurnAt, lastUserTurnAt > cancelledAt else { return }
        cancelled = nil
        self.cancelledAt = nil
    }

    /// Pick a cancellation notice back up off disk, which is how it survives a self-update.
    ///
    /// The exec keeps the pid and starts this state from nothing, so the notice the replaced image
    /// had just raised exists only in `<pid>.notice` - and the seeded writer's first honest "nothing
    /// is pending" would unlink it (PendingNotice.swift). The file carries everything needed to put
    /// it back, including WHEN it was raised (`since`), so the expiry measures from the original
    /// moment rather than from the upgrade.
    ///
    /// Only a cancellation is adopted. Every other badge on this track is re-derived from live state
    /// within a tick or two of the new image starting, so adopting those would be picking up a value
    /// that is about to be recomputed anyway - and picking up a stale one if the condition has since
    /// cleared.
    mutating func adoptCancellation(_ notice: PendingNotice?) {
        guard let notice, notice.kind == cancellationNoticeKind else { return }
        cancelled = PendingBadge(notice.badge, detail: notice.detail, kind: notice.kind)
        cancelledAt = notice.since
    }

    /// `servedEpoch` defaults to whatever is pending right now, so a request written before this
    /// supervisor existed is never replayed (the file is addressed by pid, and pids come round
    /// again). A test supplies it directly, and so does the ONE caller for which that default is
    /// wrong: a self-update exec keeps the pid and IS the same session, so a request written
    /// moments before it was written for this conversation and would be swallowed by the seed
    /// (`resumed`, Supervisor.swift).
    ///
    /// `sessionPin` is likewise handed over across that exec (`--session-pin`, SelfUpdate.swift),
    /// and so is `overriddenPin` before it (`--pin-override`): both are promises about the user's
    /// SESSION rather than about this process, and a new image that started without them would undo
    /// by itself an instruction the user gave by hand.
    init(sessionKey: String, servedEpoch: Int? = nil, sessionPin: String? = nil,
         overriddenPin: String? = nil, dir: URL = switchRequestDir) {
        self.sessionKey = sessionKey
        self.servedEpoch = servedEpoch
            ?? (readSwitchRequest(sessionKey: sessionKey, dir: dir)?.epoch ?? 0)
        self.sessionPin = sessionPin
        self.overriddenPin = overriddenPin
    }

    func pinOverridden(_ pinnedAccountID: String) -> Bool { pinnedAccountID == overriddenPin }

    /// A relaunch is about to happen for `reason`: whether it is the one move allowed past the
    /// session pin, which therefore ends it. True exactly once per pin, and the pin is gone by the
    /// time this returns - the caller's only job is to SAY so (`sessionPinClearedByCapNotice`) and
    /// to name the audit line accordingly.
    ///
    /// The cap alone. Every other automatic mover is prevented from planning anything at all while
    /// a pin stands (`sessionPolicy`), so nothing else can reach here holding one; a cap can,
    /// because a session that cannot answer is worse than a session that moved. Clearing rather
    /// than remembering is what stops the pin from dragging the conversation back to a capped
    /// account on the next quiet tick.
    mutating func pinClearedByCap(_ reason: String) -> Bool {
        guard reason == "cap", sessionPin != nil else { return false }
        sessionPin = nil
        return true
    }
}

/// What the user is told when a cap takes a pinned session anyway. A constant because it is the one
/// sentence tying the two halves of that decision together (the move happened, the pin is gone), and
/// a copy of it drifting in a test would assert nothing.
let sessionPinClearedByCapNotice =
    "session pin cleared (cap hit); re-pin with `tally switch <account>` once quota is back"

/// The bookkeeping a PLANNED switch owes, carried from the decision to the execution point and
/// written only once the relaunch is certain.
///
/// Recording it while planning is what the unresolved-fork hold turns into a lost request: the tick
/// stands the relaunch down, and a stamp already marked served makes every later tick read the
/// request as one it has handled (StandDown.swift, where a `tally reload` proved it). Nothing here
/// is undone on a stand-down because nothing has been written yet.
struct PendingSwitchConsumption {
    let epoch: Int
    /// Where the session pin stands once this request has been served: the account it named, or nil
    /// for a `--auto` that released it. A branch that changes nothing about the pin passes what is
    /// already there.
    let sessionPin: String?
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
        state.sessionPin = sessionPin
        state.waiting = nil
        if readSwitchRequest(sessionKey: state.sessionKey, dir: dir)?.epoch == epoch {
            clearSwitchRequest(sessionKey: state.sessionKey, dir: dir)
        }
    }
}

// MARK: - What the rest of the loop sees

/// The launch policy this SESSION runs under: the one the loop already assembles (the app's, with
/// this project's profile over it) with the session pin over that.
///
/// A session pin is presented as a manual pin because it IS one, at a third scope - "this
/// conversation runs there", against the project's "this repo runs there" and the app's "this fleet
/// runs there". Expressing it as the pin the whole CLI already understands is what makes every
/// consequence follow without teaching anything: the idle rebalance leaves a pinned account alone
/// (Rebalance.swift), the degradation rescue does too (ModelDegradation.swift), the reload's repick
/// is the rebalance so it does as well, and a launch-default follow adopts the new model ON this
/// account instead of re-picking one (FollowAdoption.swift). Exactly the same reasoning
/// `effectivePolicy` uses for a project account (ProjectPolicy.swift), one scope down.
///
/// `pinnedHome` goes with it for that same reason: it is a denormalised path the APP wrote beside
/// the account IT pinned, and carrying it under a different account's id would name the wrong
/// config dir.
///
/// THE ONE READER THAT MUST NOT USE THIS is the cap handoff, which is asked against the fleet's
/// policy through `capReading` (CapDetection.swift, beside the handoff that is its only caller): a
/// capped session that cannot answer is worse than one that moved, so the cap is allowed past and
/// takes the pin with it (`pinClearedByCap`).
func sessionPolicy(_ policy: LaunchPolicy, sessionPin: String?) -> LaunchPolicy {
    guard let sessionPin else { return policy }
    var pinned = policy
    pinned.mode = "manual"
    pinned.pinnedAccountID = sessionPin
    pinned.pinnedHome = nil
    return pinned
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
/// pin it leaves behind a pinned project would drag the session home on the very next tick, which
/// is the one outcome that would make the command useless to the person most likely to want it.
///
/// `policy` COMES IN as the fleet's (the app's, with this project's profile over it) and GOES OUT as
/// this session's, because the pin can change inside this call and every mover after it is judged by
/// the pin the session has NOW.
///
/// That is a fix, not a convenience. A request that plans no relaunch still records a pin the moment
/// it is consumed - naming the account the session is already on is exactly that - so a policy
/// derived before this call says "unpinned" while the state says "pinned to A". The degradation
/// rescue or the idle rebalance would then move the session off A on that same tick, and because
/// nothing but a cap ever clears a pin, every later tick would refuse to move it back: the pin and
/// the account it names would disagree for the rest of the session. Deriving it here means no caller
/// can hold the stale reading, because there is no moment at which one exists.
///
/// `accounts` is a closure because the snapshot read behind it is one most ticks do not need;
/// `request` is one because a default argument cannot name `state.sessionKey`, and the file it
/// reads is what every tick is polling for anyway. Both are also the seam that makes this testable
/// without a home directory or a snapshot.
func applyManualMoves(plan: inout RelaunchPlan?, state: inout ManualMoveState,
                      record: inout PendingSwitchConsumption?, policy: inout LaunchPolicy,
                      account: Snapshot.Account, providerID: String,
                      watcher: inout TranscriptWatcher, childAge: TimeInterval,
                      keyboardIdle: (TimeInterval) -> Bool,
                      dir: URL = switchRequestDir,
                      request: (String) -> SwitchRequest? = {
                          readSwitchRequest(sessionKey: $0)
                      },
                      accounts: @escaping () -> [Snapshot.Account]? = {
                          loadSnapshot().0?.accounts
                      },
                      homeOnDisk: @escaping (String, String) -> Bool = {
                          accountHomeExists($0, provider: $1)
                      },
                      now: Date = Date()) {
    let fleet = policy
    // Before anything else this tick, and on every tick rather than only the ones with a request:
    // the cancellation notice is the one badge here that nothing re-derives, so the tick that takes
    // it down has to be a tick that runs anyway (`expireCancellation`). The watcher has already
    // scanned this tick's new lines by the time the loop reaches this call (`observeCapHit` runs
    // first, Supervisor.swift), so the prompt that ends it is seen on the tick it lands.
    state.expireCancellation(lastUserTurnAt: watcher.lastUserTurnAt)
    applySwitchRequest(plan: &plan, state: &state, record: &record, account: account,
                       providerID: providerID, watcher: &watcher,
                       childAge: childAge, keyboardIdle: keyboardIdle, dir: dir,
                       request: request(state.sessionKey), accounts: accounts,
                       homeOnDisk: homeOnDisk, now: now)
    policy = sessionPolicy(fleet, sessionPin: state.sessionPin)
    guard plan == nil else { return }
    // The FLEET's policy, deliberately: this half is about the pin moved in the panel, and the
    // session's own pin reaches it as the stand-down inside it rather than as a pin to follow.
    applyPinSwitch(plan: &plan, state: state, account: account, providerID: providerID,
                   policy: fleet, watcher: &watcher, keyboardIdle: keyboardIdle,
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

/// What a held switch says on the status line: one badge per REASON the move has not happened, and
/// they are kept apart because the reader can only act on one of them.
///
/// A dormant account is theirs to renew, and the badge says so. An account the fleet has momentarily
/// stopped listing is Tally's to notice again and needs nothing from them. A snapshot that cannot be
/// read at all is a third thing again - the app is not running, or its file is unreadable - and until
/// this existed all three said "signed out", which sends someone to re-authenticate a login that was
/// never the problem.
///
/// `staying` is the account the session remains on meanwhile, named in every detail line because the
/// question behind the badge is always "so where am I right now".
///
/// The two states that are not waits answer nil: a launchable target is not held, and a removed one
/// is cancelled rather than held (a `cancelled` badge, which is news rather than a state).
func switchWaitBadge(_ target: SwitchTargetState, staying: String) -> PendingBadge? {
    switch target {
    case .signedOut:
        return PendingBadge("switch: signed out",
                            detail: "the account `tally switch` named has no login right now; "
                                + "staying on \(staying) until it is renewed")
    case .unlisted:
        return PendingBadge("switch: not listed",
                            detail: "the account `tally switch` named is not in the current fleet "
                                + "snapshot, though its config home is still on disk; staying on "
                                + "\(staying) until Tally lists it again")
    case .unreadable:
        return PendingBadge("switch: no snapshot",
                            detail: "there is no fleet snapshot to find that account in - is "
                                + "Tally.app running? - so the move is held; staying on \(staying) "
                                + "until one can be read")
    case .launchable, .removed:
        return nil
    }
}

/// The `tally switch` half. Consumes nothing on the branch that plans a relaunch (see
/// `PendingSwitchConsumption`); the three that plan NOTHING (removed account, already there,
/// released pin) consume immediately, because there is no execution point to hang the bookkeeping
/// on and an unserved request would otherwise be re-read forever.
private func applySwitchRequest(plan: inout RelaunchPlan?, state: inout ManualMoveState,
                                record: inout PendingSwitchConsumption?,
                                account: Snapshot.Account, providerID: String,
                                watcher: inout TranscriptWatcher, childAge: TimeInterval,
                                keyboardIdle: (TimeInterval) -> Bool,
                                dir: URL, request: SwitchRequest?,
                                accounts: () -> [Snapshot.Account]?,
                                homeOnDisk: (String, String) -> Bool, now: Date) {
    // No request, or one this supervisor has already served. The staleness rule is answered here as
    // well as inside the decision below, because everything between costs a snapshot read and a
    // transcript tail: `isQuiet` locates and tails the file, which is not free per tick.
    guard let request, request.epoch > state.servedEpoch else { return }
    /// Consume the request, leaving the session pin wherever `pin` puts it. The default is "leave
    /// it alone", which is what the branches that changed nothing about where this session runs
    /// want; the two that decided something about the pin say so.
    func consume(pin: String?) {
        PendingSwitchConsumption(epoch: request.epoch, sessionPin: pin, dir: dir).commit(&state)
    }
    // A request this supervisor has not served yet supersedes whatever was said about the last one:
    // the cancellation badge describes a request that no longer exists, and this is the moment it
    // stops being the news. Its stamp goes with it, so nothing is left for the expiry to compare
    // against a turn that has not happened yet.
    state.cancelled = nil
    state.cancelledAt = nil
    let target = switchTargetState(request.accountID, provider: providerID, accounts: accounts(),
                                   homeOnDisk: homeOnDisk)
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
        // input box it is drawing. The badge is re-derived every tick, so it goes when the account
        // comes back, and the switch then happens on its own.
        //
        // Which wait it is comes from the target, because the three are not the same news to the
        // person reading them (`switchWaitBadge`).
        state.waiting = switchWaitBadge(target, staying: account.label)
    case .cancelled:
        // Not a wait, so not a `waiting` badge: there is nothing left to happen. An account id is
        // its config home's name, so holding this would eventually resume the conversation onto
        // whatever new login claims that name (`SwitchTargetState`). Reached only once the fleet AND
        // the disk agree the account is gone - a snapshot alone cannot cancel anything.
        state.waiting = nil
        consume(pin: state.sessionPin)
        state.cancelledAt = now
        state.cancelled = PendingBadge(
            "switch: account removed",
            detail: "the account `tally switch` named is no longer in the fleet, so the move was "
                + "cancelled rather than held for a different login with the same name",
            kind: cancellationNoticeKind)
    case .alreadyThere:
        // A handoff got there first, or the user named the account they are already on. Either way
        // the instruction was "run this session there", and the pin is the half of it that has not
        // happened yet - without this, `tally switch <the account I am on>` would be the one way to
        // ask for a pin and not get one.
        consume(pin: named?.id ?? state.sessionPin)
    case .unpin:
        // `tally switch --auto`: automatic selection is in charge again from this tick on. Nothing
        // is relaunched and nothing is said - the session stays exactly where it is, which is what
        // the command that wrote this already told the person who ran it.
        //
        // The legacy override goes with the pin, and it has to: a session that upgraded out of an
        // older build carries one (`overriddenPin`), and it makes `applyPinSwitch` refuse the fleet
        // pin all by itself. Leaving it behind would mean this command said "following automatic
        // selection again" and then went on ignoring the one instruction that selection has.
        state.waiting = nil
        state.overriddenPin = nil
        consume(pin: nil)
    case .relaunch:
        guard let named else { return }
        warn("switching to \(named.label) as asked, and staying there until you say otherwise")
        plan = RelaunchPlan(target: named, reason: "switch", countsFuse: false)
        record = PendingSwitchConsumption(epoch: request.epoch, sessionPin: named.id, dir: dir)
    }
}

/// Live pin switch: pinning another account in the Tally panel moves the RUNNING session there. An
/// explicit human act, so no fuse; the pinned account is used even when capped (that is what pinning
/// means). Waits for a quiet transcript so an in-flight response is never cut mid-stream (the next
/// 2s poll retries) and a quiet keyboard so a prompt being typed survives too; both default to the
/// same 5s bar.
///
/// It stands down entirely while this session carries a pin of its own: the session scope outranks
/// the fleet scope, so a panel pin moved after a `tally switch` is a change to where NEW sessions
/// go, not an instruction to drag this conversation somewhere its user just moved it off. (The
/// legacy `overriddenPin` says the same thing about a narrower case, for a session that upgraded
/// mid-life out of a build that only had that.)
private func applyPinSwitch(plan: inout RelaunchPlan?, state: ManualMoveState,
                            account: Snapshot.Account, providerID: String, policy: LaunchPolicy,
                            watcher: inout TranscriptWatcher,
                            keyboardIdle: (TimeInterval) -> Bool,
                            accounts: () -> [Snapshot.Account]?) {
    guard state.sessionPin == nil,
          policy.mode == "manual", let pinnedID = policy.pinnedAccountID, pinnedID != account.id,
          !state.pinOverridden(pinnedID), watcher.isQuiet(manualMoveIdleSeconds),
          keyboardIdle(manualMoveIdleSeconds),
          let target = launchableAccount(pinnedID, provider: providerID, in: accounts)
    else { return }
    warn("pinned in Tally → switching to \(target.label)")
    plan = RelaunchPlan(target: target, reason: "pin", countsFuse: false)
}

