import Foundation

// THE WATER LINE ON THE LAUNCH NOBODY TYPED AN ACCOUNT ON.
//
// `runLaunch` says out loud when a pick had to spend a reserve the owner asked to be left standing
// (`reserveDipNotice`), and the two commands in LaunchDir.swift make the very same pick, drought
// fallback included. The shim's bare `claude` is the one that most needs the sentence and the one
// that could not receive it: `eval "$(tally launch-dir claude 2> /dev/null)"`
// (IntegrationsStore.shimScript) reads this process's stderr into /dev/null, so a `warn` here is a
// no-op. The notice travels as a LINE OF THE SCRIPT and is printed by the user's own shell.
//
// Asserted as behaviour rather than as text: the pick is run against a real drought fixture, and the
// line is handed to bash exactly as the shim hands it over, so what is pinned is what the user ends
// up seeing rather than the spelling we happened to choose. The harness (`check`, `tmp`, `claude`)
// is shared from main.swift.

func runReserveNoticeChecks() {
    let instant = Date()
    func inHours(_ hours: Double) -> Date { instant.addingTimeInterval(hours * 3600) }

    /// An account whose WEEKLY window is the interesting one, keyed on a home a reserve can sit on.
    /// Session at 90% with a reset four hours out never binds. Same shape as the reserve fixtures in
    /// the smartpick suite, because this is the same drought seen from the shim's side.
    func acct(_ id: String, weekly: Double, label: String? = nil) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: label ?? id,
                         launchHome: "/tmp/notice-\(id)",
                         sessionRemaining: 90, weeklyRemaining: weekly, modelRemaining: nil,
                         sessionResetsAt: inHours(4), weeklyResetsAt: inHours(100),
                         modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil,
                         isStale: false, error: nil, lastRefreshFailed: false)
    }
    func fleet(_ accounts: [Snapshot.Account]) -> Snapshot {
        Snapshot(version: 2, generatedAt: instant, accounts: accounts)
    }
    let auto = LaunchPolicy()
    /// 30 points held back on account A and nothing anywhere else, in the SHARED entry type
    /// (Tally/Core/AccountReserve.swift), so the fixture cannot describe a document the app could
    /// not have written.
    let personalA = AccountReserves(settings: ["/tmp/notice-A":
        AccountRoleSetting(role: AccountRoles.personal, reserve: 30)])
    // The real shape of a drought: an account with no reserve is under its own line only when it is
    // empty, and an empty account is not eligible at all - so the fallback is reached exactly when
    // every account still launchable carries a reserve.
    let drought = fleet([acct("A", weekly: 25), acct("B", weekly: 0)])
    let dipped = steeredLaunch(claude, in: drought, policy: auto, reserves: personalA,
                               quarantined: [], now: instant)
    check("a bare launch onto a fleet under its own water lines still resolves an account",
          dipped?.home == "/tmp/notice-A")
    check("…and carries the launcher's own sentence about the reserve it just spent",
          dipped?.dip == reserveDipNotice(acct("A", weekly: 25), primaryModel: nil,
                                          reserves: personalA, now: instant))
    check("…which is that sentence itself rather than a second spelling of it",
          dipped?.dip == "dipping into A's reserve (30% kept for web use)")
    let ample = fleet([acct("A", weekly: 60), acct("B", weekly: 55)])
    check("a launch that stayed above every line says nothing at all",
          steeredLaunch(claude, in: ample, policy: auto, reserves: personalA, quarantined: [],
                        now: instant)?.dip == nil)
    check("…and neither does one onto an account nobody reserved anything on",
          steeredLaunch(claude, in: fleet([acct("B", weekly: 25)]), policy: auto,
                        reserves: personalA, quarantined: [], now: instant)?.dip == nil)
    // A PIN IS A PERSON NAMING AN ACCOUNT, which is the one rule this feature has: those paths pass
    // no reserves, so there is no line for them to cross and nothing to announce.
    let pinned = LaunchPolicy(mode: "manual", pinnedAccountID: "A")
    let pin = steeredLaunch(claude, in: drought, policy: pinned, reserves: personalA,
                            quarantined: [], now: instant)
    check("a pinned launch resolves to the account the person pinned",
          pin?.home == "/tmp/notice-A")
    check("…and says nothing about a reserve, having been asked for by name", pin?.dip == nil)

    // MARK: - The line as the shim runs it

    let script = tmp.appendingPathComponent("notice.sh")
    /// What bash makes of these lines, run the way the shim runs them - `eval "$(…)"` over the whole
    /// output - rather than what they look like to us. Both streams, because which one the sentence
    /// comes out on is the point: stdout belongs to the caller of `best-dir`.
    func evaluated(_ lines: [String], reading variable: String = "") -> (out: String, err: String) {
        try? lines.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
        let read = variable.isEmpty ? "" : "; printf %s \"${\(variable)}\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "eval \"$(cat '\(script.path)')\"\(read)"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try? process.run()
        let printed = out.fileHandleForReading.readDataToEndOfFile()
        let warned = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: printed, encoding: .utf8) ?? "",
                String(data: warned, encoding: .utf8) ?? "")
    }

    let notice = dipped?.dip ?? ""
    let withNotice = launchExportLines(claude, home: "/tmp/notice-A", model: "opus", notice: notice)
    check("the notice is the first line of the script, as it is the first thing the launcher says",
          withNotice.first?.hasPrefix("printf ") == true)
    let ran = evaluated(withNotice)
    check("evaluating the script prints the notice on the user's own stderr, marked as ours",
          ran.err == "[tally] \(notice)\n")
    check("…and puts nothing on stdout, which belongs to whoever asked",
          ran.out.isEmpty)
    check("a launch with nothing to announce writes no such line",
          !launchExportLines(claude, home: "/tmp/notice-A", model: "opus")
              .contains { $0.contains("printf") })

    // THE LABEL IN THAT SENTENCE IS TEXT SOMEBODY TYPED, and this line is source the shell is about
    // to run - the same hole `shellSingleQuoted` was written for one line down.
    let marker = tmp.appendingPathComponent("notice-injected")
    try? FileManager.default.removeItem(at: marker)
    let hostile = acct("A", weekly: 25, label: "A'; touch \(marker.path); echo '")
    let attacked = steeredLaunch(claude, in: fleet([hostile, acct("B", weekly: 0)]), policy: auto,
                                 reserves: personalA, quarantined: [], now: instant)
    let hostileRun = evaluated(launchExportLines(claude, home: "/tmp/notice-A",
                                                 notice: attacked?.dip ?? ""))
    check("a label carrying a shell of its own reaches the terminal as text",
          hostileRun.err == "[tally] \(attacked?.dip ?? "")\n")
    check("…and the shell ran none of it",
          !FileManager.default.fileExists(atPath: marker.path))
    // The notice must not have disturbed the lines the shim is actually there for.
    check("…while the environment beside it is still the environment",
          evaluated(withNotice, reading: "CLAUDE_CONFIG_DIR").out == "/tmp/notice-A")
    check("…including the model the account was chosen for",
          evaluated(withNotice, reading: "ANTHROPIC_MODEL").out == "opus")
}
