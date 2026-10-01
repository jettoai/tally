import Foundation

// MARK: - B-558: the Chrome call answered BEFORE it is sent (TallyCLI/ChromePreflight.swift), and the
// failed call (ChromeReach.swift), both handing the step to `tally chrome run` and never moving the
// session. Every collaborator is injected.

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
    func preDeps(setting: String?, account: String = "claude:.claude5", child: Int = 101) -> ChromeGapDeps {
        ChromeGapDeps(account: { _ in account }, child: { _ in child }, labels: { realLabels },
                      ledgerFile: ledger, chromeAccount: { setting })
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

    func post(_ deps: ChromeGapDeps) -> String? {
        chromeGapNotice(tool: "mcp__claude-in-chrome__list_connected_browsers", outcome: .gap,
                        supervisor: supervisorPID, stateDir: state, now: t0, deps: deps)
    }
}

func runPreflightChecks() {
    let two = "claude:.claude2"
    let s1Head = "Tally: Claude in Chrome is signed in to \"Claude 2\" (set in Tally), not to this"
        + " session's account \"Claude 5\", so this call was not sent."
    let runLine = "tally chrome run --file /tmp/tally-chrome-task-77123.md"
    let moveWords = ["tally account", "moves to", "End this turn"]

    do {
        let w = World("p1")
        check("P1 no setting: the call goes through untouched", w.runPre(w.preDeps(setting: nil)).isEmpty)
        check("P1 a setting naming an unknown account is no setting",
              w.runPre(w.preDeps(setting: "claude:.gone")).isEmpty)
    }

    do {
        let w = World("p2")
        let out = w.runPre(w.preDeps(setting: two))
        let d = Decision(out)
        check("P2 one deny document under PreToolUse",
              out.count == 1 && d.event == "PreToolUse" && d.permission == "deny")
        check("P2 the reason opens with the sentence naming both accounts", d.reason?.hasPrefix(s1Head) == true)
        check("P2 it gives the runner command and says the session keeps its account",
              d.reason?.contains(runLine) == true && d.reason?.contains("keeps its own account") == true)
        check("P3 it names no account move",
              d.reason.map { r in !moveWords.contains(where: r.contains) } == true)
        check("P10 the denial is in the input log",
              w.logText().contains("pid=\(supervisorPID) input=chrome-preflight-denied "))
        check("P4 the same generation is denied once, then calls go through",
              w.runPre(w.preDeps(setting: two)).isEmpty)
        check("P4 the claim maps back to its supervisor for the dead-pid sweep",
              supervisorStatePid(ofFile: "\(supervisorPID).chromepre.101") == 77123)
        let next = Decision(w.runPre(w.preDeps(setting: two, child: 102)))
        check("P5 a new child generation is denied once more",
              next.permission == "deny" && next.reason?.contains(runLine) == true)
    }

    do {
        let w = World("p6")
        check("P6 a session already on the set account goes through",
              w.runPre(w.preDeps(setting: two, account: two)).isEmpty)
    }

    do {
        let w = World("p7")
        let d = Decision(w.runPre(w.preDeps(setting: two),
                                  extra: ["agent_id": "a1", "agent_type": "general-purpose"]))
        check("P7 a subagent's Chrome call gets the same runner sentence",
              d.permission == "deny" && d.reason?.hasPrefix(s1Head) == true && d.reason?.contains(runLine) == true)
    }

    do {
        let w = World("p8")
        w.fileKnock()
        let d = Decision(w.runPre(w.preDeps(setting: two)))
        check("P8 PreToolUse never claims the quota knock",
              d.permission == "deny" && w.knockStillFiled() && d.reason?.contains("[tally] low.") == false)
        let w2 = World("p8b")
        w2.fileKnock()
        check("P8 a non-Chrome PreToolUse prints nothing and consumes nothing",
              w2.runPre(w2.preDeps(setting: two), tool: "Bash").isEmpty && w2.knockStillFiled())
    }

    do {
        let w = World("p9")
        check("P9 a nested session's PreToolUse says nothing",
              w.runPre(w.preDeps(setting: two), session: "11111111-2222-4333-8444-555555555555").isEmpty)
    }

    do {
        let w = World("p11")
        let text = w.post(w.preDeps(setting: two)) ?? ""
        check("P11 a failed call opens with the not-connected sentence and gives the runner command",
              text.hasPrefix(chromeGapOpening(accountLabel: "Claude 5")) && text.contains(runLine))
        check("P11 it names no account move", !moveWords.contains(where: text.contains))
    }

    do {
        let quoted = "Cl\"au\\de"
        let reason = chromeRunnerSentence(
            settingLabel: quoted, supervisor: supervisorPID,
            opening: chromePreflightOpening(accountLabel: quoted, settingLabel: quoted))
        check("P12 a label with a quote and a backslash survives the deny document",
              Decision([chromePreflightHookOutput(reason: reason)]).reason == reason)
        let banned = ["\u{2014}", "manifest", "reinstall", "restart", "mismatch"]
        check("P12 the runner sentence carries no em dash and none of the banned words",
              !banned.contains(where: reason.lowercased().contains))
    }

    do {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for name in ["ChromePreflight.swift", "ChromeReach.swift"] {
            let text = (try? String(contentsOf: repo.appendingPathComponent("TallyCLI/\(name)"), encoding: .utf8)) ?? ""
            check("P13 \(name) is readable", !text.isEmpty)
            for word in ["attemptSwitch", "writeSwitchRequest", "tally account", "SwitchOrigin"] {
                check("P13 \(name) never says \(word)", !text.contains(word))
            }
        }
    }
}
