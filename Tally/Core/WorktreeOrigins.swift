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
/// So the fact is written down while something still knows it, and the map reads it back. Teardown
/// is the last moment that is true, not the only one: a worktree removed by hand (`git worktree
/// remove`, or `rm -rf` on the directory) never reaches teardown at all, and its transcripts would
/// pool exactly as if nothing had been kept. So the note is also written the moment a live worktree
/// is SEEN, by both sides that see one: `tally claude -w` when it opens or reuses a parallel line,
/// and the app's own scan when it folds one into its repository. By the time the directory is gone,
/// whichever way it went, the ledger already says where it belonged.
///
/// The file is `~/.tally/worktree-origins.json`, versioned and additive like the other app-CLI
/// contracts in that folder, and written by both the CLI and the app: both targets compile this one
/// file rather than keeping two spellings of the same record.
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

    /// Add one record. The batch form with one element, so there is a single write rule.
    static func record(_ origin: WorktreeOrigin, in url: URL = fileURL()) {
        recordAll([origin], in: url)
    }

    /// Add records, each replacing any earlier record naming the same directory in any of its
    /// spellings (a directory name is reusable, and the repository it belonged to last is the one
    /// that answers for it; matching on every spelling is what lets the note a teardown writes at
    /// git's recorded path supersede the one a scan wrote at the workspace folder's), and keeping
    /// the newest `limit`.
    ///
    /// A batch rather than a loop because a caller records what it saw in one go: each call is a
    /// read-modify-write of the whole file under a lock, so a fleet of parallel lines would
    /// otherwise rewrite the ledger once per line. Nothing to add writes nothing at all.
    ///
    /// This is the unconditional writer, which teardown uses: its record is the last word on a
    /// worktree and replaces whatever was there. A writer describing a LIVE worktree uses
    /// `recordNew` instead, which must not overwrite that last word.
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
    static func recordAll(_ origins: [WorktreeOrigin], in url: URL = fileURL()) {
        guard !origins.isEmpty else { return }
        update(url) { merged(origins, into: $0) }
    }

    /// Add only the records the ledger does not already answer for, deciding that INSIDE the lock.
    ///
    /// The form the two live-worktree writers use, and the reason it is not `record` behind a
    /// filter: the app's scan sees the same worktrees on every pass and `tally claude -w` re-enters
    /// the same one day after day, so the common case is having nothing to say, and saying it anyway
    /// would put a lock and an atomic write on a background scan. Deciding that from a snapshot read
    /// before the lock is what makes it wrong rather than merely wasteful: between that read and the
    /// write, a teardown can record the same worktree's removal, and a live note computed from the
    /// stale snapshot would then overwrite it inside the lock. So the read, the comparison and the
    /// write are one critical section (`answered` is the comparison), and a live note never displaces
    /// a teardown's own record of the same parallel line.
    static func recordNew(_ origins: [WorktreeOrigin], in url: URL = fileURL()) {
        guard !origins.isEmpty else { return }
        update(url) { entries in
            let fresh = origins.filter { !answered($0, by: entries) }
            return fresh.isEmpty ? nil : merged(fresh, into: entries)
        }
    }

    /// Drop every record naming any of `paths`, in any of its spellings.
    ///
    /// The counterpart of writing a note when a worktree is opened: `--purge-transcripts` says the
    /// conversation is not worth keeping, and once it is deleted there is nothing left to attribute,
    /// so the note has to go with it. Leaving it would outlive both the worktree and its transcripts
    /// and go on crediting that path to a repository, which is wrong the day the path is reused by
    /// something else. A ledger that does not exist is left alone rather than answered with a lock
    /// file beside nothing.
    static func removeAll(matching paths: [String], in url: URL = fileURL()) {
        guard !paths.isEmpty, FileManager.default.fileExists(atPath: url.path) else { return }
        let claimed = Set(paths)
        update(url) { entries in
            let kept = entries.filter { !$0.paths.contains(where: claimed.contains) }
            return kept.count == entries.count ? nil : kept
        }
    }

    /// Read-modify-write the ledger under the write lock: `change` is handed what is on file and
    /// returns what should replace it, or nil to leave the file exactly as it is. The one place the
    /// three writers agree on how a change is made, so "decided the change from what the lock is
    /// holding still" and "nothing to say writes nothing" are properties of the ledger rather than
    /// of each caller (a snapshot read before the lock is what let a scan overwrite a teardown).
    private static func update(_ url: URL, _ change: ([WorktreeOrigin]) -> [WorktreeOrigin]?) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        withWriteLock(for: url) {
            guard let next = change(load(from: url)) else { return }
            write(next, to: url)
        }
    }

    /// Whether the ledger already says what `origin` would say, so writing it adds nothing.
    ///
    /// Two ways it can: the record is held word for word, or the ledger holds a TEARDOWN's record
    /// (one carrying a removal time) of the same directory and the same repository. The second is
    /// the ordering rule between the two kinds of writer. Both agree on the answer that matters -
    /// which repository those transcripts belong to - and only one of them knows the worktree is
    /// gone, so the one that knows more wins and a scan racing it cannot reopen a closed line.
    /// A note naming a DIFFERENT repository is news either way: that directory has been cut anew
    /// from somewhere else, and the newest answer is the one that answers for it.
    private static func answered(_ origin: WorktreeOrigin, by existing: [WorktreeOrigin]) -> Bool {
        let spellings = Set(origin.paths)
        return existing.contains { held in
            held == origin
                || (origin.removedAt == nil && held.removedAt != nil
                    && held.repository == origin.repository
                    && held.paths.contains(where: spellings.contains))
        }
    }

    /// `origins` on top of `existing`, each replacing any record naming the same directory in any of
    /// its spellings, capped at the newest `limit`.
    private static func merged(_ origins: [WorktreeOrigin],
                               into existing: [WorktreeOrigin]) -> [WorktreeOrigin] {
        let claimed = Set(origins.flatMap(\.paths))
        let kept = existing.filter { !$0.paths.contains(where: claimed.contains) }
        return Array((kept + origins).suffix(limit))
    }

    /// Write the whole ledger. Called only with the lock held.
    private static func write(_ entries: [WorktreeOrigin], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Document(version: 1, entries: entries)) else { return }
        try? data.write(to: url, options: .atomic)
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
