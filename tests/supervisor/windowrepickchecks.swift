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
              mode: String = "auto", carryable: Bool = true, fuseAllows: Bool = true,
              quarantine: [String: (model: String?, until: Date)] = [:],
              on: Snapshot.Account = dying) -> Snapshot.Account? {
        windowRepickMove(provider: "claude", account: on, primaryModel: primary, mode: mode,
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

    /// A session bound to `id`, whose transcript was last written `age` seconds ago.
    func session(id: String, age: TimeInterval = 600) -> TranscriptWatcher {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-window-repick-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(id).jsonl")
        try! "{}".write(to: file, atomically: true, encoding: .utf8)
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
              keyboardIdle: Bool = true, fuseAllows: Bool = true,
              plan seed: RelaunchPlan? = nil,
              at when: Date = launch.addingTimeInterval(4)) -> (plan: RelaunchPlan?, claimed: Bool) {
        let claimDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-window-repick-claim-\(UUID().uuidString)")
        var plan = seed
        applyProactiveMoves(plan: &plan, repick: &repick, watcher: &watcher,
                            keyboardIdle: { _ in keyboardIdle }, provider: "claude",
                            account: dying, primaryModel: primary, mode: mode, launchArgs: [],
                            fuseAllows: fuseAllows,
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
    check("the first landing seen is the baseline", evidence.noteLanded(in: "after",
                                                                       writtenAt: cleared))
    check("…and the same file, unmoved, is still that empty window",
          evidence.noteLanded(in: "after", writtenAt: cleared))
    check("a write past that baseline is somebody using the window",
          !evidence.noteLanded(in: "after", writtenAt: cleared.addingTimeInterval(1)))
    check("…which disarms, because the ordinary rebalance owns that session now",
          evidence.typedAt == nil)
    var movedAgain = WindowRepickState()
    movedAgain.arm(typed: "/clear", transcript: "before", now: launch)
    _ = movedAgain.noteLanded(in: "after", writtenAt: cleared)
    // Mtimes from two different files cannot be compared at all, so a conversation that has moved
    // AGAIN is not a quieter window, it is one nothing here can say anything about.
    check("a conversation that moved again is not the file the baseline describes",
          !movedAgain.noteLanded(in: "later", writtenAt: cleared.addingTimeInterval(-60)))
    check("…and that disarms too", movedAgain.typedAt == nil)
    var unstatted = WindowRepickState()
    unstatted.arm(typed: "/clear", transcript: "before", now: launch)
    check("a transcript nothing could stat decides nothing, in either direction",
          !unstatted.noteLanded(in: "after", writtenAt: nil) && unstatted.typedAt == launch)

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
                                 relaunchPlanned: false, dir: inputDir, log: inputLog,
                                 inject: { _ in inject })
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
    // The consequence is not a delay. A `tally session send` lives 120s and the misreading lasts up
    // to `subagentIdleSeconds`, five times that, so the line is not late: it is refused - and the
    // commonest caller is a head clearing its own context at the end of a window, which returns
    // exit 0 saying `queued` and only learns otherwise from `~/.tally/logs/input.log`.
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
    // own live fan-out, and typing into that would land in the middle of a turn. Unchanged.
    var liveFanOut = residueWatcher(callAge: openTurnMaxSeconds + 120, subagentAge: 5,
                                    childLaunchedAt: realNow.addingTimeInterval(-7200))
    check("a live fan-out past the relaunch ceiling still reads as this session's own turn",
          liveFanOut.quietness(followIdleSeconds) == .busy)
    check("…and the input gate still holds the line as that turn",
          sessionInputHold(state: .working, quiet: liveFanOut.quietness(followIdleSeconds),
                           turnEnded: false, keyboardIdle: true,
                           relaunchPlanned: false) == .turn)

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
    check("read that way, a self-send is refused rather than delayed",
          selfSend(&beforeFix, pid: "9920", age: sessionInputTTL + 1)
              == .refuse(.refusedExpired, SessionInputHold.turn.sentence(ttl: sessionInputTTL)))
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
    check("the repick is armed from what the input gate TYPED, not from the request",
          loop.contains("windowRepick.arm(typed: applySessionInput("))
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
