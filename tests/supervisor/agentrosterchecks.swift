import Foundation

// HOW MANY SUBAGENTS A SESSION HAS WORKING (TallyCLI/AgentRoster.swift). Four rules, all pure:
//
//   1. WHAT ONE HOOK PAYLOAD SAYS: which of the three events it is, which agent it is about, and
//      whether it carried the roll call - which is the CAPABILITY, separately from its contents.
//   2. HOW AN EVENT FOLDS INTO A ROSTER: the roll call first and the edge second, because the roll
//      call describes the session as of the event and the event is the change.
//   3. WHEN A COUNT MAY BE DRAWN AT ALL. Fail-closed: an edge-counted roster with nothing
//      correcting it drifts the first time an agent dies without saying so.
//   4. WHICH CLAUDE CODE PUBLISHES THE ROLL CALL, read off the path it was launched from.

func runAgentRosterChecks() {
    let t0 = Date(timeIntervalSince1970: 1_786_571_200)

    func payload(_ event: String, agent: String? = nil, tasks: [[String: Any]]? = nil)
        -> [String: Any] {
        var out: [String: Any] = ["hook_event_name": event]
        if let agent { out["agent_id"] = agent }
        if let tasks { out["background_tasks"] = tasks }
        return out
    }
    func task(_ id: String, type: String = "subagent") -> [String: Any] {
        ["agent_id": id, "type": type]
    }

    // MARK: what one payload says

    check("a start names its event and the agent it is about",
          agentRosterEvent(payload("SubagentStart", agent: "a1"), registered: "SubagentStart")
              == AgentRosterEvent(kind: .started, agentID: "a1"))
    // The payload's own word leads, and the command line we registered is the belt behind it: a
    // field that moves is exactly what the second reading is for.
    check("…and an event that does not name itself is read off the registration",
          agentRosterEvent(["agent_id": "a1"], registered: "SubagentStop")
              == AgentRosterEvent(kind: .stopped, agentID: "a1"))
    check("an event this build does not know is not one of ours",
          agentRosterEvent(payload("PreToolUse"), registered: nil) == nil
              && agentRosterEvent(nil, registered: "PreToolUse") == nil)
    // A payload whose event word is a stranger still belongs to the registration that ran it.
    check("…unless the registration says which of the three ran",
          agentRosterEvent(payload("SubagentStopped"), registered: "SubagentStop")?.kind == .stopped)
    // THE ROLL CALL IS THE CAPABILITY, and it is read even when it is empty: an empty list is a
    // session with no agents left, which is a reading rather than an absence.
    let census = agentRosterEvent(payload("Stop", tasks: [task("a1"), task("a2")]),
                                  registered: "Stop")
    check("a turn boundary carrying the roll call names everyone on it",
          census?.carriedCensus == true && census?.census.map(Set.init) == ["a1", "a2"])
    check("…and an empty roll call is still a roll call",
          agentRosterEvent(payload("Stop", tasks: []), registered: "Stop")
              == AgentRosterEvent(kind: .boundary, carriedCensus: true, census: []))
    check("a payload with no roll call at all says so",
          agentRosterEvent(payload("Stop"), registered: "Stop")?.carriedCensus == false)
    // Only subagents are counted: a shell command left running in the background is a background
    // task too, and the card says "agents".
    check("a background task that is not a subagent is not an agent",
          agentRosterEvent(payload("Stop", tasks: [task("a1"), task("b1", type: "bash")]),
                           registered: "Stop")?.census == ["a1"])
    // ALL OR NOTHING: a roll call missing one entry's name is indistinguishable from a complete one
    // that is missing somebody, and acting on it would retire an agent that is still working.
    check("a roll call this build cannot fully read is not acted on, though it still proves the build",
          agentRosterEvent(payload("Stop", tasks: [task("a1"), ["type": "subagent"]]),
                           registered: "Stop").map { $0.census == nil && $0.carriedCensus } == true)
    // A field written blank says nothing, and two nameless agents must not count as one.
    check("an empty id is not an id",
          agentRosterEvent(["hook_event_name": "SubagentStart", "agent_id": ""],
                           registered: nil)?.agentID == nil)
    // The spellings are tried in order, so a list that names tasks rather than agents still reads.
    check("a task named under another of the known keys is still named",
          agentRosterEvent(payload("Stop", tasks: [["id": "t1", "type": "subagent"]]),
                           registered: "Stop")?.census == ["t1"])

    // MARK: folding events into a roster

    func fold(_ record: SessionAgentsRecord?, _ event: AgentRosterEvent,
              declared: Bool = false) -> SessionAgentsRecord {
        advanceAgentRoster(record, event: event, declared: declared, now: t0)
    }
    let one = fold(nil, AgentRosterEvent(kind: .started, agentID: "a1"))
    let two = fold(one, AgentRosterEvent(kind: .started, agentID: "a2"))
    check("agents arrive one at a time", one.live == ["a1"] && two.live == ["a1", "a2"])
    check("…and leave the same way",
          fold(two, AgentRosterEvent(kind: .stopped, agentID: "a1")).live == ["a2"])
    // A SET RATHER THAN A TALLY. A subagent resumed by a message goes live, idle and live again
    // under the one id, so a +1/-1 count would leave the session permanently one agent over.
    check("a second start for a name already there changes nothing",
          fold(two, AgentRosterEvent(kind: .started, agentID: "a2")).live == ["a1", "a2"])
    check("…and an id that comes back after leaving is one agent, not two",
          fold(fold(two, AgentRosterEvent(kind: .stopped, agentID: "a2")),
               AgentRosterEvent(kind: .started, agentID: "a2")).live == ["a1", "a2"])
    // THE ROLL CALL IS AUTHORITATIVE, which is what bounds the drift the edges alone cannot see: an
    // agent that crashed leaves no stop event, and this is where it comes off the roster.
    check("a roll call replaces whatever the edges believed",
          fold(two, AgentRosterEvent(kind: .boundary, carriedCensus: true, census: ["a9"])).live
              == ["a9"])
    check("…including a roll call that says nobody is working",
          fold(two, AgentRosterEvent(kind: .boundary, carriedCensus: true, census: [])).live == [])
    // ROLL CALL FIRST, EDGE SECOND. A stop whose roll call was taken before the agent was struck
    // off would put it straight back; read this way round, the stop is what the event is about.
    check("a stop whose roll call still names the agent is still a stop",
          fold(two, AgentRosterEvent(kind: .stopped, agentID: "a2", carriedCensus: true,
                                     census: ["a1", "a2"])).live == ["a1"])
    check("…and a start the roll call has not caught up with is still a start",
          fold(one, AgentRosterEvent(kind: .started, agentID: "a3", carriedCensus: true,
                                     census: ["a1"])).live == ["a1", "a3"])
    // A boundary carries no edge of its own, so a payload naming an agent does not move the roster.
    check("a turn boundary with no roll call leaves the roster where it was",
          fold(two, AgentRosterEvent(kind: .boundary, agentID: "a1")).live == ["a1", "a2"])

    // MARK: when the count may be drawn

    check("an edge-counted roster is not drawn, however confident the edges look",
          one.trusted == false && one.reportable == nil)
    // Either half of the bar opens it: a payload that actually carried the roll call, or a version
    // that says this build publishes one.
    let observed = fold(one, AgentRosterEvent(kind: .boundary, carriedCensus: true, census: ["a1"]))
    check("a roll call proves the build, so the count is drawn from then on",
          observed.trusted && observed.reportable == 1)
    check("…and so does the version, before any roll call has arrived",
          fold(nil, AgentRosterEvent(kind: .started, agentID: "a1"), declared: true).reportable == 1)
    // STICKY, because a build does not stop publishing the roster halfway through a session, and a
    // `SubagentStart` between two turns carries no roll call of its own.
    check("trust once earned survives an event that carries no roll call",
          fold(observed, AgentRosterEvent(kind: .started, agentID: "a2")).reportable == 2)

    // MARK: which Claude Code publishes the roll call

    let installed = "/Users/a/.local/share/claude/versions/"
    check("the version is the file name the installer gives the build",
          claudeCodeVersion(executablePath: installed + "2.1.233") == [2, 1, 233])
    check("an install laid out any other way says nothing rather than guessing",
          claudeCodeVersion(executablePath: "/opt/homebrew/bin/claude") == nil
              && claudeCodeVersion(executablePath: nil) == nil
              && claudeCodeVersion(executablePath: installed + "2.1.233-beta") == nil)
    // The bar itself, from both sides and on it.
    check("the build that first publishes the roll call clears the bar",
          claudeCodeReportsAgents(executablePath: installed + "2.1.145"))
    check("…and the one before it does not",
          !claudeCodeReportsAgents(executablePath: installed + "2.1.144"))
    // Segment by segment rather than as text, so 2.1.99 is below 2.1.145 and 2.2 is above it.
    check("versions are compared as numbers, not as strings",
          !claudeCodeReportsAgents(executablePath: installed + "2.1.99")
              && claudeCodeReportsAgents(executablePath: installed + "2.2")
              && claudeCodeReportsAgents(executablePath: installed + "3.0.0")
              && !claudeCodeReportsAgents(executablePath: installed + "2.1"))
    // FAIL-CLOSED: an install this cannot read is not assumed to be a recent one.
    check("a path with no version in it does not clear the bar",
          !claudeCodeReportsAgents(executablePath: "/opt/homebrew/bin/claude")
              && !claudeCodeReportsAgents(executablePath: nil))

    // MARK: the document on disk

    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-agents-\(getpid())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    check("a roster nobody wrote is no roster", readSessionAgents(pid: "77", dir: dir) == nil)
    let written = SessionAgentsRecord(live: ["a1", "a2"], trusted: true, updatedAt: t0)
    check("a roster survives the trip through the file",
          writeSessionAgents(written, pid: "77", dir: dir)
              && readSessionAgents(pid: "77", dir: dir) == written)
    // The sweep reads a file name as a pid, so a session that ended must not leave its roster for
    // the next process to be handed that number (`supervisorStateSuffixes`).
    check("the roster is swept with the rest of a dead supervisor's files",
          supervisorStateSuffixes.contains(sessionAgentsSuffix)
              && supervisorStatePid(ofFile: "77" + sessionAgentsSuffix) == 77)
    // The three events the CLI answers to are the three the app registers, spelled once.
    check("the CLI and the registration name the same three events",
          AgentRosterEvent.events == ["SubagentStart", "SubagentStop", "Stop"])
}
