import Foundation

// The Chrome-gap notice (TallyCLI/ChromeReach.swift, the branch in TallyCLI/HookKnock.swift and the
// app's event file in TallyCLI/ChromeGapEvent.swift). Every collaborator is injected: nothing here
// reads a real ~/.tally, supervisor, snapshot, Claude session or browser.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS: \(name)") } else { failures += 1; print("FAIL: \(name)") }
}

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("tally-chromegap-\(UUID().uuidString)")
let t0 = Date(timeIntervalSince1970: 1_790_000_000)
let supervisorPID = "77123"
let conversation = "0189aa3f-1c2d-4e5f-8a9b-0c1d2e3f4a5b"
let labels = ["c2": "Claude 2", "c4": "Claude 4", "c1": "Claude"]

// The three masked results the plan measured (§1 Q1), plus the binary's authentication variant.
let notConnectedList: [[String: Any]] = [["type": "text", "text":
    "Browser extension is not connected. Please ensure the Claude browser extension is installed and running (https://claude.ai/chrome), and that you are logged into claude.ai with the same account as Claude Code."]]
let timeoutString = "Error: The hidden tabs_context_mcp lookup did not respond within 8s. The Chrome extension may be slow to start, or the computer running that browser may be offline or asleep."
let authError = "Authentication error occurred. Please ensure you are logged into the Claude browser extension with the same claude.ai account as Claude Code."
let tabsOk = "{\"availableTabs\":[{\"tabId\":1841,\"title\":\"Example\",\"url\":\"https://example.com/\"}],\"tabGroupId\":22}"

/// One scratch world: supervisor state, ledger, event directory and input log.
struct World {
    let base: URL
    var state: URL { base.appendingPathComponent("supervisor-state") }
    var ledger: URL { base.appendingPathComponent("tally/chrome-reach.json") }
    var events: URL { base.appendingPathComponent("tally/chrome-gap") }
    var log: URL { base.appendingPathComponent("input.log") }
    init(_ name: String) {
        base = root.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("supervisor-state"),
                                                 withIntermediateDirectories: true)
    }
    func deps(account: String?, child: Int?) -> ChromeGapDeps {
        ChromeGapDeps(account: { _ in account }, child: { _ in child }, labels: { labels },
                      ledgerFile: ledger, eventDir: events)
    }
    func run(tool: String = "mcp__claude-in-chrome__tabs_context_mcp", response: Any? = notConnectedList,
             event: String = "PostToolUse", account: String? = "c4", child: Int? = 101,
             session: String = conversation, omitResponse: Bool = false) -> [String] {
        var body: [String: Any] = ["hook_event_name": event, "session_id": session,
                                   "tool_name": tool, "cwd": "/Users/x/workspace/finance"]
        if !omitResponse { body["tool_response"] = response ?? NSNull() }
        var printed: [String] = []
        _ = runHookKnock(args: [event], environment: ["TALLY_SUPERVISOR_PID": supervisorPID],
                         input: { (try? JSONSerialization.data(withJSONObject: body)) ?? Data() },
                         dir: state, alive: { _ in true }, watching: { _ in conversation },
                         log: log, now: t0, chrome: deps(account: account, child: child),
                         emit: { printed.append($0) })
        return printed
    }
    func eventCount() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: events.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.count
    }
    func ledgerExists() -> Bool { FileManager.default.fileExists(atPath: ledger.path) }
    func readLedger() -> ChromeReachLedger { readChromeReachLedger(file: ledger) }
    func seedOk(_ account: String) {
        _ = recordChromeReach(.ok, account: account, now: t0.addingTimeInterval(-86_400), file: ledger)
    }
    func logText() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
}

func context(_ out: [String]) -> String? {
    guard let text = out.first, let data = text.data(using: .utf8),
          let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    return (document["hookSpecificOutput"] as? [String: Any])?["additionalContext"] as? String
}

// MARK: - T1 / T2: a cold ledger, one generation

do {
    let w = World("t1")
    let out = w.run()
    let text = context(out) ?? ""
    check("T1 a not-connected result emits one hook document", out.count == 1)
    check("T1 the sentence names the account by its label", text.contains("\"Claude 4\""))
    check("T1 a cold ledger says none recorded yet", text.contains("none recorded yet"))
    check("T1 the cold wording does not claim a previous connection",
          !text.contains("has connected to Chrome on this machine before"))
    check("T1 this generation's claim file exists", FileManager.default.fileExists(
        atPath: w.state.appendingPathComponent("\(supervisorPID).chromegap.101").path))
    check("T1 one event file is filed for the app", w.eventCount() == 1)
    check("T1 the input log records the delivery",
          w.logText().contains("pid=\(supervisorPID) input=chrome-gap-delivered "))
    let again = w.run()
    check("T2 the same generation is told only once", again.isEmpty)
    check("T2 no second event file", w.eventCount() == 1)

    // T4: the same session moved again, a new child, still an account that never reached Chrome.
    let moved = w.run(child: 102)
    check("T4 a new child generation is told again", context(moved)?.contains("\"Claude 4\"") == true)
    check("T4 and files its own event", w.eventCount() == 2)
}

