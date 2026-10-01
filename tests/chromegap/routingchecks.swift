import Foundation

// MARK: - B-558: routing by the "Claude in Chrome account" setting. Real account id shapes, so the
// runner sentence asserted names the task file this supervisor writes.
//
// Split out of main.swift when it reached its 500-line cap. Runs as a function main.swift calls,
// which owns the shared harness (`check`, `World`, `t0`, `supervisorPID`).

let realLabels = ["claude:.claude2": "Claude 2", "claude:.claude5": "Claude 5"]

final class SignalBox { var calls: [(String, Date)] = [] }

extension World {
    /// One gap on Claude 5 (the 2026-10-01 07:45 sample), routed by `setting`.
    func runRouted(setting: String?, signals: SignalBox, account: String = "claude:.claude5",
                   child: Int = 101) -> String? {
        let deps = ChromeGapDeps(account: { _ in account }, child: { _ in child },
                                 labels: { realLabels }, ledgerFile: ledger,
                                 chromeAccount: { setting },
                                 signalSettingGap: { signals.calls.append(($0, $1)) })
        return chromeGapNotice(tool: "mcp__claude-in-chrome__list_connected_browsers", outcome: .gap,
                               supervisor: supervisorPID, stateDir: state, now: t0, deps: deps)
    }
}

func runRoutingChecks() {
    let today = chromeGapMessage(accountLabel: "Claude 5", reachedBefore: false, reachableLabels: [])
    let runLine = "tally chrome run --file /tmp/tally-chrome-task-77123.md"

    do {
        // sample-a/b: set to Claude 2, the session runs on Claude 5.
        let w = World("sample-runner")
        let signals = SignalBox()
        let text = w.runRouted(setting: "claude:.claude2", signals: signals) ?? ""
        check("sample-runner the sentence opens with the not-connected line and gives the runner command",
              text == chromeRunnerSentence(settingLabel: "Claude 2", supervisor: supervisorPID,
                                           opening: chromeGapOpening(accountLabel: "Claude 5")))
        check("sample-runner it names both accounts and no move or relay",
              text.contains(runLine) && text.contains("\"Claude 2\"") && text.contains("\"Claude 5\"")
                  && !text.contains("tally account") && !text.contains("tally message"))
        check("sample-runner it is not the explain sentence", !text.contains("Accounts observed connecting previously"))
        check("sample-runner writes no settings signal", signals.calls.isEmpty)
        check("R7 the runner route still tells one generation once",
              w.runRouted(setting: "claude:.claude2", signals: signals) == nil)
    }

    do {
        check("G1 no setting routes to explain",
              chromeGapRoute(account: "claude:.claude5", setting: nil, known: Set(realLabels.keys)) == .explain)
        check("G1 an unknown setting routes to explain",
              chromeGapRoute(account: "claude:.claude5", setting: "claude:.claude9", known: Set(realLabels.keys)) == .explain)
        check("G1 the same account routes to settingItself",
              chromeGapRoute(account: "claude:.claude5", setting: "claude:.claude5", known: Set(realLabels.keys))
                  == .settingItself("claude:.claude5"))
        check("G1 another account routes to the runner",
              chromeGapRoute(account: "claude:.claude5", setting: "claude:.claude2", known: Set(realLabels.keys))
                  == .runner("claude:.claude2"))
    }

    do {
        // sample-c: set to Claude 5, the account that just reported not connected.
        let w = World("sample-c")
        let signals = SignalBox()
        let text = w.runRouted(setting: "claude:.claude5", signals: signals) ?? ""
        check("sample-c the sentence is today's sentence plus the settings suffix",
              text == today + chromeSettingItselfSuffix)
        check("sample-c the settings signal is written once for Claude 5 at the event time",
              signals.calls.count == 1 && signals.calls[0].0 == "claude:.claude5" && signals.calls[0].1 == t0)
        check("sample-c the same generation writes the signal only once",
              w.runRouted(setting: "claude:.claude5", signals: signals) == nil && signals.calls.count == 1)
    }

    do {
        let signals = SignalBox()
        let unset = World("r-unset").runRouted(setting: nil, signals: signals)
        check("R1 no setting is today's sentence word for word", unset == today)
        check("R1 and names no command", unset?.contains("tally chrome run") == false
                  && unset?.contains("tally account") == false)
        let stale = World("r-stale").runRouted(setting: "claude:.claude9", signals: signals)
        check("R5 a setting the snapshot does not know reads as no setting", stale == today)
        check("R1 R5 write no settings signal", signals.calls.isEmpty)

        let wOk = World("r6-ledger")
        _ = recordChromeReach(.ok, account: "claude:.claude2", now: t0.addingTimeInterval(-86_400),
                              file: wOk.ledger)
        let byLedger = wOk.runRouted(setting: nil, signals: signals) ?? ""
        check("R6 a ledger that saw Claude 2 connect does not route without a setting",
              byLedger.hasSuffix("previously: Claude 2.") && !byLedger.contains("tally chrome run"))
        let bySetting = World("r6-setting").runRouted(setting: "claude:.claude2", signals: signals) ?? ""
        check("R6 a setting routes to the runner with an empty ledger", bySetting.contains(runLine))
    }

    do {
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
            chromeRunnerSentence(settingLabel: "Claude 2", supervisor: supervisorPID,
                                 opening: chromeGapOpening(accountLabel: "Claude 5")),
            chromeRunnerSentence(settingLabel: "Claude 2", supervisor: supervisorPID,
                                 opening: chromePreflightOpening(accountLabel: "Claude 5", settingLabel: "Claude 2")),
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
