import Foundation

// Carrying folder trust to a newly added account, so the fleet does not re-interrogate the user.
//
// Claude Code asks "is this a project you trust?" once per folder per config dir, and remembers the
// answer in `<state>.claude.json` under `projects[<path>].hasTrustDialogAccepted`. That file is
// deliberately NOT part of the shared harness (SharedHarness.swift): it is an identity file, it
// carries `oauthAccount`, and every running session rewrites it constantly, so symlinking it would
// braid two accounts together. The cost of that correct decision is that account number three is
// asked about every folder the user already vouched for on account number one.
//
// So adding an account seeds it instead of sharing it: at login time, the trusted PATHS are copied
// across and nothing else. A copy, once, of a list of directories the user has already approved.
//
// Compiled into both targets (it moved out of TallyCLI/ on 2026-08-03): `tally add` and Settings'
// own "Add account" flow prepare a new home the same way, from one implementation.
//
// MEASURED 2026-07-28, because seeding a file another program owns is only safe if that program
// merges rather than overwrites. Against claude 2.1.220, in a throwaway config dir:
//
//   - a `.claude.json` pre-seeded with `projects[<cwd>].hasTrustDialogAccepted = true` launched
//     straight to the prompt, and afterwards still held that value, with claude's own per-project
//     fields (`lastVersionBase` and friends) added ALONGSIDE it. It merges; it does not reset.
//   - the control, same config dir and same launch, in a cwd absent from that map: the trust
//     dialog appeared. So the skip above is caused by the seeded value rather than by anything
//     else about the run.

// The state file is addressed through the shared `claudeStateFile(forConfigDir:)`
// (Tally/Core/ClaudeStatePath.swift), because the app reads the same file for the same dirs. Get
// that path wrong and this seeds nothing, which looks exactly like "nothing was trusted yet".

/// The trust seed to write into a new account's state: every path the source account has ACCEPTED,
/// each reduced to that single fact.
///
/// Reduced rather than copied. The source entries carry per-project history (onboarding counters,
/// last version, shutdown state) and the file around them carries the account's identity; none of
/// that belongs to the new account, and a copy that took the whole map would be one edit away from
/// carrying `oauthAccount` too. Paths that were never accepted are left out entirely, so the new
/// account asks about them exactly as the old one did.
func trustedProjectSeed(fromState raw: Data) -> [String: [String: Bool]] {
    guard let root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
          let projects = root["projects"] as? [String: Any] else { return [:] }
    var seed: [String: [String: Bool]] = [:]
    for (path, entry) in projects {
        guard let entry = entry as? [String: Any],
              entry["hasTrustDialogAccepted"] as? Bool == true else { continue }
        seed[path] = ["hasTrustDialogAccepted": true]
    }
    return seed
}

/// Write the seed into a config dir that has no state file yet.
///
/// Returns the number of paths seeded, or 0 when there was nothing to do. Never overwrites: an
/// existing file belongs either to a real account or to an aborted login that already has its own
/// answers, and this is a convenience, not a migration. Best-effort throughout, like every other
/// side errand `tally add` runs before handing the terminal over: a failure here must cost the user
/// a trust prompt, never the login they actually asked for.
@discardableResult
func seedFolderTrust(from source: URL, to target: URL) -> Int {
    let targetFile = claudeStateFile(forConfigDir: target)
    guard !FileManager.default.fileExists(atPath: targetFile.path),
          let raw = try? Data(contentsOf: claudeStateFile(forConfigDir: source)) else { return 0 }
    let seed = trustedProjectSeed(fromState: raw)
    guard !seed.isEmpty,
          let body = try? JSONSerialization.data(withJSONObject: ["projects": seed]) else { return 0 }
    try? FileManager.default.createDirectory(at: targetFile.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    guard (try? body.write(to: targetFile, options: .atomic)) != nil else { return 0 }
    return seed.count
}

/// How many paths a state file carries IF it is still exactly what `seedFolderTrust` wrote, and nil
/// for anything else.
///
/// The shape is the signature: the seed is one top-level key (`projects`) whose every entry is the
/// single fact `hasTrustDialogAccepted: true`. Claude Code writing to that file at all adds its own
/// top-level fields (`userID`, `oauthAccount`, …) and its own per-project history, and a user who
/// edited it by hand leaves something else again. So anything that fails this test belongs to
/// somebody, and the undo below leaves it alone.
func untouchedTrustSeedCount(_ raw: Data) -> Int? {
    guard let root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
          root.count == 1, let projects = root["projects"] as? [String: Any],
          !projects.isEmpty else { return nil }
    for (_, entry) in projects {
        guard let entry = entry as? [String: Any], entry.count == 1,
              entry["hasTrustDialogAccepted"] as? Bool == true else { return nil }
    }
    return projects.count
}

/// Undo a seed an earlier, shared run wrote into a home this run is preparing UNSHARED.
///
/// Returns the number of paths removed, 0 when there was nothing of ours to remove. The counterpart
/// to `unlinkSharedHarness`, and for the same reason: a first attempt at adding an account defaults
/// to sharing, an aborted one leaves its home to be resumed, and opting out on the retry has to undo
/// what that first attempt put there. Without this the new account skips the trust prompt for every
/// project the main account vouched for, while the sheet says it starts empty.
///
/// Only ever removes a file that is still exactly the seed (`untouchedTrustSeedCount`): once the
/// account or the user has written to it, it is theirs.
@discardableResult
func removeSeededFolderTrust(from target: URL) -> Int {
    let file = claudeStateFile(forConfigDir: target)
    guard let raw = try? Data(contentsOf: file), let count = untouchedTrustSeedCount(raw),
          (try? FileManager.default.removeItem(at: file)) != nil else { return 0 }
    return count
}
