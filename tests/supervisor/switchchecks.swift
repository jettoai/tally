import Foundation

// `tally switch <account>`: the request file and the session it addresses (SwitchRequest.swift),
// the tick decision and the wiring around it (SessionSwitch.swift), and the one rule that makes the
// command usable at all - an explicit switch outranks the pin, and keeps outranking it.
//
// The scenario every assertion here is written against: the agent INSIDE the session is asked to
// move to another account and runs the command itself, as a tool call. So at the moment the request
// lands the session is mid-turn by construction, and the thing that must never happen is the
// supervisor killing the child in the middle of the turn that asked for the switch.

private func switchAccount(_ id: String, label: String? = nil,
                           home: String? = nil) -> Snapshot.Account {
    Snapshot.Account(id: id, provider: "claude", label: label ?? id,
                     launchHome: home ?? "/tmp/\(id)", sessionRemaining: 90, weeklyRemaining: 90,
                     modelRemaining: 90, sessionResetsAt: nil, weeklyResetsAt: nil,
                     modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil,
                     isStale: false, error: nil)
}

/// A session that has been silent for long enough to pass any bar, with no open tool call in it.
private func idleWatcher(_ label: String) -> TranscriptWatcher {
    switchWatcher(label, lines: [#"{"type":"user","timestamp":"2026-01-01T00:00:00Z"}"#])
}

/// A session in the middle of a tool call: the assistant opened one moments ago and no result has
/// come back, which is exactly the state `tally switch` is run from. The FILE is stale (the mtime
/// bar passes), so only the open-turn veto can hold this one busy.
private func midTurnWatcher(_ label: String) -> TranscriptWatcher {
    let opened = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30))
    return switchWatcher(label, lines: [
        #"{"type":"assistant","timestamp":"\#(opened)","isSidechain":false,"message":{"content":[{"type":"tool_use","id":"toolu_switch"}]}}"#,
    ])
}

private func switchWatcher(_ label: String, lines: [String]) -> TranscriptWatcher {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-switch-\(label)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("session.jsonl")
    try! lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    // Written a minute ago: past every idle bar in play here, so a session that still reads busy
    // can only be doing so because of what is IN the file.
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)],
                                           ofItemAtPath: file.path)
    return TranscriptWatcher(projectDir: dir, file: file, since: Date().addingTimeInterval(-600))
}

