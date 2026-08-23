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
/// IT RUNS BEFORE THE FIRST USAGE POLL, AND THAT ORDER IS THE POINT. This used to say the two were
/// deliberately uncoupled, which was wrong in the one direction that matters: `UsageStore.start()`
/// schedules a refresh that runs the `claude` CLI, and the `claude` CLI reads its credentials
/// through `/usr/bin/security`, so on a machine with damaged items the app's own first reading is
/// one of the things that raises the "security" panel this repair exists to remove. Started beside
/// the repair rather than after it, it would also race the rewrite. So `AppDelegate` awaits this and
/// then starts the store, both inside one `Task` (codex review, 2026-08-23).
///
/// WHAT WAITS IS THAT TASK AND NOTHING ELSE. This function is `async` and suspends rather than
/// blocking, so the main actor is free throughout and the rest of `applicationDidFinishLaunching` -
/// the status item, the windows, the pickers - is already on screen while this is in flight. What
/// the wait costs is the first usage reading arriving later, bounded by the timeout below, and only
/// on a machine that has something to repair: a healthy one answers in well under a second, having
/// read one ACL per item.
///
/// Nothing is read back and nothing is reported: the answer this cares about is "it is finished",
/// not what it found.
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
/// WHAT IS BOUNDED IS HOW LONG IT MAY SIT THERE, and the first usage reading waits behind that bound
/// on the machines where the panel appears. `CLIRunner`'s watchdog terminates the child, and the
/// panel with it, after `timeout`; an unanswered or refused panel leaves the item exactly as it was,
/// and the next launch tries again.
enum KeychainRepairLaunch {
    /// How long the helper is given.
    ///
    /// THIRTY SECONDS BECAUSE THE SLOW CASE IS A PERSON, not a computation. Every mechanical outcome
    /// here is sub-second (a healthy machine reads one ACL per item; an item that cannot be read
    /// unattended answers `errSecAuthFailed` immediately), so a shorter bound buys nothing against
    /// any of them. The one thing that takes time is somebody noticing a panel and clicking Allow,
    /// and ten seconds is inside human reaction-plus-decision time for a dialog that appeared while
    /// they were looking somewhere else. Killing it there would throw away the ONE moment the item
    /// could have been healed, and hand them the unattributed "security" panel from the usage poll
    /// instead - the worse of the two dialogs, and the one that comes back every launch.
    ///
    /// What the choice costs is the ceiling on how late a first usage reading can be, on a machine
    /// that has a damaged item AND whose owner never answered the v0.63 panel, once, until the
    /// repair succeeds.
    private static let timeout: TimeInterval = 30

    /// Run the repair to completion, or to its timeout. Returns when the helper has exited; returns
    /// immediately on a build that may not touch shared state.
    @MainActor
    static func run() async {
        guard !BuildVariant.isUnshipped else { return }
        // Read on the main actor because the constant is the store's, and handed on as a path: what
        // crosses into `CLIRunner` is a string, so nothing MainActor-isolated is touched off it.
        let helper = IntegrationsStore.bundledCLIURL.path
        guard FileManager.default.isExecutableFile(atPath: helper) else { return }
        _ = await CLIRunner.run(helper, arguments: ["keychain-repair"], timeout: timeout)
    }
}
