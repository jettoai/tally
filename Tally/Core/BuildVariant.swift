import Foundation

/// Which flavour of the app this process is. The Debug configuration builds "Tally Dev"
/// (bundle id `ai.jetto.tally.dev`): its own defaults domain, running happily NEXT TO the
/// installed release app - but the launch control plane stays the release app's alone, so the
/// dev instance must never publish to the shared `~/.tally` files.
enum BuildVariant {
    static let isDev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
}
