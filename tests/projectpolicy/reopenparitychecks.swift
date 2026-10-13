import Foundation

// THE REOPEN PRECHECK AGREES WITH THE LAUNCHER IT PREDICTS (B-1706).
//
// A `tally session clear` that reopens a window as the project's default provider ends the child
// FIRST and then execs `tally <provider> --new`. If that launcher refuses, the window is left with
// no session while the clear has already reported success. So `reopenLaunchable` (ProviderReopen.swift)
// must answer yes exactly when `runLaunch` (main.swift) would launch an account under a supervisor.
//
// `launcherSupervises` below is main.swift's decision for `tally <id> --new` (no `--account`, no
// `--spend-reserve`, nothing typed), built from the same functions it calls and stopping where it
// would exec. Every cell of the matrix is listed, none sampled: the reserved account above/under
// its line x a sibling without a reserve absent/present x pin none/reserved/sibling x exported
// home none/reserved/sibling, for both providers.
// The harness (`check`, `claude`, `codex`) is shared from main.swift.

/// SelfUpdate.swift's lookup, standing in so this suite need not compile the supervisor.
func selfUpdateBinary(_ candidate: String? = Bundle.main.executableURL?.path) -> String? {
    guard let candidate, FileManager.default.isExecutableFile(atPath: candidate) else { return nil }
    return candidate
}

