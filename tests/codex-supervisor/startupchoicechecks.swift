import Foundation

// B-1736 round 2: the update menu as published for a person elsewhere (CodexStartupScreen.swift) and
// the supervisor's decision on one `tally session skip-update` request (CodexStartupChoice.swift).
// `check` and `start` come from main.swift.
func runCodexStartupChoiceChecks() throws {
    let fixtures = URL(fileURLWithPath: "tests/codex-supervisor/fixtures")
    var menu = CodexStartupScreen(rows: 40, cols: 120)
    menu.observe(Array(try Data(contentsOf: fixtures.appendingPathComponent("update-menu-0.162.1.bin"))))
    let lines = menu.menuLines ?? []
    check("C1 the 0.162.1 menu publishes its rows from the title down",
          lines.first?.hasPrefix("Update available") == true && lines.count <= 12
              && lines.contains("2. Skip") && lines.contains("3. Skip until next version")
              && lines.contains { $0.hasPrefix("› 1. Update now") })
    check("C2 Skip on the 0.162.1 menu is Esc alone", CodexStartupScreen.skipKeys(lines) == [0x1B])
    check("C3 Skip already selected is still Esc", CodexStartupScreen.skipKeys(["1. Update now", "› 2. Skip"]) == [0x1B])
    check("C3 Skip above the selection is still Esc",
          CodexStartupScreen.skipKeys(["1. Update now", "2. Skip", "› 3. Skip until next version"]) == [0x1B])
    check("C4 no row labelled exactly Skip types nothing",
          CodexStartupScreen.skipKeys(["› 1. Update now", "2. Skip until next version"]) == nil)
    check("C4 no selected row is still Esc (the selection is not read)",
          CodexStartupScreen.skipKeys(["1. Update now", "2. Skip"]) == [0x1B])

    // codex redraws only the two rows a move touches; the grid keeps the rest, so the rows follow
    // the selection (bytes recorded from codex-cli 0.162.1). Esc is Skip whichever row is selected.
    for (path, selected) in [("1-2-3-2-1", "1. Update now (runs `brew upgrade --cask codex`)"),
                             ("1-2-3-2-1-2-3", "3. Skip until next version"), ("1-2-3-2-1-3", "3. Skip until next version")] {
        var moved = menu
        moved.observe(Array(try Data(contentsOf: fixtures.appendingPathComponent("update-menu-moves-\(path)-0.162.1.bin"))))
        check("C8 after moves \(path) Skip is Esc alone", CodexStartupScreen.skipKeys(moved.menuLines ?? []) == [0x1B])
        check("C8 after moves \(path) the selected row is where the moves ended", (moved.menuLines ?? []).contains("› " + selected))
    }

    var signIn = CodexStartupScreen(rows: 24, cols: 80)
    signIn.observe(Array("\u{1B}[2;3HSign in with ChatGPT\u{1B}[4;3Hhttps://auth.example/device?code=ABCD-1234\u{1B}[6;1H› 1. Sign in".utf8))
    check("C5 a sign-in screen publishes no rows (it can carry a login link and code)", signIn.menuLines == nil)
    var menuThenSignIn = menu
    menuThenSignIn.observe(Array("\u{1B}[2;3HSign in with ChatGPT\u{1B}[4;3Hhttps://auth.example/device?code=ABCD-1234".utf8))
    check("C5 a sign-in screen drawn after the update menu publishes no rows either",
          menuThenSignIn.menuLines == nil)
    var menuThenPicker = menu
    menuThenPicker.observe(Array("\u{1B}[7;1H› Ask Codex to do anything\u{1B}[9;1H› 1. Allow this command".utf8))
    check("C5 the old menu's rows are not published under a later picker", menuThenPicker.menuLines == nil)

    var after = menu
    after.observe(Array(try Data(contentsOf: fixtures.appendingPathComponent("composer-after-menu-0.162.1.bin"))))
    let launched = start.addingTimeInterval(-30)
    let stuck = codexStartupStall(screen: menu, launchedAt: launched, bindingLanded: false, now: start)
    let record = codexStartupScreenRecord(menu, stall: stuck)
    check("C6 a stuck menu publishes its title, rows, id and since",
          record?.title == "Update available" && record?.lines == lines
              && record?.screenID == CodexStartupScreen.screenID(lines) && record?.since == launched)
    check("C6 the composer after the menu clears the published screen",
          codexStartupScreenRecord(after, stall: codexStartupStall(screen: after, launchedAt: launched,
                                                                   bindingLanded: false, now: start)) == nil)

    let id = CodexStartupScreen.screenID(lines)
    var edited = lines
    edited[0] += "x"
    check("C7 the id is stable for the same rows, scr_ plus 16 hex digits",
          id == CodexStartupScreen.screenID(lines) && id.hasPrefix("scr_") && id.count == 20
              && id.dropFirst(4).allSatisfy(\.isHexDigit))
    check("C7 one character more is another id", CodexStartupScreen.screenID(edited) != id)

    let request = StartupChoiceRequest(screenID: id, nonce: "n1", at: start)
    func decide(_ request: StartupChoiceRequest = request, record: CodexStartupScreenRecord? = record,
                typed: Date? = nil, now: Date = start.addingTimeInterval(1)) -> String {
        decideStartupChoice(request, record: record, humanInputAt: typed, now: now).result
    }
    var signInRecord = record
    signInRecord?.title = "Sign in with ChatGPT"
    var other = request
    other.screenID = "scr_0000000000000000"
    check("D1 a request older than 15s is expired", decide(now: start.addingTimeInterval(16)) == "expired")
    check("D1 no published screen is no-menu", decide(record: nil) == "no-menu")
    check("D1 another screen is no-menu", decide(record: signInRecord) == "no-menu")
    check("D1 another drawing of the menu is stale-screen", decide(other) == "stale-screen")
    check("D1 a person typing a second ago holds it", decide(typed: start) == "typing")
    let sent = decideStartupChoice(request, record: record, humanInputAt: start.addingTimeInterval(-10),
                                   now: start.addingTimeInterval(1))
    check("D1 the shown menu, nobody typing: sent with the C2 keys", sent.result == "sent" && sent.keys == [0x1B])

    let encoded = try startupChoiceEncoder().encode(request)
    check("D2 a request reads back equal through the shared coder pair",
          (try? startupChoiceDecoder().decode(StartupChoiceRequest.self, from: encoded)) == request)

    try runCodexModelNoticeChecks(fixtures: fixtures)
}

