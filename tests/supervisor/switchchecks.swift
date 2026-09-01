import Foundation

// The TICK half of `tally switch`: what one poll decides about a request (SessionSwitch.swift), and
// the one rule that makes the command usable at all - an explicit switch outranks the pin, and keeps
// outranking it. The request file and the session addressing are in switchrequestchecks.swift and
// switchsessionchecks.swift; the fixtures below are shared with both.
//
// The scenario every assertion here is written against: the agent INSIDE the session is asked to
// move to another account and runs the command itself, as a tool call. So at the moment the request
// lands the session is mid-turn by construction, and the thing that must never happen is the
// supervisor killing the child in the middle of the turn that asked for the switch.

/// Whether a badge names a MOMENT rather than the state it is in. The wording rule both waiting
/// axes are held to (`quietGateHolding`, Reload.swift): the gate reports the first term that said
/// no, so any promise about when a wait lifts is a promise the second term can break, and the badge
/// is the half a person actually reads.
///
/// On WORDS rather than substrings, so a badge is not failed for the letters inside one of its own
/// (a `.contains("when")` would fail "whenever" and, less obviously, would pass "afterwards").
func promisesAMoment(_ badge: String) -> Bool {
    let promises: Set<String> = ["after", "once", "when", "until", "till", "soon", "then"]
    return badge.lowercased().split { !$0.isLetter }.contains { promises.contains(String($0)) }
}

func switchAccount(_ id: String, label: String? = nil,
                           home: String? = nil) -> Snapshot.Account {
    Snapshot.Account(id: id, provider: "claude", label: label ?? id,
                     launchHome: home ?? "/tmp/\(id)", sessionRemaining: 90, weeklyRemaining: 90,
                     modelRemaining: 90, sessionResetsAt: nil, weeklyResetsAt: nil,
                     modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil,
                     isStale: false, error: nil)
}

/// The tick's snapshot reading as the PIN SWITCH asks for it: a fresh document listing exactly
/// these accounts.
///
/// It exists because that half of `applyManualMoves` plays on the movers' shared field
/// (`liveMoveField`, MoveField.swift) rather than on the typed switch's classifier, so a test that
/// wants the pin to act has to hand it a snapshot that can ANSWER - a listing alone is what the
/// typed switch reads, and handing one to an automatic mover is the 2026-09-01 defect
/// (SessionSwitch.swift carries it). `generatedAt` is the seam for the stale case.
func switchFleetReading(_ accounts: [Snapshot.Account],
                        generatedAt: Date = Date()) -> (Snapshot?, String?) {
    let snapshot = Snapshot(version: 2, generatedAt: generatedAt, accounts: accounts)
    let age = Date().timeIntervalSince(generatedAt)
    return (snapshot, age > snapshotMaxAge ? "snapshot is \(Int(age / 60))m old" : nil)
}

/// A session that has been silent for long enough to pass any bar, with no open tool call in it.
func idleWatcher(_ label: String) -> TranscriptWatcher {
    switchWatcher(label, lines: [#"{"type":"user","timestamp":"2026-01-01T00:00:00Z"}"#])
}

/// A child that started moments ago: no transcript anywhere yet, which is the state `reloadQuiet`
/// holds on the child's AGE because there is no file to ask (Reload.swift). The third of the three
/// sources a queued switch can have, and the one with no turn in it at all.
func startupWatcher(_ label: String) -> TranscriptWatcher {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-switch-\(label)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return TranscriptWatcher(projectDir: dir, file: nil, since: Date())
}

/// A session in the middle of a tool call: the assistant opened one moments ago and no result has
/// come back, which is exactly the state `tally switch` is run from. The FILE is stale (the mtime
/// bar passes), so only the open-turn veto can hold this one busy.
func midTurnWatcher(_ label: String) -> TranscriptWatcher {
    let opened = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30))
    return switchWatcher(label, lines: [
        #"{"type":"assistant","timestamp":"\#(opened)","isSidechain":false,"message":{"content":[{"type":"tool_use","id":"toolu_switch"}]}}"#,
    ])
}

