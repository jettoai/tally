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
/// fresh window. Only a target that is installed and has an account is offered: the reopen is an
/// exec, and an exec into nothing leaves the terminal with no session at all.
func clearReopenProvider(current: String, declared: String?,
                         installed: (String) -> Bool, launchable: (String) -> Bool) -> String? {
    guard let declared else { return nil }
    if current == "claude", declared == "claude" { return nil }
    guard installed(declared), launchable(declared) else { return nil }
    return declared
}

/// Whether the snapshot has an account `tally <id>` could launch on. No snapshot reads as no.
func providerLaunchable(_ id: String, cwd: String) -> Bool {
    guard let snapshot = loadSnapshot().0 else { return false }
    let model = effectivePolicy(launchPolicy(id), project: projectPolicy(id, cwd: cwd)).model
    return best(providerID: id, in: snapshot, primaryModel: model) != nil
}

/// The live reading behind `clearReopenProvider`. The binary is checked here, BEFORE anything is
/// killed, so a reopen that could not exec is never offered.
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
