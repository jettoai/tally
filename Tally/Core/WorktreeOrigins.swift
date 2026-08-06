import Foundation

/// Which repository a worktree belonged to, remembered past the worktree's own removal.
///
/// Attribution normally reads the filesystem: a worktree's `.git` file names the repository it was
/// cut from, so `TokenProjectMap` can fold the parallel line's usage into the repository's row.
/// Teardown deletes that file. Keeping the transcripts (the default since `--purge-transcripts`
/// became the way to ask for deletion) is therefore only half of keeping the history: attribution
/// is rebuilt from scratch on every full rescan, which a cache version bump forces, and by then
/// nothing on disk says where those sessions were working. They would land in the pooled Other row
/// and the repository's own recorded history would shrink anyway, which is exactly what keeping the
/// transcripts was meant to prevent.
///
/// So teardown writes the fact down while it still knows it, and the map reads it back. The file is
/// `~/.tally/worktree-origins.json`, versioned and additive like the other app-CLI contracts in that
/// folder, and written by the CLI while being read by the app: both targets compile this one file
/// rather than keeping two spellings of the same record.
struct WorktreeOrigin: Codable, Sendable, Equatable {
    /// The worktree directory as git recorded it (which may be a symlinked spelling).
    var worktree: String
    /// Its fully resolved path, when that differs: a transcript records the working directory the
    /// process really had, so both spellings have to be claimable.
    var resolved: String?
    /// The repository it was cut from, resolved.
    var repository: String
    /// When teardown removed it. Informational, and what the newest-first cap is judged by.
    var removedAt: String?

    /// Every spelling of the worktree directory this record can answer for.
    var paths: [String] {
        guard let resolved, resolved != worktree else { return [worktree] }
        return [worktree, resolved]
    }
}

enum WorktreeOrigins {
    /// How many records are kept. One line per worktree ever torn down would otherwise grow without
    /// bound, and the oldest are the ones whose transcripts are most likely already gone.
    static let limit = 500

    /// `~/.tally/worktree-origins.json`. The home is a parameter so a fixture tree can be used
    /// (tests/tokenprojectmap, tests/worktree); every caller in the app and the CLI takes the
    /// default, which is the same real file for both.
    static func fileURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".tally/worktree-origins.json")
    }

    /// The records on file, oldest first; empty when the file is absent or unreadable. Fail-open in
    /// the same direction as the rest of attribution: not knowing costs a row, and a decode that
    /// threw would cost the whole table.
    static func load(from url: URL = fileURL()) -> [WorktreeOrigin] {
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data)
        else { return [] }
        return document.entries
    }

    /// Add one record, replacing any earlier record for the same worktree path (a directory name is
    /// reusable, and the repository it belonged to last is the one that answers for it), dropping
    /// records whose repository is no longer on disk, and keeping the newest `limit`.
    ///
    /// Written atomically, because the app reads this file on a background scan while the CLI is
    /// writing it: a reader that caught a half-written file would drop every origin at once.
    /// Failure is silent by design - teardown must never fail over its own bookkeeping.
    static func record(_ origin: WorktreeOrigin, in url: URL = fileURL()) {
        var entries = load(from: url).filter { existing in
            existing.worktree != origin.worktree
                && FileManager.default.fileExists(atPath: existing.repository)
        }
        entries.append(origin)
        entries = Array(entries.suffix(limit))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Document(version: 1, entries: entries)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The file itself. `version` is written, never gated on: the contract is additive, so a reader
    /// from an older app must keep understanding the entries a newer one wrote.
    private struct Document: Codable {
        var version: Int
        var entries: [WorktreeOrigin]
    }
}
