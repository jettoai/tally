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
    /// embedded by the release pipeline), so from then on every `/tally-account` answered "No such
    /// file or directory" and fell through to a model turn, on a machine whose actual installed app
    /// was fine.
    ///
    /// Judged on the path because that is the thing that differs. The build tree is where Xcode
    /// puts products (`~/Library/Developer/Xcode/DerivedData/…/Build/Products/Release/Tally.app`,
    /// and the same tail under a custom derived-data location), and an installed app never lives
    /// under either of those.
    static let isBuildTree = isBuildProductsPath(Bundle.main.bundleURL.path)

    /// The path test on its own, so it can be asserted without building an app bundle.
    static func isBuildProductsPath(_ path: String) -> Bool {
        path.contains("/DerivedData/") || path.contains("/Build/Products/")
    }

    /// Whether this process must keep its hands off everything shared: `~/.tally`, the config homes,
    /// their settings.json. True for the dev variant AND for any bundle running from a build tree,
    /// which are two different ways of being a build nobody installed - the second one wearing the
    /// release app's own identity.
    static var isUnshipped: Bool { isDev || isBuildTree }

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
