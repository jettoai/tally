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
}
