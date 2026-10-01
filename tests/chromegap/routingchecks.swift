import Foundation

// MARK: - B-558: routing by the "Claude in Chrome account" setting. Real account id shapes, so the
// move sentence asserted is `tally account .claude2`, a command that actually runs.
//
// Split out of main.swift when it reached its 500-line cap. Runs as a function main.swift calls,
// which owns the shared harness (`check`, `World`, `t0`, `supervisorPID`).

let realLabels = ["claude:.claude2": "Claude 2", "claude:.claude5": "Claude 5"]

final class SignalBox { var calls: [(String, Date)] = [] }
final class RelayProbe { var calls: [(String, String)] = [] }

extension World {
    /// One gap on Claude 5 (the 2026-10-01 07:45 sample), routed by `setting`.
    func runRouted(setting: String?, relays: [ChromeRelaySession] = [], signals: SignalBox,
                   probe: RelayProbe = RelayProbe(), account: String = "claude:.claude5",
                   child: Int = 101) -> String? {
        let deps = ChromeGapDeps(account: { _ in account }, child: { _ in child },
                                 labels: { realLabels }, ledgerFile: ledger,
                                 chromeAccount: { setting },
                                 relays: { probe.calls.append(($0, $1)); return relays },
                                 signalSettingGap: { signals.calls.append(($0, $1)) })
        return chromeGapNotice(tool: "mcp__claude-in-chrome__list_connected_browsers", outcome: .gap,
                               supervisor: supervisorPID, stateDir: state, now: t0, deps: deps)
    }
}