func runSwitchChecks() {
    // MARK: - 31a. The request format

    // Two lines: the stamp, then the account id the CLI resolved against the live fleet. Anything
    // else is no request at all - a half-written file must never read as a switch to nowhere.
    check("a request parses into stamp and account",
          parseSwitchRequest("1800000000123\nacct-2\n")
              == SwitchRequest(epoch: 1_800_000_000_123, accountID: "acct-2"))
    check("a request with no trailing newline parses",
          parseSwitchRequest("1800000000123\nacct-2")
              == SwitchRequest(epoch: 1_800_000_000_123, accountID: "acct-2"))
    check("surrounding whitespace is tolerated",
          parseSwitchRequest(" 1800000000123 \n acct-2 ")
              == SwitchRequest(epoch: 1_800_000_000_123, accountID: "acct-2"))
    check("an id with a slash survives", parseSwitchRequest("1\nwith/slash")?.accountID
              == "with/slash")
    check("an empty body is no request", parseSwitchRequest("") == nil)
    check("a stamp with no account is no request", parseSwitchRequest("1800000000123\n") == nil)
    check("a blank account line is no request", parseSwitchRequest("1800000000123\n\n") == nil)
    check("an account with no stamp is no request", parseSwitchRequest("\nacct-2\n") == nil)
    check("a garbage body is no request", parseSwitchRequest("switch please\nacct-2") == nil)

    // MARK: - 31b. The file: round trip, resolution, cleanup

    let switchDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-switch-file-\(UUID().uuidString)")
    check("a session with no request reads as nil",
          readSwitchRequest(sessionKey: "4242", dir: switchDir) == nil)
    try! writeSwitchRequest(accountID: "acct-2", sessionKey: "4242",
                            now: Date(timeIntervalSince1970: 1_800_000_000.5), dir: switchDir)
    check("a written request round-trips",
          readSwitchRequest(sessionKey: "4242", dir: switchDir)
              == SwitchRequest(epoch: 1_800_000_000_500, accountID: "acct-2"))
    // Milliseconds, not seconds: "switch to A" then, on seeing the wrong one, "switch to B" is a
    // real sequence, and at second resolution the second request reads as already served and
    // disappears without a word.
    try! writeSwitchRequest(accountID: "acct-3", sessionKey: "4242",
                            now: Date(timeIntervalSince1970: 1_800_000_000.9), dir: switchDir)
    check("two requests inside one second are distinguishable",
          readSwitchRequest(sessionKey: "4242", dir: switchDir)?.epoch == 1_800_000_000_900)
    check("the newer request replaces the older, and names its own account",
          readSwitchRequest(sessionKey: "4242", dir: switchDir)?.accountID == "acct-3")
    // Addressed: one session's request is invisible to another.
    check("a request is addressed to one session only",
          readSwitchRequest(sessionKey: "9999", dir: switchDir) == nil)
    clearSwitchRequest(sessionKey: "4242", dir: switchDir)
    check("a served request is unlinked",
          readSwitchRequest(sessionKey: "4242", dir: switchDir) == nil)

    // A session can exit with a request still queued behind a turn that never ended, and pids come
    // round again: the sweep is what stops that file from moving somebody else's session.
    try! writeSwitchRequest(accountID: "acct-2", sessionKey: "99999", dir: switchDir)
    try! writeSwitchRequest(accountID: "acct-2", sessionKey: String(getpid()), dir: switchDir)
    try! "notes".write(to: switchDir.appendingPathComponent("notes.txt"), atomically: true,
                       encoding: .utf8)
    sweepDeadSwitchRequests(dir: switchDir)
    check("a request for a dead session is swept",
          readSwitchRequest(sessionKey: "99999", dir: switchDir) == nil)
    check("a live session's request survives the sweep",
          readSwitchRequest(sessionKey: String(getpid()), dir: switchDir) != nil)
    check("a file that is not named for a pid is left alone",
          FileManager.default.fileExists(atPath: switchDir.appendingPathComponent("notes.txt").path))
    try? FileManager.default.removeItem(at: switchDir)

    // MARK: - 31b2. What a supervisor starts out having served

    // A fresh supervisor seeds itself from whatever is addressed to its pid, because pids come
    // round: the request it finds at startup belongs to the session that held the pid before.
    let seedDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-switch-seed-\(UUID().uuidString)")
    try! writeSwitchRequest(accountID: "acct-2", sessionKey: "4242",
                            now: Date(timeIntervalSince1970: 1_800_000_000), dir: seedDir)
    check("a new supervisor treats a request it did not ask for as served",
          ManualMoveState(sessionKey: "4242", dir: seedDir).servedEpoch == 1_800_000_000_000)
    check("and one with nothing addressed to it starts at zero",
          ManualMoveState(sessionKey: "9999", dir: seedDir).servedEpoch == 0)
    // The exception: a self-update exec keeps the pid and IS the same session, so the file it finds
    // is a request made seconds ago by the conversation it is taking over. Seeding there would eat
    // it silently - the one outcome this feature must never produce.
    check("a self-update taking the session over does not swallow a pending request",
          ManualMoveState(sessionKey: "4242", servedEpoch: 0, dir: seedDir).servedEpoch == 0)
    let loopSource = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the switch checks", !loopSource.isEmpty)
    check("and the loop really makes that distinction",
          loopSource.contains("ManualMoveState(sessionKey: supervisorPID, servedEpoch: "
                              + "resumed ? 0 : nil,"))
    // The other half of the same promise: the override rides the exec rather than being re-derived.
    check("and it hands the overridden pin across the self-update exec",
          loopSource.contains("pinOverride: manualMoves.overriddenPin"))
    try? FileManager.default.removeItem(at: seedDir)

    // MARK: - 31b3. Which account the session being moved is actually on

    // "already on X" has to be asked of the SESSION, not of the shell asking. Through the directory
    // fallback that shell is somebody else's terminal, and its `CLAUDE_CONFIG_DIR` describes
    // whatever launched IT - usually nothing, which reads as the default home and would announce
    // "already on <the default account>" for a session running somewhere else entirely.
    let ctxDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-switch-ctx-\(UUID().uuidString)")
    let claude = providers[0]
    let defaultHomeAccount = switchAccount("D1", home: defaultHome(claude))
    let otherHomeAccount = switchAccount("H2", home: "/tmp/home2")
    let fleetHomes = [defaultHomeAccount, otherHomeAccount]
    writeSessionContext(SupervisedSession(accountID: "H2", contextTokens: 5_000, updatedAt: Date()),
                        pid: "4242", dir: ctxDir)
    check("the account its supervisor published wins",
          sessionAccountID(sessionKey: "4242", isThisSession: false, provider: claude,
                           accounts: fleetHomes, dir: ctxDir, environment: [:]) == "H2")
    check("…even when this shell's own environment says otherwise",
          sessionAccountID(sessionKey: "4242", isThisSession: true, provider: claude,
                           accounts: fleetHomes, dir: ctxDir,
                           environment: [claude.envKey: defaultHome(claude)]) == "H2")
    // Before that session has had a turn worth publishing, the environment is the only evidence -
    // and only when this process IS that session.
    check("a session with nothing published falls back to this shell, inside the session",
          sessionAccountID(sessionKey: "9999", isThisSession: true, provider: claude,
                           accounts: fleetHomes, dir: ctxDir,
                           environment: [claude.envKey: "/tmp/home2"]) == "H2")
    check("an unset config home reads as the provider's default home",
          sessionAccountID(sessionKey: "9999", isThisSession: true, provider: claude,
                           accounts: fleetHomes, dir: ctxDir, environment: [:]) == "D1")
    check("but a shell OUTSIDE the session is evidence about nothing",
          sessionAccountID(sessionKey: "9999", isThisSession: false, provider: claude,
                           accounts: fleetHomes, dir: ctxDir,
                           environment: [claude.envKey: "/tmp/home2"]) == nil)
    check("and an unknown home names no account",
          sessionAccountID(sessionKey: "9999", isThisSession: true, provider: claude,
                           accounts: fleetHomes, dir: ctxDir,
                           environment: [claude.envKey: "/tmp/nobody"]) == nil)
    try? FileManager.default.removeItem(at: ctxDir)

    // MARK: - 31c. The tick decision

    let fresh = SwitchRequest(epoch: 200, accountID: "B")
    check("a stamp this supervisor already served does nothing",
          switchDecision(served: 200, request: fresh, targetFound: true, onTarget: false,
                         isQuiet: true) == .none)
    check("an older stamp does nothing either",
          switchDecision(served: 300, request: fresh, targetFound: true, onTarget: false,
                         isQuiet: true) == .none)
    check("a newer stamp on a quiet session moves it",
          switchDecision(served: 100, request: fresh, targetFound: true, onTarget: false,
                         isQuiet: true) == .relaunch)
    check("a session mid-turn holds the request rather than losing it",
          switchDecision(served: 100, request: fresh, targetFound: true, onTarget: false,
                         isQuiet: false) == .queued)
    // Asked BEFORE quiet on purpose: the two waits are different things and the badge has to name
    // the right one. An account that is missing or signed out is HELD, not dropped - the user asked
    // for this by hand, the badge says it is stuck, and the move happens if the account comes back.
    check("an account that is gone is held, whatever the session is doing",
          switchDecision(served: 100, request: fresh, targetFound: false, onTarget: false,
                         isQuiet: false) == .unavailable)
    check("and is still held on a quiet session, rather than reading as a move",
          switchDecision(served: 100, request: fresh, targetFound: false, onTarget: false,
                         isQuiet: true) == .unavailable)
    check("a session already on the named account just consumes the request",
          switchDecision(served: 100, request: fresh, targetFound: true, onTarget: true,
                         isQuiet: true) == .alreadyThere)

    // MARK: - 31d. Which session is asking

    // The environment marker names the session the command was RUN IN, which is the main path: the
    // agent's own shell inherits it from the child. The directory can only ever name candidates.
    check("the session marker wins, even where several sessions run",
          sessionLookup(envPid: "100", here: ["200", "300"]) == .session("100"))
    check("one session in this directory needs no marker",
          sessionLookup(envPid: nil, here: ["200"]) == .session("200"))
    check("several sessions and no marker is ambiguous, and says which",
          sessionLookup(envPid: nil, here: ["200", "300"]) == .ambiguous(["200", "300"]))
    check("nothing supervised here is its own answer",
          sessionLookup(envPid: nil, here: []) == .none)

    // MARK: - 31e. The directory a session runs in

    let cwdDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-switch-cwd-\(UUID().uuidString)")
    let here = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-switch-here-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: here, withIntermediateDirectories: true)
    let mePid = String(getpid())
    markSupervisorLive(pid: mePid, dir: cwdDir)
    writeSupervisorCwd(here.path, pid: mePid, dir: cwdDir)
    // Fully resolved on the way in, because /tmp is a symlink to /private/tmp and the CLI resolves
    // its own cwd the same way: two spellings of one directory must not read as two directories.
    check("the published directory is the resolved one",
          readSupervisorCwd(pid: mePid, dir: cwdDir) == realpathString(here.path))
    check("a session in this directory is found",
          supervisorsInDirectory(here.path, dir: cwdDir) == [mePid])
    check("a session in another directory is not",
          supervisorsInDirectory(NSTemporaryDirectory(), dir: cwdDir).isEmpty)
    markSupervisorLive(pid: "99999", dir: cwdDir)
    writeSupervisorCwd(here.path, pid: "99999", dir: cwdDir)
    check("a dead supervisor's directory entry does not add a session",
          supervisorsInDirectory(here.path, dir: cwdDir) == [mePid])
    // The document has to be on the swept track, or a dead session's directory entry outlives it
    // and the next process to inherit that pid answers for a directory it never ran in.
    check("the state sweep knows this document belongs to a pid",
          supervisorStatePid(ofFile: "99999\(supervisorCwdSuffix)") == 99999)
    sweepDeadSupervisorState(dir: cwdDir)
    check("so a dead session's directory entry is reaped",
          readSupervisorCwd(pid: "99999", dir: cwdDir) == nil)
    check("and a live one's is kept", readSupervisorCwd(pid: mePid, dir: cwdDir) != nil)
    try? FileManager.default.removeItem(at: cwdDir)
    try? FileManager.default.removeItem(at: here)

    // MARK: - 31f. The switch through a whole tick

    let onA = switchAccount("A")
    let toB = switchAccount("B", label: "Claude 2")
    let toD = switchAccount("D", label: "Claude 4")
    let fleet = [onA, toB, toD]
    let tickDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-switch-tick-\(UUID().uuidString)")
    let session = "4242"
    var state = ManualMoveState(sessionKey: session, servedEpoch: 100)
    var pinnedNowhere = LaunchPolicy()
    pinnedNowhere.mode = "auto"

    /// A stamp strictly newer than `epoch`, in the millisecond units the request file uses. The
    /// scenarios below run in sequence against one `state`, so each has to be newer than everything
    /// served before it; deriving that from the served stamp rather than from the wall clock is what
    /// keeps them independent of how long the machine takes to run them.
    func stampAfter(_ epoch: Int) -> Date { Date(timeIntervalSince1970: Double(epoch + 1) / 1000) }
    func afterServed() -> Date { stampAfter(state.servedEpoch) }

    /// One poll tick's manual-move handling, with everything the loop would read injected.
    func tick(_ watcher: inout TranscriptWatcher, request: SwitchRequest?,
              policy: LaunchPolicy = pinnedNowhere, keyboardIdle: Bool = true,
              accounts: [Snapshot.Account] = fleet)
        -> (plan: RelaunchPlan?, record: PendingSwitchConsumption?) {
        var plan: RelaunchPlan?
        var record: PendingSwitchConsumption?
        applyManualMoves(plan: &plan, state: &state, record: &record, account: onA,
                         providerID: "claude", policy: policy, watcher: &watcher, childAge: 9999,
                         keyboardIdle: { _ in keyboardIdle }, dir: tickDir,
                         request: { _ in request }, accounts: { accounts })
        return (plan, record)
    }

    // The command is run as a tool call, so the request arrives mid-turn. Nothing may happen yet:
    // killing the child here would cut off the very turn that asked for the switch, before the
    // agent had said a word about it.
    var midTurn = midTurnWatcher("open")
    try! writeSwitchRequest(accountID: "B", sessionKey: session, dir: tickDir)
    let pendingRequest = readSwitchRequest(sessionKey: session, dir: tickDir)!
    check("the request really is newer than what this supervisor has served",
          pendingRequest.epoch > 100)
    let held = tick(&midTurn, request: pendingRequest)
    check("the turn that asked for the switch is not cut short", held.plan == nil)
    check("and the request is not consumed while it waits", state.servedEpoch == 100)
    check("so it is still on disk for the next tick",
          readSwitchRequest(sessionKey: session, dir: tickDir) == pendingRequest)

    // Same session, same request, once the turn has ended: the transcript is quiet and the move
    // happens in the gap after the answer.
    var idle = idleWatcher("served")
    let served = tick(&idle, request: pendingRequest)
    check("once the turn ends the session moves to the named account",
          served.plan?.target.id == "B")
    check("tagged as a switch for the audit log", served.plan?.reason == "switch")
    check("and never against the recovery fuse - the user asked for it",
          served.plan?.countsFuse == false)
    // Bookkeeping is carried, not written: a tick that stands the relaunch down (the unresolved-fork
    // hold) must leave the request exactly where it was, or it is lost for the life of the session.
    check("the stamp is not consumed at planning time", state.servedEpoch == 100)
    check("nor is the request file removed then",
          readSwitchRequest(sessionKey: session, dir: tickDir) != nil)
    let standDown = tick(&idle, request: pendingRequest)
    check("so a stood-down tick plans the same move again", standDown.plan?.target.id == "B")
    served.record?.commit(&state)
    check("committing at the execution point consumes the stamp",
          state.servedEpoch == pendingRequest.epoch)
    check("and unlinks the request", readSwitchRequest(sessionKey: session, dir: tickDir) == nil)
    check("so the very next tick plans nothing", tick(&idle, request: pendingRequest).plan == nil)

    // Two switches in quick succession, which is what the millisecond stamps exist for: the second
    // one is typed while the first is being carried out (the child is terminated, the transcript
    // located and shared, a process spawned - not an instant), so it overwrites the same file
    // between the plan and the commit. An unconditional unlink at commit time would delete an
    // instruction nobody had carried out, silently.
    var racing = idleWatcher("race")
    try! writeSwitchRequest(accountID: "B", sessionKey: session, now: afterServed(), dir: tickDir)
    let first = readSwitchRequest(sessionKey: session, dir: tickDir)!
    let racingPlan = tick(&racing, request: first)
    check("the first switch is planned", racingPlan.plan?.target.id == "B")
    // The user changes their mind mid-relaunch: a second request lands on the same path.
    try! writeSwitchRequest(accountID: "D", sessionKey: session,
                            now: stampAfter(first.epoch), dir: tickDir)
    let second = readSwitchRequest(sessionKey: session, dir: tickDir)!
    check("the second request really is a newer stamp", second.epoch > first.epoch)
    racingPlan.record?.commit(&state)
    check("committing the first one does not delete the second",
          readSwitchRequest(sessionKey: session, dir: tickDir) == second)
    check("and it records only the epoch it served", state.servedEpoch == first.epoch)
    let secondServed = tick(&racing, request: second)
    check("so the next tick carries out the second switch", secondServed.plan?.target.id == "D")
    secondServed.record?.commit(&state)
    check("which then consumes its own request",
          state.servedEpoch == second.epoch
              && readSwitchRequest(sessionKey: session, dir: tickDir) == nil)

    // A prompt being typed holds it too, on the same bar as everything else non-urgent.
    var typing = idleWatcher("typing")
    let later = SwitchRequest(epoch: state.servedEpoch + 1, accountID: "B")
    check("a busy keyboard queues the switch",
          tick(&typing, request: later, keyboardIdle: false).plan == nil)
    check("without consuming it", state.servedEpoch < later.epoch)

    // An account that signed out (or a snapshot that no longer lists it) between the command and
    // the tick: nothing is relaunched into a config dir with no login in it, and nothing is said on
    // the terminal either - the child is alive and drawing there, so the wait goes to the status
    // line's badge (PendingNotice.swift's whole rule).
    var vanished = idleWatcher("gone")
    try! writeSwitchRequest(accountID: "Z", sessionKey: session, now: afterServed(), dir: tickDir)
    let goneRequest = readSwitchRequest(sessionKey: session, dir: tickDir)!
    let dropped = tick(&vanished, request: goneRequest)
    check("a request naming an account that is gone plans nothing", dropped.plan == nil)
    check("it raises a badge instead of a line on the shared terminal",
          state.waiting?.badge == "switch: account is gone")
    check("with the long form kept for a surface that has room",
          state.waiting?.detail?.contains("missing from the snapshot or signed out") == true)
    check("the badge fits a status line beside the quota meters",
          (state.waiting?.badge.count ?? 99) <= 24)
    check("and the request is held, not consumed", state.servedEpoch < goneRequest.epoch)
    check("so its file is still there for the tick that can serve it",
          readSwitchRequest(sessionKey: session, dir: tickDir) == goneRequest)
    // The account comes back (a renewed login, a snapshot that lists it again): the held request
    // moves the session on its own, and the badge goes with it.
    let returned = tick(&vanished, request: goneRequest,
                        accounts: fleet + [switchAccount("Z", label: "Claude 9")])
    check("a held request fires once its account is back", returned.plan?.target.id == "Z")
    returned.record?.commit(&state)
    check("and the badge comes down with it", state.waiting == nil)

    // The session got there on its own (a cap handoff landed on the named account first).
    var arrived = idleWatcher("arrived")
    let onTarget = SwitchRequest(epoch: state.servedEpoch + 1, accountID: "A")
    let alreadyThere = tick(&arrived, request: onTarget)
    check("a switch to the account we are already on restarts nothing",
          alreadyThere.plan == nil)
    check("and is consumed, not left pending", state.servedEpoch == onTarget.epoch)

    // MARK: - 31g. The switch against the pin

    // The case the override exists for: a project pinned to one account (`tally project set
    // --account`, which reads as a manual pin) and a user who asks this conversation to move
    // elsewhere. Without it the pin drags the session home on the next tick and the command is
    // useless to exactly the person most likely to want it.
    var pinnedToB = LaunchPolicy()
    pinnedToB.mode = "manual"
    pinnedToB.pinnedAccountID = "B"
    var pinned = idleWatcher("pinned")
    let awayFromPin = SwitchRequest(epoch: state.servedEpoch + 1, accountID: "D")
    let overriding = tick(&pinned, request: awayFromPin, policy: pinnedToB)
    check("an explicit switch outranks the pin", overriding.plan?.target.id == "D")
    check("and is planned as a switch, not as a pin", overriding.plan?.reason == "switch")
    overriding.record?.commit(&state)
    check("the pin it overrode is remembered", state.overriddenPin == "B")
    check("so the pin no longer drags the session back",
          tick(&pinned, request: nil, policy: pinnedToB).plan == nil)
    // A pin MOVED afterwards is a fresh instruction from the same person, and takes effect as it
    // always did: the override is scoped to the pin that was overridden, not to pinning as such.
    var pinnedToD = LaunchPolicy()
    pinnedToD.mode = "manual"
    pinnedToD.pinnedAccountID = "D"
    let repinned = tick(&pinned, request: nil, policy: pinnedToD)
    check("moving the pin somewhere new still moves the session", repinned.plan?.target.id == "D")
    check("as a pin switch", repinned.plan?.reason == "pin")

    // The pin switch itself, unchanged by any of this: a session with no switch in its history
    // follows the panel exactly as before (this path moved file when the switch was added).
    var plainPin = ManualMoveState(sessionKey: "no-switches", servedEpoch: 0)
    var plainWatcher = idleWatcher("plainpin")
    var plainPlan: RelaunchPlan?
    var plainRecord: PendingSwitchConsumption?
    applyManualMoves(plan: &plainPlan, state: &plainPin, record: &plainRecord, account: onA,
                     providerID: "claude", policy: pinnedToB, watcher: &plainWatcher,
                     childAge: 9999, keyboardIdle: { _ in true }, dir: tickDir,
                     request: { _ in nil }, accounts: { fleet })
    check("a pinned session with no switch history follows the pin",
          plainPlan?.target.id == "B" && plainPlan?.reason == "pin")
    check("a pin switch never counts against the fuse either", plainPlan?.countsFuse == false)
    // Mid-turn, the pin waits exactly as the switch does.
    var pinMidTurn = midTurnWatcher("pinopen")
    var midPlan: RelaunchPlan?
    var midRecord: PendingSwitchConsumption?
    var midState = ManualMoveState(sessionKey: "no-switches", servedEpoch: 0)
    applyManualMoves(plan: &midPlan, state: &midState, record: &midRecord, account: onA,
                     providerID: "claude", policy: pinnedToB, watcher: &pinMidTurn, childAge: 9999,
                     keyboardIdle: { _ in true }, dir: tickDir, request: { _ in nil },
                     accounts: { fleet })
    check("a pin does not cut a live turn short either", midPlan == nil)
    try? FileManager.default.removeItem(at: tickDir)

    // MARK: - 31h. The bar the switch waits on

    check("a switch settles for the short quiet gap, not the 120s left-alone bar",
          manualMoveIdleSeconds == reloadNowIdleSeconds && manualMoveIdleSeconds < followIdleSeconds)

    // MARK: - 31i. Will anything read the request?

    // The failure this answers is the silent one: a supervisor from a build without this feature
    // registers and stamps its pid exactly like a current one, so a request written for it would be
    // read by nobody while the command reported success.
    check("a supervisor on the installed build reads the request",
          switchHonourability(supervisorVersion: "0.37.0", installedVersion: "0.37.0")
              == .honoured)
    check("another build reads it after replacing itself",
          switchHonourability(supervisorVersion: "0.36.1", installedVersion: "0.37.0")
              == .afterSelfUpdate)
    check("a supervisor with no version stamp never will",
          switchHonourability(supervisorVersion: nil, installedVersion: "0.37.0") == .tooOld)
    check("a CLI outside any bundle cannot compare, and does not invent a problem",
          switchHonourability(supervisorVersion: "0.36.1", installedVersion: nil) == .honoured)

    // MARK: - 31j. The marker the whole feature is addressed by

    // The child env is where `tally switch` finds its session: the supervisor stamps its own pid,
    // and every process the child spawns (the agent's shell included) inherits it.
    let childEnv = supervisedChildEnvironment(
        provider: providers[0], home: "/tmp/A", supervisorVersion: "9.9.9", supervisorPID: "4242",
        relaunch: false, base: ["PATH": "/usr/bin", "CLAUDE_CONFIG_DIR": "/tmp/stale"])
    check("the child carries the supervisor pid a switch addresses",
          childEnv["TALLY_SUPERVISOR_PID"] == "4242")
    check("and the Tally marker the status line reads", childEnv["TALLY_LAUNCHED"] == "1")
    check("and the build stamp behind the supervision note",
          childEnv["TALLY_SUPERVISOR_VERSION"] == "9.9.9")
    check("the account's own home replaces whatever was exported into this process",
          childEnv["CLAUDE_CONFIG_DIR"] == "/tmp/A")
    check("the rest of the environment is passed through", childEnv["PATH"] == "/usr/bin")
    check("a first launch keeps Claude Code's own resume prompt",
          childEnv[resumeTokenThresholdEnvKey] == nil)
    // A switch relaunch resumes by id with nobody at the keyboard, so it must not stop at that
    // prompt - the same suppression every other relaunch gets, carried by the same assembly.
    let relaunchEnv = supervisedChildEnvironment(
        provider: providers[0], home: "/tmp/A", supervisorVersion: nil, supervisorPID: "4242",
        relaunch: true, base: [:])
    check("a relaunch suppresses it",
          relaunchEnv[resumeTokenThresholdEnvKey] == resumePromptDisabledThreshold)
    check("and a supervisor with no version stamps none",
          relaunchEnv["TALLY_SUPERVISOR_VERSION"] == nil)
}
