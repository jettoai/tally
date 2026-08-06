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
    /// When teardown removed it. Informational: the file's cap drops the records written longest
    /// ago, which is insertion order, and a record of a LIVE worktree has no removal time at all.
    var removedAt: String?
    /// Whether teardown deleted its transcripts too (`--purge-transcripts`), which makes this a
    /// tombstone rather than an attribution: there is nothing left to credit, so the map skips it.
    ///
    /// A record rather than a deletion because a deletion cannot be defended. A scan that collected
    /// its live worktrees while this one was still on disk writes them after the purge has finished,
    /// and an absent record is indistinguishable from one that was never written: the live note
    /// lands and the dead path is credited to the repository again. A record IS the defence, since
    /// what a writer observed earlier cannot displace what was observed later (`answered`) - while a
    /// worktree genuinely cut anew under the same name afterwards was observed later, so it replaces
    /// this record outright and the flag goes with it. Optional, and absent when false, so an older
    /// reader (or an older ledger) is unchanged by it.
    var purged: Bool?
    /// When the writer OBSERVED what this record states (ISO8601), which is not when it wrote it.
    ///
    /// The ledger is written by three processes that cannot see each other, and a directory name is
    /// reusable, so what is being ordered is not paths but INCARNATIONS of a path: one "cut here,
    /// then removed" lifetime after another. Ordering those by who reached the lock last says the
    /// wrong thing whenever a writer is slower than the fact it carries - a scan that listed the
    /// worktrees, then wrote them a second later, is reporting the world as it was when it looked.
    /// So each writer records when it looked (teardown: the instant it read the `.git` file, which
    /// is `removedAt`; a scan: when its snapshot BEGAN, not when it got to the lock; `tally claude
    /// -w`: the moment of entry, since it is standing in the directory), and `answered` orders by
    /// that. Absent on records written before this field existed, which read as "long ago" - the
    /// conservative direction, since anything that states when it looked is more trustworthy than
    /// something that does not.
    var observedAt: String?

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

    /// The record for a worktree that is being SEEN alive, written by both sides that see one: the
    /// app's scan when it folds a worktree into its repository, and `tally claude -w` when it opens
    /// or re-enters one. One constructor because the two must produce the same record for the same
    /// directory - a launch that spelled it one way and a scan that spelled it another would take
    /// turns overwriting each other, and the shorter spelling would drop a path a transcript can
    /// have recorded. `observedAt` is the caller's, because only the caller knows when it looked:
    /// a scan looked when its snapshot began, a launch is looking right now.
    static func liveNote(worktree: String, repository: String, observedAt: String) -> WorktreeOrigin {
        let resolved = resolvedPath(worktree)
        return WorktreeOrigin(worktree: worktree,
                              resolved: resolved == worktree ? nil : resolved,
                              repository: resolvedPath(repository),
                              removedAt: nil, purged: nil, observedAt: observedAt)
    }

    /// The path a process started at `path` would report as its working directory.
    ///
    /// `realpath(3)` rather than `URL.resolvingSymlinksInPath()`, which strips a leading `/private`
    /// and so returns a spelling no transcript ever contains (TokenProjectMap says the same).
    private static func resolvedPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
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

    /// Read-modify-write the ledger under the write lock: `change` is handed what is on file and
    /// returns what should replace it, or nil to leave the file exactly as it is. The one place both
    /// writers agree on how a change is made, so "decided the change from what the lock is
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
    /// One ordering rule, over the directory's records rather than over its writers: a record is
    /// answered by any record of the same directory that was OBSERVED no earlier than it was
    /// (`observedAt`, falling back to `removedAt` and then to long ago for records written before
    /// that field existed). Nothing here asks which process wrote what, or whether a record carries
    /// a removal time, or whether the repository matches - those were the special cases this
    /// replaces, and each of them was this rule seen from one angle:
    ///
    ///   - a scan still in flight when a teardown stamped the worktree observed the world BEFORE
    ///     the stamp, so its live note is answered and cannot reopen a closed line, or undo a
    ///     tombstone (which was `stamped wins`);
    ///   - a worktree cut anew under a name that had been torn down is observed AFTER the stamp, so
    ///     its note lands and replaces the old record outright, tombstone and all (which the
    ///     stamped-wins rule got backwards, silencing the reused directory for good);
    ///   - a stale note naming another repository loses to the newer record that took the path over
    ///     (which `a different repository is always news` got backwards for as long as it took the
    ///     next scan to correct it).
    ///
    /// A tie goes to what is already on file, so a teardown and a scan that observed the same
    /// instant leave the removal standing.
    ///
    /// Ahead of all that, two ways of holding the same answer already, which keep a repeating writer
    /// silent: the record is held word for word, or the directory is held as a LIVE worktree of the
    /// same repository under at least the spellings this one claims. The second is what makes a scan
    /// free - its notes carry the snapshot's instant, so they are never word for word identical to
    /// last scan's, and without this it would rewrite the ledger on every pass. It asks for the
    /// spellings because a record that claims fewer of them answers for less: the launch side knows
    /// the worktree by its resolved path alone, and letting that answer for the scan's pair would
    /// drop the spelling a transcript may have recorded.
    private static func answered(_ origin: WorktreeOrigin, by existing: [WorktreeOrigin]) -> Bool {
        let clock = ISO8601DateFormatter()
        let spellings = Set(origin.paths)
        let observed = observation(of: origin, clock)
        return existing.contains { held in
            if held == origin { return true }
            guard held.paths.contains(where: spellings.contains) else { return false }
            if held.removedAt == nil, origin.removedAt == nil,
               held.repository == origin.repository,
               spellings.isSubset(of: Set(held.paths)) { return true }
            return observation(of: held, clock) >= observed
        }
    }

    /// When a record's writer looked, for ordering. Records from before `observedAt` fall back to
    /// their removal time, and a live one from back then has neither, so it reads as long ago.
    private static func observation(of origin: WorktreeOrigin,
                                    _ clock: ISO8601DateFormatter) -> Date {
        guard let stamp = origin.observedAt ?? origin.removedAt,
              let date = clock.date(from: stamp) else { return .distantPast }
        return date
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
