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
    check("no roster at all is not an idle session",
          !turnBoundaryAgentsIdle(pid: "1", dir: stateDir))
    writeSessionAgents(SessionAgentsRecord(live: [], trusted: true, updatedAt: launch),
                       pid: "2", dir: stateDir)
    check("an empty trusted roster is", turnBoundaryAgentsIdle(pid: "2", dir: stateDir))
    writeSessionAgents(SessionAgentsRecord(live: ["a1"], trusted: true, updatedAt: launch),
                       pid: "3", dir: stateDir)
    check("a roster naming a live agent is not", !turnBoundaryAgentsIdle(pid: "3", dir: stateDir))
    // FAIL-CLOSED ON A COUNT NOBODY VOUCHES FOR. A Claude Code below `agentCensusClaudeVersion`
    // fires the edge events and publishes no roll call, so its roster drifts upward with nothing to
    // correct it - and an untrusted zero is exactly what a session with three agents looks like
    // after three crashes.
    writeSessionAgents(SessionAgentsRecord(live: [], trusted: false, updatedAt: launch),
                       pid: "4", dir: stateDir)
    check("an empty roster that cannot be believed is not an idle session either",
          !turnBoundaryAgentsIdle(pid: "4", dir: stateDir))

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
              agentsIdle: Bool = true, turnEnded: Bool = true, toolCallOpen: Bool = false,
              accounts: [Snapshot.Account] = [dying, healthy],
              plan seed: RelaunchPlan? = nil) -> (plan: RelaunchPlan?, claimed: Bool) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-turn-boundary-claim-\(UUID().uuidString)")
        var plan = seed
        applyTurnBoundaryMove(plan: &plan, state: &state, event: event, steering: steering,
                              provider: "claude", account: dying, primaryModel: primary,
                              mode: mode, blocked: blocked, keyboardIdle: keyboardIdle,
                              draftSuspected: draftSuspected, carryable: carryable,
                              fuseAllows: fuseAllows, agentsIdle: agentsIdle,
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
          tick(state: &waiting, event: first, agentsIdle: false).plan == nil)
    check("…and does not spend the boundary", turnBoundaryPending(waiting, event: first))
    check("…so the tick after the fan-out ends moves it",
          tick(state: &waiting, event: first).plan?.target.id == "B")

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
    check("…taking the board's own blocked reading rather than a second opinion",
          loop.contains("blocked: board.state == .blocked"))
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
          mover.contains("claimRebalanceCycle(account.id, cycle: cycle, dir: dir)")
              && mover.contains("dir: URL = rebalanceDir"))
    check("and reads the same cycle key, so the two agree about which drought they are in",
          mover.contains("rebalanceCycleKey(field.current, primaryModel: primaryModel, now: now)"))
}
