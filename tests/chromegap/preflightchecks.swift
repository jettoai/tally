import Foundation

// MARK: - B-558 second round: the Chrome call answered BEFORE it is sent (TallyCLI/ChromePreflight.swift),
// and the failed call moving the session itself (ChromeReach.swift). Every collaborator is injected:
// the move is a probe, the subagent witness a closure, the pending request a value.

final class MoveProbe {
    var calls: [(String, String)] = []
    var answer: ChromeMoveQueue = .queued
}

struct Decision {
    let event: String?, permission: String?, reason: String?
    init(_ out: [String]) {
        let document = out.first.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let inner = document?["hookSpecificOutput"] as? [String: Any]
        event = inner?["hookEventName"] as? String
        permission = inner?["permissionDecision"] as? String
        reason = inner?["permissionDecisionReason"] as? String
    }
}

extension World {
    func moveDeps(setting: String?, account: String = "claude:.claude5", idle: Bool = true,
                  pending: SwitchRequest? = nil, relays: [ChromeRelaySession] = [],
                  probe: MoveProbe, child: Int = 101,
                  idleRule: ((ChromeCallContext) -> Bool)? = nil) -> ChromeGapDeps {
        ChromeGapDeps(account: { _ in account }, child: { _ in child }, labels: { realLabels },
                      ledgerFile: ledger, chromeAccount: { setting },
                      relays: { _, _ in relays },
                      agentsIdle: { _, context in idleRule?(context) ?? idle },
                      queueMove: { probe.calls.append(($0, $1)); return probe.answer },
                      pendingSwitch: { _ in pending })
    }

    func runPre(_ deps: ChromeGapDeps, session: String = conversation,
                tool: String = "mcp__claude-in-chrome__tabs_context_mcp",
                extra: [String: Any] = [:]) -> [String] {
        var body: [String: Any] = ["hook_event_name": "PreToolUse", "session_id": session,
                                   "tool_name": tool, "transcript_path": "/tmp/x.jsonl",
                                   "tool_input": [String: Any]()]
        for (key, value) in extra { body[key] = value }
        var printed: [String] = []
        _ = runHookKnock(args: ["PreToolUse"], environment: ["TALLY_SUPERVISOR_PID": supervisorPID],
                         input: { (try? JSONSerialization.data(withJSONObject: body)) ?? Data() },
                         dir: state, alive: { _ in true }, watching: { _ in conversation },
                         log: log, now: t0, chrome: deps, emit: { printed.append($0) })
        return printed
    }

    func post(_ deps: ChromeGapDeps, child: Int = 101) -> String? {
        chromeGapNotice(tool: "mcp__claude-in-chrome__list_connected_browsers", outcome: .gap,
                        supervisor: supervisorPID, stateDir: state, now: t0, deps: deps)
    }
}

func pendingRequest(_ account: String, age: TimeInterval) -> SwitchRequest {
    SwitchRequest(epoch: Int((t0.timeIntervalSince1970 - age) * 1000), accountID: account,
                  origin: .chromeHook)
}

