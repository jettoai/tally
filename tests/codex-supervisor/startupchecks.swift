import Foundation

// B-1736: what Codex drew before its composer (CodexStartupScreen.swift) and the wait the tracker
// publishes for a launch stuck there (CodexWaitEvents.swift). `check` and `start` come from main.swift.
func runCodexStartupChecks() throws {
    func screen(_ chunks: [String]) -> CodexStartupScreen {
        var screen = CodexStartupScreen()
        for chunk in chunks { screen.observe(Array(chunk.utf8)) }
        return screen
    }
    let menu = "\u{1B}[2;1H\u{1B}[J\u{1B}[2;3H\u{1B}[1mUpdate available\u{1B}[22m\u{1B}[2m · 0.162.1 → 9.0.0"
        + "\u{1B}[5;1H\u{1B}[7m\u{1B}[1m› 1. Update now\u{1B}[6;3H\u{1B}[27m2.\u{1B}[6;6HSkip"
    let s1 = screen([menu])
    check("S1 styled and positioned bytes read as the update menu", s1.title == "Update available" && !s1.reachedPrompt)

    let bytes = Array(menu.utf8)
    let arrow = bytes.firstIndex(of: 0xE2)!
    var split = CodexStartupScreen()
    split.observe(Array(bytes[..<12]))   // inside the third CSI
    split.observe(Array(bytes[12...(arrow + 1)]))   // inside a three-byte character
    split.observe(Array(bytes[(arrow + 2)...]))
    check("S2 escapes and UTF-8 cut across packets still read cleanly",
          split.title == "Update available" && split.text.contains("› 1. Update now") && !split.text.contains("\u{FFFD}"))

    let loading = "\u{1B}[7;1H\u{1B}[1m›\u{1B}[22m \u{1B}[2mAsk Codex to do anything"
    check("S3 a composer with no screen after it is the prompt", screen([loading]).reachedPrompt)
    check("S3 a screen drawn over the loading composer is not the prompt (codex 0.162.1 order)",
          !screen([loading, menu]).reachedPrompt)
    check("S3 the composer drawn again after the screen is the prompt", screen([loading, menu, loading]).reachedPrompt)

    check("S4 an unnamed picker is named by its selected row",
          screen(["\u{1B}[3;1H› 1. Yes, continue\u{1B}[4;3H2. No"]).title == "Yes, continue")
    check("S4 the composer row itself is no picker", screen([loading]).title == nil)

    let launched = start
    let stuck = s1
    check("S5 19 seconds is not yet a stall",
          codexStartupStall(screen: stuck, launchedAt: launched, bindingLanded: false, now: launched.addingTimeInterval(19)) == nil)
    let stall = codexStartupStall(screen: stuck, launchedAt: launched, bindingLanded: false, now: launched.addingTimeInterval(21))
    check("S5 21 seconds is a stall since the launch, titled", stall?.since == launched && stall?.title == "Update available")
    check("S5 a landed binding is no stall",
          codexStartupStall(screen: stuck, launchedAt: launched, bindingLanded: true, now: launched.addingTimeInterval(60)) == nil)
    check("S5 a reached prompt is no stall",
          codexStartupStall(screen: screen([loading]), launchedAt: launched, bindingLanded: false, now: launched.addingTimeInterval(60)) == nil)

    let fixtures = URL(fileURLWithPath: "tests/codex-supervisor/fixtures")
    let menuBytes = try Data(contentsOf: fixtures.appendingPathComponent("update-menu-0.162.1.bin"))
    let composerBytes = try Data(contentsOf: fixtures.appendingPathComponent("composer-after-menu-0.162.1.bin"))
    var real = CodexStartupScreen()
    for chunk in stride(from: 0, to: menuBytes.count, by: 97) {
        real.observe(Array(menuBytes[chunk..<min(chunk + 97, menuBytes.count)]))
    }
    check("S6 codex 0.162.1's real update menu bytes read as the menu", real.title == "Update available" && !real.reachedPrompt)
    real.observe(Array(composerBytes))
    check("S6 codex 0.162.1's real composer after Skip reads as the prompt", real.reachedPrompt)

    let identity = SessionWaitIdentity(key: "codex:4242:1758575401000000", supervisorPid: 4242,
        supervisorStartedAt: 1758575401000000, childPid: 4243, transcriptSessionId: nil,
        launchNonce: "fresh", account: "codex:.codex2", directory: nil, project: nil, worktree: nil)
    var tracker = CodexWaitTracker(identity: identity)
    func tick(_ tracker: inout CodexWaitTracker, _ screen: (since: Date, title: String?)?,
              observer: CodexSessionObserver? = nil, at: TimeInterval) -> [SessionWaitEvent] {
        tracker.reconcile(observer: observer, directory: "/work/tally", project: "tally", worktree: nil,
                          startupScreen: screen, now: start.addingTimeInterval(at))
    }
    let opened = tick(&tracker, stall, at: 21)
    check("T1 a stalled launch opens one suspected unknown startup-screen wait",
          opened.count == 1 && opened[0].kind == "wait.opened" && opened[0].provider == "codex"
          && opened[0].request?.kind == "unknown" && opened[0].request?.confidence == "suspected"
          && opened[0].request?.tool == codexStartupScreenTool && opened[0].request?.since == launched
          && opened[0].request?.summary == codexStartupSummaryPrefix + "Update available"
          && opened[0].session.key == identity.key && opened[0].session.account == "codex:.codex2")
    check("T2 the same stall is not re-emitted", tick(&tracker, stall, at: 22).isEmpty)
    let resolved = tick(&tracker, nil, at: 30)
    check("T3 reaching the prompt resolves it as unknown",
          resolved.count == 1 && resolved[0].kind == "wait.resolved" && resolved[0].resolution == "unknown"
          && resolved[0].request?.id == opened[0].request?.id)

    var finishing = CodexWaitTracker(identity: identity)
    _ = tick(&finishing, stall, at: 21)
    let finished = finishing.finish(now: start.addingTimeInterval(40))
    check("T4 a session ending on the screen resolves session-ended, then ends",
          finished.map(\.kind) == ["wait.resolved", "session.ended"] && finished[0].resolution == "session-ended")

    var (_, permissionObserver) = try fixture("startup-vs-permission", contents: meta() + event("task_complete"))
    permissionObserver.poll(home: home.path, activity: CodexSessionActivity(nonce: "fresh", sessionID: sid,
        turnID: nextTurn, event: "UserPromptSubmit", at: start.addingTimeInterval(2)))
    permissionObserver.poll(home: home.path, activity: CodexSessionActivity(nonce: "fresh", sessionID: sid,
        turnID: nextTurn, event: "PermissionRequest", at: start.addingTimeInterval(3), tool: "shell"))
    var both = CodexWaitTracker(identity: identity)
    let ranked = tick(&both, stall, observer: permissionObserver, at: 21)
    check("T5 a pending permission outranks the startup screen",
          ranked.count == 1 && ranked[0].request?.kind == "permission" && ranked[0].request?.tool == "shell")
}