func runReopenParityChecks() {
    let instant = Date()
    func inHours(_ hours: Double) -> Date { instant.addingTimeInterval(hours * 3600) }
    func acct(_ provider: String, _ name: String, weekly: Double,
              signedOut: Bool = false) -> Snapshot.Account {
        Snapshot.Account(id: "\(provider):\(name)", provider: provider, label: name,
                         launchHome: signedOut ? nil : "/tmp/reopen-\(provider)-\(name)",
                         sessionRemaining: 90, weeklyRemaining: weekly, modelRemaining: nil,
                         sessionResetsAt: inHours(4), weeklyResetsAt: inHours(100),
                         modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil,
                         isStale: false, error: nil, lastRefreshFailed: false)
    }
    let above = 90.0, under = 50.0  // read against the one 60% reserve each fixture holds

    /// main.swift:159-263 for `tally <id> --new`, minus the exec: true only for a supervised launch.
    func launcherSupervises(_ provider: Provider, _ snapshot: Snapshot, _ policy: LaunchPolicy,
                            exported: String?, reserves: AccountReserves) -> Bool {
        let model = policy.model
        if let home = exported {
            // Refused under its reserve, otherwise a plain exec with no supervisor (main.swift:163-171).
            _ = exportedHomeRefusal(home, providerID: provider.id, in: snapshot, primaryModel: model,
                                    reserves: reserves)
            return false
        }
        if policy.mode == "manual",
           pinStepAsideRow(snapshot, policy: policy, primaryModel: model, quarantined: [],
                           reserves: reserves, spendReserve: false, now: instant) == nil {
            if let match = snapshot.accounts.first(where: {
                $0.id == policy.pinnedAccountID && $0.launchHome != nil
            }) {
                return namedReserveRefusal(match, primaryModel: model, reserves: reserves,
                                           now: instant) == nil
            }
            if pinnedLaunchHome(snapshot, policy: policy) != nil { return false }
        }
        return launchPick(providerID: provider.id, in: snapshot, primaryModel: model,
                          quarantined: [], reserves: reserves, now: instant) != nil
    }

    // The reserve is single select (AccountRoles.reserve): ONE account, R, carries it. O is a
    // sibling with no reserve, present or not. The pin and the exported home name R, O or nothing.
    enum Target: String, CaseIterable { case none, R, O }
    var cells = 0, agreed = 0
    for provider in [claude, codex] {
        for rAbove in [true, false] {
            for sibling in [false, true] {
                for pin in Target.allCases where sibling || pin != .O {
                    for exported in Target.allCases where sibling || exported != .O {
                        let p = provider.id
                        var accounts = [acct(p, "R", weekly: rAbove ? above : under)]
                        if sibling { accounts.append(acct(p, "O", weekly: above)) }
                        let snapshot = Snapshot(version: 2, generatedAt: instant, accounts: accounts)
                        let reserves = AccountReserves(settings: ["/tmp/reopen-\(p)-R":
                            AccountRoleSetting(role: AccountRoles.personal, reserve: 60)])
                        let policy = pin == .none ? LaunchPolicy()
                            : LaunchPolicy(mode: "manual", pinnedAccountID: "\(p):\(pin.rawValue)")
                        let home = exported == .none ? nil : "/tmp/reopen-\(p)-\(exported.rawValue)"
                        let env = home.map { [provider.envKey: $0] } ?? [:]
                        let expected = launcherSupervises(provider, snapshot, policy, exported: home,
                                                          reserves: reserves)
                        let precheck = reopenLaunchable(provider, in: snapshot, policy: policy,
                                                        environment: env, stdoutIsTTY: true,
                                                        reserves: reserves, quarantined: [])
                        cells += 1
                        if precheck == expected { agreed += 1 }
                        check("reopen parity \(p) R=\(rAbove ? "above" : "under") sibling=\(sibling) "
                            + "pin=\(pin) exported=\(exported): precheck \(precheck) == launcher \(expected)",
                              precheck == expected)
                    }
                }
            }
        }
    }
    check("reopen parity: all 52 cells were run and agreed", cells == 52 && agreed == cells)

    // How the pin resolves when its own row cannot launch it: missing from the snapshot or signed
    // out x the policy's denormalized home present or not x another account in the snapshot or not.
    // Missing + home is main.swift's plain-exec fallback; signed out drops the home and picks.
    var pinCells = 0, pinAgreed = 0
    for provider in [claude, codex] {
        for signedOut in [false, true] {
            for denormalized in [false, true] {
                for other in [false, true] {
                    let p = provider.id
                    var accounts: [Snapshot.Account] = []
                    if signedOut { accounts.append(acct(p, "P", weekly: above, signedOut: true)) }
                    if other { accounts.append(acct(p, "O", weekly: above)) }
                    let snapshot = Snapshot(version: 2, generatedAt: instant, accounts: accounts)
                    let policy = LaunchPolicy(mode: "manual", pinnedAccountID: "\(p):P",
                                              pinnedHome: denormalized ? "/tmp/reopen-\(p)-P" : nil)
                    let expected = launcherSupervises(provider, snapshot, policy, exported: nil,
                                                      reserves: .none)
                    let precheck = reopenLaunchable(provider, in: snapshot, policy: policy,
                                                    environment: [:], stdoutIsTTY: true,
                                                    reserves: .none, quarantined: [])
                    pinCells += 1
                    if precheck == expected { pinAgreed += 1 }
                    check("reopen parity \(p) pin row=\(signedOut ? "signed-out" : "missing") "
                        + "pinnedHome=\(denormalized) other=\(other): precheck \(precheck) == launcher \(expected)",
                          precheck == expected)
                }
            }
        }
    }
    check("reopen parity: all 16 pin-resolution cells were run and agreed",
          pinCells == 16 && pinAgreed == pinCells)
    check("a pin missing from the snapshot, run on its denormalized home, is not offered",
          !reopenLaunchable(claude, in: Snapshot(version: 2, generatedAt: instant, accounts: []),
                            policy: LaunchPolicy(mode: "manual", pinnedAccountID: "claude:P",
                                                 pinnedHome: "/tmp/reopen-claude-P"),
                            environment: [:], stdoutIsTTY: true, reserves: .none, quarantined: []))

    // The judge's named samples, as the cells they are, so a red one says which case regressed.
    func s(_ provider: Provider, _ accounts: [Snapshot.Account], pin: String? = nil,
           env: [String: String] = [:], tty: Bool = true) -> Bool {
        // The first account is the one holding the (single select) reserve.
        let reserves = AccountReserves(settings: [accounts[0].launchHome!:
            AccountRoleSetting(role: AccountRoles.personal, reserve: 60)])
        return reopenLaunchable(provider, in: Snapshot(version: 2, generatedAt: instant, accounts: accounts),
                                policy: pin.map { LaunchPolicy(mode: "manual", pinnedAccountID: $0) } ?? LaunchPolicy(),
                                environment: env, stdoutIsTTY: tty, reserves: reserves, quarantined: [])
    }
    check("S1: the only Claude account under its reserve is not offered",
          !s(claude, [acct("claude", "A", weekly: under)]))
    check("S1 control: the same account above its reserve is offered",
          s(claude, [acct("claude", "A", weekly: above)]))
    check("S2: a pin under its reserve is not offered even with a healthy sibling",
          !s(claude, [acct("claude", "A", weekly: under), acct("claude", "B", weekly: above)],
             pin: "claude:A"))
    check("S3: an exported CLAUDE_CONFIG_DIR under its reserve is not offered",
          !s(claude, [acct("claude", "A", weekly: under), acct("claude", "B", weekly: above)],
             env: ["CLAUDE_CONFIG_DIR": "/tmp/reopen-claude-A"]))
    check("S4: the only Codex account under its reserve is not offered",
          !s(codex, [acct("codex", "C", weekly: under)]))
    // A home leaked from a parent Claude session is ignored by the launcher (main.swift:142-157),
    // which then picks normally: the precheck must not refuse on it.
    check("a leaked CLAUDE_CONFIG_DIR (child marker on a TTY) does not block the reopen",
          s(claude, [acct("claude", "A", weekly: under), acct("claude", "B", weekly: above)],
            env: ["CLAUDE_CONFIG_DIR": "/tmp/reopen-claude-A", childSessionMarker: "1"]))
    check("…but the same marker off a TTY keeps the home, so it still blocks",
          !s(claude, [acct("claude", "A", weekly: above)],
             env: ["CLAUDE_CONFIG_DIR": "/tmp/reopen-claude-A", childSessionMarker: "1"], tty: false))
}
