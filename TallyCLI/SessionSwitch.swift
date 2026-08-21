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
// door in SwitchRequest.swift, the command that writes one is in SwitchCommand.swift, what one tick
// DECIDES about a request - purely, from the fleet and the disk - is in SwitchDecision.swift, and
// what the session carries between ticks is in ManualMoveState.swift. What a supervisor DOES about
// that decision, against live state, is here.
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
// THREE WAYS OUT, and only three. `tally switch --auto` releases it, which is the user changing
// their mind. A hard cap moves the session anyway, because a pinned session that cannot answer is
// worse than one that moved. And the account running out ENTIRELY releases it to the preventive
// movers, which is the same sentence one step earlier: a pin names the account this conversation
// belongs on, not an instruction to sit on an empty one (DroughtWatch.swift, 2026-08-21). All
// three that MOVE the session clear the pin and say so (`pinCleared(by:)`), so it does not
// silently drift back later.
//
// A NEARLY DRY ACCOUNT IS STILL NOT ONE OF THEM. The release is drawn at no effective remaining at
// all (`accountIsSpent`), never at the 5% line the movers draw for everyone else: 1% is an account
// that can still serve the turn the user pinned it for, and its quota is their business.
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
/// takes the pin with it (`pinCleared(by:)`).
///
/// AND THE `manual` IT RETURNS IS RELEASED AGAIN when the account it names has nothing left at all,
/// by the caller rather than here (`pinReleasedPolicy`, DroughtWatch.swift): what this function
/// expresses is the pin, and what that one expresses is the one state in which a pin protects
/// nothing. Kept apart so this stays the single answer to "is this session pinned", which is what
/// every gate downstream is really asking.
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

/// The status-line badge a switch leaves while the gate holds it. A constant because the wording is
/// asserted in a test and read by a person on the same line, and a copy of it drifting in one of the
/// two would assert nothing - the model axis keeps its own for that reason
/// (`sessionModelWaitingBadge`), and this is the same wait one axis over.
///
/// Short because it shares its row with the quota meters, like every badge on this track: WHICH
/// account the session is moving to, and which one it sits on until then, are the detail's job.
///
/// THE STATE, NOT A DEADLINE, which is the rule the long form already follows (`quietGateHolding`
/// carries the review): "after this turn" told the reader WHEN, and the gate reports only the first
/// term that said no, so the named moment arrived with nothing happening. It also promised a turn
/// this arm cannot promise - one Bool covers a live turn, an open tool call, an unresolved fork and
/// a subagent, so the badge says what the reload axis's short form has always said about the same
/// term (`reloadWaitReason`): the session is busy (codex review of fe4462d).
let switchQueuedBadge = "switch: session busy"

/// The other two waits the same gate produces, described the same way. `reloadQuiet` is three terms
/// (SessionSwitch asks it through `reloadQuiet` itself) and only the first is the transcript: a
/// prompt being typed and a session that has not written a turn at all both hold the move too. The
/// reader can only act on one of the three, which is the whole reason the reload axis names its gate
/// as well (`reloadWaitReason`).
let switchQueuedTypingBadge = "switch: typing"
let switchQueuedStartupBadge = "switch: starting up"
/// The fourth arm of `QuietGate`, which no caller can reach today: a gate term added there and not
/// here would land on a badge that is vague rather than wrong.
let switchQueuedIdleBadge = "switch: in use"

/// Which of the four badges above a gate wears. Apart from the wording below because the SHORT form
/// is a constant a test pins and a person reads on the same row, while the long form is composed.
private func queuedSwitchBadge(_ gate: QuietGate) -> String {
    switch gate {
    case .transcript: return switchQueuedBadge
    case .keyboard: return switchQueuedTypingBadge
    case .startup: return switchQueuedStartupBadge
    case .unknown: return switchQueuedIdleBadge
    }
}

