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
    guard let declared, declared != "claude" else { return "claude" }
    return installed(declared) ? declared : "claude"
}

/// The provider a `tally session clear` should reopen this window as, or nil to clear the way this
/// provider always has. A Claude window keeps its own `/clear` while Claude is still the default; a
/// Codex window has no clear of its own, so a declared default (Codex included) is its only way to a
/// fresh window. Only a target that is installed and that `providerLaunchable` says the launcher will
/// run supervised is offered: the reopen is an exec AFTER the child is ended, and an exec into a
/// refusal leaves the terminal with no session at all.
func clearReopenProvider(current: String, declared: String?,
                         installed: (String) -> Bool, launchable: (String) -> Bool) -> String? {
    guard let declared else { return nil }
    if current == "claude", declared == "claude" { return nil }
    guard installed(declared), launchable(declared) else { return nil }
    return declared
}

/// Whether `tally <id> --new`, exec'd with this process's environment, launches an account under a
/// supervisor. No snapshot reads as no.
func providerLaunchable(_ id: String, cwd: String) -> Bool {
    guard let provider = providers.first(where: { $0.id == id }) else { return false }
    return reopenLaunchable(provider, in: loadSnapshot().0,
                            policy: effectivePolicy(launchPolicy(id), project: projectPolicy(id, cwd: cwd)),
                            environment: ProcessInfo.processInfo.environment,
                            stdoutIsTTY: isatty(STDOUT_FILENO) == 1)
}

/// `providerLaunchable` with its readings passed in. It asks the launcher's own decisions rather
/// than a third copy of them: an exported config home that `runLaunch` honours (main.swift) is
/// either refused under its reserve or run as a plain exec no later clear can reach, so it is a no
/// either way, as is a pin resolved only through the policy's denormalized home; otherwise the
/// answer is `steeredLaunch`, the prediction that already carries the pin,
/// the pin's reserve and the reserves of the automatic pick (LaunchDir.swift).
func reopenLaunchable(_ provider: Provider, in snapshot: Snapshot?, policy: LaunchPolicy,
                      environment: [String: String], stdoutIsTTY: Bool,
                      reserves: AccountReserves = accountReserves(),
                      quarantined: Set<String>? = nil) -> Bool {
    guard snapshot != nil else { return false }
    if environment[provider.envKey] != nil,
       !inheritedSessionEnvironment(providerID: provider.id, stdoutIsTTY: stdoutIsTTY,
                                    environment: environment) {
        return false
    }
    // A pin with no launchable row of its own that `pinnedLaunchHome` still resolves (the home the
    // app denormalized into the policy) is exec'd plain by `runLaunch`, with no supervisor. The
    // shim's `steeredLaunch` launches it too, so it is excluded here, not there.
    if policy.mode == "manual",
       snapshot?.accounts.contains(where: { $0.id == policy.pinnedAccountID && $0.launchHome != nil }) != true,
       pinnedLaunchHome(snapshot, policy: policy) != nil {
        return false
    }
    return steeredLaunch(provider, in: snapshot, policy: policy, reserves: reserves,
                         quarantined: quarantined) != nil
}

/// The live reading behind `clearReopenProvider`. The binary and the launcher's decision are both
/// checked here, BEFORE anything is killed. Still a prediction: the snapshot and the reserves are
/// read again by the new process after the child's teardown, and can change in between.
func clearReopenTarget(current: String, cwd: String) -> String? {
    guard selfUpdateBinary() != nil else { return nil }
    return clearReopenProvider(current: current, declared: projectDefaultProvider(cwd: cwd),
                               installed: providerInstalled,
                               launchable: { providerLaunchable($0, cwd: cwd) })
}

/// Replace this supervisor with `tally <provider> --new` in the same terminal and environment:
/// `--new` because a clear asked for an empty window, and the launch policy's continue-by-default
/// would otherwise pick this directory's last conversation back up. Never returns: on an exec
/// failure the caller has already ended the child, so it can only leave.
func execProviderReopen(_ providerID: String) -> Never {
    if let binary = selfUpdateBinary() {
        warn("reopening this window as \(providerID), this project's default provider")
        var argv: [UnsafeMutablePointer<CChar>?] = ["tally", providerID, "--new"].map { strdup($0) } + [nil]
        execv(binary, &argv)
    }
    warn("could not reopen as \(providerID); this window has ended")
    exit(1)
}