/// B-1736 package 4: the new-model announcement ("Meet GPT-6 Sol") gets a one-step answer that keeps
/// the launched model, and the update banner codex draws above its composer after Skip is not the menu.
/// Bytes recorded from real codex-cli 0.162.1 windows (tmux, `-m gpt-5.6-sol`, a fresh home).
func runCodexModelNoticeChecks(fixtures: URL) throws {
    func replay(_ name: String, rows: Int, cols: Int) throws -> CodexStartupScreen {
        var screen = CodexStartupScreen(rows: rows, cols: cols)
        screen.observe(Array(try Data(contentsOf: fixtures.appendingPathComponent(name))))
        return screen
    }
    let down: [UInt8] = [0x1B, 0x5B, 0x42], up: [UInt8] = [0x1B, 0x5B, 0x41], enter: [UInt8] = [0x0D]
    let launched = start.addingTimeInterval(-30)
    for (name, rows, cols) in [("model-notice-0.162.1-120x40.bin", 40, 120), ("model-notice-0.162.1-80x24.bin", 24, 80),
                               ("update-then-model-notice-0.162.1-120x40.bin", 40, 120)] {
        let screen = try replay(name, rows: rows, cols: cols)
        let lines = screen.menuLines ?? []
        check("M1 \(name) reads as the announcement, not the prompt",
              screen.title == CodexStartupScreen.modelNoticeMarker && !screen.reachedPrompt)
        check("M1 \(name) publishes its rows from the heading, the first row selected",
              lines.first == "Meet GPT-6 Sol" && lines.contains("› 1. Try new model") && lines.contains("2. Use existing model"))
        check("M2 \(name): one Down from the selected first row, then Enter",
              CodexStartupScreen.existingModelKeys(lines) == down + enter)
        let record = codexStartupScreenRecord(screen, stall: codexStartupStall(screen: screen, launchedAt: launched,
                                                                               bindingLanded: false, now: start))
        let id = record?.screenID ?? ""
        let sent = decideStartupChoice(StartupChoiceRequest(screenID: id, nonce: "m", at: start), record: record,
                                       humanInputAt: nil, now: start.addingTimeInterval(1))
        check("M3 \(name): status carries the title and an id, and the request types Down Enter",
              record?.title == CodexStartupScreen.modelNoticeMarker && id.hasPrefix("scr_")
                  && sent.result == "sent" && sent.keys == down + enter)
        let stale = decideStartupChoice(StartupChoiceRequest(screenID: "scr_0000000000000000", nonce: "m", at: start),
                                        record: record, humanInputAt: nil, now: start.addingTimeInterval(1))
        check("M3 \(name): another drawing's id is refused and types nothing", stale.result == "stale-screen" && stale.keys == nil)
    }
    check("M4 already on Use existing model: Enter alone",
          CodexStartupScreen.existingModelKeys(["1. Try new model", "› 2. Use existing model"]) == enter)
    check("M4 the selection below it: Up, then Enter",
          CodexStartupScreen.existingModelKeys(["1. Use existing model", "2. Try new model", "› 3. Something else"]) == up + up + enter)
    check("M4 no selected row types nothing",
          CodexStartupScreen.existingModelKeys(["1. Try new model", "2. Use existing model"]) == nil)
    check("M4 no Use existing model row types nothing",
          CodexStartupScreen.existingModelKeys(["› 1. Try new model", "2. Keep the old one"]) == nil)
    var unreliable = try replay("model-notice-0.162.1-120x40.bin", rows: 40, cols: 120)
    unreliable.observe(Array("\u{1B}[5Z".utf8))
    check("M5 an unreliable grid publishes no announcement rows", unreliable.menuLines == nil)

    // rw2B: Skip answered (Esc), codex reached its composer and drew "✨ Update available!" above it.
    let banner = try replay("update-banner-after-skip-0.162.1-120x40.bin", rows: 40, cols: 120)
    check("B1 the update banner above the composer is the prompt, not the menu",
          banner.reachedPrompt && banner.title == nil && banner.menuLines == nil)
    check("B1 so nothing stands in front of the prompt and status publishes no screen",
          codexStartupStall(screen: banner, launchedAt: launched, bindingLanded: false, now: start) == nil)
    var shaped = CodexStartupScreen(rows: 24, cols: 80)
    shaped.observe(Array("\u{1B}[20;1H› Ask Codex to do anything\u{1B}[2;3HUpdate available! 0.1 -> 0.2".utf8))
    check("B2 a banner drawn after the composer, with no numbered choice under it, is not the menu",
          shaped.title == nil && shaped.reachedPrompt)

    // One wait per screen: the announcement after the update menu is a new request with its own key.
    let identity = SessionWaitIdentity(key: "codex:4242:1758575401000000", supervisorPid: 4242,
        supervisorStartedAt: 1758575401000000, childPid: 4243, transcriptSessionId: nil,
        launchNonce: "fresh", account: "codex:.codex2", directory: nil, project: nil, worktree: nil)
    var tracker = CodexWaitTracker(identity: identity)
    func tick(_ title: String?, at: TimeInterval) -> [SessionWaitEvent] {
        tracker.reconcile(observer: nil, directory: nil, project: nil, worktree: nil,
                          startupScreen: title.map { (launched, $0) }, now: start.addingTimeInterval(at))
    }
    let first = tick("Update available", at: 21).filter { $0.kind == "wait.opened" }
    _ = tick(nil, at: 25)
    let second = tick(CodexStartupScreen.modelNoticeMarker, at: 27).filter { $0.kind == "wait.opened" }
    check("W1 the announcement's wait.opened carries another request id and idempotency key than the menu's",
          first.count == 1 && second.count == 1 && first[0].idempotencyKey != second[0].idempotencyKey
              && first[0].request?.id != second[0].request?.id)

    // After the keys: what one read of the session state means (#442 and the "reached its prompt" wording).
    let next = CodexStartupScreenRecord(title: CodexStartupScreen.modelNoticeMarker, lines: nil, screenID: "scr_1", since: start)
    check("F1 the state file gone after the keys is a session that ended, not a reached prompt",
          startupAnswerOutcome(stateFound: false, screen: nil, answered: "Update available") == .sessionEnded)
    check("F1 a live session with no screen reached its prompt",
          startupAnswerOutcome(stateFound: true, screen: nil, answered: "Update available") == .prompt)
    check("F1 the announcement after Skip is the next screen, named",
          startupAnswerOutcome(stateFound: true, screen: next, answered: "Update available") == .next(next))
    check("F1 the answered screen still up is still up",
          startupAnswerOutcome(stateFound: true, screen: next, answered: CodexStartupScreen.modelNoticeMarker) == .stillUp)
}