func runRoutingChecks() {
    let today = chromeGapMessage(accountLabel: "Claude 5", reachedBefore: false, reachableLabels: [])
    let twoSessions = [ChromeRelaySession(supervisorPid: "4242", project: "finance"),
                       ChromeRelaySession(supervisorPid: "5151", project: "tally")]

    do {
        // sample-a: set to Claude 2, and Claude 2 has live sessions.
        let w = World("sample-a")
        let signals = SignalBox(), probe = RelayProbe()
        let text = w.runRouted(setting: "claude:.claude2", relays: twoSessions, signals: signals,
                               probe: probe) ?? ""
        check("sample-a the relay sentence names the command to hand the step over",
              text.contains("tally message claude --session 4242 --file /tmp/tally-chrome-task-77123.md"))
        check("sample-a it gives this session's address for the result",
              text.contains("tally message claude --session 77123 --file"))
        check("sample-a it lists the live sessions on Claude 2 with their projects",
              text.contains("4242 (finance), 5151 (tally)") && text.contains("\"Claude 2\"")
                  && text.contains("\"Claude 5\""))
        check("sample-a it is not the explain sentence",
              !text.contains("Accounts observed connecting previously") && !text.contains("tally account"))
        check("sample-a the sessions were read for the set account, excluding this supervisor",
              probe.calls.count == 1 && probe.calls[0].0 == "claude:.claude2" && probe.calls[0].1 == supervisorPID)
        check("sample-a writes no settings signal", signals.calls.isEmpty)
        check("R7 the relay route still tells one generation once",
              w.runRouted(setting: "claude:.claude2", relays: twoSessions, signals: signals) == nil)
    }

    do {
        // sample-b: set to Claude 2, and nothing runs on it.
        let w = World("sample-b")
        let signals = SignalBox()
        let text = w.runRouted(setting: "claude:.claude2", relays: [], signals: signals) ?? ""
        check("sample-b the move sentence gives tally account .claude2",
              text.contains("`tally account .claude2`") && text.contains("\"Claude 2\""))
        check("sample-b it names the way back", text.contains("`tally account --auto`"))
        check("sample-b it offers no hand-off", !text.contains("tally message"))
        check("sample-b writes no settings signal", signals.calls.isEmpty)
    }

    do {
        // sample-c: set to Claude 5, the account that just reported not connected.
        let w = World("sample-c")
        let signals = SignalBox(), probe = RelayProbe()
        let text = w.runRouted(setting: "claude:.claude5", signals: signals, probe: probe) ?? ""
        check("sample-c the sentence is today's sentence plus the settings suffix",
              text == today + chromeSettingItselfSuffix)
        check("sample-c the settings signal is written once for Claude 5 at the event time",
              signals.calls.count == 1 && signals.calls[0].0 == "claude:.claude5" && signals.calls[0].1 == t0)
        check("sample-c no sessions are read", probe.calls.isEmpty)
        check("sample-c the same generation writes the signal only once",
              w.runRouted(setting: "claude:.claude5", signals: signals) == nil && signals.calls.count == 1)
    }

    do {
        let signals = SignalBox()
        let unset = World("r-unset").runRouted(setting: nil, relays: twoSessions, signals: signals)
        check("R1 no setting is today's sentence word for word", unset == today)
        check("R1 and names no command", unset?.contains("tally message") == false
                  && unset?.contains("tally account") == false)
        let stale = World("r-stale").runRouted(setting: "claude:.claude9", signals: signals)
        check("R5 a setting the snapshot does not know reads as no setting", stale == today)
        check("R1 R5 write no settings signal", signals.calls.isEmpty)

        let wOk = World("r6-ledger")
        _ = recordChromeReach(.ok, account: "claude:.claude2", now: t0.addingTimeInterval(-86_400),
                              file: wOk.ledger)
        let byLedger = wOk.runRouted(setting: nil, relays: twoSessions, signals: signals) ?? ""
        check("R6 a ledger that saw Claude 2 connect does not route without a setting",
              byLedger.hasSuffix("previously: Claude 2.") && !byLedger.contains("tally message"))
        let bySetting = World("r6-setting").runRouted(setting: "claude:.claude2", relays: twoSessions,
                                                      signals: signals) ?? ""
        check("R6 a setting routes with an empty ledger", bySetting.contains("tally message claude --session 4242"))
    }

    do {
        let many = (1...7).map { ChromeRelaySession(supervisorPid: "\(900 + $0)", project: nil) }
        let text = chromeRelayMessage(accountLabel: "Claude 5", settingLabel: "Claude 2", sessions: many,
                                      selfSupervisor: supervisorPID)
        check("R9 at most five sessions are listed", text.contains("901, 902, 903, 904, 905.")
                  && !text.contains("906"))

        let owner = ["1": "claude:.claude2", "2": "claude:.claude2", "3": "claude:.claude4",
                     "4": "codex:.codex", "5": "claude:.claude2", supervisorPID: "claude:.claude2"]
        let found = chromeRelaySessions(account: "claude:.claude2", excluding: supervisorPID,
                                        pids: ["1", "2", "3", "4", "5", supervisorPID],
                                        isCodex: { owner[$0]?.hasPrefix("codex:") == true },
                                        accountOf: { owner[$0] }, hasChild: { $0 != "5" },
                                        cwd: { $0 == "1" ? "/Users/x/workspace/finance" : nil })
        check("R10 only live Claude sessions on the set account, never this one", found == [
            ChromeRelaySession(supervisorPid: "1", project: "finance"),
            ChromeRelaySession(supervisorPid: "2", project: nil)])

        let dir = root.appendingPathComponent("r11")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func setting(_ json: String) -> String? {
            let file = dir.appendingPathComponent("state-\(UUID().uuidString).json")
            try? json.write(to: file, atomically: true, encoding: .utf8)
            return chromeAccountSetting(file)
        }
        check("R11 no key, empty, a Codex id and a missing file read as no setting",
              setting("{\"version\":1}") == nil && setting("{\"chromeAccount\":\"\"}") == nil
                  && setting("{\"chromeAccount\":\"codex:.codex\"}") == nil
                  && chromeAccountSetting(dir.appendingPathComponent("absent.json")) == nil)
        check("R11 a Claude id is read back", setting("{\"chromeAccount\":\"claude:.claude2\"}") == "claude:.claude2")
    }

    do {
        let variants = [
            chromeRelayMessage(accountLabel: "Claude 5", settingLabel: "Claude 2", sessions: twoSessions,
                               selfSupervisor: supervisorPID),
            chromeMoveMessage(accountLabel: "Claude 5", settingLabel: "Claude 2", settingID: "claude:.claude2"),
            today + chromeSettingItselfSuffix]
        let banned = ["\u{2014}", "manifest", "reinstall", "restart", "mismatch"]
        for (index, text) in variants.enumerated() {
            check("R8 routed variant \(index) avoids the banned words",
                  !banned.contains(where: text.lowercased().contains))
        }
    }

    do {
        let signal = ChromeSettingGapSignal(account: "claude:.claude2", at: t0.addingTimeInterval(10))
        check("N1 a signal for the setting after it was chosen notifies",
              chromeSettingGapShouldNotify(setting: "claude:.claude2", setAt: t0, signal: signal, notified: false))
        check("N1 not twice", !chromeSettingGapShouldNotify(setting: "claude:.claude2", setAt: t0,
                                                            signal: signal, notified: true))
        check("N1 not for another account", !chromeSettingGapShouldNotify(
            setting: "claude:.claude4", setAt: t0, signal: signal, notified: false))
        check("N1 not for a signal older than the choice", !chromeSettingGapShouldNotify(
            setting: "claude:.claude2", setAt: t0.addingTimeInterval(20), signal: signal, notified: false))
        check("N1 not without a setting", !chromeSettingGapShouldNotify(
            setting: nil, setAt: t0, signal: signal, notified: false))

        let file = root.appendingPathComponent("n2/chrome-setting-gap.json")
        writeChromeSettingGapSignal(signal, file: file)
        check("N2 the signal round-trips", readChromeSettingGapSignal(file: file) == signal)
    }
}
