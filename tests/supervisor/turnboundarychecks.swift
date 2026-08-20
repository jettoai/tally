import Foundation

// MOVING A BUSY SESSION AT THE END OF ONE OF ITS TURNS.
//
// The gate table is the whole of this feature - a relaunch nobody asked for, taken while somebody is
// working, is the most expensive thing this supervisor can get wrong - so every gate has a check
// that it refuses, a check that the other eight together do not, and the positive case where all of
// them hold. The one that matters most is the roster: a `/clear` or a handoff that lands on a live
// fan-out kills it with the child (2026-07-25, and again in the four handoffs of 2026-08-17), and
// this mover fires precisely when work is most likely to be in flight.

func runTurnBoundaryChecks() {
    // MARK: - 36. The fixtures

    /// Session and weekly healthy, so the flagship window alone decides whether the account is
    /// dying - the same fixture shape the rebalance and repick checks use.
    func acct(_ id: String, model: Double) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: id, launchHome: "/tmp/\(id)",
                         sessionRemaining: 90, weeklyRemaining: 90, modelRemaining: model,
                         sessionResetsAt: launch.addingTimeInterval(4 * 3600),
                         weeklyResetsAt: launch.addingTimeInterval(100 * 3600),
                         modelResetsAt: launch.addingTimeInterval(100 * 3600),
                         modelWindowName: "fable", resetCreditsAvailable: nil,
                         isStale: false, error: nil)
    }
    let dying = acct("A", model: 3)
    let healthy = acct("B", model: 77)
    let alsoDry = acct("C", model: 2)
    let primary = "fable"

    /// The pure decision, with every gate open unless the check names it. Nine parameters and one
    /// default each, so a check reads as the single thing it varies.
    func target(steering: Bool = true, mode: String = "auto", blocked: Bool = false,
                keyboardIdle: Bool = true, draftSuspected: Bool = false, carryable: Bool = true,
                fuseAllows: Bool = true, agentsIdle: Bool = true, turnEnded: Bool = true,
                toolCallOpen: Bool = false, current: Snapshot.Account = dying,
                candidates: [Snapshot.Account] = [healthy],
                claim: () -> Bool = { true }) -> Snapshot.Account? {
        turnBoundaryTarget(steering: steering, mode: mode, blocked: blocked,
                           keyboardIdle: keyboardIdle, draftSuspected: draftSuspected,
                           carryable: carryable, fuseAllows: fuseAllows, agentsIdle: agentsIdle,
                           turnEnded: turnEnded, toolCallOpen: toolCallOpen, current: current,
                           candidates: candidates, primaryModel: primary, now: launch,
                           claim: claim)
    }

    // MARK: - 36a. The positive case, which every refusal below is measured against

    check("a turn that ended on a dying account with a healthy sibling moves", target()?.id == "B")
    check("…to the healthiest sibling rather than merely an eligible one",
          target(candidates: [alsoDry, healthy])?.id == "B")

    // MARK: - 36b. Gate by gate, each one alone

    check("1. an observe-only fleet does not move it", target(steering: false) == nil)
    check("2. a pinned session does not move it", target(mode: "manual") == nil)
    check("3. a session waiting on a person does not move it", target(blocked: true) == nil)
    // AND WHICH WAIT THAT IS, through the real classification. A turn boundary is precisely when
    // Claude Code is about to fire its soft `idle_prompt` - it has just stopped speaking - so the
    // board's coarse `blocked` would veto this mover as reliably as it vetoed the rebalance.
    func waitingTick(_ type: String?) -> SessionTick {
        let wait = userWait(notificationType: type)
        return SessionTick(state: supervisedSessionState(wait: wait, hasTranscript: true,
                                                         quiet: true),
                           quiet: .quiet, wait: wait)
    }
    check("3a. an idle prompt is not somebody waiting, so the move goes ahead",
          target(blocked: waitingTick("idle_prompt").waitingOnPerson)?.id == "B")
    check("3b. a permission prompt is, so it does not",
          target(blocked: waitingTick("permission_prompt").waitingOnPerson) == nil)
    check("4. somebody typing in that terminal does not move it", target(keyboardIdle: false) == nil)
    check("5. a suspected draft in the composer does not move it",
          target(draftSuspected: true) == nil)
    check("6. a conversation that cannot be carried does not move it", target(carryable: false) == nil)
    check("7. a spent recovery fuse does not move it", target(fuseAllows: false) == nil)
    check("8. a subagent still working does not move it", target(agentsIdle: false) == nil)
    check("9. a boundary that no longer stands does not move it", target(turnEnded: false) == nil)
    check("10. an open tool call does not move it", target(toolCallOpen: true) == nil)
    check("11. a comfortable account is left where it is",
          target(current: acct("A", model: 40)) == nil)
    check("12. an all-dry field has nowhere better to go", target(candidates: [alsoDry]) == nil)
    check("13. and an empty field the same", target(candidates: []) == nil)
    check("14. a claim another supervisor holds does not move it", target(claim: { false }) == nil)

    // 15. THE CLAIM'S ONE EXEMPTION, shared with the idle rebalance rather than invented here
    // (Rebalance.swift, 2026-08-20): an account with no effective remaining left is left without
    // asking for the claim, because what justifies waiting for one is the cap handoff making the
    // move later, and an account with nothing left never serves the turn a cap lands in. Two movers
    // that disagreed about when the claim is required would strand a session on a spent account
    // precisely because the other mover had already moved one off it.
    let spent = acct("A", model: 0)
    check("15. a spent account moves even while another supervisor holds the claim",
          target(current: spent, claim: { false })?.id == "B")
    var spentAsked = false
    _ = target(current: spent, claim: { spentAsked = true; return true })
    check("…and does not ask for the claim at all", !spentAsked)
    check("…while 1% is not exempt, which is the 2026-08-02 red line",
          target(current: acct("A", model: 1), claim: { false }) == nil)
    check("…an observe-only fleet still moves nothing off a spent account",
          target(steering: false, current: spent, claim: { false }) == nil)
    check("…the recovery fuse is still a hard wall",
          target(fuseAllows: false, current: spent, claim: { false }) == nil)
    check("…so is a live fan-out", target(agentsIdle: false, current: spent,
                                          claim: { false }) == nil)
    check("…and so is having nowhere better to go",
          target(current: spent, candidates: [alsoDry], claim: { false }) == nil)
    // AND A ZERO NOBODY HAS CONFIRMED IS NOT ONE, argued in full where the reading is taken
    // (`accountIsSpent`): a failed refresh leaves the last good numbers in place behind a flag, and
    // every supervisor on that account holds the same remembered zero on the same tick. Asserted in
    // both movers because the exemption is what they share; a fix reaching only one of them would
    // hand this mover the crowd the other had just been taught to refuse.
    var staleSpent = spent
    staleSpent.isStale = true
    var erroredSpent = spent
    erroredSpent.error = "boom"
    check("…and a stale spent account is not exempt at all",
          target(current: staleSpent, claim: { false }) == nil)
    check("…nor one whose last refresh errored",
          target(current: erroredSpent, claim: { false }) == nil)
    check("…though both still move when the claim is theirs to take",
          target(current: staleSpent)?.id == "B" && target(current: erroredSpent)?.id == "B")

    // The line is the shared one, not a second threshold of this mover's own. Asserted against the
    // constant so a change to `nearlyDryPercent` moves this gate with everything else.
    check("the dry line is exactly the one the rest of the product draws",
          target(current: acct("A", model: nearlyDryPercent))?.id == "B"
              && target(current: acct("A", model: nearlyDryPercent + 0.1)) == nil)

    // THE ORDER MATTERS FOR ONE GATE ONLY, and it is the one with a side effect: an account gets one
    // move per window cycle across every supervisor, so asking for the claim on a tick that then
    // declines would spend the drought's one move on nothing.
    var claimAsked = 0
    func counted() -> Bool { claimAsked += 1; return true }
    claimAsked = 0
    _ = target(agentsIdle: false, claim: counted)
    _ = target(turnEnded: false, claim: counted)
    _ = target(blocked: true, claim: counted)
    _ = target(current: acct("A", model: 40), claim: counted)
    _ = target(candidates: [], claim: counted)
    check("no refusal ever asks for the claim", claimAsked == 0)
    _ = target(claim: counted)
    check("and the move asks for it exactly once", claimAsked == 1)

    // MARK: - 36c. The facts this mover reads for itself

    let stateDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-turn-boundary-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: stateDir) }
    /// The child this suite's rosters are judged against: started a minute before the boundary, so
    /// a record stamped at `launch` belongs to it and one stamped before that does not.
    ///
    /// DELIBERATELY OFF A WHOLE SECOND. A child that started exactly on one makes flooring a no-op,
    /// and the fixture below - the one that asserts the comparison is EXACT rather than at the
    /// roster's whole-second resolution - then passes whether the comparison is exact or not. It
    /// did, and a mutant that floored this test survived the whole suite (2026-08-21).
    let childStartedAt = launch.addingTimeInterval(-59.5)
    /// The reading for a boundary at `launch`, asked a moment after it, through the same two
    /// functions the tick uses: the generation filter and the pure decision over what it kept.
    func roster(_ pid: String, at asked: TimeInterval = 1) -> TurnBoundaryAgents {
        turnBoundaryAgents(currentGenerationRoster(pid: pid, childStartedAt: childStartedAt,
                                                   dir: stateDir),
                           boundary: launch, now: launch.addingTimeInterval(asked))
    }
    // NO ROSTER AT ALL is the machine whose hooks are not installed, and it is `unavailable` rather
    // than `retry`: waiting for a file nothing writes would hold this boundary open forever, and an
    // open boundary holds the idle rebalance with it.
    check("no roster at all can never answer for this boundary", roster("1") == .unavailable)
    writeSessionAgents(SessionAgentsRecord(live: [], trusted: true, updatedAt: launch),
                       pid: "2", dir: stateDir)
    check("an empty trusted roster stamped at the boundary is idle", roster("2") == .idle)
    writeSessionAgents(SessionAgentsRecord(live: ["a1"], trusted: true, updatedAt: launch),
                       pid: "3", dir: stateDir)
    check("one naming a live agent is asked again rather than believed", roster("3") == .retry)
    // FAIL-CLOSED ON A COUNT NOBODY VOUCHES FOR. A Claude Code below `agentCensusClaudeVersion`
    // fires the edge events and publishes no roll call, so its roster drifts upward with nothing to
    // correct it - and an untrusted zero is exactly what a session with three agents looks like
    // after three crashes. Unavailable rather than retry, for the reason above: nothing about that
    // build changes while this session runs.
    writeSessionAgents(SessionAgentsRecord(live: [], trusted: false, updatedAt: launch),
                       pid: "4", dir: stateDir)
    check("an empty roster that cannot be believed answers for nothing", roster("4") == .unavailable)

    // MARK: - 36c1a. A roll call is not overruled by an inference about it

    // THE REVERSAL (codex review of 388fc84). The previous version arbitrated a roster naming
    // workers against `subagentIdleSeconds` of silence under `subagents/`, which declared a subagent
    // sitting inside ONE long tool call gone after ten minutes of writing nothing - and the
    // rebalance then reached the same conclusion from the same mtime and restarted the child on top
    // of it. Claude Code's roll call is a census; the mtime is an inference about that census; an
    // inference may not overrule it.
    check("a current roster naming a worker is waited for, however long it stays silent",
          roster("3", at: subagentIdleSeconds * 3) == .retry)
    check("…and the wait has no deadline of its own at all",
          roster("3", at: 60 * 60 * 24) == .retry)

    // WHAT DOES END IT is the roster ceasing to name anybody, which is what a `SubagentStop` or the
    // next `Stop` writes.
    writeSessionAgents(SessionAgentsRecord(live: [], trusted: true, updatedAt: launch),
                       pid: "3b", dir: stateDir)
    check("a roster that has stopped naming anybody is idle", roster("3b") == .idle)

    // MARK: - 36c1b. Whose roster it is, which is the structural test that replaced the clock

    // The ghost: the file is named for the SUPERVISOR pid and the supervisor outlives its children,
    // so a relaunch that ended a live fan-out leaves ids nothing will ever strike off. That is a
    // question about WHICH PROCESS WROTE IT, so it is answered by the stamp against this child's
    // start rather than by any reading of whether the contents are still true.
    writeSessionAgents(SessionAgentsRecord(live: ["ghost"], trusted: true,
                                           updatedAt: childStartedAt.addingTimeInterval(-30)),
                       pid: "5b", dir: stateDir)
    check("a roster written before this child started belongs to the one before it",
          roster("5b") == .unavailable)
    check("…which is the generation filter's answer, not this decision's",
          currentGenerationRoster(pid: "5b", childStartedAt: childStartedAt, dir: stateDir) == nil)
    check("…while the same record inside this child's life is kept",
          currentGenerationRoster(pid: "3", childStartedAt: childStartedAt, dir: stateDir) != nil)
    // THE COMPARISON IS EXACT, not at the roster's whole-second resolution, because the two errors
    // are not alike: reading a current roster as old costs one preventive move, reading an old one
    // as current holds a boundary open forever.
    // Inside the SAME whole second as the child's start, but before it: flooring the comparison
    // would keep this record, and keeping it is the ghost surviving.
    writeSessionAgents(SessionAgentsRecord(live: ["ghost"], trusted: true,
                                           updatedAt: childStartedAt.addingTimeInterval(-0.4)),
                       pid: "5c", dir: stateDir)
    check("a fraction of a second before the child started is still the previous generation",
          currentGenerationRoster(pid: "5c", childStartedAt: childStartedAt, dir: stateDir) == nil)
    check("…and that fixture really does sit inside the same whole second as the start",
          childStartedAt.addingTimeInterval(-0.4).timeIntervalSince1970.rounded(.down)
              == childStartedAt.timeIntervalSince1970.rounded(.down))
    // An untrusted count never reaches the decision either, whatever generation it is from.
    check("a count this Claude Code cannot vouch for is dropped by the same filter",
          currentGenerationRoster(pid: "4", childStartedAt: childStartedAt, dir: stateDir) == nil)
    check("…and what the filter drops reads as unavailable here", roster("4") == .unavailable)

    // AND THE CLAIM ITSELF, which the rebalance now reads too (Rebalance.swift).
    check("a kept roster naming somebody reports work in flight",
          rosterReportsWorking(currentGenerationRoster(pid: "3", childStartedAt: childStartedAt,
                                                       dir: stateDir)))
    check("an empty one does not",
          !rosterReportsWorking(currentGenerationRoster(pid: "2", childStartedAt: childStartedAt,
                                                        dir: stateDir)))
    check("and nothing at all does not, so a mover with no roster keeps the evidence it had",
          !rosterReportsWorking(nil))

    // MARK: - 36c2. The roster has to describe THIS boundary

    // THE RACE THIS CLOSES (codex review of d21f2e0, P1): the previous turn's roll call is on disk,
    // this turn's has not landed, and an empty one of those is a SIGTERM into a live fan-out.
    writeSessionAgents(SessionAgentsRecord(live: [], trusted: true,
                                           updatedAt: launch.addingTimeInterval(-30)),
                       pid: "5", dir: stateDir)
    check("a roster older than the boundary is not believed", roster("5") != .idle)
    check("…it is asked again, because the hook run that owns it may still be writing",
          roster("5") == .retry)
    // AND THE WAIT HAS AN END. A hook run that died between its two writes never lands that roster,
    // and a boundary held open for it would block the idle rebalance for the life of the session.
    check("…until the grace runs out, after which the boundary is spent instead",
          roster("5", at: turnBoundaryRosterGrace + 1) == .unavailable)
    check("…the boundary of that grace being inclusive",
          roster("5", at: turnBoundaryRosterGrace) == .retry)
    writeSessionAgents(SessionAgentsRecord(live: [], trusted: true,
                                           updatedAt: launch.addingTimeInterval(30)),
                       pid: "6", dir: stateDir)
    check("a roster written after the boundary is believed", roster("6") == .idle)

    // THE TWO ENCODINGS, END TO END, which is the trap this comparison exists to survive: the
    // roster is written with whole-second ISO-8601 and the boundary with the fractional formatter,
    // so ONE hook run handing both the same instant still produces two different strings on disk. A
    // bare `>=` between them would refuse the roster the hook had just written, and this feature
    // would never fire at all. Asserted through the real writers and readers rather than against
    // two `Date` values, because the loss happens in the encoding.
    let sharedInstant = launch.addingTimeInterval(0.75)
    let boundaryEvent = AgentRosterEvent(kind: .boundary, agentID: nil, carriedCensus: true,
                                         census: [])
    writeSessionAgents(advanceAgentRoster(nil, event: boundaryEvent, declared: true,
                                          now: sharedInstant),
                       pid: "7", dir: stateDir)
    if let ended = turnEndEvent(boundaryEvent, sessionID: "s7", now: sharedInstant) {
        writeSessionTurnEnd(ended, pid: "7", dir: stateDir)
    }
    let readBack = readSessionTurnEnd(pid: "7", dir: stateDir)
    check("the boundary round-trips with its fractional second", readBack?.at == sharedInstant)
    check("the roster round-trips truncated to the second, which is why the test is not a bare >=",
          readSessionAgents(pid: "7", dir: stateDir)?.updatedAt == launch)
    check("…and one hook run's own pair still reads as describing each other",
          turnBoundaryAgents(currentGenerationRoster(pid: "7", childStartedAt: childStartedAt,
                                                     dir: stateDir),
                             boundary: readBack?.at ?? .distantPast,
                             now: sharedInstant.addingTimeInterval(1)) == .idle)

    // The open tool call, read from a transcript rather than from the tick's cached scan (the cache
    // is empty exactly when this asks - a file written seconds ago never reaches the scan).
    let transcripts = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-turn-boundary-tx-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: transcripts) }
    func transcript(_ name: String, _ lines: [String]) -> URL {
        let url = transcripts.appendingPathComponent("\(name).jsonl")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    let closed = transcript("closed", [
        "{\"type\":\"assistant\",\"isSidechain\":false,\"timestamp\":\"\(stamp(10))\","
            + "\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}",
    ])
    check("a turn that answered in prose holds no call open",
          !turnBoundaryToolCallOpen(closed, now: launch.addingTimeInterval(20)))
    let open = transcript("open", [
        "{\"type\":\"assistant\",\"isSidechain\":false,\"timestamp\":\"\(stamp(10))\","
            + "\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\"}]}}",
    ])
    check("an unanswered tool_use does", turnBoundaryToolCallOpen(open, now: launch.addingTimeInterval(20)))
    check("a transcript that cannot be read reads as a call open, never as a clear field",
          turnBoundaryToolCallOpen(transcripts.appendingPathComponent("missing.jsonl"),
                                   now: launch))
    check("and no transcript at all the same", turnBoundaryToolCallOpen(nil, now: launch))

    // MARK: - 36d. One decision per boundary

    var state = TurnBoundaryState()
    let first = SessionTurnEnd(at: launch, sessionID: "s1")
    check("a session with no reported boundary has nothing pending",
          !turnBoundaryPending(state, event: nil))
    check("a reported one is pending until it is ruled on",
          turnBoundaryPending(state, event: first))
    state.decide(first.at)
    check("…and is not afterwards", !turnBoundaryPending(state, event: first))
    let second = SessionTurnEnd(at: launch.addingTimeInterval(60), sessionID: "s1")
    check("the next boundary is a new question", turnBoundaryPending(state, event: second))

    // MARK: - 36e. The station, and where it records a decision

    /// One tick of the station, with the transcript facts injected so the table above is reachable
    /// without a live conversation.
    func tick(state: inout TurnBoundaryState, event: SessionTurnEnd?, steering: Bool = true,
              mode: String = "auto", blocked: Bool = false, keyboardIdle: Bool = true,
              draftSuspected: Bool = false, carryable: Bool = true, fuseAllows: Bool = true,
              agents: TurnBoundaryAgents = .idle, turnEnded: Bool = true, toolCallOpen: Bool = false,
              accounts: [Snapshot.Account] = [dying, healthy],
              plan seed: RelaunchPlan? = nil) -> (plan: RelaunchPlan?, claimed: Bool) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-turn-boundary-claim-\(UUID().uuidString)")
        var plan = seed
        applyTurnBoundaryMove(plan: &plan, state: &state, event: event, steering: steering,
                              provider: "claude", account: dying, primaryModel: primary,
                              mode: mode, blocked: blocked, keyboardIdle: keyboardIdle,
                              draftSuspected: draftSuspected, carryable: carryable,
                              fuseAllows: fuseAllows, agents: { _, _ in agents },
                              turnEnded: turnEnded, toolCallOpen: toolCallOpen, quarantine: [:],
                              loaded: (Snapshot(version: 2, generatedAt: launch,
                                                accounts: accounts), nil),
                              now: launch, dir: dir)
        let cycle = rebalanceCycleKey(dying, primaryModel: primary, now: launch) ?? "-"
        let claimed = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .contains { $0.hasSuffix(".\(cycle)") }
        try? FileManager.default.removeItem(at: dir)
        return (plan, claimed)
    }

    var moving = TurnBoundaryState()
    let moved = tick(state: &moving, event: first)
    check("the station plans the move", moved.plan?.target.id == "B")
    check("…tagged so the log can tell it from a rebalance and a cap",
          moved.plan?.reason == turnBoundaryReason && turnBoundaryReason == "turn-boundary")
    check("…and the audit log passes that tag through unchanged",
          handoffReason(turnBoundaryReason, pinCleared: false) == "turn-boundary")
    check("…counting against the recovery fuse, like every automatic cross-account move",
          moved.plan?.countsFuse == true)
    check("…carrying the conversation rather than starting a fresh one",
          moved.plan?.fresh == false)
    check("…and taking the account's claim for this cycle", moved.claimed)
    check("…and it is recorded as decided, so the next tick does not ask again",
          !turnBoundaryPending(moving, event: first))

    // A plan another reason already made is never replaced, and the boundary is left undecided so
    // that a stood-down relaunch does not cost this session its move.
    var behindPlan = TurnBoundaryState()
    let seeded = RelaunchPlan(target: healthy, reason: "cap", countsFuse: true)
    let held = tick(state: &behindPlan, event: first, plan: seeded)
    check("a tick that already has a plan is left alone", held.plan?.reason == "cap")
    check("…and the boundary stays undecided for the next child to answer",
          turnBoundaryPending(behindPlan, event: first))

    // A gate about the WORLD leaves nothing behind: the same boundary is asked again next tick,
    // which is what makes a live fan-out a wait rather than a refusal.
    var waiting = TurnBoundaryState()
    check("a tick held by a live fan-out plans nothing",
          tick(state: &waiting, event: first, agents: .retry).plan == nil)
    check("…and does not spend the boundary", turnBoundaryPending(waiting, event: first))
    check("…so the tick after the fan-out ends moves it",
          tick(state: &waiting, event: first).plan?.target.id == "B")

    // A ROSTER THAT WILL NEVER ANSWER IS THE OPPOSITE CASE, and the difference is the whole of the
    // P2 fix: it plans nothing either, and it SPENDS the boundary, so the idle rebalance that this
    // station stands down is handed straight back (`turnBoundaryPending`, WindowRepick.swift).
    var unanswerable = TurnBoundaryState()
    let noRoster = tick(state: &unanswerable, event: first, agents: .unavailable)
    check("a session with no usable roster is not moved by this station", noRoster.plan == nil)
    check("…and takes no claim", !noRoster.claimed)
    check("…while the boundary IS spent, so the idle rebalance is not blocked behind it",
          !turnBoundaryPending(unanswerable, event: first))
    // And it stays spent: a second tick on the same boundary changes nothing, so the rebalance
    // keeps running on its own 120s bar with the 600s subagent heuristic behind it, exactly as it
    // did before this feature existed.
    check("…on that tick and every one after it",
          tick(state: &unanswerable, event: first, agents: .unavailable).plan == nil
              && !turnBoundaryPending(unanswerable, event: first))

    var typing = TurnBoundaryState()
    _ = tick(state: &typing, event: first, keyboardIdle: false)
    check("somebody typing does not spend the boundary either",
          turnBoundaryPending(typing, event: first))

    // A gate about the BOUNDARY spends it: nothing takes back a message written after the stamp.
    var stale = TurnBoundaryState()
    check("a boundary that no longer stands plans nothing",
          tick(state: &stale, event: first, turnEnded: false).plan == nil)
    check("…and is recorded, so the tail is not re-read every two seconds until the next turn",
          !turnBoundaryPending(stale, event: first))

    // So does a quota answer: an account that is comfortable, or a field with nothing better in it,
    // is the idle rebalance's problem at its own 120s bar rather than this one's every 2s.
    var comfortable = TurnBoundaryState()
    check("a comfortable account plans nothing",
          tick(state: &comfortable, event: first, accounts: [acct("A", model: 40), healthy]).plan
              == nil)
    check("…and the boundary is spent", !turnBoundaryPending(comfortable, event: first))
    var nowhere = TurnBoundaryState()
    let barren = tick(state: &nowhere, event: first, accounts: [dying, alsoDry])
    check("an all-dry field plans nothing", barren.plan == nil)
    check("…and spends no claim doing it", !barren.claimed)

    // THE EXEMPTION THROUGH THE WHOLE STATION, which is where it has to hold: the account this
    // session is on is empty, so the move is planned and the drought's record is never written -
    // and the boundary is spent either way, so nothing holds the idle rebalance behind it.
    var spentBoundary = TurnBoundaryState()
    let spentMove = tick(state: &spentBoundary, event: first, accounts: [spent, healthy])
    check("the station moves a session off a spent account", spentMove.plan?.target.id == "B")
    check("…without taking the drought's claim", !spentMove.claimed)
    check("…and records the boundary as decided",
          !turnBoundaryPending(spentBoundary, event: first))

    var noEvent = TurnBoundaryState()
    check("a session whose Claude Code reports no boundary at all is never moved by this",
          tick(state: &noEvent, event: nil).plan == nil)

    // MARK: - 36f. The wiring the tick carries

    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the turn-boundary checks", !loop.isEmpty)
    check("the tick runs the station", loop.contains("applyTurnBoundaryMove(plan: &plan,"))
    // AFTER the board, because the blocked reading is what it needs from there and nothing else in
    // the tick can produce it.
    check("…after the board has decided what this session is doing",
          loop.range(of: "let board = syncSessionState(").map { board in
              loop.range(of: "applyTurnBoundaryMove(plan: &plan,").map {
                  board.upperBound < $0.lowerBound
              } ?? false
          } ?? false)
    check("…and before the tick reads whether it is replacing the child, so the input station and "
          + "the knock both see this plan",
          loop.range(of: "applyTurnBoundaryMove(plan: &plan,").map { station in
              loop.range(of: "var replacingChild = relaunchIsHappening(").map {
                  station.upperBound < $0.lowerBound
              } ?? false
          } ?? false)
    check("…taking the board's hard-wait reading rather than a second opinion",
          loop.contains("blocked: board.waitingOnPerson"))
    // ONE ROSTER READ FOR BOTH MOVERS, generation-filtered where it is read rather than at each
    // consumer: two reads are two answers to "who is working" that can disagree about one tick.
    check("the tick filters the roster by generation once, above both movers",
          loop.contains("let roster = currentGenerationRoster(pid: supervisorPID, "
                        + "childStartedAt: launchedAt)")
              && loop.contains("let agentsWorking = rosterReportsWorking(roster)"))
    check("…and hands that same record to this station",
          loop.contains("agents: { turnBoundaryAgents(roster, boundary: $0, now: $1) }"))
    check("…and the claim from it to the rebalance",
          loop.contains("agentsWorking: agentsWorking"))
    // ONE CLOCK FOR THE STATION: the grace is judged against the same instant the quota gates below
    // it use, rather than a reading the closure takes for itself.
    check("…on the station's own clock rather than one of the closure's",
          loop.contains("now: $1"))
    check("…and never the word that also covers the soft prompt fired a minute after every turn",
          !loop.contains("board.state == .blocked"))
    // ONE READING OF THE BOUNDARY for the two stations that consult it, taken above both.
    check("the boundary is read once, above the preventive station",
          loop.components(separatedBy: "readSessionTurnEnd(pid: supervisorPID)").count == 2
              && (loop.range(of: "let boundary = readSessionTurnEnd(").map { read in
                  loop.range(of: "applyProactiveMoves(plan: &plan,").map {
                      read.upperBound < $0.lowerBound
                  } ?? false
              } ?? false))
    // THE ORDER OF THE LADDER, bought with the stand-down rather than by moving a station the
    // tick's other priorities are arranged around: free repick, then this, then the rebalance.
    check("the rebalance is stood down while a boundary is undecided",
          loop.contains("turnBoundaryPending: turnBoundaryPending(turnBoundary,"))
    let station = (try? String(contentsOfFile: "TallyCLI/WindowRepick.swift", encoding: .utf8)) ?? ""
    check("…and the stand-down is inside the preventive station, after the free repick",
          station.range(of: "windowRepickMove(provider: provider,").map { repick in
              station.range(of: "guard !turnBoundaryPending else { return }").map {
                  repick.upperBound < $0.lowerBound
              } ?? false
          } ?? false)
    check("…and before the rebalance it is protecting",
          station.range(of: "guard !turnBoundaryPending else { return }").map { hold in
              station.range(of: "rebalanceMove(provider: provider,").map {
                  hold.upperBound < $0.lowerBound
              } ?? false
          } ?? false)
    // ONE CLAIM FOR BOTH, which is what that stand-down is protecting: two claims would hand the
    // same drought two moves for one account.
    let mover = (try? String(contentsOfFile: "TallyCLI/TurnBoundaryMove.swift",
                             encoding: .utf8)) ?? ""
    check("the turn boundary claims the cycle through the rebalance's own record",
          mover.contains("claimRebalanceCycle(account.id, cycle: $0, dir: dir)")
              && mover.contains("dir: URL = rebalanceDir"))
    check("and reads the same cycle key, so the two agree about which drought they are in",
          mover.contains("rebalanceCycleKey(field.current, primaryModel: primaryModel, now: now)"))
    // ONE CLAIM MEANS ONE EXEMPTION TOO, spelled identically in both movers rather than twice in
    // two ways: a mover with a threshold of its own would hold a session on an account the other
    // one had already emptied by leaving it.
    let idle = (try? String(contentsOfFile: "TallyCLI/Rebalance.swift", encoding: .utf8)) ?? ""
    let waiver = "accountIsSpent(current, primaryModel: primaryModel, now: now) || claim()"
    check("the two movers waive the claim on one shared reading of the account",
          !idle.isEmpty && mover.contains(waiver) && idle.contains(waiver))

    // MARK: - 36g. The hook writes the roster before it publishes the boundary

    // THE OTHER HALF OF THE P1 FIX, and the half no value assertion can reach: the ordering lives
    // in a process that reads a hook payload off stdin. Once the roster is on disk first, the race
    // above cannot be entered at all on this build - the comparison in 36c2 is what covers the
    // sessions still running the previous hook.
    let hook = (try? String(contentsOfFile: "TallyCLI/HookAgents.swift", encoding: .utf8)) ?? ""
    check("the hook source is readable from the turn-boundary checks", !hook.isEmpty)
    check("the roster fold is written before the boundary is published",
          hook.range(of: "recordAgentEvent(event, declared:").map { fold in
              hook.range(of: "writeSessionTurnEnd(ended, pid: supervisor)").map {
                  fold.upperBound < $0.lowerBound
              } ?? false
          } ?? false)
    // ONE INSTANT FOR BOTH DOCUMENTS. Two `Date()` calls either side of a second boundary would
    // publish a roster stamped a second before the turn end it belongs to, and 36c2's comparison
    // would then correctly refuse the pair the hook had just written.
    check("…and both are stamped from one instant taken above them",
          hook.contains("let now = Date()")
              && hook.contains("pid: supervisor, now: now)")
              && hook.contains("turnEndEvent(event, sessionID: session, now: now)"))
    // COMMENT LINES FILTERED FIRST, which is not fastidiousness: the paragraph above this line in
    // the hook explains the hazard by naming `Date()`, so a bare count over the whole file reports
    // two clock readings for a run that takes one, and the check goes red on prose.
    check("…which is the only clock reading the run takes",
          hook.split(separator: "\n", omittingEmptySubsequences: false)
              .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                  && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
              .filter { $0.contains("Date()") }.count == 1)
}
