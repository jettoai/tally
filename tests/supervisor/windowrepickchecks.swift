import Foundation

// The window repick: a session that has just cleared its own context is empty, so the restart that
// carries it off a nearly dry account costs nothing, and that is the one moment the idle rebalance
// next door cannot reach (its bar is 120s of total silence plus one move per account per drought,
// which on a busy machine arrived 29 times in three weeks and then not at all for eleven days).
//
// The behaviour under test, in the order the feature happens: what arms it (the line the input gate
// actually typed, not the one somebody asked for), what fires it (Claude Code reporting a DIFFERENT
// conversation, which is the only evidence that the `/clear` reached a composer rather than a
// prompt), which gates it holds, and the order it is asked in relative to the rebalance.
//
// Section 34 also carries the residue defect this package fixed alongside it: a relaunch inherits
// the previous child's subagent transcripts, and a window measured against the wall clock read them
// as a live package on a brand new idle child.

func runWindowRepickChecks() {
    // MARK: - 33. Arming, and the evidence that the window really closed

    var armed = WindowRepickState()
    armed.arm(typed: "/clear", transcript: "before", now: launch)
    check("a `/clear` that was typed arms the repick", armed.typedAt == launch)
    check("…remembering the conversation it is leaving", armed.leaving == "before")

    var spaced = WindowRepickState()
    spaced.arm(typed: "  /clear  ", transcript: nil, now: launch)
    check("surrounding whitespace does not hide the command", spaced.typedAt == launch)

    for other in ["/compact", "/clear now", "clear", "2", ""] {
        var no = WindowRepickState()
        no.arm(typed: other, transcript: "before", now: launch)
        // `/compact` is the one worth naming: it KEEPS the conversation, so the restart it would
        // open is not free, and everything here rests on the session being empty.
        check("`\(other)` is not a window closing", no.typedAt == nil)
    }
    var nothing = WindowRepickState()
    nothing.arm(typed: nil, transcript: "before", now: launch)
    check("a request that typed nothing arms nothing", nothing.typedAt == nil)

    func readiness(_ state: WindowRepickState, _ transcript: String?,
                   after seconds: TimeInterval = 4) -> WindowRepickReadiness {
        windowRepickReadiness(state, transcript: transcript,
                              now: launch.addingTimeInterval(seconds))
    }
    check("nothing typed is nothing to wait for",
          readiness(WindowRepickState(), "anything") == .idle)
    // THE GATE THE BRIEF NAMES: a line still sitting in the composer, or one that went into a
    // prompt instead, leaves Claude Code in the conversation it was already in. Nothing is planned
    // on the strength of having typed it.
    check("the same conversation means the clear has not landed", readiness(armed, "before")
          == .waiting)
    check("no conversation at all is not evidence either", readiness(armed, nil) == .waiting)
    check("a different conversation is the clear landing", readiness(armed, "after") == .landed)
    check("and the wait is bounded, so a line that was eaten fires nothing later",
          readiness(armed, "after", after: windowRepickWindow + 1) == .expired)
    check("the boundary itself is still inside the window",
          readiness(armed, "after", after: windowRepickWindow) == .landed)
    // A session that had written no transcript when the line was typed: any reported id differs
    // from nothing, which is the right reading - there is a conversation now and there was not.
    var unbound = WindowRepickState()
    unbound.arm(typed: "/clear", transcript: nil, now: launch)
    check("a session with nothing bound when it cleared still lands", readiness(unbound, "after")
          == .landed)
    var disarmed = armed
    disarmed.disarm()
    check("disarming really disarms", readiness(disarmed, "after") == .idle)

    // MARK: - 33b. Which sessions move, and where to

    func acct(_ id: String, model: Double, provider: String = "claude", stale: Bool = false,
              error: String? = nil) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: provider, label: id, launchHome: "/tmp/\(id)",
                         sessionRemaining: 90, weeklyRemaining: 90, modelRemaining: model,
                         sessionResetsAt: launch.addingTimeInterval(4 * 3600),
                         weeklyResetsAt: launch.addingTimeInterval(100 * 3600),
                         modelResetsAt: launch.addingTimeInterval(100 * 3600),
                         modelWindowName: "fable", resetCreditsAvailable: nil,
                         isStale: stale, error: error)
    }
    let dying = acct("A", model: 3)
    let healthy = acct("B", model: 77)
    let alsoDry = acct("C", model: 2)
    let primary = "fable"

    var snapshotReads = 0
    func move(_ accounts: [Snapshot.Account] = [dying, healthy], problem: String? = nil,
              mode: String = "auto", steering: Bool = true, carryable: Bool = true,
              fuseAllows: Bool = true,
              quarantine: [String: (model: String?, until: Date)] = [:],
              on: Snapshot.Account = dying) -> Snapshot.Account? {
        windowRepickMove(provider: "claude", account: on, primaryModel: primary, mode: mode,
                         steering: steering,
                         carryable: carryable, fuseAllows: fuseAllows, quarantine: quarantine,
                         loaded: {
                             snapshotReads += 1
                             return (Snapshot(version: 2, generatedAt: launch,
                                              accounts: accounts), problem)
                         }(),
                         now: launch)
    }

    // The move this whole feature exists for.
    check("a cleared window on a dying account reopens on the comfortable sibling",
          move()?.id == "B")
    check("and it picks the healthiest sibling rather than merely an eligible one",
          move([dying, alsoDry, healthy])?.id == "B")

    // THE BRIEF'S SECOND DIRECTION: this is opportunistic, not "re-pick every window". An account
    // with room is left exactly where it is, however good a sibling looks.
    check("a comfortable account is not moved off", move([acct("A", model: 40), healthy]) == nil)
    check("the line is the shared one, not a second threshold of its own",
          move([acct("A", model: nearlyDryPercent), healthy])?.id == "B"
              && move([acct("A", model: nearlyDryPercent + 0.1), healthy]) == nil)

    check("nowhere better to be means stay put", move([dying, alsoDry]) == nil)
    check("no sibling at all means stay put", move([dying]) == nil)
    check("a pinned session is never moved by quota reasoning", move(mode: "manual") == nil)
    check("a spent recovery fuse stops it too", move(fuseAllows: false) == nil)
    check("a conversation that cannot be carried is not moved", move(carryable: false) == nil)
    check("a stale snapshot moves nobody", move(problem: "snapshot is 40m old") == nil)
    check("an account missing from the snapshot moves nobody", move([healthy]) == nil)
    check("a quarantined sibling is not a target",
          move(quarantine: ["B": (model: primary, until: launch.addingTimeInterval(600))]) == nil)
    check("a sibling on another provider is not a target",
          move([dying, acct("codex-1", model: 77, provider: "codex")]) == nil)
    check("an errored sibling is not a target", move([dying, acct("B", model: 77, error: "boom")])
          == nil)
    check("a stale-flagged sibling is not a target",
          move([dying, acct("B", model: 77, stale: true)]) == nil)

    // The cheap gates come first, so a tick that could not move this session never opens the file.
    snapshotReads = 0
    _ = move(mode: "manual")
    _ = move(carryable: false)
    _ = move(fuseAllows: false)
    check("a session this could not move reads no snapshot at all", snapshotReads == 0)
    check("and the one it can reads it once", move()?.id == "B" && snapshotReads == 1)

    // THE STAMPEDE DECISION, ASSERTED RATHER THAN DESCRIBED. The rebalance takes one move per
    // account per drought across supervisors, because every session re-reads the same picture on
    // every 2s tick. This does not, and must not: a weekly drought lasts days, so the first session
    // to clear a window would take the account's one move and every window cleared afterwards would
    // be refused for the rest of it - which is the eleven-day silence this feature answers.
    check("a second window closing in the same drought is moved as well",
          move()?.id == "B" && move()?.id == "B" && move()?.id == "B")

    // MARK: - 33c. The station, and the order the two movers are asked in

    // WHAT A CLEARED TRANSCRIPT HOLDS, in the shape this machine's corpus holds it (2026-08-17,
    // 208 transcripts a `/clear` created): the invocation itself is a main-chain `user` event, and
    // the caveat beside it is another. So "any main-chain message means the window was used" reads
    // EVERY fresh window as used, and the fixtures have to carry the real records for a test to be
    // able to tell the difference at all.
    let clearRecords = """
        {"type":"attachment","isSidechain":false}
        {"type":"user","isMeta":true,"isSidechain":false,"message":{"role":"user",\
        "content":"<local-command-caveat>Caveat: The messages below were generated by the user."}}
        {"type":"user","isSidechain":false,"message":{"role":"user",\
        "content":"<command-name>/clear</command-name> <command-message>clear</command-message>"}}
        {"type":"system","subtype":"local_command","isSidechain":false}
        """
    /// And what somebody coming back to that window leaves in it, before any answer has arrived.
    let typedPrompt = """
        {"type":"user","isSidechain":false,"promptSource":"typed","timestamp":"2026-08-17T04:00:00.000Z",\
        "message":{"role":"user","content":"right, next task"}}
        """
    /// The two together: a window that was cleared and then worked in.
    let workedWindow = clearRecords + "\n" + typedPrompt
    /// A SessionStart injection waking the session up: `isMeta`, `promptSource:"system"`, and the
    /// opening of a REAL turn - 1,963 of them in this machine's corpus, 83 of them the first turn of
    /// a cleared window. It is the shape a rule that forgave every meta expansion could not see.
    let metaWakeUp = """
        {"type":"user","isMeta":true,"isSidechain":false,"promptSource":"system",\
        "timestamp":"2026-08-17T04:00:00.000Z","message":{"role":"user",\
        "content":"<system-reminder>inbox: 1 unread</system-reminder>"}}
        """
    /// What Claude Code writes AFTER a prompt and before the answer, and therefore all that is left
    /// in view when the prompt itself is bigger than the tail window.
    let trailingRecords = """
        {"type":"attachment","isSidechain":false}
        {"type":"last-prompt"}
        {"type":"queue-operation"}
        """

    /// A session bound to `id`, whose transcript was last written `age` seconds ago and holds
    /// `body`.
    func session(id: String, age: TimeInterval = 600, body: String = "{}") -> TranscriptWatcher {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-window-repick-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(id).jsonl")
        try! body.write(to: file, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
        // `since` in the future keeps the fork scan out of this: these fixtures are about the
        // repick's own gates, and `launch` is what every other supervisor fixture uses for it.
        return TranscriptWatcher(projectDir: dir, file: file, since: launch)
    }

    /// That session writing to its own transcript, `secondsAgo` seconds ago: what a turn typed into
    /// the cleared window leaves behind. Ages rather than timestamps, because a file's mtime is read
    /// against the wall clock while the state above runs on the suite's own `launch`.
    func wrote(_ watcher: TranscriptWatcher, secondsAgo: TimeInterval) {
        guard let file = watcher.file else { return }
        try! FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-secondsAgo)], ofItemAtPath: file.path)
    }

    /// One tick of the station. Returns the plan it made and whether the rebalance's cross-
    /// supervisor claim was taken, which is how the ORDER of the two movers is observed.
    func tick(repick: inout WindowRepickState, watcher: inout TranscriptWatcher,
              accounts: [Snapshot.Account] = [dying, healthy], mode: String = "auto",
              keyboardIdle: Bool = true, fuseAllows: Bool = true, draftSuspected: Bool = false,
              steering: Bool = true, blocked: Bool = false, agentsWorking: Bool = false,
              turnBoundaryPending: Bool = false,
              plan seed: RelaunchPlan? = nil,
              at when: Date = launch.addingTimeInterval(4)) -> (plan: RelaunchPlan?, claimed: Bool) {
        let claimDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-window-repick-claim-\(UUID().uuidString)")
        var plan = seed
        applyProactiveMoves(plan: &plan, repick: &repick, watcher: &watcher,
                            keyboardIdle: { _ in keyboardIdle },
                            draftSuspected: draftSuspected, provider: "claude",
                            account: dying, primaryModel: primary, mode: mode,
                            steering: steering, blocked: blocked, agentsWorking: agentsWorking,
                            launchArgs: [],
                            fuseAllows: fuseAllows, turnBoundaryPending: turnBoundaryPending,
                            loaded: (Snapshot(version: 2, generatedAt: launch,
                                              accounts: accounts), nil),
                            now: when, dir: claimDir)
        let cycle = rebalanceCycleKey(dying, primaryModel: primary, now: when) ?? "-"
        let claimed = ((try? FileManager.default.contentsOfDirectory(atPath: claimDir.path)) ?? [])
            .contains { $0.hasSuffix(".\(cycle)") }
        try? FileManager.default.removeItem(at: claimDir)
        return (plan, claimed)
    }

    // THE BRIEF'S FIRST DIRECTION, end to end: the clear was served, Claude Code reports the new
    // conversation, the account is nearly dry, and a repick is planned.
    var landedState = WindowRepickState()
    landedState.arm(typed: "/clear", transcript: "before", now: launch)
    var landedWatcher = session(id: "after")
    let planned = tick(repick: &landedState, watcher: &landedWatcher)
    check("a cleared window on a dying account plans a repick",
          planned.plan?.target.id == "B" && planned.plan?.reason == "window-repick")
    check("…and it counts against the recovery fuse, like every automatic move",
          planned.plan?.countsFuse == true)
    // THE ORDER, WHICH IS A RULE: this fixture satisfies the rebalance too (600s of silence, quiet
    // keyboard, dying account, healthy sibling), so if the rebalance were asked first it would have
    // answered AND spent the account's one claim for the drought on it.
    check("the free move is taken first, leaving the drought's one rebalance claim untouched",
          !planned.claimed)
    // AND THE FREE MOVE IS AHEAD OF THE TURN BOUNDARY'S STAND-DOWN TOO, which is the same rule
    // reaching one mover further down the ladder: a boundary waiting to be ruled on holds the
    // rebalance and must not hold the cheapest restart in the session's life.
    var boundaryLanded = WindowRepickState()
    boundaryLanded.arm(typed: "/clear", transcript: "before", now: launch)
    var boundaryLandedWatcher = session(id: "after")
    check("…even when a reported turn boundary is still waiting to be ruled on",
          tick(repick: &boundaryLanded, watcher: &boundaryLandedWatcher,
               turnBoundaryPending: true).plan?.reason == "window-repick")

    // THE BRIEF'S SECOND DIRECTION at the station: a comfortable account plans nothing at all. The
    // rebalance behind it agrees, so this also proves the station does not fall through into a move
    // the repick declined.
    var comfyState = WindowRepickState()
    comfyState.arm(typed: "/clear", transcript: "before", now: launch)
    var comfyWatcher = session(id: "after")
    let comfy = tick(repick: &comfyState, watcher: &comfyWatcher,
                     accounts: [acct("A", model: 40), healthy])
    check("a cleared window on a comfortable account plans nothing", comfy.plan == nil)

    // THE BRIEF'S THIRD DIRECTION: the queued line has NOT been consumed. Claude Code still reports
    // the conversation it was in, so nothing is planned - and the plan that would lose the queued
    // line is precisely the one this refuses to make.
    //
    // The fixture is quiet at the repick's 5s bar and NOT at the rebalance's 120s one, so nothing
    // else in the station can answer and the refusal is unambiguously this gate's. (Left at 600s it
    // would be the rebalance planning a move, which is correct and says nothing about the repick.)
    var queuedState = WindowRepickState()
    queuedState.arm(typed: "/clear", transcript: "before", now: launch)
    var queuedWatcher = session(id: "before", age: 30)
    let queued = tick(repick: &queuedState, watcher: &queuedWatcher)
    check("a `/clear` still sitting in the composer relaunches nothing", queued.plan == nil)
    check("…and the arm survives, so the tick after the clear lands can still take it",
          queuedState.typedAt == launch)

    // MARK: - The draft gate, at the trigger end of the same invariant

    // WHAT THIS ANSWERS (2026-08-19, the last of the draft-protection family): the arm end of the
    // rule lives in the input station - a clear typed over a suspected draft cancels rather than
    // arms (`SessionInputRepick`) - and it cannot see a draft that was typed AFTERWARDS, in a window
    // this station cleared cleanly. Five seconds after that person stops typing, both gates above
    // are satisfied and the relaunch takes their composer with it: the same defect through a
    // different door. So the reading is asked here too, and it covers BOTH movers below it.
    var draftState = WindowRepickState()
    draftState.arm(typed: "/clear", transcript: "before", now: launch)
    var draftWatcher = session(id: "after")
    let held = tick(repick: &draftState, watcher: &draftWatcher, draftSuspected: true)
    check("a session that may hold an unsent draft is not repicked, however free the move is",
          held.plan == nil)
    // A DELAY, NOT A CANCELLATION, which is the whole of why this gate is here rather than in the
    // arm: nothing is consumed, so the move happens as soon as the draft reading clears - a new user
    // turn, or this supervisor typing. The arm is intact and the very next tick takes it.
    check("…and the arm is untouched, so this is a delay rather than a cancellation",
          draftState.typedAt == launch)
    let released = tick(repick: &draftState, watcher: &draftWatcher)
    check("…which the next reading proves: the same state plans the same move once the draft clears",
          released.plan?.target.id == "B" && released.plan?.reason == "window-repick")
    // AND THE IDLE REBALANCE IS BEHIND THE SAME GATE, which is the half a repick-only fix would have
    // left open: it restarts the same child for the same reason on a session nobody ever clears.
    // This fixture has no arm at all, so what answers here can only be the rebalance.
    var restlessState = WindowRepickState()
    var restlessWatcher = session(id: "after")
    let heldRebalance = tick(repick: &restlessState, watcher: &restlessWatcher,
                             draftSuspected: true)
    check("a session that may hold an unsent draft is not rebalanced either",
          heldRebalance.plan == nil)
    // …AND THE DROUGHT'S ONE CLAIM IS NOT SPENT ON A MOVE THAT DID NOT HAPPEN, which is what makes
    // this a delay for the whole machine rather than only for this session: the claim is taken
    // inside `rebalanceMove`, so a gate placed after it would have burned the account's one move per
    // window cycle every time a draft held this tick.
    check("…and the account's one rebalance claim is left for a tick that can use it",
          !heldRebalance.claimed)
    var restlessAgain = WindowRepickState()
    var restlessWatcherAgain = session(id: "after")
    let undrafted = tick(repick: &restlessAgain, watcher: &restlessWatcherAgain)
    check("…while the same session with nothing suspected is rebalanced exactly as before",
          undrafted.plan?.reason == "rebalance" && undrafted.claimed)

    // Somebody typing in that terminal is the one thing the empty conversation cannot rule out: the
    // composer may hold their next prompt, and a restart takes it with them.
    var typingState = WindowRepickState()
    typingState.arm(typed: "/clear", transcript: "before", now: launch)
    var typingWatcher = session(id: "after")
    check("a keyboard in use holds the repick",
          tick(repick: &typingState, watcher: &typingWatcher, keyboardIdle: false).plan == nil)

    // A session that started a turn in the cleared window is no longer empty, so the move is no
    // longer free and this is not the mover for it.
    var busyState = WindowRepickState()
    busyState.arm(typed: "/clear", transcript: "before", now: launch)
    var busyWatcher = session(id: "after", age: 1)
    check("a conversation that is writing again holds the repick",
          tick(repick: &busyState, watcher: &busyWatcher).plan == nil)
    // AND THE ARM SURVIVES THAT ONE, which is the thing a single reading cannot decide: `/clear`
    // writes the transcript it creates (ten lines, TranscriptFork.swift), so "written a second ago"
    // is also exactly what a window that has just opened looks like. What tells the two apart is a
    // write that arrives AFTER this supervisor has seen the landing, which is the case below.
    check("…and the arm survives a write nothing can attribute yet", busyState.typedAt == launch)

    // MARK: - 33c-ii. A window that has been worked in is no longer free

    // THE ACCIDENT THE SECOND PIECE OF EVIDENCE EXISTS FOR (codex review of 01799d5): the window
    // opened, somebody came back, ran a turn in it and then read the answer. Six seconds of reading
    // satisfies the 5s quiet bar, and the arm is still up because none of the gates that failed
    // earlier in the window consumed it - so the tick relaunched a conversation with a live turn in
    // it, which is the accident this whole feature was built to avoid, self-inflicted.
    //
    // Two ticks, because that is what the fact is made of: the first sees the clear land and takes
    // the transcript's mtime as it then stands (the `/clear`'s own records), the turn writes, and
    // the second reads a file that has moved since. A single tick cannot hold that fact - at the
    // moment a landing is first seen, its baseline and its reading are the same stat.
    var workedState = WindowRepickState()
    workedState.arm(typed: "/clear", transcript: "before", now: launch)
    var workedWatcher = session(id: "after")
    let landed = tick(repick: &workedState, watcher: &workedWatcher, keyboardIdle: false)
    check("the landing tick with somebody at the keyboard plans nothing", landed.plan == nil)
    check("…and keeps the arm, because that window is still empty", workedState.typedAt == launch)
    wrote(workedWatcher, secondsAgo: 6)   // the turn they typed, finished six seconds ago
    let worked = tick(repick: &workedState, watcher: &workedWatcher,
                      at: launch.addingTimeInterval(8))
    check("a window that has been worked in is not relaunched, however quiet it has gone",
          worked.plan == nil)
    check("…and the arm is dropped for good rather than left to run the window out",
          workedState.typedAt == nil)

    // The same two ticks with NOTHING written in between, so the refusal above is about the write
    // and not about the second tick: the free move is still there to be taken.
    var untouchedState = WindowRepickState()
    untouchedState.arm(typed: "/clear", transcript: "before", now: launch)
    var untouchedWatcher = session(id: "after")
    _ = tick(repick: &untouchedState, watcher: &untouchedWatcher, keyboardIdle: false)
    let untouched = tick(repick: &untouchedState, watcher: &untouchedWatcher,
                         at: launch.addingTimeInterval(8))
    check("a window nobody touched is still moved on a later tick",
          untouched.plan?.reason == "window-repick" && untouched.plan?.target.id == "B")

    // The signal itself, with no station around it and no clock in it at all.
    var evidence = WindowRepickState()
    evidence.arm(typed: "/clear", transcript: "before", now: launch)
    let cleared = launch.addingTimeInterval(1)
    check("the first landing seen is the baseline",
          evidence.noteLanded(in: "after", window: .empty(writtenAt: cleared)))
    check("…and the same file, unmoved, is still that empty window",
          evidence.noteLanded(in: "after", window: .empty(writtenAt: cleared)))
    check("a write past that baseline is somebody using the window",
          !evidence.noteLanded(in: "after",
                               window: .empty(writtenAt: cleared.addingTimeInterval(1))))
    check("…which disarms, because the ordinary rebalance owns that session now",
          evidence.typedAt == nil)
    var movedAgain = WindowRepickState()
    movedAgain.arm(typed: "/clear", transcript: "before", now: launch)
    _ = movedAgain.noteLanded(in: "after", window: .empty(writtenAt: cleared))
    // Mtimes from two different files cannot be compared at all, so a conversation that has moved
    // AGAIN is not a quieter window, it is one nothing here can say anything about.
    check("a conversation that moved again is not the file the baseline describes",
          !movedAgain.noteLanded(in: "later",
                                 window: .empty(writtenAt: cleared.addingTimeInterval(-60))))
    check("…and that disarms too", movedAgain.typedAt == nil)
    var unstatted = WindowRepickState()
    unstatted.arm(typed: "/clear", transcript: "before", now: launch)
    check("a transcript nothing could be read from decides nothing, in either direction",
          !unstatted.noteLanded(in: "after", window: .unreadable) && unstatted.typedAt == launch)
    var inUse = WindowRepickState()
    inUse.arm(typed: "/clear", transcript: "before", now: launch)
    check("a window with a turn in it is refused on sight, with no baseline to compare against",
          !inUse.noteLanded(in: "after", window: .used) && inUse.typedAt == nil)

    // MARK: - 33c-iii. The window's own contents, which is the evidence the mtime cannot hold

    // THE HOLE THE BASELINE LEFT IN FRONT OF IT (codex review of 4d7288a): the baseline is taken on
    // the first tick that SEES the landing, so a prompt submitted in the couple of seconds before
    // that tick is absorbed into it. A model request that has not answered yet writes nothing else -
    // no unmatched `tool_use` for the open-turn veto, nothing for the 5s bar - so the window read as
    // untouched while a turn was running in it, which is the accident this feature exists to avoid.
    //
    // Quiet at the repick's 5s bar and NOT at the rebalance's 120s one, for the reason the queued
    // fixture above states: nothing else in the station can answer, so the refusal is unambiguously
    // this gate's.
    var promptState = WindowRepickState()
    promptState.arm(typed: "/clear", transcript: "before", now: launch)
    var promptWatcher = session(id: "after", age: 30, body: workedWindow)
    let prompted = tick(repick: &promptState, watcher: &promptWatcher)
    check("a prompt typed before the first tick saw the landing is still a window in use",
          prompted.plan == nil)
    check("…and it disarms, rather than waiting for an mtime it can no longer be told from",
          promptState.typedAt == nil)

    // THE SAME HOLE THROUGH THE STATION'S OWN EARLY RETURN: a tick that already has a relaunch
    // planned never reaches this mover at all, so the baseline is built late, and everything written
    // before it is invisible to an mtime. The contents are not.
    var skippedState = WindowRepickState()
    skippedState.arm(typed: "/clear", transcript: "before", now: launch)
    var skippedWatcher = session(id: "after", age: 30, body: workedWindow)
    _ = tick(repick: &skippedState, watcher: &skippedWatcher,
             plan: RelaunchPlan(target: healthy, reason: "cap", countsFuse: true))
    let skipped = tick(repick: &skippedState, watcher: &skippedWatcher,
                       at: launch.addingTimeInterval(8))
    check("a window worked in while the station was skipped is refused on the tick that gets there",
          skipped.plan == nil)
    check("…and disarmed there", skippedState.typedAt == nil)

    // A META EVENT IS NOT AUTOMATICALLY THE CLEAR'S OWN (codex review of 1db9ebf): Claude Code
    // opens real turns with them, and a window woken by one is a window with a turn starting in it.
    // Corpus, 2026-08-17: 1,963 turns opened by nothing but a meta user event, 83 of them the first
    // turn of a cleared window, one measured at 6.1s of silence before its first assistant event -
    // past the 5s quiet bar, with the arm still up.
    var wokenState = WindowRepickState()
    wokenState.arm(typed: "/clear", transcript: "before", now: launch)
    var wokenWatcher = session(id: "after", age: 30, body: clearRecords + "\n" + metaWakeUp)
    let woken = tick(repick: &wokenState, watcher: &wokenWatcher)
    check("a window woken by a system injection is a window with a turn in it", woken.plan == nil)
    check("…and it disarms like any other used window", wokenState.typedAt == nil)

    // A FIRST PROMPT TOO BIG FOR THE TAIL, which is the other blind spot: `transcriptTail` opens
    // mid-file and drops the partial line, so a 300 KB prompt takes itself out of view and leaves
    // the bookkeeping written after it, which reads as an empty window. Corpus holds typed prompts
    // of 344 KB and 519 KB, and 13 windows blinded this way.
    let hugePrompt = #"{"type":"user","isSidechain":false,"promptSource":"typed","message":"#
        + #"{"role":"user","content":""# + String(repeating: "x", count: 300_000) + #""}}"#
    var hugeState = WindowRepickState()
    hugeState.arm(typed: "/clear", transcript: "before", now: launch)
    var hugeWatcher = session(id: "after", age: 30,
                              body: clearRecords + "\n" + hugePrompt + "\n" + trailingRecords)
    // The fixture really does exercise the truncation, rather than passing because the prompt is
    // still in view: what the tail alone can see reads EMPTY, and the size is what refuses it.
    check("the tail of that window, read alone, cannot see the prompt at all",
          !windowRepickUsed(inTail: transcriptTail(of: hugeWatcher.file!) ?? ""))
    check("…so the reading refuses on the size instead", clearedWindow(of: hugeWatcher.file)
          == .used)
    let huge = tick(repick: &hugeState, watcher: &hugeWatcher)
    check("a window holding a quarter of a megabyte is not an empty one", huge.plan == nil)
    check("…and disarms, rather than reading the records written after the prompt",
          hugeState.typedAt == nil)

    // And the records a `/clear` leaves behind are NOT a window in use, which is the other half:
    // read as messages they would turn this feature off altogether.
    var freshState = WindowRepickState()
    freshState.arm(typed: "/clear", transcript: "before", now: launch)
    var freshWatcher = session(id: "after", body: clearRecords)
    check("a window holding only what the clear itself wrote is still the free move",
          tick(repick: &freshState, watcher: &freshWatcher).plan?.reason == "window-repick")

    // THE RESIDUE, PINNED RATHER THAN DESCRIBED (codex review of 9ec6f3d). The class this reading
    // is known not to cover: a turn opens in the cleared window and, before its first assistant
    // event lands, has written no user record at all - so the tail at the moment the repick asks
    // holds the clear's own records and the bookkeeping around them and nothing else, which is bit
    // for bit a window nobody came back to. All 6 windows of this shape in the corpus were out of
    // reach anyway (135s to three days of clear-to-turn gap against a 60s arm), but the one measured
    // at 9.613s was INSIDE the arm, and what refused it was a `<task-notification>` written before
    // the clear and still in view because the reader takes the last 256 KiB of the FILE rather than
    // the stretch after the clear. Both halves are asserted, so the day that coincidence stops
    // holding is a red suite rather than a relaunched turn.
    let modeRecord = #"{"type":"mode","mode":"default"}"#
    let residueTail = clearRecords + "\n" + modeRecord + "\n" + trailingRecords
    check("a turn that has not written a user record yet is invisible to this reading",
          !windowRepickUsed(inTail: residueTail))
    var residueState = WindowRepickState()
    residueState.arm(typed: "/clear", transcript: "before", now: launch)
    var residueTurn = session(id: "after", age: 30, body: residueTail)
    // CURRENT BEHAVIOUR RATHER THAN THE WANTED ONE, which is why it is written down: inside the arm
    // this window is still read as the free move. The residue's cost, as an assertion.
    check("so inside the arm that window is still read as free, which is the residue's cost",
          tick(repick: &residueState, watcher: &residueTurn).plan?.reason == "window-repick")
    // And what refused the 9.613s one: a single user record from earlier in the file, which the
    // backwards walk reaches after passing over the clear's own two and forgiving them, and which
    // neither of those two structures covers.
    let strayNotification = """
        {"type":"user","isSidechain":false,"message":{"role":"user",\
        "content":"<task-notification><task-id>bjz5lotbe</task-id></task-notification>"}}
        """
    check("the stray notification fixture is a line this reader can parse",
          (try? JSONSerialization.jsonObject(with: Data(strayNotification.utf8))) != nil)
    check("…and one such record, from before the clear, is what refuses the window",
          windowRepickUsed(inTail: strayNotification + "\n" + residueTail))

    // The reading itself, over the shapes measured on this machine.
    check("the clear's own caveat and invocation are not a turn", !windowRepickUsed(inTail:
        clearRecords))
    // THE FORGIVENESS IS TWO STRUCTURES, NOT THE META FLAG: same flag, different record, opposite
    // answer. (And `newestMainChainMessage` next door counts BOTH, which is what holds the
    // blocked-Stop hole shut - the two readers are deliberately opposite here.)
    check("a meta record that is not the clear's caveat is a turn opening",
          windowRepickUsed(inTail: clearRecords + "\n" + metaWakeUp))
    check("…while the caveat, which carries the same flag, is not",
          !windowRepickUsed(inTail: """
              {"type":"user","isMeta":true,"isSidechain":false,"message":{"role":"user",\
              "content":"<local-command-caveat>Caveat: generated by the user."}}
              """))
    let answerRecord =
        #"{"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-5"}}"#
    let toolResult = #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"#
        + #"[{"type":"tool_result","tool_use_id":"toolu_1"}]}}"#
    // EVERY FIXTURE BELOW THAT EXPECTS `used` HAS TO PARSE, because a line that will not parse is
    // read as use by the half-written rule: a malformed one would pass its check while asserting
    // nothing at all about the rule that check names. Two of these were malformed when written.
    for (name, line) in [("typed prompt", typedPrompt), ("meta wake-up", metaWakeUp),
                         ("answer", answerRecord), ("tool result", toolResult),
                         ("huge prompt", hugePrompt)] {
        check("the \(name) fixture is a line this reader can parse",
              (try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil)
    }
    check("a prompt typed into that window is", windowRepickUsed(inTail: workedWindow))
    check("so is an answer", windowRepickUsed(inTail: clearRecords + "\n" + answerRecord))
    check("so is a tool result, which is work rather than a person",
          windowRepickUsed(inTail: toolResult))
    // The parsed type decides, so an attachment carrying another event's JSON proves nothing: this
    // repo's own transcripts are full of both.
    check("an attachment quoting a user event is not one",
          !windowRepickUsed(inTail: #"{"type":"attachment","isSidechain":false,"#
              + #""text":"{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}"}"#))
    // A tail's last line may still be half written, and half an object is not evidence of an empty
    // window - the direction this reader is allowed to be wrong in is declining a free move.
    check("a half-written line claiming to be a message counts as one",
          windowRepickUsed(inTail: #"{"type":"user","isSidechain":false,"message":{"role"#))
    check("and a window with nothing in it at all is empty", !windowRepickUsed(inTail: ""))

    // A second `/clear` in the same child re-opens the question rather than inheriting the first
    // window's landing, which the id comparison would otherwise refuse for the rest of the child.
    var rearmed = WindowRepickState()
    rearmed.arm(typed: "/clear", transcript: "one", now: launch)
    _ = rearmed.noteLanded(in: "two", window: .empty(writtenAt: cleared))
    rearmed.arm(typed: "/clear", transcript: "two", now: launch.addingTimeInterval(600))
    check("arming again forgets the window it landed in last time", rearmed.landing == nil)
    check("…so the second window can be taken as well",
          rearmed.noteLanded(in: "three", window: .empty(writtenAt: cleared)))

    // The window closes, and closing it clears the arm: a line that never reached a composer must
    // not fire a restart minutes later off some unrelated fork.
    var staleState = WindowRepickState()
    staleState.arm(typed: "/clear", transcript: "before", now: launch)
    var staleWatcher = session(id: "after", age: 30)
    let expired = tick(repick: &staleState, watcher: &staleWatcher,
                       at: launch.addingTimeInterval(windowRepickWindow + 1))
    check("a window that ran out plans nothing", expired.plan == nil)
    check("…and disarms itself rather than waiting for a later fork", staleState.typedAt == nil)
    // Falling out of the window hands the question back rather than closing it: the same session,
    // once it has been left alone for the ordinary bar, is the rebalance's to move.
    var laterState = staleState
    var laterWatcher = session(id: "after")
    check("and the ordinary path still has it afterwards",
          tick(repick: &laterState, watcher: &laterWatcher).plan?.reason == "rebalance")

    // Everything above this station in the tick is repairing something; neither mover here is.
    var yieldState = WindowRepickState()
    yieldState.arm(typed: "/clear", transcript: "before", now: launch)
    var yieldWatcher = session(id: "after")
    let yielded = tick(repick: &yieldState, watcher: &yieldWatcher,
                       plan: RelaunchPlan(target: healthy, reason: "cap", countsFuse: true))
    check("a relaunch another reason already planned is left exactly as it was",
          yielded.plan?.reason == "cap")

    // And the rebalance is still reachable through the station for a session nobody cleared, which
    // is what makes this a station rather than a replacement.
    var unarmed = WindowRepickState()
    var idleWatcher = session(id: "quiet")
    let rebalanced = tick(repick: &unarmed, watcher: &idleWatcher)
    check("a session nobody cleared is still rebalanced when it has been left alone",
          rebalanced.plan?.reason == "rebalance" && rebalanced.plan?.target.id == "B")
    check("…and that one DOES take the drought's claim, as it always has", rebalanced.claimed)

    // UNLESS A REPORTED TURN BOUNDARY IS STILL UNRULED ON. The turn-boundary mover shares this
    // account's one claim per window cycle and runs later in the tick (it needs the board's blocked
    // reading), so the rebalance stands down for exactly one poll and leaves the claim for it. The
    // fixture here is the one directly above, which does rebalance: the only thing that changes is
    // the boundary (TurnBoundaryMove.swift carries the whole argument).
    var boundaryHeld = WindowRepickState()
    var heldWatcher = session(id: "quiet")
    let stoodDown = tick(repick: &boundaryHeld, watcher: &heldWatcher, turnBoundaryPending: true)
    check("a session with an unruled turn boundary is not rebalanced on that tick",
          stoodDown.plan == nil)
    check("…and its drought claim is left for the mover that is about to ask for it",
          !stoodDown.claimed)

    // AND THE STATION REFUSES A BLOCKED SESSION THROUGH THE REBALANCE'S OWN GATE, not as a side
    // effect of the stand-down above it. That distinction is the whole of why the gate was added
    // (2026-08-20): a session waiting on a person must not be restarted whether or not a turn
    // boundary happens to be pending on the same tick.
    var blockedState = WindowRepickState()
    var blockedWatcher = session(id: "quiet")
    let waitingOnUser = tick(repick: &blockedState, watcher: &blockedWatcher, blocked: true)
    check("a session waiting on a person is not rebalanced by the station",
          waitingOnUser.plan == nil)
    check("…and no drought claim is spent on it", !waitingOnUser.claimed)

    // AND THE ROLL CALL REACHES THE STATION TOO. This fixture is the one that rebalances; the only
    // thing that changes is Claude Code saying a subagent is still working, which the mtime behind
    // `isQuiet` cannot see while that subagent sits inside one long tool call.
    var rollCallState = WindowRepickState()
    var rollCallWatcher = session(id: "quiet")
    let namedWorker = tick(repick: &rollCallState, watcher: &rollCallWatcher, agentsWorking: true)
    check("a session whose Claude Code names a live worker is not rebalanced by the station",
          namedWorker.plan == nil)
    check("…and no drought claim is spent on that either", !namedWorker.claimed)
    check("…while the same session with nobody waiting on it is rebalanced",
          { var s = WindowRepickState(); var w = session(id: "quiet")
            return tick(repick: &s, watcher: &w).plan?.reason == "rebalance" }())

    // AND THE TICK HANDS IT THE BOARD'S OWN READING rather than a literal or a second opinion. That
    // reading is the fold of the notice hook, the open question and the quiet scan
    // (SessionStateSync.swift), and it is why the board is now decided ABOVE this station.
    let tickSource = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the preventive-station checks",
          !tickSource.isEmpty)
    // READ OFF THE CALL, NOT THE FILE. The turn-boundary station a hundred lines below is handed
    // the same reading, so a file-wide `contains` stayed green while this station was handed a
    // literal - the check passing through a line other than the one it is about (caught by
    // mutation, 2026-08-20).
    let preventiveCall = tickSource.range(of: "applyProactiveMoves(plan: &plan,").flatMap { station in
        tickSource.range(of: "quarantine: quarantine, reserves: reserves)",
                         range: station.upperBound ..< tickSource.endIndex).map {
            String(tickSource[station.upperBound ..< $0.upperBound])
        }
    } ?? ""
    check("the preventive station is handed the hard-wait reading",
          preventiveCall.contains("blocked: board.waitingOnPerson"))
    // AND NOT THE BOARD'S OWN WORD, which is the regression this narrowing repaired: `blocked`
    // covers the `idle_prompt` an idle session carries, and this mover waits 120 seconds for
    // exactly that idleness, so the word refused every rebalance it was ever asked about.
    check("…rather than the word that also covers a soft idle prompt",
          !preventiveCall.contains("board.state == .blocked"))
    // AND THE RULE THAT MOVE HAD TO NOT BREAK, pinned here for the first time (review of e52a436,
    // B2). The repick's id and its window reading are a PAIR taken off the file the tick adopted,
    // and they have to be read BEFORE the `isQuiet` in this station can relocate the watcher under
    // them - otherwise a window reading describes one transcript and the id names another. A locate
    // ANYWHERE ABOVE the station is harmless to that (the tick already ran two), but a locate
    // between the two halves is not, and nothing but this check stands between them.
    let stationSource = (try? String(contentsOfFile: "TallyCLI/WindowRepick.swift",
                                     encoding: .utf8)) ?? ""
    check("the window repick source is readable from its own checks", !stationSource.isEmpty)
    check("the repick reads its id and window pair before anything can relocate the watcher",
          stationSource.range(of: "let landed = windowRepickLanded(").map { pair in
              stationSource.range(of: "watcher.isQuiet(windowRepickQuietSeconds)").map {
                  pair.upperBound < $0.lowerBound
              } ?? false
          } ?? false)
    check("…which is decided above it, not after",
          tickSource.range(of: "let board = syncSessionState(").map { board in
              tickSource.range(of: "applyProactiveMoves(plan: &plan,").map {
                  board.upperBound < $0.lowerBound
              } ?? false
          } ?? false)

    // MARK: - 33d. The input gate hands over the line it typed

    let inputDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-window-repick-input-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
    let inputLog = inputDir.appendingPathComponent("input.log")
    func served(_ text: String, state: SupervisedState = .idle, quiet: SessionQuiet = .quiet,
                inject: SessionInputInjection = .done) -> String? {
        var input = SessionInputState(sessionKey: "9910", servedEpoch: 0, dir: inputDir)
        try? writeSessionInputRequest(
            SessionInputRequest(epoch: Int(Date().timeIntervalSince1970 * 1000), text: text),
            sessionKey: "9910", dir: inputDir)
        return applySessionInput(&input, session: state, quiet: quiet, turnEnded: { false },
                                 keyboardIdle: true,
                                 relaunchPlanned: false, draftSuspected: false, dir: inputDir,
                                 log: inputLog,
                                 inject: { _, _ in inject }).typed
    }
    check("the gate hands back the line it actually typed", served("/clear") == "/clear")
    // ARMING ON THE REQUEST RATHER THAN ON THE TYPING is the defect this return value exists to
    // rule out: a line that was never typed closed no window, and a mover armed on it would sit
    // waiting for a clear that is not coming.
    check("a line the terminal refused arms nothing",
          served("/clear", inject: .failed(EPERM)) == nil)
    check("a line still waiting on the session's own turn arms nothing",
          served("/clear", state: .working, quiet: .busy) == nil)
    var armedByGate = WindowRepickState()
    armedByGate.arm(typed: served("/clear"), transcript: "before", now: launch)
    check("the two halves fit: what the gate returns is what arms the repick",
          armedByGate.typedAt == launch)
    try? FileManager.default.removeItem(at: inputDir)

    // MARK: - 34. A relaunch does not inherit the dead child's subagents

    // THE DEFECT (codex review of fa9533b, seen live in the four cap handoffs of 2026-08-17 16:33):
    // a handoff kills a child mid-Workflow and resumes the SAME transcript on the new account. What
    // it leaves on disk is an unmatched `tool_use` older than the relaunch ceiling and a subagent
    // transcript written seconds ago, which is bit for bit the shape of a live fan-out. The new
    // child, idle and with nothing running, therefore read as `busy`.
    //
    // The consequence was not a delay. A `tally session send` lived 120s while the misreading lasts
    // up to `subagentIdleSeconds`, five times that, so the line was not late: it was refused - and
    // the commonest caller is a head clearing its own context at the end of a window, which returns
    // exit 0 saying `queued` and only learns otherwise from `~/.tally/logs/input.log`. Since
    // 2026-08-18 a queued request outlives that window (`sessionInputQueuedLife`), so the same
    // misreading costs the line ten minutes instead of losing it; this fixture is kept because ten
    // minutes is still the wrong answer, and because the reading itself is what it pins.
    let realNow = Date()
    let iso8601 = ISO8601DateFormatter()
    iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    /// A transcript holding one tool call that never came back, opened `callAge` seconds ago, with
    /// a subagent transcript written `subagentAge` seconds ago beside it. `childLaunchedAt` is what
    /// the supervisor passes as the watcher's `since`: the moment the CHILD now running started.
    func residueWatcher(callAge: TimeInterval, subagentAge: TimeInterval,
                        childLaunchedAt: Date) -> TranscriptWatcher {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-residue-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("session.jsonl")
        let opened = iso8601.string(from: realNow.addingTimeInterval(-callAge))
        try! ("{\"parentUuid\":\"p0\",\"isSidechain\":false,\"type\":\"assistant\",\"uuid\":\"a1\","
            + "\"timestamp\":\"\(opened)\",\"message\":{\"model\":\"claude-opus-5\","
            + "\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_r\","
            + "\"name\":\"Workflow\",\"input\":{}}],\"stop_reason\":\"tool_use\"}}\n")
            .write(to: file, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes(
            [.modificationDate: realNow.addingTimeInterval(-callAge)], ofItemAtPath: file.path)
        let subDir = file.deletingPathExtension().appendingPathComponent("subagents")
            .appendingPathComponent("workflows").appendingPathComponent("wf_dead")
        try! FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let agent = subDir.appendingPathComponent("agent-a3b273b656da7c735.jsonl")
        try! "{}".write(to: agent, atomically: true, encoding: .utf8)
        // The directories are dated with the file, for the reason `dropSubagentWrite` states in
        // openturnchecks: the walk takes the newest mtime it enumerates, so a parent created a
        // moment ago answers "written just now" whatever the file says.
        var path = agent
        for _ in 0...3 {
            try! FileManager.default.setAttributes(
                [.modificationDate: realNow.addingTimeInterval(-subagentAge)],
                ofItemAtPath: path.path)
            path = path.deletingLastPathComponent()
        }
        return TranscriptWatcher(projectDir: dir, file: file, since: childLaunchedAt)
    }

    // A child that has been running for hours: the subagent writing beside its over-age call is its
    // own live fan-out. It reads as dispatched work, and since 2026-08-18 that is a line this gate
    // TYPES - Albert's rule is that agents running are not a reason a window cannot be cleared, and
    // what the `/clear` costs is reported rather than avoided (`landSessionInput`). The restart
    // gates are untouched by that: this session is still not quiet, so nothing relaunches under it.
    var liveFanOut = residueWatcher(callAge: openTurnMaxSeconds + 120, subagentAge: 5,
                                    childLaunchedAt: realNow.addingTimeInterval(-7200))
    check("a live fan-out past the relaunch ceiling reads as dispatched work rather than a turn",
          liveFanOut.quietness(followIdleSeconds) == .subagentsWriting
              && !liveFanOut.isQuiet(followIdleSeconds))
    check("…and the input gate types into it, dispatched work holding nothing",
          sessionInputHold(state: .working, quiet: liveFanOut.quietness(followIdleSeconds),
                           turnEnded: false, keyboardIdle: true,
                           relaunchPlanned: false) == nil)

    // The same bytes on disk, one relaunch later. The only thing that differs is WHEN the child
    // running now started, which is the dimension the reading was missing.
    var afterHandoff = residueWatcher(callAge: openTurnMaxSeconds + 120, subagentAge: 5,
                                      childLaunchedAt: realNow.addingTimeInterval(-1))
    check("the same files under a child that started after them are residue, not dispatch",
          afterHandoff.quietness(followIdleSeconds) == .quiet)
    check("…so nothing holds the line",
          sessionInputHold(state: .idle, quiet: afterHandoff.quietness(followIdleSeconds),
                           turnEnded: false, keyboardIdle: true, relaunchPlanned: false) == nil)

    // WHAT THE CALLER SAW, which is the reason this is a defect rather than a slow tick. Both ends
    // of it, through the real publisher and the real decision.
    let boardDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-residue-board-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: boardDir, withIntermediateDirectories: true)
    func selfSend(_ watcher: inout TranscriptWatcher, pid: String,
                  age: TimeInterval) -> SessionInputDecision {
        var writer = SessionStateWriter()
        let board = syncSessionState(&writer, pid: pid,
                                     project: PickProject(name: "p", path: boardDir.path),
                                     accountID: "claude:.claude", childPid: nil, model: nil,
                                     watcher: &watcher, keyboardBurstAt: nil, dir: boardDir)
        let asked = Date().addingTimeInterval(-age)
        return sessionInputDecision(
            request: SessionInputRequest(epoch: Int(asked.timeIntervalSince1970 * 1000),
                                         text: "/clear"),
            servedEpoch: 0, state: board.state, quiet: board.quiet, turnEnded: false,
            keyboardIdle: true, relaunchPlanned: false)
    }
    var beforeFix = residueWatcher(callAge: openTurnMaxSeconds + 120, subagentAge: 5,
                                   childLaunchedAt: .distantPast)
    // `.distantPast` is what the reading amounted to before the child's start entered it: every
    // write in that directory counted, whoever made it.
    //
    // WHAT THE MISREADING COSTS NOW, which is the third answer this pair has had and the one the
    // 2026-08-18 rework left: the residue is read as dispatched work, and dispatched work holds no
    // line - so the self-send is TYPED even under the reading that could not tell a dead child's
    // wreckage from a live package. The `since` filter above is therefore no longer what saves this
    // send (it saves the restart gates, `newestSubagentWrite`), and this fixture is kept because it
    // is the shape that reaches both.
    if case .inject = selfSend(&beforeFix, pid: "9920", age: subagentIdleSeconds - 1) {
        check("read that way, a self-send is typed rather than held", true)
    } else {
        check("read that way, a self-send is typed rather than held", false)
    }
    // The one ending that still refuses it is the staleness ceiling, and with nothing holding the
    // line the sentence is the one that names no hold at all.
    check("…and refused only once it is past the staleness ceiling",
          selfSend(&beforeFix, pid: "9920", age: sessionInputQueuedLife + 1)
              == .refuse(.refusedExpired, "it reached a moment this could be typed at only after "
                         + "its \(Int(sessionInputQueuedLife))s life had run out"))
    var afterFix = residueWatcher(callAge: openTurnMaxSeconds + 120, subagentAge: 5,
                                  childLaunchedAt: realNow.addingTimeInterval(-1))
    if case .inject = selfSend(&afterFix, pid: "9921", age: 1) {
        check("read with the child's own start, the same session is typed into", true)
    } else {
        check("read with the child's own start, the same session is typed into", false)
    }
    try? FileManager.default.removeItem(at: boardDir)

    // MARK: - 34b. A stamp nobody here wrote cannot take the command down

    // The request channel is a directory every process running as this user can write, and the
    // second caller's refusal does arithmetic on what it finds there. `Int(someDouble)` TRAPS in
    // Swift, so a poisoned answer killed the one command whose job is to explain why the first line
    // is still queued (exit 133, reproduced against this expression before the clamp).
    //
    // BOTH FIELDS ARE POISONED, and that is not belt and braces. `epoch` alone cannot reach the
    // trap (milliseconds divided by a thousand tops out around 9.2e15, four orders below the
    // boundary) and `waitSeconds` alone lands ON it, where the subtraction of the current clock
    // rounds it to either side depending on the microsecond the suite runs at - a flaky assertion
    // for a real defect. Together they clear the boundary by 9.2e15, which is deterministic.
    let poisoned = SessionInputResult(epoch: Int.max, outcome: "submitted", detail: nil,
                                      waitSeconds: Int.max)
    let refusal = sessionInputBusyRefusal(.answer(poisoned), sessionKey: "9930")
    check("a poisoned wait prints a sentence instead of trapping", refusal.contains("9930"))
    check("…and the number it prints is the clamp, absurd enough to read as the diagnosis it is",
          refusal.contains("\(Int.max)s"))
    let negative = SessionInputResult(epoch: 0, outcome: "submitted", detail: nil,
                                      waitSeconds: nil)
    check("and a stamp from 1970 reads as no time left, as it always did",
          sessionInputBusyRefusal(.answer(negative), sessionKey: "9930").contains(" 0s "))

    // MARK: - 34c. The loop wiring

    // The station's placement in the tick is not reachable from a test (it lives in a `while true`
    // inside a process that spawns children), so the source carries it - the technique the
    // rebalance, the follow dead end and the self-update fold all use.
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the window repick checks", !loop.isEmpty)
    check("the tick runs the preventive station", loop.contains("applyProactiveMoves("))
    // AND HANDS IT THIS TICK'S OWN DRAFT READING, which is the trigger end of the invariant the
    // input station holds at the arm end. Read off the call rather than off the file, because
    // `draftSuspected` is also the name of the input station's argument a hundred lines below: a
    // file-wide search would pass on that one alone.
    if let station = loop.range(of: "applyProactiveMoves(plan: &plan,"),
       let end = loop.range(of: "quarantine: quarantine, reserves: reserves)",
                            range: station.upperBound ..< loop.endIndex) {
        let call = String(loop[station.upperBound ..< end.upperBound])
        check("…under this tick's own draft reading, not a literal",
              call.contains("draftSuspected: draftSuspected"))
    } else {
        check("…under this tick's own draft reading, not a literal", false)
    }
    // ONE READING FOR BOTH ENDS OF THE INVARIANT: the movers here and the input station below are
    // handed the same value, taken once, so the two ends can never disagree about the same instant.
    check("…and it is the same reading the input station is given, taken once above both",
          loop.range(of: "let draftSuspected = sessionInputDraftSuspected(").map { taken in
              loop.range(of: "applyProactiveMoves(plan: &plan,").map {
                  taken.upperBound < $0.lowerBound
              } ?? false
          } ?? false)
    // TWO FACTS RATHER THAN ONE SUBSTRING, since the advisory knock joined this station and the
    // gate's answer had to be given a name to be handed to both (`typedAlready`, QuotaKnock.swift):
    // the arm is fed the value the input gate RETURNED, and that value is the gate's own return.
    // Read together they pin what one substring used to - a repick armed from the request rather
    // than from what reached the terminal would fire on a `/clear` that never closed a window.
    check("the repick is armed from what the input gate TYPED, not from the request",
          loop.contains("let action = applySessionInput(")
              && loop.contains("windowRepick.apply(action.repick,"))
    // …AND NOT FROM EVERY TYPED LINE EITHER, which is the 2026-08-19 narrowing: this arm ends in a
    // relaunch, and a relaunch ends the composer and the kill buffer of the child it replaces. A
    // clear typed into a session that may be holding an unsent draft hands back a delivered line and
    // an instruction to CANCEL rather than to arm (`SessionInputRepick`, draftstashchecks holds the
    // table).
    check("…and a line typed over somebody's suspected draft arms nothing at all",
          !loop.contains("windowRepick.arm(typed: action.typed,"))
    // AND NOT FROM ITS OTHER ENDING, which is the 2026-08-18 addition and the one way this arm could
    // now fire on a session that was never typed into: a `tally session clear` answered by moving
    // the session IS the move, so arming a second mover behind it would queue a second relaunch
    // against a conversation that no longer exists (`SessionInputAction`).
    check("…and the move it may decide instead becomes the tick's own relaunch rather than an arm",
          loop.contains("clearBoundaryPlan(action.moveTo,")
              && !loop.contains("windowRepick.arm(typed: action.moveTo"))
    check("…and it is told which conversation the session was in when the line went out",
          loop.contains("transcript: watcher.transcriptSessionID)"))
    // Per child: a relaunch replaces the conversation, so an arm against the old one is answered.
    if let declaration = loop.range(of: "var windowRepick = WindowRepickState()"),
       let childLoop = loop.range(of: "while true {"),
       let poll = loop.range(of: "while child.isRunning {") {
        check("the arm lives with the child it belongs to, not with the session",
              childLoop.lowerBound < declaration.lowerBound
                  && declaration.lowerBound < poll.lowerBound)
    } else {
        check("the window repick's state was found in the tick", false)
    }
}