// MARK: - T3 / T4b: an account that reached Chrome before still gets told, in the other wording

do {
    let w = World("t3")
    w.seedOk("c2")
    let text = context(w.run(account: "c2", child: 201)) ?? ""
    check("T3 a gap on an account with a recorded connection is still told once",
          text.contains("\"Claude 2\""))
    check("T3 the wording says it has connected before",
          text.contains("has connected to Chrome on this machine before"))
    check("T3 and lists it among the accounts observed", text.hasSuffix("previously: Claude 2."))
    check("T3 the ledger records the gap beside the ok",
          w.readLedger().accounts["c2"]?.lastGap == t0 && w.readLedger().accounts["c2"]?.lastOk != nil)

    // T4b: moved twice in one session, the second move onto the account that reached Chrome.
    _ = w.run(account: "c4", child: 202)
    let back = context(w.run(account: "c2", child: 203)) ?? ""
    check("T4b the second move onto a known account is told in the before wording",
          back.contains("has connected to Chrome on this machine before"))
}

// MARK: - T5: a session that never touches Chrome

do {
    let w = World("t5")
    let out = w.run(tool: "Bash", response: "ok")
    check("T5 a non-Chrome tool says nothing", out.isEmpty)
    check("T5 and writes no ledger", !w.ledgerExists())
}

// MARK: - T6 / T7: success and the empty browser list

do {
    let w = World("t6")
    let listed: [[String: Any]] = [["type": "text", "text": "[{\"id\":\"x\"}]"]]
    let out = w.run(tool: "mcp__claude-in-chrome__list_connected_browsers", response: listed)
    check("T6 a successful Chrome result says nothing", out.isEmpty)
    check("T6 and records ok for the account", w.readLedger().accounts["c4"]?.lastOk == t0)
    let later = context(w.run(child: 301)) ?? ""
    check("T6 a later gap on that account is told in the before wording",
          later.contains("has connected to Chrome on this machine before"))

    let w7 = World("t7")
    let empty = context(w7.run(tool: "mcp__claude-in-chrome__list_connected_browsers",
                               response: [["type": "text", "text": "[]"]])) ?? ""
    check("T7 an empty browser list is a gap and is told", empty.contains("none recorded yet"))
}

// MARK: - T8 / T11 / T12 / T14 / T15: the paths that record nothing and say nothing

do {
    let w = World("t8")
    check("T8 a timeout says nothing",
          w.run(tool: "mcp__claude-in-chrome__navigate", response: timeoutString).isEmpty)
    check("T8 and records nothing", !w.ledgerExists())

    let w11 = World("t11")
    check("T11 a numeric response says nothing", w11.run(response: 42).isEmpty)
    check("T11 a null response says nothing", w11.run(response: NSNull()).isEmpty)
    check("T11 a missing response says nothing", w11.run(omitResponse: true).isEmpty)
    check("T11 and none of them record", !w11.ledgerExists())

    let w12 = World("t12")
    check("T12 an unreadable account says nothing", w12.run(account: nil).isEmpty)
    check("T12 and records nothing", !w12.ledgerExists())

    let w14 = World("t14")
    check("T14 UserPromptSubmit never takes the Chrome branch",
          w14.run(event: "UserPromptSubmit").isEmpty && !w14.ledgerExists())

    let w15 = World("t15")
    check("T15 a nested session's event says nothing",
          w15.run(session: "11111111-2222-4333-8444-555555555555").isEmpty)
}

// MARK: - T9 / T10: a missing or damaged ledger fails toward telling

