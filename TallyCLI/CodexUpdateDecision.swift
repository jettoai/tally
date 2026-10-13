import Foundation

// Whether codex's own startup update menu would come up for this launch, decided the way codex
// decides it (codex-rs/tui/src/updates.rs and update_versions.rs, rust-v0.162.1): the cached
// latest version in <CODEX_HOME>/version.json is newer than the installed one by its first three
// integer fields, it is not the version the user dismissed, and the check is not switched off.
// Split in two so the installed version (a `codex --version` child process) is only asked for when
// the cache already names a candidate.

struct CodexVersionCache: Decodable {
    var latestVersion: String
    var dismissedVersion: String?
    enum CodingKeys: String, CodingKey {
        case latestVersion = "latest_version", dismissedVersion = "dismissed_version"
    }
}

/// codex's `parse_version`: the first three dot-separated fields as integers, nil when any fails
/// (so "0.163.0-alpha.1" is not comparable, exactly as codex treats it).
func codexReleaseTriple(_ version: String) -> [UInt64]? {
    let fields = version.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: ".", omittingEmptySubsequences: false)
    guard fields.count >= 3 else { return nil }
    let parsed = fields.prefix(3).compactMap { UInt64($0) }
    return parsed.count == 3 ? parsed : nil
}

func codexIsNewer(_ latest: String, than installed: String) -> Bool {
    guard let l = codexReleaseTriple(latest), let i = codexReleaseTriple(installed) else { return false }
    return i.lexicographicallyPrecedes(l)
}

/// "codex-cli 0.162.1" -> "0.162.1".
func codexVersionFromOutput(_ output: String) -> String? {
    guard let last = output.split(whereSeparator: { $0 == " " || $0 == "\n" }).last,
          codexReleaseTriple(String(last)) != nil else { return nil }
    return String(last)
}

/// A top-level `check_for_update_on_startup = false` in config.toml (before the first table header).
func codexConfigDisablesUpdateCheck(_ toml: String) -> Bool {
    for raw in toml.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") { return false }
        guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: eq)...].split(separator: "#").first?
            .trimmingCharacters(in: .whitespaces)
        if key == "check_for_update_on_startup" { return value == "false" }
    }
    return false
}

/// Step one: the cached latest version codex would offer, before knowing what is installed. nil
/// when the check is off, the cache is missing or unreadable, its version is not comparable, or the
/// user dismissed exactly that version.
func codexCachedUpdateCandidate(cache: Data?, checkDisabled: Bool) -> String? {
    guard !checkDisabled, let cache,
          let info = try? JSONDecoder().decode(CodexVersionCache.self, from: cache),
          codexReleaseTriple(info.latestVersion) != nil,
          info.dismissedVersion != info.latestVersion else { return nil }
    return info.latestVersion
}

enum CodexUpdateNeed: Equatable {
    case none
    case available(latest: String)
    case installedUnknown(latest: String)
}

/// Step two: the candidate against the installed version. A 0.0.0 source build never gets the menu.
func codexUpdateNeed(candidate: String?, installed: String?) -> CodexUpdateNeed {
    guard let candidate else { return .none }
    guard let installed else { return .installedUnknown(latest: candidate) }
    if codexReleaseTriple(installed) == [0, 0, 0] { return .none }
    return codexIsNewer(candidate, than: installed) ? .available(latest: candidate) : .none
}

func codexUpdateFailureLine(latest: String, reason: String) -> String {
    "Codex \(latest) is available; automatic update failed (\(reason)). Opening without the update menu."
}

/// A failed attempt at `latest` within `window` of `now` suppresses another try.
func codexUpdateBackedOff(attempt: (version: String, failedAt: Date)?, latest: String,
                          now: Date, window: TimeInterval = 6 * 3600) -> Bool {
    guard let attempt, attempt.version == latest else { return false }
    return now.timeIntervalSince(attempt.failedAt) < window
}

// MARK: - The background update (`tally codex-update`, CodexUpdateCommand.swift)

/// The newest version any of these Codex homes would offer, and the home that offers it.
func codexBestCandidate(_ homes: [(home: String, cache: Data?, checkDisabled: Bool)]) -> (home: String, version: String)? {
    homes.compactMap { entry in
        codexCachedUpdateCandidate(cache: entry.cache, checkDisabled: entry.checkDisabled).map { (entry.home, $0) }
    }.max { codexIsNewer($1.1, than: $0.1) }
}

/// Whether `--if-due` should look at all: once an hour, and at once when it never has.
func codexUpdateCheckDue(lastCheckedAt: Date?, now: Date, every: TimeInterval = 3600) -> Bool {
    guard let lastCheckedAt else { return true }
    return now.timeIntervalSince(lastCheckedAt) >= every
}

/// One line of `~/.tally/logs/codex-update.log`: what ran, why, and what came of it.
func codexUpdateLogLine(at: Date, trigger: String, codex: String, from: String?, to: String?,
                        result: String, seconds: Int) -> String {
    var fields: [String: Any] = ["at": ISO8601DateFormatter().string(from: at), "trigger": trigger,
                                 "codex": codex, "result": result, "seconds": seconds]
    fields["from"] = from
    fields["to"] = to
    let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    return String(decoding: data, as: UTF8.self) + "\n"
}