func runPreflightChecks() {
    let two = "claude:.claude2"
    let sessions = [ChromeRelaySession(supervisorPid: "4242", project: "finance")]
    let s1Head = "Tally: Claude in Chrome is signed in to \"Claude 2\" (set in Tally), not to this"
        + " session's account \"Claude 5\", so this call was not sent."

    do {
        let w = World("p-t1"), probe = MoveProbe()
        check("P-T1 no setting: the call goes through untouched",
              w.runPre(w.moveDeps(setting: nil, probe: probe)).isEmpty && probe.calls.isEmpty)
        check("P-T1b a setting naming an unknown account is no setting",
              w.runPre(w.moveDeps(setting: "claude:.gone", probe: probe)).isEmpty && probe.calls.isEmpty)
    }

    do {
        let w = World("p-t2"), probe = MoveProbe()
        let out = w.runPre(w.moveDeps(setting: two, probe: probe))
        let d = Decision(out)
        check("P-T2 one deny document under PreToolUse",
              out.count == 1 && d.event == "PreToolUse" && d.permission == "deny")
        check("P-T2 the reason opens with the move sentence naming both accounts",
              d.reason?.hasPrefix(s1Head) == true && d.reason?.contains("This session moves to \"Claude 2\"") == true)
        check("P-T2 it tells the agent to end the turn and names the way back",
              d.reason?.contains("End this turn now") == true && d.reason?.contains("tally account --auto") == true)
        check("P-T2 the move was queued once, onto the set account, for this supervisor",
              probe.calls.count == 1 && probe.calls[0].0 == two && probe.calls[0].1 == supervisorPID)
        check("P-T2 the denial is in the input log",
              w.logText().contains("pid=\(supervisorPID) input=chrome-preflight-denied "))
    }

    do {
        let w = World("p-t3"), probe = MoveProbe()
        let d = Decision(w.runPre(w.moveDeps(setting: two, pending: pendingRequest(two, age: 30),
                                             probe: probe)))
        check("P-T3 a move already pending keeps denying with the move sentence",
              d.permission == "deny" && d.reason?.hasPrefix(s1Head) == true
                  && d.reason?.contains("This session moves to") == true)
        check("P-T3 and does not write the request again", probe.calls.isEmpty)
        let edge = Decision(w.runPre(w.moveDeps(setting: two, pending: pendingRequest(two, age: 600),
                                                probe: probe)))
        check("P-T3b at exactly the window it still denies", edge.permission == "deny")
    }

    do {
        let w = World("p-t4"), probe = MoveProbe()
        check("P-T4 a move pending past the window lets the call through, never denying forever",
              w.runPre(w.moveDeps(setting: two, pending: pendingRequest(two, age: 601), probe: probe))
                  .isEmpty && probe.calls.isEmpty)
    }

    do {
        let w = World("p-t5"), probe = MoveProbe()
        let d = Decision(w.runPre(w.moveDeps(setting: two, idle: false, relays: sessions, probe: probe)))
        check("P-T5 work in flight: a hand-off denial, not a move",
              d.permission == "deny" && probe.calls.isEmpty
                  && d.reason?.hasPrefix(s1Head) == true
                  && d.reason?.contains("tally message claude --session 4242 --file") == true)
        check("P-T5 it says why the session was not moved", d.reason?.hasSuffix(chromeAgentsSuffix) == true)
        check("P-T5 the same generation is handed off once, then calls go through",
              w.runPre(w.moveDeps(setting: two, idle: false, relays: sessions, probe: probe)).isEmpty)
        check("P-T5 the claim maps back to its supervisor for the dead-pid sweep",
              supervisorStatePid(ofFile: "\(supervisorPID).chromepre.101") == 77123)
        let next = Decision(w.runPre(w.moveDeps(setting: two, probe: probe)))
        check("P-T5b once the work is done the claim does not block the move",
              next.reason?.contains("This session moves to") == true && probe.calls.count == 1)
        let w3 = World("p-t5c")
        let none = Decision(w3.runPre(w3.moveDeps(setting: two, idle: false, probe: MoveProbe())))
        check("P-T5c nothing on the set account: the manual move command, after the same opening",
              none.reason?.hasPrefix(s1Head) == true
                  && none.reason?.contains("`tally account .claude2`") == true
                  && none.reason?.hasSuffix(chromeAgentsSuffix) == true)
    }

    do {
        let w = World("p-t6"), probe = MoveProbe()
        check("P-T6 a session already on the set account goes through",
              w.runPre(w.moveDeps(setting: two, account: two, probe: probe)).isEmpty && probe.calls.isEmpty)
    }

    do {
        let w = World("p-t7"), probe = MoveProbe()
        probe.answer = .refused
        let d = Decision(w.runPre(w.moveDeps(setting: two, probe: probe)))
        check("P-T7 a refused move falls back to the hand-off denial",
              d.permission == "deny" && probe.calls.count == 1
                  && d.reason?.contains("`tally account .claude2`") == true
                  && d.reason?.hasSuffix(chromeAgentsSuffix) == false)
        let w2 = World("p-t7b"), there = MoveProbe()
        there.answer = .alreadyThere
        check("P-T7b already there lets the call through",
              w2.runPre(w2.moveDeps(setting: two, probe: there)).isEmpty)
    }

    do {
        let w = World("p-t8"), probe = MoveProbe()
        let d = Decision(w.runPre(w.moveDeps(setting: two, pending: pendingRequest("claude:.claude3", age: 30),
                                             probe: probe)))
        check("P-T8 a person's own move moments ago is not overwritten",
              d.permission == "deny" && probe.calls.isEmpty && d.reason?.hasSuffix(chromeAgentsSuffix) == true)
    }

    do {
        let w = World("p-t9"), probe = MoveProbe()
        w.fileKnock()
        let d = Decision(w.runPre(w.moveDeps(setting: two, probe: probe)))
        check("P-T9 PreToolUse never claims the quota knock",
              d.permission == "deny" && w.knockStillFiled() && d.reason?.contains("[tally] low.") == false)
        let w2 = World("p-t9b")
        w2.fileKnock()
        check("P-T9b a non-Chrome PreToolUse prints nothing and consumes nothing",
              w2.runPre(w2.moveDeps(setting: two, probe: probe), tool: "Bash").isEmpty && w2.knockStillFiled())
    }

    do {
        let w = World("p-t10"), probe = MoveProbe()
        check("P-T10 a nested session's PreToolUse says nothing",
              w.runPre(w.moveDeps(setting: two, probe: probe),
                       session: "11111111-2222-4333-8444-555555555555").isEmpty && probe.calls.isEmpty)
    }

    do {
        let w = World("p-t11"), probe = MoveProbe()
        let text = w.post(w.moveDeps(setting: two, probe: probe)) ?? ""
        check("P-T11 a failed call with nothing on the set account moves this session",
              text.contains("so this session moves to \"Claude 2\" when this turn ends")
                  && probe.calls.count == 1 && !text.contains("tally account .claude2"))
        let w12 = World("p-t12"), probe12 = MoveProbe()
        let relayed = w12.post(w12.moveDeps(setting: two, relays: sessions, probe: probe12)) ?? ""
        check("P-T12 with a live session there, this session still moves itself first",
              relayed.contains("this session moves to") && !relayed.contains("tally message")
                  && probe12.calls.count == 1)
        let w13 = World("p-t13"), probe13 = MoveProbe()
        let busy = w13.post(w13.moveDeps(setting: two, idle: false, relays: sessions, probe: probe13)) ?? ""
        check("P-T13 work in flight: the relay sentence, plus why it was not moved",
              busy == chromeRelayMessage(accountLabel: "Claude 5", settingLabel: "Claude 2",
                                         sessions: sessions, selfSupervisor: supervisorPID)
                  + chromeAgentsSuffix && probe13.calls.isEmpty)
        let w6 = World("p-t6post"), probe6 = MoveProbe()
        let stale = w6.post(w6.moveDeps(setting: two, pending: pendingRequest(two, age: 900), probe: probe6)) ?? ""
        check("P-T6post a failure after the window says the move is queued and does not rewrite it",
              stale.contains("this session moves to") && probe6.calls.isEmpty)
    }

    do {
        let w = World("p-t14")
        let deps = ChromeGapDeps(account: { _ in "claude:.claude5" }, child: { _ in 101 },
                                 labels: { realLabels }, ledgerFile: w.ledger, chromeAccount: { two })
        check("P-T14 deps with no way to move keep the 69ead54 sentence word for word",
              w.post(deps) == chromeMoveMessage(accountLabel: "Claude 5", settingLabel: "Claude 2",
                                                settingID: two))
        let w2 = World("p-t14b")
        let pre = ChromeGapDeps(account: { _ in "claude:.claude5" }, child: { _ in 101 },
                                labels: { realLabels }, ledgerFile: w2.ledger, chromeAccount: { two })
        check("P-T14b and never deny before the call", w2.runPre(pre).isEmpty)
    }

    // P-T15: the subagent witness, each missing reading answering "busy".
    do {
        let start = t0.addingTimeInterval(-3600)
        func idle(fromSubagent: Bool = false, child: Date? = start, hook: Bool = true, version: Bool = true,
                  record: SessionAgentsRecord? = nil, rosterBad: Bool = false, write: Date? = nil,
                  treeBad: Bool = false, background: Bool? = false) -> Bool {
            chromeAgentsIdle(fromSubagent: fromSubagent, childStartedAt: child, agentHookRegistered: hook,
                             claudeReportsAgents: version, record: record, rosterUnreadable: rosterBad,
                             newestSubagentWrite: write, subagentsUnreadable: treeBad,
                             backgroundThisTurn: background, now: t0)
        }
        let current = t0.addingTimeInterval(-60)
        let rows: [(String, Bool, Bool)] = [
            ("a call from a subagent", idle(fromSubagent: true), false),
            ("no child start time", idle(child: nil), false),
            ("no roster hook registered", idle(hook: false), false),
            ("a Claude Code whose census cannot be read", idle(version: false), false),
            ("a subagent write 30s ago", idle(write: t0.addingTimeInterval(-30)), false),
            ("a subagent write from before this child", idle(write: start.addingTimeInterval(-10)), true),
            ("a current roster with a live agent",
             idle(record: SessionAgentsRecord(live: ["a1"], trusted: true, updatedAt: current)), false),
            ("a current roster with background work",
             idle(record: SessionAgentsRecord(live: [], trusted: true, updatedAt: current, background: 1)), false),
            ("an earlier generation's roster",
             idle(record: SessionAgentsRecord(live: ["ghost"], trusted: true, updatedAt: start.addingTimeInterval(-5))), true),
            ("a current empty roster",
             idle(record: SessionAgentsRecord(live: [], trusted: true, updatedAt: current, background: 0)), true),
            ("background work started this turn", idle(background: true), false),
            ("a turn whose background starts cannot be read", idle(background: nil), false),
            ("a roster file that will not decode", idle(rosterBad: true), false),
            ("a subagents directory that cannot be listed", idle(treeBad: true), false),
        ]
        for (name, got, want) in rows { check("P-T15 \(name) reads \(want ? "idle" : "busy")", got == want) }
        check("P-T15 the live reader with no transcript path reads busy",
              !chromeAgentsIdleLive(supervisor: "999999", context: ChromeCallContext()))
    }

    do {
        check("P-T16 agent_id marks a subagent call",
              ChromeCallContext(payload: ["agent_id": "a1"]).fromSubagent)
        check("P-T16 agent_type alone marks it too", ChromeCallContext(payload: ["agent_type": "Explore"]).fromSubagent)
        check("P-T16 neither is the main chain, and the transcript path is kept",
              ChromeCallContext(payload: ["transcript_path": "/t.jsonl"])
                  == ChromeCallContext(fromSubagent: false, transcriptPath: "/t.jsonl"))
        let w = World("p-t16"), probe = MoveProbe()
        let d = Decision(w.runPre(w.moveDeps(setting: two, probe: probe, idleRule: { !$0.fromSubagent }),
                                  extra: ["agent_id": "a1", "agent_type": "general-purpose"]))
        check("P-T16 a subagent's Chrome call is handed off, never moved",
              d.reason?.hasSuffix(chromeAgentsSuffix) == true && probe.calls.isEmpty)
    }

    do {
        let quoted = "Cl\"au\\de"
        let texts = [chromePreflightMoveMessage(accountLabel: "Claude 5", settingLabel: "Claude 2"),
                     chromeMovedMessage(accountLabel: "Claude 5", settingLabel: "Claude 2"),
                     chromeAgentsSuffix,
                     chromePreflightOpening(accountLabel: quoted, settingLabel: quoted)]
        check("P-T21 the new sentences carry no em dash", !texts.joined().contains("\u{2014}"))
        let reason = chromePreflightMoveMessage(accountLabel: quoted, settingLabel: quoted)
        check("P-T21 a label with a quote and a backslash survives the deny document",
              Decision([chromePreflightHookOutput(reason: reason)]).reason == reason)
    }

    runBackgroundTurnChecks()
}
