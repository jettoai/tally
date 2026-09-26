import Foundation

// AN IDLE SELF-UPDATE WAITS FOR BACKGROUND WORK (TallyCLI/AgentRoster.swift `background`,
// SelfUpdate.swift `selfUpdateHeldByBackground`).
//
// THE INCIDENT (2026-09-26 10:19:26Z). A session idle between turns was waiting on three Monitors;
// the self-update restart killed them, and nothing woke the session for half an hour. The turn
// end's `background_tasks` list names that work, so the roster now counts what is not a subagent.

func runSelfUpdateBackgroundChecks() {
    let t0 = Date(timeIntervalSince1970: 1_786_571_200)
    func stop(_ tasks: [[String: Any]]?, event: String = "Stop") -> AgentRosterEvent {
        var payload: [String: Any] = ["hook_event_name": event]
        if let tasks { payload["background_tasks"] = tasks }
        return agentRosterEvent(payload, registered: event)!
    }
    let mixed: [[String: Any]] = [["type": "subagent", "agent_id": "a1"],
                                  ["type": "shell", "id": "b1"], ["type": "monitor", "id": "b2"]]

    // B1. What one turn end's list says.
    check("background: entries that are not subagents are counted, whatever their type",
          stop(mixed).otherTasks == 2 && stop(mixed).census == ["a1"])
    check("background: an empty list counts none", stop([]).otherTasks == 0)
    check("background: no list is no count", stop(nil).otherTasks == nil)

    // B2. How the count folds.
    func fold(_ record: SessionAgentsRecord?, _ event: AgentRosterEvent) -> SessionAgentsRecord {
        advanceAgentRoster(record, event: event, declared: true, now: t0)
    }
    let afterStop = fold(nil, stop(mixed))
    check("background: a turn end records its count", afterStop.background == 2)
    let afterSubagent = fold(afterStop, stop([["type": "shell", "id": "x"]],
                                             event: "SubagentStop"))
    check("background: a subagent's own stop does not overwrite the session's count",
          afterSubagent.background == 2)
    check("background: the next turn end with nothing running clears it",
          fold(afterSubagent, stop([])).background == 0)
    let old = #"{"live":["a1"],"trusted":true,"updatedAt":"2026-08-12T00:00:00Z"}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let legacy = try? decoder.decode(SessionAgentsRecord.self, from: Data(old.utf8))
    check("background: a roster written before the field still reads, with no count",
          legacy != nil && legacy?.background == nil && legacy?.live == ["a1"])

    // B3. What the gate reads.
    let shellOnly = SessionAgentsRecord(live: [], trusted: true, updatedAt: t0, background: 3)
    check("background: a shell left running is background work",
          rosterReportsBackgroundWork(shellOnly))
    check("background: a subagent is too",
          rosterReportsBackgroundWork(SessionAgentsRecord(live: ["a1"], trusted: true,
                                                          updatedAt: t0)))
    check("background: nothing running is none",
          !rosterReportsBackgroundWork(SessionAgentsRecord(live: [], trusted: true,
                                                           updatedAt: t0, background: 0)))
    check("background: a count this Claude Code cannot vouch for reads as none",
          !rosterReportsBackgroundWork(SessionAgentsRecord(live: [], trusted: false,
                                                           updatedAt: t0, background: 3)))
    check("background: no roster reads as none", !rosterReportsBackgroundWork(nil))

    // B4-B6. The gate and its limit.
    check("background: work running holds the update",
          selfUpdateHeldByBackground(working: true, heldSince: t0,
                                     now: t0.addingTimeInterval(10 * 60)))
    check("background: the first held tick holds too",
          selfUpdateHeldByBackground(working: true, heldSince: nil, now: t0))
    check("background: nothing running never holds it",
          !selfUpdateHeldByBackground(working: false, heldSince: t0, now: t0)
              && !selfUpdateHeldByBackground(working: false, heldSince: nil, now: t0))
    check("background: the hold ends at the limit",
          !selfUpdateHeldByBackground(working: true, heldSince: t0,
                                      now: t0.addingTimeInterval(selfUpdateBackgroundHoldLimit)))
    check("background: …and not a second before it",
          selfUpdateHeldByBackground(working: true, heldSince: t0,
                                     now: t0.addingTimeInterval(selfUpdateBackgroundHoldLimit - 1)))
    check("background: the limit is the hour this gate was written for",
          selfUpdateBackgroundHoldLimit == 3600)

    // B8. The 10:17:23 turn end of the incident, as the roster would have read it.
    let incident = try? decoder.decode(SessionAgentsRecord.self, from: Data(
        #"{"live":[],"trusted":true,"updatedAt":"2026-09-26T10:17:23Z","background":1}"#.utf8))
    check("background: the incident's roster holds the update",
          rosterReportsBackgroundWork(incident)
              && selfUpdateHeldByBackground(working: rosterReportsBackgroundWork(incident),
                                            heldSince: nil, now: t0))

    // B7. Wired into the idle self-update, and nowhere else.
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    let gateEnd = loop.range(of: "reason: \"self-update\"")?.lowerBound ?? loop.startIndex
    let gate = String(loop[..<gateEnd].suffix(400))
    check("background: the idle self-update asks the gate before planning",
          gate.contains("selfUpdateHeldByBackground("))
    check("background: …off this child's own roster",
          loop.contains("let backgroundWorking = rosterReportsBackgroundWork(roster)"))
}
