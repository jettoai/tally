import Foundation

// B-1736 round 3: codex's first-run folder trust screen and its startup hooks review, recognised and
// published like the update menu; the trust screen answered with "Trust and continue" (never Esc,
// which is Quit there), the hooks review never answered. `check` and `start` come from main.swift.
// The trust bytes are what codex-cli 0.162.1 wrote on a first launch in a new folder (tmux pipe-pane,
// 120 columns), the folder path replaced with one of the same length.
func runCodexTrustFolderChecks(fixtures: URL) throws {
    let down: [UInt8] = [0x1B, 0x5B, 0x42], up: [UInt8] = [0x1B, 0x5B, 0x41], enter: [UInt8] = [0x0D]
    let launched = start.addingTimeInterval(-30)
    var trust = CodexStartupScreen(rows: 36, cols: 120)
    trust.observe(Array(try Data(contentsOf: fixtures.appendingPathComponent("trust-folder-0.162.1-120x36.bin"))))
    let lines = trust.menuLines ?? []
    check("T1 the trust screen reads as itself, not as its selected row, and not as the prompt",
          trust.title == CodexStartupScreen.trustFolderMarker && !trust.reachedPrompt && !trust.unreliable)
    check("T2 its rows are published from the Folder access heading, folder and choices included",
          lines.first == "Folder access" && lines.contains { $0.hasPrefix("/private/tmp/") }
              && lines.contains { $0.hasPrefix("Trust this folder?") }
              && lines.contains("› 1. Trust and continue") && lines.contains("2. Quit")
              && lines.last == "enter continue · esc quit")
    let record = codexStartupScreenRecord(trust, stall: codexStartupStall(screen: trust, launchedAt: launched,
                                                                          bindingLanded: false, now: start))
    check("T3 status carries title, rows, id and the answer, like the update menu",
          record?.title == CodexStartupScreen.trustFolderMarker && record?.lines == lines
              && record?.screenID == CodexStartupScreen.screenID(lines) && record?.answer == "Trust and continue")
    let id = record?.screenID ?? ""
    let sent = decideStartupChoice(StartupChoiceRequest(screenID: id, nonce: "t", at: start), record: record,
                                   humanInputAt: nil, now: start.addingTimeInterval(1))
    check("T4 the request on the shown drawing types Enter alone (Trust and continue is selected)",
          sent.result == "sent" && sent.keys == enter)
    let stale = decideStartupChoice(StartupChoiceRequest(screenID: "scr_0000000000000000", nonce: "t", at: start),
                                    record: record, humanInputAt: nil, now: start.addingTimeInterval(1))
    check("T4 another drawing's id types nothing", stale.result == "stale-screen" && stale.keys == nil)
    check("T5 Quit selected: Up, then Enter, never Esc",
          CodexStartupScreen.answerKeys(title: CodexStartupScreen.trustFolderMarker,
                                        lines: ["1. Trust and continue", "› 2. Quit"]) == up + enter)
    check("T5 a restricted row between them: the arrows count rows",
          CodexStartupScreen.answerKeys(title: CodexStartupScreen.trustFolderMarker,
                                        lines: ["1. Trust and continue", "2. Open restricted", "› 3. Quit"]) == up + up + enter)
    let noTrustRow = ["› 1. Open existing task", "2. Back to Agent Command Center"]
    check("T6 a trust screen with no Trust and continue row has no answer and types nothing",
          CodexStartupScreen.answerKeys(title: CodexStartupScreen.trustFolderMarker, lines: noTrustRow) == nil
              && CodexStartupScreen.answerLabel(title: CodexStartupScreen.trustFolderMarker, lines: noTrustRow) == nil)
    var moved = trust
    moved.observe(Array("\u{1B}[10;1H  1. Trust and continue\u{1B}[K\u{1B}[11;1H› 2. Quit\u{1B}[K".utf8))
    check("T5 the drawn Quit selection is a new id and Up Enter",
          moved.menuLines.map(CodexStartupScreen.screenID) != id
              && CodexStartupScreen.answerKeys(title: CodexStartupScreen.trustFolderMarker, lines: moved.menuLines ?? []) == up + enter)
    var unreliable = trust
    unreliable.observe(Array("\u{1B}[5Z".utf8))
    check("T8 an unreliable grid publishes no trust rows", unreliable.menuLines == nil)

    // The hooks review: published, never answered (no-menu), no answer for a button.
    var hooks = CodexStartupScreen(rows: 24, cols: 80)
    hooks.observe(Array(("\u{1B}[2;3HHooks need review\u{1B}[3;3H1 hook is new or changed.\u{1B}[5;1H› 1. Trust all and continue"
        + "\u{1B}[6;3H2. Continue without trusting (hooks won't run)\u{1B}[7;3H3. Review hooks").utf8))
    let hooksRecord = codexStartupScreenRecord(hooks, stall: (launched, hooks.title))
    check("T7 the hooks review is named and its rows published with an id",
          hooks.title == CodexStartupScreen.hooksReviewMarker && hooksRecord?.lines?.first == "Hooks need review"
              && hooksRecord?.screenID?.hasPrefix("scr_") == true)
    let hooksDecision = decideStartupChoice(StartupChoiceRequest(screenID: hooksRecord?.screenID ?? "", nonce: "h", at: start),
                                            record: hooksRecord, humanInputAt: nil, now: start.addingTimeInterval(1))
    check("T7 but never answered: no answer, no-menu, nothing typed",
          hooksRecord?.answer == nil && hooksDecision.result == "no-menu" && hooksDecision.keys == nil)

    // The answers the two older screens already had, now also named in status.
    var menu = CodexStartupScreen(rows: 40, cols: 120)
    menu.observe(Array(try Data(contentsOf: fixtures.appendingPathComponent("update-menu-0.162.1.bin"))))
    var notice = CodexStartupScreen(rows: 24, cols: 80)
    notice.observe(Array(try Data(contentsOf: fixtures.appendingPathComponent("model-notice-0.162.1-80x24.bin"))))
    check("T9 the update menu's answer is Skip and the announcement's is Use existing model",
          codexStartupScreenRecord(menu, stall: (launched, menu.title))?.answer == "Skip"
              && codexStartupScreenRecord(notice, stall: (launched, notice.title))?.answer == "Use existing model"
              && CodexStartupScreen.answerKeys(title: CodexStartupScreen.modelNoticeMarker, lines: notice.menuLines ?? []) == down + enter)
    var signIn = CodexStartupScreen(rows: 24, cols: 80)
    signIn.observe(Array("\u{1B}[2;3HSign in with ChatGPT\u{1B}[4;3Hhttps://auth.example/device?code=ABCD-1234\u{1B}[6;1H› 1. Sign in".utf8))
    check("T9 sign-in still publishes nothing and has no answer",
          codexStartupScreenRecord(signIn, stall: (launched, signIn.title)).map { $0.lines == nil && $0.answer == nil } == true)

    // The wait the tracker opens for it names the screen.
    let identity = SessionWaitIdentity(key: "codex:4343:1758575401000000", supervisorPid: 4343,
        supervisorStartedAt: 1758575401000000, childPid: 4344, transcriptSessionId: nil,
        launchNonce: "trust", account: "codex:.codex", directory: nil, project: nil, worktree: nil)
    var tracker = CodexWaitTracker(identity: identity)
    let opened = tracker.reconcile(observer: nil, directory: nil, project: nil, worktree: nil,
                                   startupScreen: codexStartupStall(screen: trust, launchedAt: launched, bindingLanded: false, now: start),
                                   now: start).filter { $0.kind == "wait.opened" }
    check("T10 a launch stuck on the trust screen opens one wait naming it",
          opened.count == 1 && opened[0].request?.summary?.hasSuffix(CodexStartupScreen.trustFolderMarker) == true)
}
