import Darwin
import Foundation

// WHICH PROVIDER A NEW WINDOW OPENS WITH, at the two places a window is new: `tally start`, and a
// `tally session clear` that lands (B-1706). The answer is the project's declared default
// (`tally project set ... --default`, ProjectPolicy.swift). Account handoffs (cap, rebalance, pin,
// follow, self-update) never change provider: they carry the conversation, and a Claude transcript
// cannot be continued by Codex.

/// Whether `id`'s CLI resolves to a runnable file on PATH (Tally's own shim excluded).
func providerInstalled(_ id: String) -> Bool {
    guard let cli = providers.first(where: { $0.id == id })?.cli else { return false }
    return resolveProviderExecutable(cli).contains("/")
}

/// What `tally start` launches: the declared default when it is installed, Claude otherwise.
func startProviderID(declared: String?, installed: (String) -> Bool) -> String {
    guard let declared, declared != "claude", installed(declared) else { return "claude" }
    return declared
}

/// The provider a `tally session clear` should reopen this window as, or nil to clear the way this
/// provider always has. A Claude window keeps its own `/clear` while Claude is still the default; a
/// Codex window has no clear of its own, so a declared default (Codex included) is its only way to a
/// fresh window. Only a target that is installed and that `providerLaunchable` says the launcher will
/// run supervised is offered: the reopen is an exec AFTER the child is ended, and an exec into a
/// refusal leaves the terminal with no session at all. `launchable` is asked with whether the
/// reopen's own argv carries `--spend-reserve` (`providerReopenArgv`), so the precheck predicts the
/// launch that will actually run.
func clearReopenProvider(current: String, declared: String?, spendReserve: Bool = false,
                         installed: (String) -> Bool,
                         launchable: (String, Bool) -> Bool) -> String? {
    guard let declared else { return nil }
    if current == "claude", declared == "claude" { return nil }
    let spends = providerReopenArgv(target: declared, current: current, spendReserve: spendReserve)
        .contains(spendReserveFlag)
    guard installed(declared), launchable(declared, spends) else { return nil }
    return declared
}

/// What a reopen execs. `--spend-reserve` goes along only to the same provider: the reserve the
/// person said to spend belongs to this provider's fleet, not to the other one's. `--new` because a
/// clear asked for an empty window, and the launch policy's continue-by-default would otherwise pick
/// this directory's last conversation back up.
func providerReopenArgv(target: String, current: String, spendReserve: Bool) -> [String] {
    ["tally", target] + (spendReserve && target == current ? [spendReserveFlag] : []) + ["--new"]
}

/// Whether `tally <id> --new`, exec'd with this process's environment, launches under a supervisor
/// or the Codex monitor.
func providerLaunchable(_ id: String, cwd: String, spendReserve: Bool = false) -> Bool {
    guard let provider = providers.first(where: { $0.id == id }) else { return false }
    return reopenLaunchable(provider, in: loadSnapshot().0,
                            policy: effectivePolicy(launchPolicy(id), project: projectPolicy(id, cwd: cwd)),
                            environment: ProcessInfo.processInfo.environment,
                            stdoutIsTTY: isatty(STDOUT_FILENO) == 1, spendReserve: spendReserve)
}

/// `providerLaunchable` with its readings passed in. It is the launcher's own decision
/// (`resolveLaunch`, LaunchDecision.swift) for `tally <id> --new` with these readings, so it cannot
/// drift from what the exec it predicts will do: yes exactly when that launch is neither refused nor
/// left unsupervised (an opt-out, Claude on an exported or missing home).
///
/// `stdoutIsTTY` is the caller's terminal, read only for whether an exported home is a leak from
/// another session. The reopen itself execs in the supervisor's own terminal, so it is never a
/// one-shot run, whoever asks (`tally status --json` is usually read through a pipe).
func reopenLaunchable(_ provider: Provider, in snapshot: Snapshot?, policy: LaunchPolicy,
                      environment: [String: String], stdoutIsTTY: Bool, spendReserve: Bool = false,
                      reserves: AccountReserves = accountReserves(),
                      quarantined: Set<String>? = nil) -> Bool {
    // The exec this predicts, minus `tally <provider>`.
    let args = Array(providerReopenArgv(target: provider.id, current: provider.id,
                                        spendReserve: spendReserve).dropFirst(2))
    var intent = launchIntent(provider, args: args, accountFlag: nil, stdoutIsTTY: stdoutIsTTY,
                              environment: environment)
    intent.oneShot = false
    let launched = applyLaunchDefaults(removingOption(intent.passthrough, "--new"), policy: policy,
                                       providerID: provider.id)
    let model = launchPrimaryModel(launched, providerID: provider.id) ?? policy.model
    let decision = resolveLaunch(provider, intent: intent, readings: LaunchReadings(
        snapshot: snapshot, policy: policy, pinnedBy: "pinned", primaryModel: model,
        reserves: reserves, quarantined: quarantined ?? quarantinedAccounts(forPrimary: model),
        clearance: false, now: Date()))
    if case .none = decision.supervision { return false }
    return decision.refusal == nil
}

/// The live reading behind `clearReopenProvider`. The binary and the launcher's decision are both
/// checked here, BEFORE anything is killed. Still a prediction: the snapshot and the reserves are
/// read again by the new process after the child's teardown, and can change in between.
func clearReopenTarget(current: String, cwd: String, spendReserve: Bool = false) -> String? {
    guard selfUpdateBinary() != nil else { return nil }
    return clearReopenProvider(current: current, declared: projectDefaultProvider(cwd: cwd),
                               spendReserve: spendReserve, installed: providerInstalled,
                               launchable: { providerLaunchable($0, cwd: cwd, spendReserve: $1) })
}

/// Replace this supervisor with `providerReopenArgv` in the same terminal and environment. Never
/// returns: on an exec failure the caller has already ended the child, so it can only leave.
func execProviderReopen(_ providerID: String, current: String, spendReserve: Bool) -> Never {
    if let binary = selfUpdateBinary() {
        warn("reopening this window as \(providerID), this project's default provider")
        var argv: [UnsafeMutablePointer<CChar>?] = providerReopenArgv(
            target: providerID, current: current, spendReserve: spendReserve).map { strdup($0) } + [nil]
        execv(binary, &argv)
    }
    warn("could not reopen as \(providerID); this window has ended")
    exit(1)
}
