import Foundation

/// Which flavour of the app this process is. The Debug configuration builds "Tally Dev"
/// (bundle id `ai.jetto.tally.dev`): its own defaults domain, running happily NEXT TO the
/// installed release app - but the launch control plane stays the release app's alone, so the
/// dev instance must never publish to the shared `~/.tally` files.
enum BuildVariant {
    static let isDev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true

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
