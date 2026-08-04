import Foundation

// The other thing a brand new account's config home needs, and the one thing the login Tally drives
// does not write: the note saying Claude Code's first-run wizard is done.
//
// `claude auth login` completes the OAuth round trip and stops there. `hasCompletedOnboarding` is
// written by the WIZARD, and only by the wizard, so a home Tally created and signed in through the
// app arrives at its first `tally claude` looking untouched: the theme picker, and then a request to
// sign in to the account that is already signed in. Every account added through Settings had this,
// and only a hand-edited state file made it stop.
//
// MEASURED 2026-08-04 against claude 2.1.221, by reading the shipped bundle and by running a
// command that spends no credential - never by driving a real login:
//
//   - the startup gate is `if (!config.hasCompletedOnboarding || …) { show Onboarding }`. One key,
//     read as a boolean. Setting it is the whole fix.
//   - `lastOnboardingVersion` is WRITTEN beside it by all three paths that finish onboarding, and
//     read by nothing in the binary. This machine agrees: the main home records "1.0.77" while
//     2.1.221 is installed and no wizard appears. So it is bookkeeping, which is why the seed below
//     copies a neighbour's value when there is one and omits the key when there is not - a version
//     number Tally invented would be the only way to make that field WRONG.
//   - a `.claude.json` pre-seeded with keys claude has never heard of survived a `claude auth
//     status` run against that config dir intact, with claude's own fields (`machineID`,
//     `migrationVersion`, `firstStartTime`, …) added ALONGSIDE. It merges; it does not overwrite.
//     This seed merges for the same reason and in the same direction. (It also showed the file has
//     a lock directory of claude's own, which is why the seed refuses to write when it would change
//     nothing: the file another program is actively rewriting is the one this must not touch.)
//
// Writing into a file another program owns is the exception to Tally's read-only posture, and the
// boundary IS the justification: the only home this ever writes to is the one a login Tally itself
// just started landed in, or one still carrying the marker Tally wrote when it created the directory
// (`addAccountPendingMarker`, AddAccount.swift). Never a scan for homes to repair, never a home the
// user built for themselves. Reading is wider than writing on purpose - the donor lookup below
// reads every home and writes to none of them.
//
// The neighbouring seed (TrustSeed.swift) is drawn on the same line for the same reason: an account
// Tally opened should not re-interrogate the user about answers they have already given.

/// The key Claude Code's first-run wizard writes, and the only one its startup gate reads.
private let onboardingCompletedKey = "hasCompletedOnboarding"

/// Written beside it by the wizard, and read by nothing. Copied when a neighbour has one, never
/// invented.
private let onboardingVersionKey = "lastOnboardingVersion"

/// The state file's new contents, or nil when nothing needs to change.
///
/// nil is the common answer and the important one. An account that has been through the wizard
/// keeps its file byte for byte, so the renewal path - which runs against homes full of somebody's
/// live state - cannot lose an update to a file claude is writing at the same moment. The only
/// homes that get written to are the ones that would otherwise show the wizard.
///
/// `donorVersion` is a closure rather than a value because finding one reads other homes' state
/// files: worth doing for the home that needs a seed, wasted on every home that does not.
func claudeOnboardingSeed(intoState raw: Data?, donorVersion: () -> String?) -> Data? {
    var root: [String: Any] = [:]
    if let raw, !raw.isEmpty {
        // Unreadable is a REFUSAL, not an empty start. The file belongs to Claude Code; replacing
        // one this cannot parse would be a repair nobody asked for, and it would take the account's
        // identity (`oauthAccount`) and every project's history with it.
        guard let parsed = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        else { return nil }
        root = parsed
    }
    guard root[onboardingCompletedKey] as? Bool != true else { return nil }
    root[onboardingCompletedKey] = true
    // Only ever ADDED. A value already in the file is the wizard's own record of which version it
    // ran, and nothing here knows better than that.
    if root[onboardingVersionKey] == nil, let version = donorVersion(), !version.isEmpty {
        root[onboardingVersionKey] = version
    }
    return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

/// A `lastOnboardingVersion` some other Claude home on this machine already recorded, or nil when
/// this is the only one.
///
/// Copied rather than derived, and certainly rather than hardcoded: the field means "the version
/// whose wizard was completed", Tally did not complete one, and a literal in here would be wrong
/// from the next release onwards. A machine with no other home simply gets a state file without the
/// key - which nothing reads (see the header), so the wizard stays shut either way.
///
/// The walk mirrors the slot rule's (`~/.claude`, `~/.claude2` … `~/.claude99`) so it looks in the
/// same places an account can live. Read-only, every one of them.
func claudeOnboardingDonorVersion(excluding target: URL,
                                  userHome: URL = FileManager.default.homeDirectoryForCurrentUser)
    -> String? {
    let base = addAccountConfigBase(providerID: "claude")
    let excluded = target.standardizedFileURL.path
    for n in 1 ... 99 {
        let dir = userHome.appendingPathComponent(n == 1 ? base : "\(base)\(n)")
        guard dir.standardizedFileURL.path != excluded,
              let raw = try? Data(contentsOf: claudeStateFile(forConfigDir: dir)),
              let root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              root[onboardingCompletedKey] as? Bool == true,
              let version = root[onboardingVersionKey] as? String, !version.isEmpty
        else { continue }
        return version
    }
    return nil
}

/// Record that ONE config home is past the first-run wizard, unless its state file says so already.
///
/// Returns whether anything was written, which is false for almost every call: an existing account
/// already has the key. Best-effort like every other errand around a login - a failure here costs
/// the user one wizard screen, never the login they asked for.
///
/// Claude only. Codex has no such wizard and no such file, so asking would be asking a question
/// with no answer; the provider id is taken as an argument rather than assumed so the callers can
/// stay provider-agnostic.
@discardableResult
func markClaudeOnboardingComplete(providerID: String, home: String,
                                  userHome: URL = FileManager.default.homeDirectoryForCurrentUser)
    -> Bool {
    guard providerID == "claude", !home.isEmpty else { return false }
    let dir = URL(fileURLWithPath: home)
    // Through the shared path rule, because the default home keeps its state one level UP
    // (`~/.claude.json`, ClaudeStatePath.swift). Get that wrong and this writes a file claude never
    // reads, which looks exactly like the bug it is fixing.
    let file = claudeStateFile(forConfigDir: dir)
    guard let body = claudeOnboardingSeed(
        intoState: try? Data(contentsOf: file),
        donorVersion: { claudeOnboardingDonorVersion(excluding: dir, userHome: userHome) })
    else { return false }
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    return (try? body.write(to: file, options: .atomic)) != nil
}
