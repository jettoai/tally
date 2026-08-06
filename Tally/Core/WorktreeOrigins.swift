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

    /// The advisory lock writers hold, `<file>.lock` beside the file itself.
    ///
    /// Readers never take it: the write below is atomic, so a reader either sees the whole previous
    /// file or the whole new one, and taking a lock on the app's background scan would let a stuck
    /// CLI stall the table. Writers need more than atomicity, because each one reads the file,
    /// changes it and writes it back: an atomic write stops a reader from seeing half a file, it
    /// does not stop the second writer from overwriting what the first one added. Tearing down a
    /// fleet of parallel lines at once is exactly the case that does it.
    static func lockURL(for url: URL) -> URL {
        url.appendingPathExtension("lock")
    }

    /// Add one record, replacing any earlier record for the same worktree path (a directory name is
    /// reusable, and the repository it belonged to last is the one that answers for it), and keeping
    /// the newest `limit`.
    ///
    /// Nothing here prunes records whose repository is no longer on disk, deliberately. A repository
    /// can be missing for a moment (an external disk unmounted, a stale symlink, a checkout being
    /// moved) while its notes are still the only record of where those sessions worked, and a note
    /// is unrecoverable once dropped, while the reader already ignores repositories it cannot place
    /// and `limit` already bounds the file. Pruning would buy nothing and could delete another
    /// repository's history on an unrelated teardown.
    ///
    /// Serialised across processes by `lockURL`, then written atomically for the sake of the app
    /// reading it on a background scan. Failure is silent by design, including failure to take the
    /// lock: teardown must never fail over its own bookkeeping, so an unlockable ledger is written
    /// unserialised rather than not written at all.
    static func record(_ origin: WorktreeOrigin, in url: URL = fileURL()) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        withWriteLock(for: url) {
            var entries = load(from: url).filter { $0.worktree != origin.worktree }
            entries.append(origin)
            entries = Array(entries.suffix(limit))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(Document(version: 1, entries: entries)) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Run `body` holding an exclusive `flock` on the ledger's lock file, so that a read-modify-write
    /// of the ledger cannot interleave with another process's. Fail-open in both directions: if the
    /// lock cannot be opened or taken, `body` still runs (see `record`).
    private static func withWriteLock(for url: URL, _ body: () -> Void) {
        let descriptor = open(lockURL(for: url).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return body() }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return body() }
        defer { flock(descriptor, LOCK_UN) }
        body()
    }

    /// The file itself. `version` is written, never gated on: the contract is additive, so a reader
    /// from an older app must keep understanding the entries a newer one wrote.
    private struct Document: Codable {
        var version: Int
        var entries: [WorktreeOrigin]
    }
}
