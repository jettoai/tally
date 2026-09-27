import Foundation

/// Whole probe rounds through the real store, against a stub status CLI that logs which home it was
/// asked about and whether another copy of itself was running at the time (login-dedupe).
@MainActor
func probeRounds(_ check: (Bool, String) -> Void) async {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("login-rounds-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = dir.appendingPathComponent("spawns.log").path
    let stub = dir.appendingPathComponent("status.sh").path
    let script = """
        #!/bin/sh
        home="${CODEX_HOME:-$CLAUDE_CONFIG_DIR}"
        mkdir "\(dir.path)/lock" 2>/dev/null || echo OVERLAP >> "\(log)"
        sleep 0.2
        echo "$(basename "$home")" >> "\(log)"
        rmdir "\(dir.path)/lock" 2>/dev/null
        echo '{"loggedIn": true, "email": "someone@example.com"}'
        """
    FileManager.default.createFile(atPath: stub, contents: Data(script.utf8),
                                   attributes: [.posixPermissions: 0o755])
    ProviderCLI.path = stub

    func account(_ name: String, _ provider: String = "claude") -> ProviderAccount {
        var account = ProviderAccount(id: "\(provider):round-\(name)", providerID: provider,
                                      label: name, locator: [:])
        account.launchHome = dir.appendingPathComponent(name).path
        return account
    }
    let a = account("a"), b = account("b"), c = account("c"), d = account("d", "codex"),
        e = account("e")
    let accounts = [a, b, c, d, e]
    let known = Set(accounts.map(\.id))
    let store = LoginStatusStore.shared
    func report(_ account: ProviderAccount, _ authenticated: Bool) {
        store.usageAuthentication(account: account, authenticated: authenticated,
                                  since: store.beginUsageAuthentication())
    }
    func round(userInitiated: Bool = false) async -> (asked: Set<String>, overlapped: Bool) {
        FileManager.default.createFile(atPath: log, contents: nil)
        await store.evaluate(accounts: accounts, known: known, userInitiated: userInitiated)
        let lines = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        return (Set(lines.filter { $0 != "OVERLAP" }), lines.contains("OVERLAP"))
    }

    let first = await round()
    check(first.asked == ["a", "b", "c", "d", "e"], "the first round asks everyone: no answers, no emails yet")
    check(!first.overlapped, "#8 the first round asks one account at a time")

    report(a, true)
    report(b, false)
    report(e, true)
    store.loginHandedOff(e.id)
    let second = await round()
    check(!second.asked.contains("a") && !store.isExpired(a.id),
          "#1 a usage answer of signed in spares the CLI and the card stays signed in")
    check(!second.asked.contains("b") && store.isExpired(b.id),
          "#2 a usage rejection spares the CLI and the card still says the login expired")
    check(second.asked.contains("c"), "#3 an account with no usage answer since the last round is asked")
    check(second.asked.contains("d"), "#7 a Codex account is asked")
    check(second.asked.contains("e"), "#4 a forced account is asked despite a current usage answer")
    check(second.asked == ["c", "d", "e"] && !second.overlapped, "#8 …one at a time")

    report(a, true)
    store.loginLanded([a.id])
    store.loginHandedOff(c.id)
    let third = await round()
    check(third.asked.contains("a"), "#5 a landing after the usage answer makes it stale: asked")
    check(third.asked.contains("b"), "#3 an answer from before the previous round began does not carry over")

    for account in [a, b, c, e] { report(account, true) }
    let fourth = await round(userInitiated: true)
    check(fourth.asked == ["a", "b", "c", "d", "e"] && !fourth.overlapped,
          "#6 an explicit refresh asks everyone, one at a time")
}