func switchWatcher(_ label: String, lines: [String]) -> TranscriptWatcher {
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
    // MARK: - 31c. The tick decision

    let fresh = SwitchRequest(epoch: 200, accountID: "B")
    let namedAccount = switchAccount("B", label: "Claude 2")
    let there = SwitchTargetState.launchable(namedAccount)
    check("a stamp this supervisor already served does nothing",
          switchDecision(served: 200, request: fresh, target: there, onTarget: false,
                         isQuiet: true) == .none)
    check("an older stamp does nothing either",
          switchDecision(served: 300, request: fresh, target: there, onTarget: false,
                         isQuiet: true) == .none)
    check("a newer stamp on a quiet session moves it",
          switchDecision(served: 100, request: fresh, target: there, onTarget: false,
                         isQuiet: true) == .relaunch)
    check("a session mid-turn holds the request rather than losing it",
          switchDecision(served: 100, request: fresh, target: there, onTarget: false,
                         isQuiet: false) == .queued)
    check("a session already on the named account just consumes the request",
          switchDecision(served: 100, request: fresh, target: there, onTarget: true,
                         isQuiet: true) == .alreadyThere)
    // What the target IS gets asked before whether the session is quiet: those are different waits
    // and the badge has to name the right one.
    check("an account that is merely signed out is held, whatever the session is doing",
          switchDecision(served: 100, request: fresh, target: .signedOut, onTarget: false,
                         isQuiet: false) == .unavailable)
    check("and is still held on a quiet session, rather than reading as a move",
          switchDecision(served: 100, request: fresh, target: .signedOut, onTarget: false,
                         isQuiet: true) == .unavailable)
    // No snapshot to judge by says nothing about the account, so it can only mean wait: reading it
    // as "removed" would cancel every pending switch on the machine the moment the file went away.
    check("an unreadable snapshot is a wait, not a verdict",
          switchDecision(served: 100, request: fresh, target: .unreadable, onTarget: false,
                         isQuiet: true) == .unavailable)
    // The one target that is NOT held: an id absent from a snapshot we can read has left the fleet,
    // and ids are re-earned by whatever config home takes the name next (AccountRemovals.swift), so
    // holding would eventually resume this conversation onto a login nobody named.
    check("an account that has left the fleet cancels the request",
          switchDecision(served: 100, request: fresh, target: .removed, onTarget: false,
                         isQuiet: true) == .cancelled)
    check("and cancels it just the same mid-turn - there is nothing left to wait for",
          switchDecision(served: 100, request: fresh, target: .removed, onTarget: false,
                         isQuiet: false) == .cancelled)

    // MARK: - 31c2. Which of those three a fleet actually shows

    let listedIn = [namedAccount,
                    Snapshot.Account(id: "S", provider: "claude", label: "Signed out",
                                     launchHome: nil, sessionRemaining: nil, weeklyRemaining: nil,
                                     modelRemaining: nil, sessionResetsAt: nil, weeklyResetsAt: nil,
                                     modelResetsAt: nil, modelWindowName: nil,
                                     resetCreditsAvailable: nil, isStale: false, error: nil)]
    /// The classifier with the disk answer injected, so nothing here reads a home directory. `gone`
    /// is the ordinary case for these fixtures: ids like "B" name no config home at all.
    func targetState(_ id: String, provider: String = "claude",
                     accounts: [Snapshot.Account]? = listedIn,
                     homeOnDisk: Bool = false) -> SwitchTargetState {
        switchTargetState(id, provider: provider, accounts: accounts,
                          homeOnDisk: { _, _ in homeOnDisk })
    }
    check("an account with a launch home is launchable", targetState("B") == there)
    // Tally publishes a dormant account WITHOUT a launch home, which is it saying "the login is
    // gone and the account is not" - the same distinction the pin resolution draws.
    check("listed with no launch home is signed out, not removed", targetState("S") == .signedOut)
    check("an id this snapshot does not list, with no config home either, has left the fleet",
          targetState("Z") == .removed)
    check("an empty snapshot really does list nobody", targetState("B", accounts: []) == .removed)
    check("but no snapshot at all is unreadable, which is a different thing entirely",
          targetState("B", accounts: nil) == .unreadable)
    check("another provider's account of the same name is not this one",
          targetState("B", provider: "codex") == .removed)
    // The fifth state, and the reason it exists: a snapshot is what the app saw a minute ago, and an
    // account drops out of one for reasons that are nothing to do with removal (a Keychain probe
    // that did not answer, a rescan in flight). A live switch was cancelled by exactly that, with
    // every account present on disk and back in the very next snapshot (2026-08-06).
    check("an id missing from the fleet whose config home is on disk is not removed",
          targetState("Z", homeOnDisk: true) == .unlisted)
    check("…and neither is one missing from an empty snapshot",
          targetState("B", accounts: [], homeOnDisk: true) == .unlisted)
    // The disk is only consulted where it can change the answer: a listed account is judged by the
    // fleet exactly as before, whatever the disk says.
    check("a listed account is not re-judged by the disk",
          targetState("B", homeOnDisk: true) == there
              && targetState("S", homeOnDisk: true) == .signedOut)

    // MARK: - 31c3. The disk answer behind it

    // The id IS the config home's name (`claude:.claude2` → `~/.claude2`), and the path is derived
    // from `defaultHome` rather than spelled here, so the CLI has ONE answer to "where does this
    // provider keep its accounts" (AccountHome.swift).
    let claude = providers[0]
    let codex = providers[1]
    let homeDir = URL(fileURLWithPath: defaultHome(claude)).deletingLastPathComponent().path
    check("the default account's home is the provider's own config dir",
          accountConfigHome("claude:.claude", provider: claude) == "\(homeDir)/.claude")
    check("a numbered one sits beside it",
          accountConfigHome("claude:.claude4", provider: claude) == "\(homeDir)/.claude4")
    check("so does a named one",
          accountConfigHome("claude:.claude-work", provider: claude) == "\(homeDir)/.claude-work")
    check("and codex answers about its own family",
          accountConfigHome("codex:.codex2", provider: codex) == "\(homeDir)/.codex2")
    // Everything that is not one of this provider's config homes answers nil, which reads as "no
    // evidence" at the caller and therefore never blocks a cancellation on its own.
    check("an id for another provider names nothing here",
          accountConfigHome("codex:.codex2", provider: claude) == nil)
    check("an id outside the family names nothing",
          accountConfigHome("claude:.ssh", provider: claude) == nil)
    check("an id with no provider prefix names nothing",
          accountConfigHome(".claude2", provider: claude) == nil)
    // A separator would let a snapshot or a request file point this at a path outside the home
    // directory; the prefix check and this one together make that impossible by construction.
    check("and a path separator is not a config dir name",
          accountConfigHome("claude:.claude/../../etc", provider: claude) == nil)
    check("an unknown provider id has no homes at all",
          !accountHomeExists("mystery:.mystery", provider: "mystery", isDirectory: { _ in true }))
    check("an account whose directory is there exists",
          accountHomeExists("claude:.claude9", provider: "claude", isDirectory: {
              $0 == "\(homeDir)/.claude9"
          }))
    check("…and one whose directory is not, does not",
          !accountHomeExists("claude:.claude9", provider: "claude", isDirectory: { _ in false }))

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

    /// One poll tick's manual-move handling, with everything the loop would read injected -
    /// including the disk, so no assertion here depends on what is in the real home directory.
    func tick(_ watcher: inout TranscriptWatcher, request: SwitchRequest?,
              policy: LaunchPolicy = pinnedNowhere, keyboardIdle: Bool = true,
              accounts: [Snapshot.Account] = fleet, homeOnDisk: Bool = false,
              childAge: TimeInterval = 9999, now: Date = Date())
        -> (plan: RelaunchPlan?, record: PendingSwitchConsumption?) {
        var plan: RelaunchPlan?
        var record: PendingSwitchConsumption?
        var under = policy   // in: the fleet's; out: this session's (`applyManualMoves`)
        applyManualMoves(plan: &plan, state: &state, record: &record, policy: &under,
                         account: onA, providerID: "claude", watcher: &watcher, childAge: childAge,
                         keyboardIdle: { _ in keyboardIdle }, dir: tickDir,
                         request: { _ in request }, accounts: { accounts },
                         homeOnDisk: { _, _ in homeOnDisk }, now: now)
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
    // AND THE WAIT IS VISIBLE WHILE IT LASTS. The panel's picker writes this same request from a
    // surface with no terminal output of its own, so without a badge the person who has just chosen
    // an account has nothing anywhere telling them it was heard (owner report, 2026-08-10).
    check("the queued move says so on the status line", state.waiting?.badge == switchQueuedBadge)
    check("naming where it is going, and where it stays until then",
          state.waiting?.detail?.contains("switching to Claude 2") == true
              && state.waiting?.detail?.contains("staying on A") == true)
    check("and that badge fits the row beside the quota meters",
          (state.waiting?.badge.count ?? 99) <= 24)

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
    check("the badge goes with the move it was describing", state.badge == nil)
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
    // …AND SAYS SO AS ITSELF. `reloadQuiet` is three terms and only the first is a turn, so the one
    // "after this turn" badge was a promise the other two sources could not keep: this session is
    // idle by the transcript, nothing is streaming, and what the move is waiting for is the person
    // to stop typing (codex review of 8b34d49). Asserted through a whole tick, so what is pinned is
    // the badge a supervisor would actually raise rather than a wording function called by hand.
    check("a prompt being typed says the keyboard is what holds the move",
          state.waiting?.badge == switchQueuedTypingBadge)
    check("…and names no turn, because there is none running",
          state.waiting?.detail?.contains("a prompt is being typed") == true
              && state.waiting?.detail?.contains("this turn ends") == false)
    check("…still naming where it is going and where it stays until then",
          state.waiting?.detail?.contains("switching to Claude 2") == true
              && state.waiting?.detail?.contains("staying on A") == true)
    check("and that badge fits the row beside the quota meters",
          (state.waiting?.badge.count ?? 99) <= 24)

    // The third source: a child that started moments ago has written no transcript at all, so the
    // gate holds the move on the child's age (Reload.swift). Nothing is streaming here either, and
    // there is not even a conversation yet for a turn to end in.
    var starting = startupWatcher("startup")
    let onStartup = SwitchRequest(epoch: state.servedEpoch + 2, accountID: "B")
    check("a session with no transcript yet queues the switch on the child's age",
          tick(&starting, request: onStartup, childAge: 1).plan == nil)
    check("…and says it is waiting for the session to come up",
          state.waiting?.badge == switchQueuedStartupBadge)
    check("…with the long form saying there is no turn to end",
          state.waiting?.detail?.contains("written no turn yet") == true
              && state.waiting?.detail?.contains("this turn ends") == false)
    check("that badge fits the row too", (state.waiting?.badge.count ?? 99) <= 24)
    // …and the same session a moment later, once the child is past the bar, is a move rather than a
    // wait: the badge described a state that ends on its own, which is what makes it honest.
    check("the same request fires once the child is old enough",
          tick(&starting, request: onStartup, childAge: 9999).plan?.target.id == "B")

    // TWO GATES SHUT AT ONCE, which is what the promise could not survive (codex review of
    // 1f0c1a6): the gate reports the FIRST term that said no, and here the keyboard is what it
    // reports while a session with no transcript is holding the move as well. Worded as "once the
    // keyboard is quiet" the badge named a moment at which nothing would happen, and the second
    // tick below is that moment.
    var bothShut = startupWatcher("both-shut")
    let onBoth = SwitchRequest(epoch: state.servedEpoch + 3, accountID: "B")
    check("a young session being typed into queues the switch",
          tick(&bothShut, request: onBoth, keyboardIdle: false, childAge: 1).plan == nil)
    check("…and names the keyboard, which is the term the gate reports",
          state.waiting?.badge == switchQueuedTypingBadge)
    check("…describing what holds it rather than promising when it lifts",
          state.waiting?.detail?.contains("a prompt is being typed here") == true
              && state.waiting?.detail?.contains("once the keyboard is quiet") == false)
    // The keyboard goes quiet and the move still does not happen, because the other term was shut
    // the whole time. This is the tick the old wording had promised the move away at.
    check("the keyboard going quiet does not release a move the other term still holds",
          tick(&bothShut, request: onBoth, keyboardIdle: true, childAge: 1).plan == nil)
    check("…and the badge has moved on to the term that is holding it now",
          state.waiting?.badge == switchQueuedStartupBadge)

    // THE THREE ARE THREE, and one wording per gate rather than one gate wearing three names.
    check("no two sources say the same thing",
          Set([switchQueuedBadge, switchQueuedTypingBadge, switchQueuedStartupBadge,
               switchQueuedIdleBadge]).count == 4)
    // Asked of the whole gate rather than of the three the tick above reached: a term added to
    // `QuietGate` and not worded here would be a switch that says nothing while it waits.
    check("the gate has exactly the four terms these badges answer", QuietGate.allCases.count == 4)
    for gate in QuietGate.allCases {
        let wait = switchQueuedWait(gate: gate, target: "Claude 2", staying: "A")
        check("\(gate): names where it is going and where it sits until then",
              wait.detail?.contains("switching to Claude 2") == true
                  && wait.detail?.contains("staying on A") == true)
        check("\(gate): fits the row beside the quota meters", wait.badge.count <= 24)
        check("\(gate): says switch, so the row says which axis is waiting",
              wait.badge.hasPrefix("switch: "))
        // THE BADGE DESCRIBES, LIKE THE CLAUSE BESIDE IT. The gate names the first term that said
        // no and a second can be shut at the same moment, so a badge that named WHEN the move
        // happens named a moment at which nothing does - and the short form is what is read on the
        // status line, so fixing only the long one left the promise on screen (codex review of
        // fe4462d). Asserted as a property of every arm rather than as four strings, because the
        // next term added is where a promise would come back.
        check("\(gate): describes the state, promising no moment it cannot keep",
              !promisesAMoment(wait.badge))
    }

    // The account SIGNED OUT between the command and the tick: nothing is relaunched into a config
    // dir with no login in it, and nothing is said on the terminal either - the child is alive and
    // drawing there, so the wait goes to the status line's badge (PendingNotice.swift's whole rule).
    let dormantZ = Snapshot.Account(id: "Z", provider: "claude", label: "Claude 9",
                                    launchHome: nil, sessionRemaining: nil, weeklyRemaining: nil,
                                    modelRemaining: nil, sessionResetsAt: nil, weeklyResetsAt: nil,
                                    modelResetsAt: nil, modelWindowName: nil,
                                    resetCreditsAvailable: nil, isStale: false, error: nil)
    var vanished = idleWatcher("gone")
    try! writeSwitchRequest(accountID: "Z", sessionKey: session, now: afterServed(), dir: tickDir)
    let goneRequest = readSwitchRequest(sessionKey: session, dir: tickDir)!
    let dropped = tick(&vanished, request: goneRequest, accounts: fleet + [dormantZ])
    check("a request naming a signed-out account plans nothing", dropped.plan == nil)
    check("it raises a badge instead of a line on the shared terminal",
          state.waiting?.badge == "switch: signed out")
    check("with the long form kept for a surface that has room",
          state.waiting?.detail?.contains("no login right now") == true)
    check("the badge fits a status line beside the quota meters",
          (state.waiting?.badge.count ?? 99) <= 24)
    check("and the request is held, not consumed", state.servedEpoch < goneRequest.epoch)
    check("so its file is still there for the tick that can serve it",
          readSwitchRequest(sessionKey: session, dir: tickDir) == goneRequest)
    // The login is renewed: the held request moves the session on its own, and the badge goes.
    let returned = tick(&vanished, request: goneRequest,
                        accounts: fleet + [switchAccount("Z", label: "Claude 9")])
    check("a held request fires once its account is back", returned.plan?.target.id == "Z")
    returned.record?.commit(&state)
    check("and the badge comes down with it", state.badge == nil)

    // The account was REMOVED, which is a different thing and must not be waited on: an id is its
    // config home's name, so a recreated `~/.claude3` is the same id with a different login behind
    // it (AccountRemovals.swift), and a request held against that name would resume this
    // conversation onto whoever claims it next.
    var deleted = idleWatcher("removed")
    try! writeSwitchRequest(accountID: "Q", sessionKey: session, now: afterServed(), dir: tickDir)
    let removedRequest = readSwitchRequest(sessionKey: session, dir: tickDir)!
    let cancelled = tick(&deleted, request: removedRequest)
    check("a request naming an account that has left the fleet plans nothing",
          cancelled.plan == nil)
    check("and is cancelled rather than held", state.servedEpoch == removedRequest.epoch)
    check("with its file removed", readSwitchRequest(sessionKey: session, dir: tickDir) == nil)
    check("the badge says the move was cancelled, not that it is waiting",
          state.badge?.badge == "switch: account removed" && state.waiting == nil)
    check("and says why at length", state.badge?.detail?.contains("no longer in the fleet") == true)
    check("that badge fits the row too", (state.badge?.badge.count ?? 99) <= 24)
    // The cancellation is news about a request that no longer exists, so it is held rather than
    // re-derived - and the next request the user makes is what supersedes it.
    check("a later tick with nothing pending keeps the notice up",
          tick(&deleted, request: nil).plan == nil && state.badge?.badge == "switch: account removed")
    let afterCancel = SwitchRequest(epoch: state.servedEpoch + 1, accountID: "B")
    _ = tick(&deleted, request: afterCancel, keyboardIdle: false)
    // The news is gone: it described a request that has been superseded. What stands in its place is
    // the new request's own wait, which is the live thing to say about this session now - it is the
    // keyboard holding this tick, and the badge for that is the keyboard's own.
    check("but a fresh request takes it down", state.cancelled == nil)
    check("leaving the wait that request is actually in",
          state.badge?.badge == switchQueuedTypingBadge)

    // …and so does the user coming back, which is the bound this notice was missing: nothing
    // re-derives it, so before it was given an end it stayed on the status line for the life of the
    // session - "switch: account removed" was still there long after the account was back, and it
    // even outlived the app update that replaced the supervisor (2026-08-06).
    //
    // The end is THEIR NEXT PROMPT, and the first version of this got that wrong in a way worth
    // keeping a test for: it ended on the next assistant event, and `tally switch` is normally run
    // BY the agent as a tool call, so the turn that queued it writes several more assistant events
    // seconds later. The notice came down before the answer it belongs to had finished printing.
    func stampedLine(_ body: String, at offset: TimeInterval) -> String {
        let when = ISO8601DateFormatter().string(from: Date().addingTimeInterval(offset))
        return #"{"timestamp":"\#(when)","isSidechain":false,\#(body)}"#
    }
    /// A transcript, ALREADY SCANNED: the tick reads the watcher `observeCapHit` has just walked
    /// (Supervisor.swift keeps that order and capresetchecks.swift asserts it), so a fixture that
    /// had never been scanned would be testing a state the loop cannot be in.
    func scannedWatcher(_ label: String, lines: [String]) -> TranscriptWatcher {
        var watcher = switchWatcher(label, lines: lines)
        _ = watcher.sawCapHit()
        return watcher
    }
    let noticeDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-switch-notice-\(UUID().uuidString)")
    // A whole second, because the file round-trips through ISO 8601 and the stamp has to come back
    // EXACTLY as it went in for the expiry to measure from the original moment.
    let raisedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let cancelledAt = Date().addingTimeInterval(-120)
    try! writeSwitchRequest(accountID: "Q2", sessionKey: session, now: afterServed(), dir: tickDir)
    let secondRemoval = readSwitchRequest(sessionKey: session, dir: tickDir)!
    _ = tick(&deleted, request: secondRemoval, now: cancelledAt)
    check("a second removal raises the notice again",
          state.badge?.badge == "switch: account removed")
    // Written to disk the way the loop writes it, so the exec case further down takes over a real
    // notice rather than a hand-built one.
    var beforeExec = PendingNoticeWriter(pid: "9191", dir: noticeDir)
    syncPendingNotice(&beforeExec, pid: "9191", manualMove: state.badge, reload: nil,
                      followDeadEnd: false, followQueued: false, policy: pinnedNowhere,
                      capReason: nil, dir: noticeDir, now: raisedAt)
    check("the loop's own writer records it as a cancellation, not as a wait",
          readPendingNotice(pid: "9191", dir: noticeDir)?.kind == cancellationNoticeKind)
    // The rest of the turn the command was run in: the tool's result comes back as a `user` event
    // and the agent keeps writing. None of that is the person saying anything.
    var restOfTurn = scannedWatcher("restofturn", lines: [
        stampedLine(#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_s","content":"cancelled"}]}"#, at: -90),
        stampedLine(#""type":"assistant","message":{"model":"claude-fable-5"}"#, at: -80),
    ])
    _ = tick(&restOfTurn, request: nil)
    check("the rest of the turn that asked for the switch does not take the notice down",
          state.badge?.badge == "switch: account removed")
    // Nor does Claude Code's own synthetic user event.
    var injected = scannedWatcher("injected", lines: [
        stampedLine(#""type":"user","isMeta":true,"message":{"content":"<system-reminder>"}"#, at: -70),
    ])
    _ = tick(&injected, request: nil)
    check("neither does a synthetic user event nobody typed",
          state.badge?.badge == "switch: account removed")
    // Nor does a background agent finishing. Claude Code appends a main-chain `user` event when a
    // task completes, and it carries no tool_result and is not isMeta, so the first two guards let
    // it through - on a machine running agents that is dozens of false "the user came back" signals
    // a day. It is refused on Claude Code's own structural marker (`promptSource: system`).
    var taskNotified = scannedWatcher("tasknotify", lines: [
        stampedLine(#""type":"user","promptSource":"system","message":{"content":"<task-notification>\n<task-name>x</task-name>"}"#, at: -95),
    ])
    check("a task notification is not the user saying anything",
          taskNotified.lastUserTurnAt == nil)
    _ = tick(&taskNotified, request: nil)
    check("so an agent finishing does not take the notice down",
          state.badge?.badge == "switch: account removed")
    // Not every system-injected prompt is a task notification (the corpus has plain ones too), and
    // those can only be refused by the structural marker - which is why the two guards are not
    // interchangeable and are asserted apart.
    let systemInjected = scannedWatcher("systeminjected", lines: [
        stampedLine(#""type":"user","promptSource":"system","message":{"content":"continue"}"#, at: -96),
    ])
    check("anything Claude Code injects as a system prompt is not the user typing",
          systemInjected.lastUserTurnAt == nil)
    // Transcripts written before that field existed carry the same events without it; the content
    // shape is the fallback that covers them, and the only fragile guard of the four.
    let legacyNotify = scannedWatcher("legacynotify", lines: [
        stampedLine(#""type":"user","message":{"content":"<task-notification>\n<task-name>x</task-name>"}"#, at: -94),
    ])
    check("…and one from before that field existed is caught by its shape",
          legacyNotify.lastUserTurnAt == nil)
    // The other direction, which the refusal must not break: a prompt with NO promptSource is what
    // every older transcript's typed prompts look like, so "absent" has to keep meaning "a person".
    let oldStyle = scannedWatcher("oldstyle", lines: [
        stampedLine(#""type":"user","message":{"content":"do the thing"}"#, at: -93),
    ])
    check("a prompt carrying no promptSource still counts as one", oldStyle.lastUserTurnAt != nil)
    let typedPrompt = scannedWatcher("typedprompt", lines: [
        stampedLine(#""type":"user","promptSource":"typed","message":{"content":"do the thing"}"#, at: -92),
    ])
    check("and a typed one certainly does", typedPrompt.lastUserTurnAt != nil)

    // A prompt OLDER than the notice is not an answer to it either: it was still on screen when
    // that prompt was sent, so it has not been read since.
    var earlier = scannedWatcher("earlier", lines: [
        stampedLine(#""type":"user","message":{"content":"before all this"}"#, at: -300),
    ])
    _ = tick(&earlier, request: nil)
    check("a prompt that predates the notice does not take it down",
          state.badge?.badge == "switch: account removed")
    // The next thing they type does.
    var typedAgain = scannedWatcher("typed", lines: [
        stampedLine(#""type":"user","message":{"content":"ok, try Claude 2"}"#, at: -60),
    ])
    _ = tick(&typedAgain, request: nil)
    check("the first prompt after it ends the notice", state.badge == nil)
    check("and it stays gone on the ticks after that",
          tick(&typedAgain, request: nil).plan == nil && state.badge == nil)

    // Surviving the app update in between: the exec keeps the pid and starts the state from
    // nothing, so the notice lives only in its file - and the seeded writer would take it down as
    // the honest answer to "nothing is pending" unless it is picked back up (`adoptCancellation`).
    var afterUpgrade = ManualMoveState(sessionKey: "9191", servedEpoch: 0)
    afterUpgrade.adoptCancellation(readPendingNotice(pid: "9191", dir: noticeDir))
    check("the new image picks the notice back up",
          afterUpgrade.badge?.badge == "switch: account removed")
    check("…stamped when it was RAISED, not when the upgrade happened",
          afterUpgrade.cancelledAt == raisedAt)
    // The half that made this necessary: the new image's writer is seeded from that same file, so
    // an empty state would have had it unlink the notice on the very first tick. With the state
    // holding it, the first sync writes the same badge back and the file stands.
    var afterExecWriter = PendingNoticeWriter(pid: "9191", dir: noticeDir)
    syncPendingNotice(&afterExecWriter, pid: "9191", manualMove: afterUpgrade.badge, reload: nil,
                      followDeadEnd: false, followQueued: false, policy: pinnedNowhere,
                      capReason: nil, dir: noticeDir, now: raisedAt.addingTimeInterval(30))
    check("so the first tick of the new image leaves the notice on screen",
          readPendingNotice(pid: "9191", dir: noticeDir)?.badge == "switch: account removed")
    check("…still stamped from when it was raised",
          readPendingNotice(pid: "9191", dir: noticeDir)?.since == raisedAt)
    // And it ends the same way it would have without the upgrade.
    afterUpgrade.expireCancellation(lastUserTurnAt: raisedAt.addingTimeInterval(-10))
    check("a prompt from before it still does not end it", afterUpgrade.badge != nil)
    afterUpgrade.expireCancellation(lastUserTurnAt: raisedAt.addingTimeInterval(10))
    check("and the first prompt after it does", afterUpgrade.badge == nil)
    // The wiring only the loop can show, asserted against the source the way the rebalance and the
    // cap reset do it: the adoption happens, and only where the pid was inherited (on a normal
    // launch any notice under this pid belongs to a dead session, and the sweep removes it).
    let loopSource = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the switch checks", !loopSource.isEmpty)
    check("a supervisor that took over a running session adopts the notice it left behind", {
        guard let start = loopSource.range(of: "if resumed {"),
              let end = loopSource.range(of: "sweepDeadSupervisorState()",
                                         range: start.upperBound ..< loopSource.endIndex)
        else { return false }
        let block = String(loopSource[start.upperBound ..< end.lowerBound])
        // Both axes are offered the same read, and each takes only its own kind: the model axis has
        // news of its own now (`adoptAdoption`, SessionModel.swift), and it was being dropped by the
        // upgrade exactly as this one was (review, 2026-08-07).
        return block.contains("readPendingNotice(") && block.contains("adoptCancellation(")
            && block.contains("adoptAdoption(")
    }())
    // The upgrade this has to survive FIRST is out of the build that shipped the notice without the
    // `kind` field (0.38.0 → 0.38.1): those files carry no kind at all, and the structural test
    // alone would refuse them - unlinking, on the very next sync, exactly the notice being kept.
    writePendingNotice(PendingNotice(badge: switchCancelledBadge, detail: "…", since: raisedAt),
                       pid: "9393", dir: noticeDir)
    var fromOldBuild = ManualMoveState(sessionKey: "9393", servedEpoch: 0)
    fromOldBuild.adoptCancellation(readPendingNotice(pid: "9393", dir: noticeDir))
    check("a notice from a build that stamped no kind is still recognised",
          fromOldBuild.badge?.badge == switchCancelledBadge)
    check("…with its original stamp, so the expiry is unchanged", fromOldBuild.cancelledAt == raisedAt)
    check("and what this session writes from here on carries the kind",
          fromOldBuild.badge?.kind == cancellationNoticeKind)
    // A WAIT is not adopted: those are re-derived from live state within a tick or two, so picking
    // one up would only risk showing a condition that has since cleared. The legacy arm above is a
    // whitelist of one badge, so it does not loosen this: a kind-less wait is still refused.
    writePendingNotice(PendingNotice(badge: "switch: signed out", detail: nil, since: raisedAt),
                       pid: "9292", dir: noticeDir)
    var waitAdopter = ManualMoveState(sessionKey: "9292", servedEpoch: 0)
    waitAdopter.adoptCancellation(readPendingNotice(pid: "9292", dir: noticeDir))
    check("a wait badge on disk is not picked up as news", waitAdopter.badge == nil)
    try? FileManager.default.removeItem(at: noticeDir)

    // The same tick, with the account's config home still on disk: the fleet and the filesystem
    // disagree, so the request is HELD rather than cancelled. This is the reported bug end to end -
    // a statusline showing "switch: account removed" while all five accounts were present, because
    // one snapshot happened not to list the target (2026-08-06).
    var blinked = idleWatcher("blinked")
    try! writeSwitchRequest(accountID: "Q", sessionKey: session, now: afterServed(), dir: tickDir)
    let blinkedRequest = readSwitchRequest(sessionKey: session, dir: tickDir)!
    let blinkHeld = tick(&blinked, request: blinkedRequest, homeOnDisk: true)
    check("an account missing from the snapshot but present on disk plans nothing yet",
          blinkHeld.plan == nil)
    check("and is HELD, not cancelled", state.servedEpoch < blinkedRequest.epoch)
    check("so the request survives for the tick that can serve it",
          readSwitchRequest(sessionKey: session, dir: tickDir) == blinkedRequest)
    check("the badge names the wait rather than announcing a removal",
          state.waiting?.badge == "switch: not listed" && state.cancelled == nil)
    check("…and says which of the two waits it is, so nobody renews a login that is fine",
          state.waiting?.detail?.contains("config home is still on disk") == true)
    check("that badge fits the status line too", (state.waiting?.badge.count ?? 99) <= 24)
    // And it fires by itself the moment the fleet lists the account again - no second command.
    let listedAgain = tick(&blinked, request: blinkedRequest,
                           accounts: fleet + [switchAccount("Q", label: "Claude 7")],
                           homeOnDisk: true)
    check("the held request moves the session once the snapshot catches up",
          listedAgain.plan?.target.id == "Q")
    listedAgain.record?.commit(&state)
    check("and the wait comes down with it", state.badge == nil)

    // An unreadable snapshot says nothing about the account, so it waits rather than cancelling:
    // otherwise a missing snapshot file would drop every pending switch on the machine.
    var blind = idleWatcher("blind")
    try! writeSwitchRequest(accountID: "B", sessionKey: session, now: afterServed(), dir: tickDir)
    let blindRequest = readSwitchRequest(sessionKey: session, dir: tickDir)!
    var blindPlan: RelaunchPlan?
    var blindRecord: PendingSwitchConsumption?
    var blindPolicy = pinnedNowhere
    applyManualMoves(plan: &blindPlan, state: &state, record: &blindRecord, policy: &blindPolicy,
                     account: onA, providerID: "claude", watcher: &blind, childAge: 9999,
                     keyboardIdle: { _ in true }, dir: tickDir, request: { _ in blindRequest },
                     accounts: { nil }, homeOnDisk: { _, _ in false })
    check("no snapshot at all holds the request", blindPlan == nil)
    check("without cancelling it", state.servedEpoch < blindRequest.epoch
              && readSwitchRequest(sessionKey: session, dir: tickDir) == blindRequest)
    // Its own wording, not the dormant account's: there is no snapshot to find ANY account in, and
    // sending the reader off to renew a login that is fine is the wrong instruction twice over.
    check("and badges it as a wait of its own kind",
          state.waiting?.badge == "switch: no snapshot")
    check("…naming what is actually missing", state.waiting?.detail?.contains("Tally.app") == true)
    check("that badge fits the row too", (state.waiting?.badge.count ?? 99) <= 24)
    // AND WHEN THE REQUEST ITSELF VANISHES, the badge goes with it. Same defect and same mechanism
    // as the model axis (reported there, QA 2026-08-07): with no request left, the early return at
    // the top of this station was the only path a tick took, so a wait raised for an instruction
    // that no longer exists stayed on the status line for the rest of the conversation. The badge
    // is only re-derived on ticks that get past that guard.
    var strandedWatcher = idleWatcher("switch-stranded")
    _ = tick(&strandedWatcher, request: nil)
    check("a tick with no request left clears the wait that described one", state.waiting == nil)
    clearSwitchRequest(sessionKey: session, dir: tickDir)

    // The session got there on its own (a cap handoff landed on the named account first).
    var arrived = idleWatcher("arrived")
    let onTarget = SwitchRequest(epoch: state.servedEpoch + 1, accountID: "A")
    let alreadyThere = tick(&arrived, request: onTarget)
    check("a switch to the account we are already on restarts nothing",
          alreadyThere.plan == nil)
    check("and is consumed, not left pending", state.servedEpoch == onTarget.epoch)

    // MARK: - 31g. The switch against the pin

    // The case the session pin exists for: a project pinned to one account (`tally project set
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
    check("the account it named is what this session is now pinned to", state.sessionPin == "D")
    check("so the pin no longer drags the session back",
          tick(&pinned, request: nil, policy: pinnedToB).plan == nil)
    // A pin MOVED afterwards does not take this session with it either: it is the FLEET saying
    // where sessions go, and this session was given an instruction of its own, which outranks it
    // until the user releases it. (The rest of that story is in sessionpinchecks.swift.)
    var pinnedToA = LaunchPolicy()
    pinnedToA.mode = "manual"
    pinnedToA.pinnedAccountID = "A"
    check("and moving that pin somewhere new does not either",
          tick(&pinned, request: nil, policy: pinnedToA).plan == nil)

    // The pin switch itself, unchanged by any of this: a session with no switch in its history
    // follows the panel exactly as before (this path moved file when the switch was added).
    var plainPin = ManualMoveState(sessionKey: "no-switches", servedEpoch: 0)
    var plainWatcher = idleWatcher("plainpin")
    var plainPlan: RelaunchPlan?
    var plainRecord: PendingSwitchConsumption?
    var plainPolicy = pinnedToB
    applyManualMoves(plan: &plainPlan, state: &plainPin, record: &plainRecord, policy: &plainPolicy,
                     account: onA, providerID: "claude", watcher: &plainWatcher,
                     childAge: 9999, keyboardIdle: { _ in true }, dir: tickDir,
                     request: { _ in nil }, accounts: { fleet },
                     loaded: { switchFleetReading(fleet) })
    check("a pinned session with no switch history follows the pin",
          plainPlan?.target.id == "B" && plainPlan?.reason == "pin")
    check("a pin switch never counts against the fuse either", plainPlan?.countsFuse == false)
    // Mid-turn, the pin waits exactly as the switch does.
    var pinMidTurn = midTurnWatcher("pinopen")
    var midPlan: RelaunchPlan?
    var midRecord: PendingSwitchConsumption?
    var midState = ManualMoveState(sessionKey: "no-switches", servedEpoch: 0)
    var midPolicy = pinnedToB
    applyManualMoves(plan: &midPlan, state: &midState, record: &midRecord, policy: &midPolicy,
                     account: onA, providerID: "claude", watcher: &pinMidTurn, childAge: 9999,
                     keyboardIdle: { _ in true }, dir: tickDir, request: { _ in nil },
                     accounts: { fleet }, loaded: { switchFleetReading(fleet) })
    check("a pin does not cut a live turn short either", midPlan == nil)
    try? FileManager.default.removeItem(at: tickDir)

}