/// What a queued switch says on the status line, and at length beside it: the gate that is actually
/// holding the move, named. `target` is where the session is going and `staying` where it sits until
/// then, which is the question behind every badge on this track.
///
/// DESCRIBED, NOT PROMISED. The long form used to finish each arm with when the move would happen
/// ("once the keyboard is quiet"), and the gate cannot support that: it reports the first term that
/// said no, and a second term can be false at the same moment, so the promised moment arrived with
/// nothing happening (`quietGateHolding` carries the review and the reasoning). The clause comes
/// from that one place now, and this axis words only what it is waiting to DO.
func switchQueuedWait(gate: QuietGate, target: String, staying: String) -> PendingBadge {
    PendingBadge(queuedSwitchBadge(gate),
                 detail: "\(quietGateHolding(gate)), so the move waits: switching to \(target); "
                     + "staying on \(staying) until then")
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
                            detail: "the account `tally account` named has no login right now; "
                                + "staying on \(staying) until it is renewed")
    case .unlisted:
        return PendingBadge("switch: not listed",
                            detail: "the account `tally account` named is not in the current fleet "
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
    //
    // A REQUEST THAT VANISHED TAKES ITS BADGE WITH IT, the same fix the model axis needed and for
    // the same reason (SessionModel.swift states it in full). The defect was reported against that
    // axis; it is one mechanism and this is the other half of it, so both are closed together
    // rather than leaving the identical hole one function away.
    guard let request else {
        state.waiting = nil
        return
    }
    guard request.epoch > state.servedEpoch else { return }
    // WHICH CONVERSATION IS ASKING, before the quiet gate reads a file that may no longer be it. A
    // `/clear` with nothing typed into it yet cannot be told from a sibling by anything inside it, so
    // the fork hold answers "not quiet" to protect a move it cannot see - and a request answered by a
    // prompt hook writes no turn to resolve it, so this one instruction waited for a turn that would
    // never come (RequestTranscript.swift). The request names the file Claude Code says the prompt
    // came from; adopting it puts the watcher back on the live conversation, and the gate below then
    // asks its ordinary question about the right file.
    adoptRequestedTranscript(request.transcriptID, watcher: &watcher, sessionKey: state.sessionKey)
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
    // Held apart rather than folded into the one call, so the queued badge below can name the gate
    // that actually decided without asking any of them a second time - the reload axis holds its
    // own components for exactly that (Reload.swift, `applyReloadRequest`). `watcher.file` is only
    // meaningful after `isQuiet` has run its locate, hence the order.
    let transcriptQuiet = watcher.isQuiet(manualMoveIdleSeconds)
    let hasTranscript = watcher.file != nil
    let keyboardQuiet = keyboardIdle(manualMoveIdleSeconds)
    let quiet = reloadQuiet(transcriptQuiet: transcriptQuiet, hasTranscript: hasTranscript,
                            childAge: childAge, bar: manualMoveIdleSeconds,
                            keyboardQuiet: keyboardQuiet)
    switch switchDecision(served: state.servedEpoch, request: request, target: target,
                          onTarget: named?.id == account.id, isQuiet: quiet) {
    case .none:
        // Nothing to serve, so nothing to say. Unreachable from here in practice: the epoch guard
        // above has already returned for every request this supervisor has served.
        state.waiting = nil
    case .queued:
        // THE WAIT THAT USED TO RAISE NOTHING. The reasoning was that it lasts at most the rest of
        // the turn that asked for the switch, and that whoever typed the command had already read
        // the timing in its own output. The second half is what does not hold: the panel's picker
        // writes this very request from a surface with no terminal output at all, so the person who
        // had just chosen an account watched the session sit there with nothing anywhere saying it
        // had been heard - a wait nobody can see is indistinguishable from a click that did nothing
        // (owner report, 2026-08-10). The typed command gains the badge too, and loses nothing by
        // it: it repeats what the command said, on the surface its user is looking at meanwhile.
        //
        // The wait itself is untouched - the move still happens at the end of the turn, on the same
        // quiet bar - and so is the rule about the TERMINAL: the child is drawing this very turn
        // there, so the badge is the one place a live child allows something to be said
        // (PendingNotice.swift: only a message that precedes a tear-down may use stderr).
        //
        // Nothing has to take it down by hand either. It is re-derived on every tick that still
        // reads a pending request, so the relaunch that ends the wait clears it as it consumes the
        // request (`PendingSwitchConsumption.commit`), a request that vanishes takes it with it
        // (the guard at the top of this function), and an account that stops being launchable
        // replaces it with the badge for that (`switchWaitBadge`, below).
        //
        // WHICH WAIT IT IS comes from the gate that held it, not from the branch: `reloadQuiet` is
        // three terms and only the first of them is a turn, so a single "after this turn" told a
        // person typing a prompt, and a session that had not written a turn at all, that something
        // was ending which was not running (codex review of 8b34d49). The gate is asked once, off
        // the components it was just given (`quietGate`), so the badge cannot name a term other
        // than the one that decided.
        state.waiting = switchQueuedWait(
            gate: quietGate(transcriptQuiet: transcriptQuiet, keyboardQuiet: keyboardQuiet,
                            hasTranscript: hasTranscript, childAge: childAge,
                            bar: manualMoveIdleSeconds),
            target: named?.label ?? request.accountID, staying: account.label)
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
            switchCancelledBadge,
            detail: "the account `tally account` named is no longer in the fleet, so the move was "
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
/// means). It stands down while that account is SPENT, because the caller hands it a released
/// policy then (DroughtWatch.swift): without that, a mover carrying the session off an empty
/// account and this dragging it back is a restart loop for the length of the drought. Waits for a quiet transcript so an in-flight response is never cut mid-stream (the next
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

