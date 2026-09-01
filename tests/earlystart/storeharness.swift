import Foundation

// WHAT IT TAKES TO COMPILE THE STORE HERE.
//
// `EarlyStartStore` was the one file in this feature that no suite compiled at all, so every rule it
// carries was held by reading its source as text (spawnchecks.swift says so about its own span
// lock). What stands between it and a plain `swiftc` is not the relay - that is all here - but four
// app-wide singletons it touches for reasons that have nothing to do with early start: the refresh
// loop, the settings, the integrations directory and the screenshot gate.
//
// FOUR STAND-INS RATHER THAN THE REAL FOUR, and the count was measured rather than assumed. Taking
// the real ones means taking what stands behind them: the settings alone pull the display
// preferences, the panel geometry, the provider catalogue, the board order, the account-removal
// traces and from there the whole add-account and keychain surface, and the screenshot fixtures pull
// the footprint readers, the token tables, the forecast and the advisor. Measured on this tree that
// is upward of thirty files for four members, and a suite that compiles the app to assert four rules
// about a schedule is a suite that goes red for things it is not about.
//
// EACH STAND-IN IS COUPLED TO THE STORE BY THE COMPILER, which is what keeps this honest: the store's
// OWN source is what is built against these declarations, so a store that renames a call, adds an
// argument or reaches for a member that is not here fails to build rather than passing quietly.
//
// WHAT THEY CANNOT CATCH, said plainly: the real singletons changing BEHAVIOUR underneath an
// unchanged call. Nothing asserted in storechecks.swift depends on any of that behaviour - the
// checks drive preferences, the arming gate and the state payload, and every one of those is the
// store's own code and the real `EarlyStartLogic` behind it. A check that ever does depend on one of
// these four belongs against the real thing, in a suite that carries it.

@MainActor
final class UsageStore {
    static let shared = UsageStore()
    func refresh(userInitiated: Bool = false) async {}
    /// Reached from `SettingsStore`'s own property observers rather than from the relay: the AppKit
    /// menu bar redraws through it. Present so those observers compile, and doing nothing, because
    /// there is no menu bar in an assertion run.
    var onChange: (() -> Void)?
    func republishSnapshot() {}
    func rescheduleRefresh() {}
}

/// THE SECOND AND LAST STAND-IN, and it is one property wide. `ProviderCLI` refuses to resolve a
/// `claude` that turns out to be Tally's own PATH shim - a launcher resolving to itself is a fork
/// bomb - and it asks that question by comparing against this directory. The real
/// `IntegrationsStore` is the app's whole integrations surface (hooks, shims, manifests, a directory
/// watcher, five files of extensions); what the relay needs from it is where that bin directory is.
///
/// The same bounded drift as the one above, and the same compiler coupling: `ProviderCLI`'s own
/// source is compiled against this, so a comparison that starts asking something else fails to build
/// here. What it cannot catch is the real directory moving, and that changes nothing this suite
/// asserts - no check below resolves a CLI at all.
@MainActor
enum IntegrationsStore {
    static let binDirURL = URL(fileURLWithPath: "/usr/local/bin")
}

/// THE THIRD, and the one that pays for itself most obviously. `DemoUsage.isActive` is a launch
/// argument the relay reads twice as a gate; the file it lives in is the app's whole screenshot
/// fixture set, which drags the footprint readers, the token tables, the forecast and the advisor
/// behind it - eight files, for one Bool.
///
/// FALSE IS THE TRUTHFUL ANSWER HERE, not a convenience: the real one reads `-TallyDemoData` off the
/// arguments, and an assertion run passes no such flag. So this stand-in answers what the real one
/// would, and the gates it guards (a screenshot run sends nothing; the notice's button is not
/// written into the defaults a real app reads) are unaffected by standing in for it.
enum DemoUsage {
    static var isActive: Bool { UserDefaults.standard.bool(forKey: "TallyDemoData") }
}

/// THE FOURTH. The relay asks the settings two questions about each account before it plans a
/// message, and the settings are the root of the deepest chain of all (see the note at the top).
///
/// Answering YES to both is what an ordinary machine answers, and it is also the answer that makes
/// this stand-in unable to hide anything the checks care about: nothing in storechecks.swift plans a
/// message at all - a test binary is a build nobody installed, so `mayRun` closes that path before
/// the settings are consulted - and the filtering these two feed is asserted for real, against the
/// real rule, one file over (relaychecks.swift drives `EarlyStartLogic.plan` with candidates whose
/// `isEnabled` is set both ways).
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()
    func isEnabled(_ providerID: String) -> Bool { true }
    func isAccountEnabled(_ accountID: String) -> Bool { true }
}
