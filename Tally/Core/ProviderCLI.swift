import Foundation

/// Which binary is a provider's REAL CLI - the one rule shared by everything Tally spawns against a
/// single named account (renewing a login, asking whether one is still signed in).
///
/// Never Tally's own PATH shim. The shim re-picks an account for any invocation with an empty
/// config-home variable, and the default home is exactly that (it runs with the variable UNSET, see
/// `RenewLoginCommand.environment`) - so a shimmed `claude` would act on whichever account the
/// launch policy currently favours rather than the one the card names. Falling back to the bare
/// name leaves the lookup to the system, which is all there is when nothing was found.
enum ProviderCLI {
    /// `cli` is the provider's command name (`claude`, `codex`). `devOverrideKey` is a dev-build
    /// launch flag that points the spawn at a stand-in CLI, so a whole chain can be exercised
    /// without spending a real credential - dev only and volatile (the argument domain), so the
    /// release app cannot be talked into running something else as a provider CLI.
    static func executable(_ cli: String, devOverrideKey: String) -> String {
        if BuildVariant.isDev,
           let standIn = UserDefaults.standard.string(forKey: devOverrideKey),
           !standIn.isEmpty {
            return standIn
        }
        guard let path = CLIRunner.resolve(cli),
              !path.hasPrefix(IntegrationsStore.binDirURL.path + "/") else { return cli }
        return path
    }
}
