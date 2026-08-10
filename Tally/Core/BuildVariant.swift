import Foundation

/// Which flavour of the app this process is. The Debug configuration builds "Tally Dev"
/// (bundle id `ai.jetto.tally.dev`): its own defaults domain, running happily NEXT TO the
/// installed release app - but the launch control plane stays the release app's alone, so the
/// dev instance must never publish to the shared `~/.tally` files.
enum BuildVariant {
    static let isDev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true

    /// Whether this bundle is running out of a build products tree rather than from where an app
    /// is installed.
    ///
    /// The dev flag above does not cover it, and that gap cost a user their slash commands: a
    /// RELEASE configuration built locally carries the release bundle id, so it read as the
    /// installed app and let itself rewrite the shared config homes - registering every prompt hook
    /// at a path inside DerivedData. A build tree holds no `Contents/Helpers/tally` (the CLI is
    /// embedded by the release pipeline), so from then on every `/tally` answered "No such
    /// file or directory" and fell through to a model turn, on a machine whose actual installed app
    /// was fine.
    ///
    /// Judged on the path because that is the thing that differs. The build tree is where Xcode
    /// puts products (`~/Library/Developer/Xcode/DerivedData/…/Build/Products/Release/Tally.app`,
    /// and the same tail under a custom derived-data location), and an installed app never lives
    /// under either of those.
    ///
    /// The ARCHIVE is the third shape, and the release pipeline makes one every time: `xcodebuild
    /// archive` writes `build/Tally.xcarchive/Products/Applications/Tally.app`, which holds neither
    /// tail above (`build` lowercase, no `Build/Products` pair) and is exactly the bundle Xcode's
    /// Organizer launches when somebody double-clicks a build to check it. Same failure, one
    /// directory over: release bundle id, no embedded CLI, hooks rewritten at a path inside `build/`.
    ///
    /// TRANSLOCATION is the fourth, and the only one a USER reaches: an app run straight out of a
    /// downloaded DMG without being dragged to /Applications is launched by macOS from a read-only
    /// copy at `/private/var/folders/…/AppTranslocation/<UUID>/d/Tally.app`, which exists for that
    /// launch and no longer afterwards. That copy is a complete shipped bundle, embedded CLI and all,
    /// so nothing else here catches it - and the hooks it would register name a path that is gone by
    /// the next boot, which is the original failure with a different cause. It is a build nobody
    /// installed in the most literal sense: installing it is the step that was skipped.
    ///
    /// Matched case-insensitively because the tails are directory names a build setting can respell
    /// (`-derivedDataPath`), and the volume this repo lives on is case-insensitive anyway, so a path
    /// that reads `build/products` is the same directory as `Build/Products`.
    static let isBuildTree = isBuildProductsPath(Bundle.main.bundleURL.path)

    /// The path test on its own, so it can be asserted without building an app bundle. Named for the
    /// shape that came first; what it actually answers is "is this bundle somewhere an INSTALLED app
    /// never lives", which the translocation tail belongs to just as much as the build ones.
    static func isBuildProductsPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return ["/deriveddata/", "/build/products/", ".xcarchive/", "/apptranslocation/"]
            .contains { lowered.contains($0) }
    }

    /// Where the release pipeline puts the `tally` CLI inside the bundle. One spelling, shared with
    /// `IntegrationsStore.bundledCLIURL`: the check below and the binary the hooks are registered
    /// with have to be talking about the same file or the check means nothing.
    static let bundledCLIRelativePath = "Contents/Helpers/tally"

    /// Whether a bundle carries that CLI. The path test above can only recognise the build layouts
    /// somebody has already been bitten by (`CONFIGURATION_BUILD_DIR` alone can put a Release build
    /// anywhere at all), so the mechanism gets asserted directly as well: the CLI is embedded by
    /// `scripts/build-release.sh` AFTER the export, so a bundle without it did not come from the
    /// release pipeline, whatever its path says. It is also the precise precondition for the write
    /// that started this: a hook registered at `<bundle>/Contents/Helpers/tally` when no such file
    /// exists is the "No such file or directory" the user got on every prompt.
    ///
    /// THE ARGUMENT AGAINST IT, so it can be weighed rather than discovered: this makes an installed
    /// app's shared-state writes depend on a step in the release script. Drop the embed from
    /// `build-release.sh` and every installed app silently stops publishing `~/.tally/snapshot.json`.
    /// That is a real cost, and it is bought back twice over - the pipeline's own step is pinned by a
    /// test (tests/integrations), and an app shipped without the CLI has no CLI to read the snapshot
    /// it would have published, nor a `/usr/local/bin/tally` that resolves, so the state it stops
    /// writing is state that nothing on that machine could still consume.
    static func bundleCarriesCLI(_ bundle: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent(bundledCLIRelativePath).path)
    }

    static let bundlesCLI = bundleCarriesCLI(Bundle.main.bundleURL)

    /// Whether this process must keep its hands off everything shared: `~/.tally`, the config homes,
    /// their settings.json. True for the dev variant, for any bundle running from a build tree, and
    /// for any bundle the release pipeline did not finish - three different ways of being a build
    /// nobody installed, the last two wearing the release app's own identity.
    static var isUnshipped: Bool { isDev || isBuildTree || !bundlesCLI }

    /// The marketing version this bundle was built with ("0.38.3"), or nil when the plist carries
    /// none. Read from `Bundle.main` rather than written down anywhere: the release script edits
    /// `project.yml` and nothing else, so a literal here would be a second version number, wrong for
    /// exactly as long as nobody notices.
    ///
    /// nil rather than a placeholder, because the two surfaces that show this want different ones: a
    /// Settings row always occupies its line and fills the gap with the no-data glyph, while the
    /// panel footer would rather show nothing at all than a byline trailed by a dash. Reporting the
    /// fact and letting each decide is also why this does not swallow the manifest's own fallback,
    /// which is a stored value rather than something anybody reads.
    static var version: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
