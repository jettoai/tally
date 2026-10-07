import Foundation

// THE WATER LINE ON THE LAUNCH NOBODY TYPED AN ACCOUNT ON.
//
// A reserve is a hard line (B-1213): the two commands in LaunchDir.swift make the very same pick
// `runLaunch` does, so a field emptied by reserves resolves nothing and the launch is REFUSED, with
// one sentence saying why. The shim's bare `claude` is the one that most needs the sentence and the
// one that could not receive it: `eval "$(tally launch-dir claude 2> /dev/null)"`
// (IntegrationsStore.shimScript) reads this process's stderr into /dev/null, so a `warn` here is a
// no-op. The sentence travels as LINES OF THE SCRIPT and is printed by the user's own shell (and
// a refusal ends that shell's script with `exit 1`).
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
    // empty, and an empty account is not eligible at all - so the field empties exactly when every
    // account still launchable carries a reserve.
    let drought = fleet([acct("A", weekly: 25), acct("B", weekly: 0)])
    check("a bare launch onto a fleet under its own water lines resolves no account",
          steeredLaunch(claude, in: drought, policy: auto, reserves: personalA,
                        quarantined: [], now: instant) == nil)
    let refusal = steeredRefusal(claude, in: drought, policy: auto, reserves: personalA,
                                 quarantined: [], now: instant)
    check("…and is refused, naming the account the reserve held back",
          refusal?.hasPrefix("every claude account Tally may launch on is under its reserve (A)")
              == true)
    let ample = fleet([acct("A", weekly: 60), acct("B", weekly: 55)])
    check("a fleet with room refuses nothing",
          steeredRefusal(claude, in: ample, policy: auto, reserves: personalA, quarantined: [],
                         now: instant) == nil)
    check("…nor does a fleet with nothing eligible for a reason other than a reserve",
          steeredRefusal(claude, in: fleet([acct("B", weekly: 0)]), policy: auto,
                         reserves: personalA, quarantined: [], now: instant) == nil)
    check("a launch that stayed above every line resolves, and says nothing at all",
          steeredLaunch(claude, in: ample, policy: auto, reserves: personalA, quarantined: [],
                        now: instant).map { $0.dip == nil } == true)
    check("…and neither does one onto an account nobody reserved anything on",
          steeredLaunch(claude, in: fleet([acct("B", weekly: 25)]), policy: auto,
                        reserves: personalA, quarantined: [], now: instant)?.dip == nil)
    // A PIN NAMES AN ACCOUNT, and naming one under its line is refused too: the shim cannot carry
    // `--spend-reserve`, so the only way onto it is `tally claude --spend-reserve`.
    let pinned = LaunchPolicy(mode: "manual", pinnedAccountID: "A")
    check("a pinned launch onto an account under its line resolves nothing",
          steeredLaunch(claude, in: drought, policy: pinned, reserves: personalA,
                        quarantined: [], now: instant) == nil)
    check("…and is refused with the flag the shim cannot carry",
          steeredRefusal(claude, in: drought, policy: pinned, reserves: personalA,
                         quarantined: [], now: instant)
              == "A is under its weekly reserve (30% kept for web use); pass --spend-reserve to "
              + "launch on it anyway (bare claude cannot carry it: run tally claude "
              + "--spend-reserve)")
    check("…while the same pin above its line is not refused",
          steeredRefusal(claude, in: fleet([acct("A", weekly: 60), acct("B", weekly: 0)]),
                         policy: pinned, reserves: personalA, quarantined: [], now: instant)
              == nil)
    let pinAbove = steeredLaunch(claude, in: fleet([acct("A", weekly: 60), acct("B", weekly: 0)]),
                                 policy: pinned, reserves: personalA, quarantined: [], now: instant)
    check("…while a pin onto the same account above its line resolves to it",
          pinAbove?.home == "/tmp/notice-A")
    check("…and says nothing about a reserve, having been asked for by name", pinAbove?.dip == nil)

    // A CONFIG HOME EXPORTED BY HAND names an account as surely as a pin (B-1213): the same refusal,
    // matched however the path was typed, and let through only where there is no reading.
    let underA = namedReserveRefusal(acct("A", weekly: 25), primaryModel: nil, reserves: personalA,
                                     now: instant)
    check("an exported home under its line is refused in the words `--account` gets",
          underA != nil && exportedHomeRefusal("/tmp/notice-A", providerID: "claude", in: drought,
                                               primaryModel: nil, reserves: personalA,
                                               now: instant) == underA)
    check("…however the path was typed",
          exportedHomeRefusal("/tmp//notice-A/", providerID: "claude", in: drought,
                              primaryModel: nil, reserves: personalA, now: instant) == underA)
    check("…while the same home above its line launches",
          exportedHomeRefusal("/tmp/notice-A", providerID: "claude", in: ample, primaryModel: nil,
                              reserves: personalA, now: instant) == nil)
    check("a home no account carries has no reading and launches (named blind spot)",
          exportedHomeRefusal("/tmp/notice-Z", providerID: "claude", in: drought,
                              primaryModel: nil, reserves: personalA, now: instant) == nil
              && exportedHomeRefusal("/tmp/notice-A", providerID: "claude", in: nil,
                                     primaryModel: nil, reserves: personalA, now: instant) == nil)
    check("the bare launch's wording names the flag it cannot carry",
          bareLaunchRefusal("X", claude)
              == "X (bare claude cannot carry it: run tally claude --spend-reserve)")
    let launchDir = (try? String(contentsOfFile: "TallyCLI/LaunchDir.swift", encoding: .utf8)) ?? ""
    check("the shim's reserve question answers with that refusal as script lines",
          launchDir.contains("launchRefusalLines(bareLaunchRefusal(refusal, provider))")
              && launchDir.contains("if let refusal = exportedHomeRefusal(String(cString: exported),"))

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

    // `--spend-reserve` still prints the dip sentence on its own stderr; this is the quoting of that
    // same sentence when it is a line of the script.
    let notice = reserveDipNotice(acct("A", weekly: 25), primaryModel: nil, reserves: personalA,
                                  now: instant) ?? ""
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
    let attacked = reserveDipNotice(hostile, primaryModel: nil, reserves: personalA,
                                    now: instant) ?? ""
    let hostileRun = evaluated(launchExportLines(claude, home: "/tmp/notice-A", notice: attacked))
    check("a label carrying a shell of its own reaches the terminal as text",
          hostileRun.err == "[tally] \(attacked)\n")
    check("…and the shell ran none of it",
          !FileManager.default.fileExists(atPath: marker.path))
    // THE REFUSAL AS THE SHIM RUNS IT: the sentence on the user's stderr, and the script ends
    // there, so the bare CLI the shim would exec next never runs.
    let refusedScript = launchRefusalLines(refusal ?? "")
    let refusedRun = evaluated(refusedScript + ["echo after"])
    check("a refused launch prints its sentence on the user's own stderr, marked as ours",
          refusedRun.err == "[tally] \(refusal ?? "")\n")
    check("…and runs nothing after it", !refusedRun.out.contains("after"))
    check("…because the script ends in a failing exit", refusedScript.last == "exit 1")
    let refusalMarker = tmp.appendingPathComponent("refusal-injected")
    try? FileManager.default.removeItem(at: refusalMarker)
    let hostileRefusal = namedReserveRefusal(
        acct("A", weekly: 25, label: "A'; touch \(refusalMarker.path); echo '"),
        primaryModel: nil, reserves: personalA, now: instant) ?? ""
    let hostileRefused = evaluated(launchRefusalLines(hostileRefusal))
    check("a hostile label in a refusal reaches the terminal as text",
          hostileRefused.err == "[tally] \(hostileRefusal)\n")
    check("…and the shell ran none of it",
          !FileManager.default.fileExists(atPath: refusalMarker.path))
    // The notice must not have disturbed the lines the shim is actually there for.
    check("…while the environment beside it is still the environment",
          evaluated(withNotice, reading: "CLAUDE_CONFIG_DIR").out == "/tmp/notice-A")
    check("…including the model the account was chosen for",
          evaluated(withNotice, reading: "ANTHROPIC_MODEL").out == "opus")
}