do {
    let w = World("t9")
    check("T9 a missing ledger reads as empty and is told",
          context(w.run())?.contains("none recorded yet") == true)

    let w10 = World("t10")
    try? FileManager.default.createDirectory(at: w10.ledger.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? "not json".write(to: w10.ledger, atomically: true, encoding: .utf8)
    check("T10 a damaged ledger reads as empty and is told",
          context(w10.run())?.contains("none recorded yet") == true)
    let rewritten = (try? Data(contentsOf: w10.ledger)).flatMap {
        try? JSONSerialization.jsonObject(with: $0)
    }
    check("T10 and is rewritten as valid JSON", rewritten != nil)
}

// MARK: - T13: a filed quota knock and a gap in one run

do {
    let w = World("t13")
    let knock = "[tally] account Claude 4 is running low: session 9% resets 2h."
    _ = writeQuotaKnockNotice(QuotaKnockNotice(message: knock, at: t0), pid: supervisorPID,
                              dir: w.state)
    let out = w.run()
    let text = context(out) ?? ""
    check("T13 exactly one line on stdout", out.count == 1)
    check("T13 which parses as the hook document", context(out) != nil)
    check("T13 carrying both sentences joined by a blank line",
          text.contains("Claude in Chrome reported not connected") && text.contains("\n\n" + knock))
    check("T13 the knock is consumed", readQuotaKnockNotice(pid: supervisorPID, dir: w.state) == nil)
}

// MARK: - T16: the claim is exclusive

do {
    let w = World("t16")
    let first = claimChromeGapNotice(supervisorPid: supervisorPID, childPid: 9, dir: w.state)
    let second = claimChromeGapNotice(supervisorPid: supervisorPID, childPid: 9, dir: w.state)
    check("T16 the first claim wins and the second loses", first && !second)
}

// MARK: - T17: what the sentences may not say

do {
    let variants = [chromeGapMessage(accountLabel: "Claude 4", reachedBefore: false, reachableLabels: []),
                    chromeGapMessage(accountLabel: "Claude 4", reachedBefore: false,
                                     reachableLabels: ["Claude", "Claude 2"]),
                    chromeGapMessage(accountLabel: "Claude 2", reachedBefore: true,
                                     reachableLabels: ["Claude 2"])]
    let banned = ["\u{2014}", "manifest", "reinstall", "restart", "mismatch"]
    for (index, text) in variants.enumerated() {
        let lowered = text.lowercased()
        check("T17 variant \(index) avoids the banned words",
              !banned.contains(where: lowered.contains))
        check("T17 variant \(index) never says signed in to some accounts only",
              lowered.range(of: "signed in to [^.]* only", options: .regularExpression) == nil)
    }
    let notifier = (try? String(contentsOfFile: "Tally/Core/ChromeGapNotifier.swift",
                                encoding: .utf8)) ?? ""
    // The wording is every L("...") literal in the notifier; comments are not shown to anybody.
    let pushWords = (try? NSRegularExpression(pattern: "L\\(\"([^\"]*)\"\\)"))
        .map { regex in
            regex.matches(in: notifier, range: NSRange(notifier.startIndex..., in: notifier))
                .compactMap { Range($0.range(at: 1), in: notifier).map { String(notifier[$0]) } }
        } ?? []
    check("T17 the push wording is found", pushWords.count >= 3)
    check("T17 the push wording has no em dash, no only-claim and no mismatch",
          !pushWords.contains { word in
              word.contains("\u{2014}") || word.lowercased().contains(" only")
                  || word.lowercased().contains("mismatch")
          })
}

// MARK: - T18: the classifier

do {
    let tabs = "mcp__claude-in-chrome__tabs_context_mcp"
    let rows: [(String, String, Any?, ChromeReachOutcome)] = [
        ("not connected, list shape", tabs, notConnectedList, .gap),
        ("did not respond, string shape", "mcp__claude-in-chrome__navigate", timeoutString, .timeout),
        ("empty browser list", "mcp__claude-in-chrome__list_connected_browsers", "[]", .gap),
        ("authentication variant", tabs, authError, .gap),
        ("not connected, content-object shape", tabs, ["content": notConnectedList], .gap),
        ("a Failed-to result", "mcp__claude-in-chrome__navigate",
         "Failed to navigate to https://example.com/: net::ERR_NAME_NOT_RESOLVED", .unknown),
        ("a normal tab list", tabs, [["type": "text", "text": tabsOk]], .ok),
        ("an empty text", tabs, "   ", .unknown),
        ("a non-Chrome tool", "Bash", notConnectedList, .unknown),
    ]
    for (name, tool, response, expected) in rows {
        check("T18 \(name) is \(expected)", chromeReachOutcome(tool: tool, response: response) == expected)
    }
    check("T18 the three response shapes read the same text",
          chromeResponseText(notConnectedList) == chromeResponseText(["content": notConnectedList])
              && chromeResponseText(notConnectedList) == (notConnectedList[0]["text"] as? String))
}

// MARK: - T19: the Chrome branch types nothing into the terminal

do {
    let source = (try? String(contentsOfFile: "TallyCLI/ChromeReach.swift", encoding: .utf8)) ?? ""
    check("T19 the source is readable", !source.isEmpty)
    for word in ["SessionInput", "writeClaudeNativeFrame", "TIOCSTI", "paste"] {
        check("T19 ChromeReach.swift does not use \(word)", !source.contains(word))
    }
}

// MARK: - T20: the app's drain

do {
    let dir = root.appendingPathComponent("t20")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fresh = ChromeGapEvent(account: "c4", label: "Claude 4", cwd: "/w/finance",
                               reachable: ["Claude"], at: t0.addingTimeInterval(-60))
    let stale = ChromeGapEvent(account: "c5", label: "Claude 5", cwd: nil, reachable: [],
                               at: t0.addingTimeInterval(-31 * 60))
    writeChromeGapEvent(fresh, supervisorPid: "1", childPid: 2, dir: dir)
    writeChromeGapEvent(stale, supervisorPid: "1", childPid: 3, dir: dir)
    try? "garbage".write(to: dir.appendingPathComponent("1.4.json"), atomically: true, encoding: .utf8)
    let drained = drainChromeGapEvents(dir: dir, now: t0)
    check("T20 only the fresh, readable event is returned", drained == [fresh])
    check("T20 the fresh, the stale and the damaged file are all deleted",
          ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty)
}

// MARK: - T21: an account that reached Chrome, then was signed out of the extension

do {
    let w = World("t21")
    w.seedOk("c4")
    let first = context(w.run(child: 401))
    let repeatRun = w.run(child: 401)
    let second = context(w.run(child: 402))
    check("T21 each generation is still told once after a recorded connection",
          first != nil && repeatRun.isEmpty && second != nil)
    check("T21 in the before wording",
          second?.contains("browser may be closed, asleep, or signed out") == true)
}

// MARK: - R1: a page that quotes the diagnostic is not a gap

do {
    let w = World("r1")
    let page: [[String: Any]] = [["type": "text", "text":
        "Troubleshooting Claude in Chrome\nIf the tool answers \"Browser extension is not connected. Please ensure the Claude browser extension is installed and running (https://claude.ai/chrome), and that you are logged into claude.ai with the same account as Claude Code.\" open the extension and sign in again.\nLast updated 2026-09-01."]]
    check("R1 a page quoting the sentence is not classified as a gap",
          chromeReachOutcome(tool: "mcp__claude-in-chrome__get_page_text", response: page) != .gap)
    let out = w.run(tool: "mcp__claude-in-chrome__get_page_text", response: page)
    check("R1 and says nothing", out.isEmpty)
    check("R1 and writes no lastGap", w.readLedger().accounts["c4"]?.lastGap == nil)
    check("R1 and files no event", w.eventCount() == 0)
    check("R1 the same sentence behind an Error: prefix is still a gap",
          chromeReachOutcome(tool: "mcp__claude-in-chrome__tabs_context_mcp",
                             response: "Error: Browser extension is not connected. Please ensure it is running.") == .gap)
}

// MARK: - R2: an error object is not a success

do {
    let w = World("r2")
    let crashed: [String: Any] = ["isError": true, "content": [["type": "text", "text": "Page crashed"]]]
    check("R2 an isError object is unknown",
          chromeReachOutcome(tool: "mcp__claude-in-chrome__navigate", response: crashed) == .unknown)
    check("R2 an is_error object is unknown",
          chromeReachOutcome(tool: "mcp__claude-in-chrome__navigate",
                             response: ["is_error": true, "content": [["type": "text", "text": "Page crashed"]]]) == .unknown)
    check("R2 the same text without the flag would have been ok (the flag is what decides)",
          chromeReachOutcome(tool: "mcp__claude-in-chrome__navigate",
                             response: ["content": [["type": "text", "text": "Page crashed"]]]) == .ok)
    check("R2 an error object that opens like a gap is still a gap",
          chromeReachOutcome(tool: "mcp__claude-in-chrome__tabs_context_mcp",
                             response: ["isError": true, "content": notConnectedList]) == .gap)
    let out = w.run(tool: "mcp__claude-in-chrome__navigate", response: crashed)
    check("R2 and the hook says nothing and writes no lastOk",
          out.isEmpty && w.readLedger().accounts["c4"]?.lastOk == nil)
}

// MARK: - B6: the dead-pid sweep can read the supervisor out of a claim file

check("B6 a claim file maps back to its supervisor", supervisorStatePid(ofFile: "77123.chromegap.101") == 77123)
check("B6 a foreign file with the infix maps to nothing", supervisorStatePid(ofFile: "x.chromegap.1") == nil)

try? FileManager.default.removeItem(at: root)
if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("all chromegap checks passed")
