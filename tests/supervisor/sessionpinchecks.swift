import Foundation

// The STICKY half of `tally switch`: the pin it leaves behind, what stops honouring quota reasoning
// while that pin stands, the two ways out of it, and what is written down when a move happens.
//
// The behaviour under test is the one the one-shot design got wrong (owner report, 2026-08-06): a
// user moved their session onto a named account, and the next automatic pick moved it back. A pin
// that any idle tick may undo is not an instruction, so a switch now outlives the relaunch it asks
// for - across the self-update exec included - and only `tally switch --auto` or a hard cap ends it.
//
// The fixtures (`switchAccount`, `idleWatcher`, `midTurnWatcher`) are shared with switchchecks.swift,
// which owns the request-and-decide half.

func runSessionPinChecks() {
    // MARK: - 31h. Releasing the pin, as a decision

    let auto = SwitchRequest(epoch: 200, accountID: switchAutoRequest)
    let named = SwitchRequest(epoch: 200, accountID: "B")
    check("the reserved id reads as a release", auto.isUnpin && !named.isUnpin)
    // It can never collide with a real account: an id is `<provider>:<config dir>`, so it carries a
    // colon and cannot start with a dash (ClaudeAccounts.swift).
    check("and cannot be spelled by an account id",
          switchAutoRequest.hasPrefix("-") && !switchAutoRequest.contains(":"))
    let target = SwitchTargetState.launchable(switchAccount("B"))
    check("a release is served whatever the target says",
          switchDecision(served: 100, request: auto, target: .removed, onTarget: false,
                         isQuiet: true) == .unpin)
    check("…including with no snapshot to judge by",
          switchDecision(served: 100, request: auto, target: .unreadable, onTarget: false,
                         isQuiet: true) == .unpin)
    // Nothing is relaunched, so there is no turn to be careful of: a release that waited for a quiet
    // moment would stand for exactly as long as the user kept working.
    check("and it does not wait for the session to go quiet",
          switchDecision(served: 100, request: auto, target: target, onTarget: false,
                         isQuiet: false) == .unpin)
    check("but a stamp already served is still nothing",
          switchDecision(served: 200, request: auto, target: target, onTarget: false,
                         isQuiet: true) == .none)

    // MARK: - 31i. The pin through a tick

    let onA = switchAccount("A")
    let toB = switchAccount("B", label: "Claude 2")
    let toD = switchAccount("D", label: "Claude 4")
    let fleet = [onA, toB, toD]
    let tickDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-session-pin-\(UUID().uuidString)")
    let session = "5151"
    var state = ManualMoveState(sessionKey: session, servedEpoch: 100)
    var auto0 = LaunchPolicy()
    auto0.mode = "auto"
    var pinnedToB = LaunchPolicy()
    pinnedToB.mode = "manual"
    pinnedToB.pinnedAccountID = "B"

    /// The policy the LAST `tick` handed back: what every mover after the manual moves would be
    /// judged by on that same tick.
    var tickPolicy = auto0
    func tick(_ watcher: inout TranscriptWatcher, request: SwitchRequest?,
              policy: LaunchPolicy = auto0, on: Snapshot.Account = onA)
        -> (plan: RelaunchPlan?, record: PendingSwitchConsumption?) {
        var plan: RelaunchPlan?
        var record: PendingSwitchConsumption?
        var under = policy
        applyManualMoves(plan: &plan, state: &state, record: &record, policy: &under,
                         account: on, providerID: "claude", watcher: &watcher, childAge: 9999,
                         keyboardIdle: { _ in true }, dir: tickDir,
                         request: { _ in request }, accounts: { fleet })
        tickPolicy = under
        return (plan, record)
    }

    var quiet = idleWatcher("sticky")
    let toDRequest = SwitchRequest(epoch: state.servedEpoch + 1, accountID: "D")
    let moved = tick(&quiet, request: toDRequest)
    check("a served switch plans the move", moved.plan?.target.id == "D")
    check("and the pin is not recorded before the relaunch is certain", state.sessionPin == nil)
    moved.record?.commit(&state)
    check("committing it pins the session to the account it named", state.sessionPin == "D")

    // The whole point: from here on the session is on D, and nothing that reasons about quota or
    // about the fleet's own pin may take it off.
    let panelPin = tick(&quiet, request: nil, policy: pinnedToB, on: toD)
    check("a fleet pin no longer drags a pinned session back", panelPin.plan == nil)
    var pinnedToA = LaunchPolicy()
    pinnedToA.mode = "manual"
    pinnedToA.pinnedAccountID = "A"
    // The one behaviour the sticky pin deliberately CHANGES: under the old override the pin being
    // moved somewhere new counted as a fresh instruction and took the session with it. It is a
    // fleet-scope instruction about where sessions go, and this session has one of its own.
    check("nor does moving that pin somewhere new",
          tick(&quiet, request: nil, policy: pinnedToA, on: toD).plan == nil)

    // `tally switch --auto`: hands the session back to whatever would have decided for it. It moves
    // nothing itself - the session stays on D under a fleet that has no opinion about where it runs.
    let release = SwitchRequest(epoch: state.servedEpoch + 1, accountID: switchAutoRequest)
    let released = tick(&quiet, request: release, on: toD)
    check("a release restarts nothing by itself", released.plan == nil)
    check("and is consumed on the spot", state.servedEpoch == release.epoch)
    check("the pin is gone", state.sessionPin == nil)
    // Which is the whole point of releasing it: the fleet's pin governs this session again, and the
    // very next tick acts on it.
    check("so the fleet pin moves the session again",
          tick(&quiet, request: nil, policy: pinnedToB, on: toD).plan?.target.id == "B")

    // Naming the account the session is already on is a request for the PIN, and it has to land:
    // otherwise it is the one way to ask for one and not get one.
    let staying = SwitchRequest(epoch: state.servedEpoch + 1, accountID: "A")
    let inPlace = tick(&quiet, request: staying, on: onA)
    check("switching to the account we are on restarts nothing", inPlace.plan == nil)
    check("but pins the session there", state.sessionPin == "A")
    check("and consumes the request", state.servedEpoch == staying.epoch)
    // …and THIS TICK's movers have to see it. That request planned no relaunch, so nothing gated on
    // `plan == nil` was stopped: a policy derived before the request was consumed would still read
    // "unpinned", the rescue or the rebalance would move the session off A on this very tick, and
    // since nothing but a cap clears a pin, every later tick would then refuse to move it back - the
    // pin and the account would disagree for the rest of the session (found in review, 2026-08-06).
    check("the policy handed back on that tick already carries the pin",
          tickPolicy.mode == "manual" && tickPolicy.pinnedAccountID == "A")
    // The release is the same hazard in reverse, and must be just as immediate: a mover held back by
    // a pin the user has just dropped is a tick of the session not following the fleet.
    let dropped = SwitchRequest(epoch: state.servedEpoch + 1, accountID: switchAutoRequest)
    _ = tick(&quiet, request: dropped, on: onA)
    check("and a release is out of the policy on the tick it lands", tickPolicy.mode == "auto")

    // MARK: - 31j. What the rest of the loop sees

    check("no pin leaves the policy exactly as it was", {
        let untouched = sessionPolicy(pinnedToB, sessionPin: nil)
        return untouched.mode == pinnedToB.mode
            && untouched.pinnedAccountID == pinnedToB.pinnedAccountID
            && untouched.model == pinnedToB.model
    }())
    let underPin = sessionPolicy(auto0, sessionPin: "D")
    check("a pinned session reads as a manual pin on its account",
          underPin.mode == "manual" && underPin.pinnedAccountID == "D")
    // The app writes that path beside the account IT pinned, so carrying it under another account's
    // id would name the wrong config dir - the same reason a project pin drops it.
    check("and carries no denormalised home", underPin.pinnedHome == nil)
    var pinnedElsewhere = LaunchPolicy()
    pinnedElsewhere.mode = "manual"
    pinnedElsewhere.pinnedAccountID = "B"
    check("the session pin outranks the fleet's own",
          sessionPolicy(pinnedElsewhere, sessionPin: "D").pinnedAccountID == "D")

    // The nearly-dry rebalance, asked through that policy: this is the move that undid the switch.
    let dyingNow = Date(timeIntervalSince1970: 1_800_000_000)
    func account(_ id: String, model: Double) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: id, launchHome: "/tmp/\(id)",
                         sessionRemaining: 90, weeklyRemaining: 90, modelRemaining: model,
                         sessionResetsAt: dyingNow.addingTimeInterval(4 * 3600),
                         weeklyResetsAt: dyingNow.addingTimeInterval(100 * 3600),
                         modelResetsAt: dyingNow.addingTimeInterval(100 * 3600),
                         modelWindowName: "fable", resetCreditsAvailable: nil, isStale: false,
                         error: nil)
    }
    func rebalance(_ policy: LaunchPolicy) -> Snapshot.Account? {
        rebalanceTarget(mode: policy.mode, isQuiet: true, carryable: true, fuseAllows: true,
                        current: account("D", model: 3), candidates: [account("B", model: 77)],
                        primaryModel: "fable", now: dyingNow)
    }
    check("an unpinned session on a dying account is rebalanced off it",
          rebalance(auto0)?.id == "B")
    check("a pinned one is left exactly where it was put", rebalance(underPin) == nil)
    // The degradation rescue and the follow adoption read the same `mode`, so they inherit this;
    // the cap handoff is asked against the policy WITHOUT the pin, which is what lets it through.
    check("the cap is still allowed to move a pinned session",
          capRecoveryAction(mode: auto0.mode, fuseAllows: true, snapshotStale: false,
                            hasTarget: true) == .handoff)

    // MARK: - 31k. The cap is the one way out that nobody asked for

    var capped = ManualMoveState(sessionKey: "cap", servedEpoch: 0, sessionPin: "D")
    check("a rebalance never reaches the pin", !capped.pinClearedByCap("rebalance"))
    check("nor does a reload restart", !capped.pinClearedByCap("reload"))
    check("and the pin is still there afterwards", capped.sessionPin == "D")
    check("a cap handoff clears it", capped.pinClearedByCap("cap"))
    check("…so the session is not dragged back to a capped account", capped.sessionPin == nil)
    check("and it is only news once", !capped.pinClearedByCap("cap"))
    var unpinned = ManualMoveState(sessionKey: "cap", servedEpoch: 0)
    check("an unpinned session's cap handoff is not a pin clearance",
          !unpinned.pinClearedByCap("cap"))
    check("the user is told how to get the pin back",
          sessionPinClearedByCapNotice.contains("tally switch")
              && sessionPinClearedByCapNotice.contains("cap"))

    // …and the cap has to be able to REACH that clearance, which is the hole this section is really
    // about: with a project or panel pin already in force, asking `capRecoveryAction` about the
    // session's own policy answers `.waitPinned` for ever, no plan is ever built, `pinClearedByCap`
    // is never called, and the session sits on a dry account it cannot work on (review, 2026-08-06).
    let capNow = Date(timeIntervalSince1970: 1_800_000_000)
    let capped0 = account("D", model: 0.5)      // where the session is, and where it just capped
    let fleetPinned = account("P", model: 60)   // what the project/panel pin names
    let sibling = account("S", model: 80)       // what a pick of its own would choose
    var pinnedToP = LaunchPolicy()
    pinnedToP.mode = "manual"
    pinnedToP.pinnedAccountID = "P"

    func capTick(fleet: LaunchPolicy, sessionPin: String?,
                 accounts: [Snapshot.Account] = [capped0, fleetPinned, sibling])
        -> (plan: RelaunchPlan?, pending: PendingCapRecovery?) {
        var plan: RelaunchPlan?
        var pending: PendingCapRecovery? = PendingCapRecovery(
            cappedAccountID: "D", cappedAt: capNow, primaryModel: "fable",
            recoveryResetsAt: nil, nextRetry: .distantPast, reason: "")
        applyCapHandoff(plan: &plan, pendingCap: &pending, account: capped0, providerID: "claude",
                        fleet: fleet, sessionPin: sessionPin, quarantine: [:], fuseAllows: true,
                        now: capNow, loaded: (Snapshot(version: 2, generatedAt: capNow, accounts: accounts), nil))
        return (plan, pending)
    }

    // The bug, end to end: both pins in force, and the session gets out.
    let bothPins = capTick(fleet: pinnedToP, sessionPin: "D")
    check("a cap moves a session pinned over a fleet pin", bothPins.plan != nil)
    check("…to the account the fleet pin names, which is where the pin says it belongs",
          bothPins.plan?.target.id == "P")
    check("…tagged as a cap, so the clearance and the audit line follow from it",
          bothPins.plan?.reason == "cap")
    var pinnedSession = ManualMoveState(sessionKey: "capped", servedEpoch: 0, sessionPin: "D")
    check("and that plan is what ends the session pin",
          pinnedSession.pinClearedByCap(bothPins.plan?.reason ?? "")
              && pinnedSession.sessionPin == nil)
    check("which the log then names for what it was",
          handoffReason(bothPins.plan?.reason ?? "", pinCleared: true) == "pin-cleared-cap")

    // A session pin with nothing under it picks for itself, as it did before.
    let onlySession = capTick(fleet: auto0, sessionPin: "D")
    check("with no fleet pin under it, the cap picks the best sibling",
          onlySession.plan?.target.id == "S")

    // Untouched: a FLEET-pinned session with no pin of its own still waits, because nothing is
    // clearing that pin and staying put is what pinning means.
    let fleetOnly = capTick(fleet: pinnedToP, sessionPin: nil)
    check("a fleet-pinned session with no session pin still stays put", fleetOnly.plan == nil)
    check("…and says why", fleetOnly.pending?.reason.contains("pinned in Tally") == true)

    // The fleet pin cannot be honoured (drained, so not a candidate at all): waiting again, and
    // deliberately. Moving anywhere else would be undone within seconds - the pin switch asks only
    // whether an account is launchable, not whether it has quota, so it would drag the session
    // straight back onto the pinned account and the cap would fire again there.
    let deadEnd = capTick(fleet: pinnedToP, sessionPin: "D",
                          accounts: [capped0, account("P", model: 0), sibling])
    check("a fleet pin that cannot take the session keeps it where it is", deadEnd.plan == nil)
    check("…rather than moving it somewhere the pin would undo",
          deadEnd.pending?.reason.contains("pinned in Tally") == true)

    // The rule those four cases come from, on its own.
    let candidates = [fleetPinned, sibling]
    check("no session pin leaves the fleet's own mode alone",
          capReading(fleet: pinnedToP, sessionPin: nil, candidates: candidates).mode == "manual")
    check("a session pin alone lets the cap decide",
          capReading(fleet: auto0, sessionPin: "D", candidates: candidates).mode == "auto")
    check("a session pin over a fleet pin lands on the fleet's account", {
        let reading = capReading(fleet: pinnedToP, sessionPin: "D", candidates: candidates)
        return reading.mode == "auto" && reading.preferred?.id == "P"
    }())
    check("a fleet pin outside the candidates is a wait, not a free pick", {
        let reading = capReading(fleet: pinnedToP, sessionPin: "D", candidates: [sibling])
        return reading.mode == "manual" && reading.preferred == nil
    }())

    // MARK: - 31l. What the audit log says

    check("a hand-typed move is named as one", handoffReason("switch", pinCleared: false)
          == "manual-switch")
    check("a cap handoff is named as one", handoffReason("cap", pinCleared: false) == "cap-handoff")
    check("quota re-picking an account is named as that",
          handoffReason("rebalance", pinCleared: false) == "auto-select")
    check("a cap that took a pinned session says so instead",
          handoffReason("cap", pinCleared: true) == "pin-cleared-cap")
    check("every other reason keeps its own tag",
          handoffReason("reload", pinCleared: false) == "reload"
              && handoffReason("pin", pinCleared: false) == "pin"
              && handoffReason("self-update", pinCleared: false) == "self-update")

    let logged = handoffLogLine(sessionID: "abcdefgh12345678", from: "Claude", to: "Claude 2",
                                reason: "manual-switch", pid: "4242",
                                cwd: "/Users/x/work/my project",
                                now: Date(timeIntervalSince1970: 1_800_000_000))
    check("the line says which session, by supervisor pid", logged.contains(" pid=4242 "))
    check("…which conversation, truncated to its prefix", logged.contains(" session=abcdefgh "))
    check("…where it moved", logged.contains(" Claude->Claude 2 "))
    check("…and why", logged.contains(" reason=manual-switch "))
    // Last, and only there, because a path may contain spaces: everything before it stays at a
    // fixed offset for a reader with an eye or a `grep`.
    check("the directory comes last, where a space in it costs nothing",
          logged.hasSuffix(" cwd=/Users/x/work/my project\n"))
    check("a session with no located transcript still logs a whole line",
          handoffLogLine(sessionID: nil, from: "A", to: "B", reason: "cap-handoff", pid: "1",
                         cwd: "/tmp").contains("session=unknown"))
    check("and it is one line", logged.filter { $0 == "\n" }.count == 1)

    // MARK: - 31m. Surviving the self-update exec

    // In memory only, like the fuse, so it rides across in the argv the old build writes and the
    // NEW build parses. Without it the first quiet tick after an app update hands the session back
    // to automatic selection, and the account the user named silently stops being the one they are
    // on (SelfUpdate.swift's contract note).
    func roundTrip(sessionPin: String?, pinOverride: String? = nil) -> (sessionPin: String?,
                                                                       pinOverride: String?,
                                                                       home: String,
                                                                       childArgs: [String]) {
        let parsed = parseResuperviseArgs(
            Array(selfUpdateArgv(binary: "/usr/local/bin/tally", id: "d", label: "Claude 4",
                                 home: "/h", follow: true, sessionPin: sessionPin,
                                 pinOverride: pinOverride,
                                 args: ["--resume", "abc"]).dropFirst(2)))
        return (parsed.sessionPin, parsed.pinOverride, parsed.home, parsed.childArgs)
    }
    let carried = roundTrip(sessionPin: "claude:.claude4")
    check("the session pin survives the round trip", carried.sessionPin == "claude:.claude4")
    check("and nothing riding with it is disturbed",
          carried.home == "/h" && carried.childArgs == ["--resume", "abc"])
    check("an unpinned session writes no flag",
          !selfUpdateArgv(binary: "/tally", id: "a", label: "A", home: "/h", follow: true,
                          args: []).contains(resuperviseSessionPinFlag))
    check("…and reads back as unpinned", roundTrip(sessionPin: nil).sessionPin == nil)
    // The contract is between BUILDS: one that predates the flag never writes it, and the parser has
    // to keep meaning "not pinned" rather than inventing one.
    check("an argv from a build predating the flag parses as unpinned",
          parseResuperviseArgs(["--id", "a", "--label", "A", "--home", "/h", "--follow",
                                "--", "--resume", "abc"]).sessionPin == nil)
    check("an empty value is a disagreement about the format, not a pin on nothing",
          parseResuperviseArgs(["--home", "/h", resuperviseSessionPinFlag, ""]).sessionPin == nil)
    // The legacy flag still parses and still travels: a session upgrading out of a build that only
    // had the override arrives holding one, and dropping it would undo that session's switch.
    let bothFlags = roundTrip(sessionPin: "claude:.claude4", pinOverride: "claude:.claude2")
    check("the legacy override rides alongside the new pin",
          bothFlags.sessionPin == "claude:.claude4" && bothFlags.pinOverride == "claude:.claude2")

    // …and a session that upgraded out of a build with no session pin arrives holding only the
    // legacy override, which refuses the fleet pin all by itself (`applyPinSwitch`). `--auto` has to
    // take that with it, or the command says "following automatic selection again" and then goes on
    // ignoring the one instruction that selection has.
    var legacy = ManualMoveState(sessionKey: "5353", servedEpoch: 100, overriddenPin: "B")
    var legacyWatcher = idleWatcher("legacy")
    func legacyTick(_ request: SwitchRequest?) -> RelaunchPlan? {
        var plan: RelaunchPlan?
        var record: PendingSwitchConsumption?
        var under = pinnedToB
        applyManualMoves(plan: &plan, state: &legacy, record: &record, policy: &under,
                         account: onA, providerID: "claude", watcher: &legacyWatcher,
                         childAge: 9999, keyboardIdle: { _ in true }, dir: tickDir,
                         request: { _ in request }, accounts: { fleet })
        return plan
    }
    check("the legacy override still refuses the pin it was taken off", legacyTick(nil) == nil)
    let legacyRelease = SwitchRequest(epoch: legacy.servedEpoch + 1, accountID: switchAutoRequest)
    let legacyPlan = legacyTick(legacyRelease)
    check("a release drops the legacy override with the pin", legacy.overriddenPin == nil)
    // On that very tick, and that is the release doing exactly what it says: the fleet pin is what
    // automatic selection has to say about this session, and it was the only thing being ignored.
    check("so the fleet pin governs the session again", legacyPlan?.target.id == "B")
    check("as a pin switch, not as anything the release invented", legacyPlan?.reason == "pin")

    // The other half of surviving it: the new process seeds its state from that argv, and the pin
    // is in force from its very first tick.
    var afterExec = ManualMoveState(sessionKey: "5252", servedEpoch: 0,
                                    sessionPin: "D", dir: tickDir)
    var relaunched = idleWatcher("afterexec")
    var execPlan: RelaunchPlan?
    var execRecord: PendingSwitchConsumption?
    var execPolicy = pinnedToB
    applyManualMoves(plan: &execPlan, state: &afterExec, record: &execRecord, policy: &execPolicy,
                     account: toD, providerID: "claude", watcher: &relaunched, childAge: 9999,
                     keyboardIdle: { _ in true }, dir: tickDir, request: { _ in nil },
                     accounts: { fleet })
    check("a session that came back from an upgrade is still pinned", execPlan == nil)
    check("and still knows what it is pinned to", afterExec.sessionPin == "D")

    // MARK: - 31n. Published for the surfaces outside this terminal

    let published = SupervisedSession(accountID: "claude:.claude4", contextTokens: 12_000,
                                      updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                      sessionPin: "claude:.claude4")
    var writer = SessionContextWriter()
    writer.sync(tokens: 12_000, accountID: "claude:.claude4", pin: "claude:.claude4",
                pid: String(getpid()), dir: tickDir, now: published.updatedAt)
    check("the pin is published beside the context reading",
          readSessionContext(pid: String(getpid()), dir: tickDir) == published)
    // A release moves nothing and changes no token count, so it would otherwise wait for the next
    // thousand tokens to be written down - describing a session that is no longer pinned.
    writer.sync(tokens: 12_100, accountID: "claude:.claude4", pin: nil, pid: String(getpid()),
                dir: tickDir, now: published.updatedAt)
    check("dropping it is written immediately, under the write delta",
          readSessionContext(pid: String(getpid()), dir: tickDir)?.sessionPin == nil)
    // Additive: the field has a default, so a document written before it existed still decodes.
    let older = #"{"accountID":"claude:.claude","contextTokens":5000,"#
        + #""updatedAt":"2026-08-06T00:00:00Z"}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    check("a document from before the field decodes as unpinned",
          (try? decoder.decode(SupervisedSession.self,
                               from: Data(older.utf8)))?.sessionPin == nil)
    clearSessionContext(pid: String(getpid()), dir: tickDir)

    // MARK: - 31o. The two instructions are mutually exclusive

    // One invocation under either reading, and the readings are opposites: refuse rather than guess.
    check("an account name asks for a pin", switchIntent(["Claude 4"]) == .pin("Claude 4"))
    check("the flag alone asks for a release", switchIntent([switchAutoRequest]) == .auto)
    check("both together is refused", switchIntent([switchAutoRequest, "Claude 4"]) == nil)
    check("…in either order", switchIntent(["Claude 4", switchAutoRequest]) == nil)
    check("a bare switch is refused, as it always was", switchIntent([]) == nil)
    check("so are two accounts", switchIntent(["Claude 4", "Claude 2"]) == nil)
    check("and so is a flag this command does not have", switchIntent(["--follow"]) == nil)
    // The exit code is the contract a script reads, and a refusal has always been a usage error.
    check("a refused invocation exits 2", runSwitch(args: [switchAutoRequest, "Claude 4"]) == 2)
    // The `/tally-switch` hook hands the rest of the typed line over as a NAME, so the release has
    // to be reachable through that surface too - one mapping, in `attemptSwitch(name:)`.
    check("the slash command can release it as well",
          hookSwitchAction(#"{"command_args":"--auto"}"#) == .queue(switchAutoRequest))

    try? FileManager.default.removeItem(at: tickDir)
}
