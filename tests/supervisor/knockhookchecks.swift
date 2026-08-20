import Foundation

// `tally hook-knock <event>` (TallyCLI/HookKnock.swift): the end of the filed channel that runs
// inside somebody's Claude Code, several times a turn, and hands the model the one sentence its
// supervisor filed for it.
//
// THREE THINGS THIS HAS TO GET RIGHT, and all three fail silently in production:
//
//   - it speaks only for the session it belongs to (the supervisor marker is inherited by every
//     descendant, so a nested `claude` would otherwise TAKE the sentence, and a claim consumes it);
//   - it delivers each sentence exactly once (Claude Code runs these hooks concurrently, so a
//     read-then-delete would put the same line into a conversation twice);
//   - and it puts nothing but the hook document on stdout, because stdout IS the answer here: a
//     diagnostic printed beside it is a parse error in the middle of a turn.

func runKnockHookChecks() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-knockhook-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let state = dir.appendingPathComponent("supervisor-state")
    try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    let log = dir.appendingPathComponent("input.log")
    let t0 = Date(timeIntervalSince1970: 1_786_571_200)
    let supervisorPID = "77123"
    let conversation = "0189aa3f-1c2d-4e5f-8a9b-0c1d2e3f4a5b"
    let sentence = "[tally] account Claude is running low: session 9% · resets 2h."

    /// One hook run, with every gate open by default so each check can close exactly one of them.
    /// The whole environment is injected: nothing here may read a real supervisor, a real config
    /// home or a real terminal.
    func run(event: String = "PostToolUse", registered: String? = nil,
             environment: [String: String] = ["TALLY_SUPERVISOR_PID": supervisorPID],
             alive: Bool = true, session: String? = nil, watching: String? = conversation,
             payload: [String: Any]? = nil) -> (code: Int32, out: [String]) {
        var printed: [String] = []
        let body = payload ?? ["hook_event_name": event,
                               "session_id": session ?? conversation]
        let code = runHookKnock(args: [registered ?? event], environment: environment,
                                input: { (try? JSONSerialization.data(withJSONObject: body))
                                    ?? Data() },
                                dir: state, alive: { _ in alive }, watching: { _ in watching },
                                log: log, now: t0, emit: { printed.append($0) })
        return (code, printed)
    }
    func file(_ message: String = sentence) {
        _ = writeQuotaKnockNotice(QuotaKnockNotice(message: message, at: t0), pid: supervisorPID,
                                  dir: state)
    }
    func stillFiled() -> Bool { readQuotaKnockNotice(pid: supervisorPID, dir: state) != nil }
    func context(_ out: [String]) -> String? {
        guard let text = out.first, let data = text.data(using: .utf8),
              let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return (document["hookSpecificOutput"] as? [String: Any])?["additionalContext"] as? String
    }

    // MARK: - Delivery

    file()
    let delivered = run()
    check("a filed sentence is handed to the model as context", context(delivered.out) == sentence)
    check("…under the event it actually arrived on, which is what Claude Code reads it as",
          ((try? JSONSerialization.jsonObject(with: Data((delivered.out.first ?? "").utf8)))
              as? [String: Any])
              .flatMap { ($0["hookSpecificOutput"] as? [String: Any])?["hookEventName"] as? String }
              == "PostToolUse")
    check("…in exactly one line on stdout, and with a zero exit",
          delivered.out.count == 1 && delivered.code == 0)
    check("…the file is consumed by the run that delivered it", !stillFiled())
    check("…and the log closes the pair the supervisor's filing opened",
          ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
              .contains("pid=\(supervisorPID) input=quota-knock-delivered "))
    // NOTHING FILED IS THE ORDINARY RUN, several times a turn, for the whole life of a session: it
    // has to be silent and free.
    let empty = run()
    check("a run with nothing filed says nothing at all", empty.out.isEmpty && empty.code == 0)

    // MARK: - Whose sentence this is

    // The marker is inherited by every descendant of a supervised session, a `claude` launched from
    // inside one included. A nested session claiming this would not merely mis-report something: it
    // would TAKE the sentence, and the conversation it was filed for would never hear it.
    file()
    let nested = run(session: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    check("a nested session does not take the sentence filed for its parent",
          nested.out.isEmpty && stillFiled())
    // Both ends have to be able to say who they are; when either cannot, the event is delivered,
    // which is the fail-open every other witness on this track takes.
    check("an event naming no conversation is still delivered",
          context(run(payload: ["hook_event_name": "PostToolUse"]).out) == sentence)
    file()
    check("…and so is one whose supervisor is too old to publish what it watches",
          context(run(watching: nil).out) == sentence)

    // A session this tool did not launch has nobody who could have filed anything.
    file()
    let unmarked = run(environment: [:])
    check("a session with no supervisor marker is not spoken into",
          unmarked.out.isEmpty && unmarked.code == 0 && stillFiled())
    let orphan = run(alive: false)
    check("…nor is one whose supervisor is gone", orphan.out.isEmpty && stillFiled())
    let nonsense = run(environment: ["TALLY_SUPERVISOR_PID": "not-a-pid"])
    check("…nor one whose marker is not a pid", nonsense.out.isEmpty && stillFiled())

    // MARK: - Which events may carry it

    // `Stop` accepts context too, and Claude Code CONTINUES THE CONVERSATION when it is given any:
    // a hook wired onto that event by hand would spend a model turn to deliver a warning about
    // spending model turns. So an event this build does not deliver on consumes nothing, and the
    // sentence stays on disk for one of the two that carry it for free.
    check("`Stop` is not an event a knock is delivered on", !quotaKnockHookEvents.contains("Stop"))
    let stopped = run(event: "Stop")
    check("…so a run on it delivers nothing and takes nothing", stopped.out.isEmpty && stillFiled())
    check("…and neither does an event neither end recognises",
          run(event: "SomethingLater").out.isEmpty && stillFiled())
    // The two ends of the reconciliation: the payload's own word is the true one where they differ,
    // and the registered argument answers for a payload that names nothing.
    check("the event the payload names wins over the one the registration guessed",
          quotaKnockHookEvent(registered: "PostToolUse", payload: "UserPromptSubmit")
              == "UserPromptSubmit")
    check("…and the registration answers when the payload names nothing this build delivers on",
          quotaKnockHookEvent(registered: "UserPromptSubmit", payload: nil) == "UserPromptSubmit"
              && quotaKnockHookEvent(registered: "UserPromptSubmit", payload: "Stop")
              == "UserPromptSubmit")
    check("…while neither naming one is nothing to answer",
          quotaKnockHookEvent(registered: "Stop", payload: nil) == nil
              && quotaKnockHookEvent(registered: nil, payload: nil) == nil)

    // MARK: - Exactly once, under a race

    // CLAUDE CODE RUNS THESE CONCURRENTLY. A read-then-delete would hand the same sentence to two
    // hook runs, and the model would be told twice about one drought - the defect the rename exists
    // to close (`claimQuotaKnockNotice`).
    file()
    let claims = NSLock()
    var winners = 0
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
        let claimed = claimQuotaKnockNotice(pid: supervisorPID, dir: state)
        claims.lock()
        if claimed?.message == sentence { winners += 1 }
        claims.unlock()
    }
    check("eight racing hook runs, and exactly one of them has the sentence", winners == 1)
    check("…and it is gone afterwards, however many asked", !stillFiled())
    // The shape behind that promise, pinned in the source: a claim that READ before it renamed, or
    // that unlinked instead of renaming, passes a sequential test and loses this race.
    let channel = (try? String(contentsOfFile: "TallyCLI/QuotaKnockNotice.swift",
                               encoding: .utf8)) ?? ""
    check("the notice source is readable from the hook checks", !channel.isEmpty)
    if let start = channel.range(of: "func claimQuotaKnockNotice"),
       let end = channel.range(of: "\n}\n", range: start.upperBound ..< channel.endIndex) {
        let body = String(channel[start.upperBound ..< end.lowerBound])
        check("the claim renames the file out of the way BEFORE it reads a byte of it",
              body.range(of: "rename(").map { rename in
                  body.range(of: "Data(contentsOf:").map { rename.lowerBound < $0.lowerBound }
                      ?? false
              } ?? false)
        check("…and reads the copy it claimed rather than the name everybody races for",
              body.contains("Data(contentsOf: claim)")
                  && !body.contains("Data(contentsOf: quotaKnockNoticeFile"))
    } else {
        check("the claim was found in the notice source", false)
    }

    // MARK: - What goes on stdout

    // A label is free text the user typed, and this document is parsed by something else: a quote
    // or a backslash in it would end the JSON early if the line were built by interpolation.
    let awkward = "[tally] account \"Claude\\2\" is running low: session 9% · resets 2h."
    file(awkward)
    let quoted = run(event: "UserPromptSubmit")
    check("a sentence carrying a quote and a backslash survives the round trip intact",
          context(quoted.out) == awkward)
    check("…and what was printed is one parseable document",
          (try? JSONSerialization.jsonObject(with: Data((quoted.out.first ?? "").utf8))) != nil)
    // EVERY REFUSAL IS SILENT. stdout is the answer channel here, so a diagnostic on it is a parse
    // error rather than a diagnostic (the other hooks may simply never print at all).
    let refusals = [run(environment: [:]), run(alive: false), run(event: "Stop"),
                    run(session: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
                    run(payload: ["hook_event_name": "PostToolUse", "session_id": 42])]
    check("no refusal path puts anything on stdout, and every one of them answers 0",
          refusals.allSatisfy { $0.out.isEmpty && $0.code == 0 })

    // MARK: - The registration this answers to

    check("the verb the app registers is the verb this binary dispatches",
          quotaKnockHookCommand("PostToolUse") == "/usr/local/bin/tally hook-knock PostToolUse"
              && quotaKnockHookMarker("PostToolUse") == " hook-knock PostToolUse")
    let dispatch = (try? String(contentsOfFile: "TallyCLI/main.swift", encoding: .utf8)) ?? ""
    check("…and the dispatch answers to it",
          dispatch.contains("case \"hook-knock\":\n    exit(runHookKnock("))

    try? FileManager.default.removeItem(at: dir)
}
