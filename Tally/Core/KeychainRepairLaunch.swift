import Foundation

/// Healing the Claude Code Keychain items Tally 0.64.0 damaged, once per app launch, by running the
/// helper's own verb (TallyCLI/KeychainPartitionRepair.swift holds the mechanism and the
/// measurements).
///
/// WHY THE APP DOES THIS AT ALL, when `tally claude` already repairs in front of every launch: the
/// damage is paid for by anybody who reads those items through `/usr/bin/security`, and the app is
/// one of them - its usage polling runs the `claude` CLI, which reads its own credentials that way
/// (CLIRunner.swift says the app touches no credential itself, and that is exactly why it depends on
/// the CLI being able to). A machine whose owner starts sessions any way other than through `tally`
/// would otherwise keep the dialog until they happened to use the launcher.
///
/// THROUGH THE HELPER RATHER THAN IN-PROCESS, and that is not a detour: the repair reads a secret,
/// and the whole shape of this app is that it never does (KeychainReader.swift). The one binary that
/// may is the CLI, so the app asks it, exactly as it asks it for the completion script.
///
/// IT MUST NEVER BLOCK ANYTHING. Nothing is read back, nothing is reported, and the work happens on
/// `CLIRunner`'s own queue behind an `await`, so the launch continues past this line immediately. It
/// is deliberately not coupled to the usage poll: a repair that failed must not be able to hold up a
/// reading, and a reading that is early must not be able to skip a repair.
///
/// UNSHIPPED BUILDS DO NOT RUN IT, on the rule the rest of this app follows (`BuildVariant`): a dev
/// build or one running out of a build tree keeps its hands off everything shared, and somebody
/// else's real credentials are the sharpest instance of that there is. The check also covers the
/// only other way this could go wrong - a bundle with no helper in it, which is the same condition.
///
/// IT MAY PUT A PANEL ON SCREEN, AND THAT IS THE POINT RATHER THAN A RISK. The verb runs
/// interactively, and a damaged item this helper is not trusted to read is not an exotic state: the
/// write that did the damage needed no decrypt right, so it did not grant one either
/// (KeychainPartitionRepair.swift has the measurement). Tally is in an item's decrypt entry only
/// where the person once answered a v0.63 panel with "Always Allow", so on every machine where they
/// did not, healing the item requires ONE macOS panel per damaged item - "tally wants to access
/// <service>" - and allowing it is what buys back a panel at every launch for ever.
///
/// WHAT IS BOUNDED IS HOW LONG IT MAY SIT THERE. `CLIRunner`'s watchdog terminates the child, and
/// the panel with it, after the timeout below; an unanswered or refused panel leaves the item
/// exactly as it was, and the next launch tries again. Nothing here waits for the answer and nothing
/// reads it.
enum KeychainRepairLaunch {
    @MainActor
    static func runAtStartup() {
        guard !BuildVariant.isUnshipped else { return }
        // Read on the main actor because the constant is the store's, and handed on as a path: what
        // crosses into the task is a string, so nothing MainActor-isolated is touched off it.
        let helper = IntegrationsStore.bundledCLIURL.path
        guard FileManager.default.isExecutableFile(atPath: helper) else { return }
        Task { _ = await CLIRunner.run(helper, arguments: ["keychain-repair"], timeout: 30) }
    }
}
