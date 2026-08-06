import Foundation

// Group 21 of the worktree assertions: the origins ledger every teardown writes through
// (Tally/Core/WorktreeOrigins.swift), split out of teardownchecks.swift for file size. Runs as one
// function that group calls, and uses the shared harness main.swift owns (`check`, `tempDir`).

/// A file's contents and modification time together, which is what "this was not rewritten" has to
/// mean here: a writer that rewrote the ledger with the records it already held would leave the
/// bytes identical and move the timestamp, so comparing either one alone would pass over it.
private func fileStamp(_ url: URL) -> String {
    let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
    return "\((modified as? Date)?.timeIntervalSince1970 ?? 0)\n\(contents)"
}

func runOriginsChecks() {
    // Its own file, so these assertions read a ledger nothing else in this run has written, and
    // never `~/.tally/worktree-origins.json`: a test must not write into the record the running app
    // reads.
    let ledger = URL(fileURLWithPath: tempDir()).appendingPathComponent("origins.json")

    // A repository that is not on disk right now keeps its note. Teardowns happen one worktree at a
    // time while other repositories may be momentarily unreachable (an external disk unmounted, a
    // stale symlink, a checkout being moved), and the note is the only surviving record of where
    // those sessions worked: an unrelated teardown must not be what deletes it. The reader already
    // skips repositories it cannot place, so nothing downstream is paying for the extra lines.
    WorktreeOrigins.record(WorktreeOrigin(worktree: "/gone/repo-feat", resolved: nil,
                                          repository: "/gone/repo",
                                          removedAt: "2026-08-06T00:00:00Z"),
                           in: ledger)
    WorktreeOrigins.record(WorktreeOrigin(worktree: "/here/repo-feat", resolved: nil,
                                          repository: "/here/repo", removedAt: nil),
                           in: ledger)
    check("a later teardown does not evict the note of a repository that is offline right now",
          WorktreeOrigins.load(from: ledger).contains { $0.repository == "/gone/repo" })
    check("and the note that later teardown wrote is on file too",
          WorktreeOrigins.load(from: ledger).contains { $0.worktree == "/here/repo-feat" })

    // The one thing that does evict: the same worktree path recorded again. A worktree directory
    // name is reusable, and the repository it belonged to last is the one that answers for it.
    WorktreeOrigins.record(WorktreeOrigin(worktree: "/here/repo-feat", resolved: nil,
                                          repository: "/other/repo", removedAt: nil),
                           in: ledger)
    let reRecorded = WorktreeOrigins.load(from: ledger).filter { $0.worktree == "/here/repo-feat" }
    check("re-recording one worktree path replaces its note instead of duplicating it",
          reRecorded.count == 1 && reRecorded.first?.repository == "/other/repo")

    // A record supersedes an earlier one naming the same directory in ANY of its spellings, not
    // just the same `worktree` string. The scan writes a worktree under the workspace folder's
    // spelling while teardown writes it under the one git recorded, and on a machine where those
    // differ (a workspace folder reached through a symlink) two spellings of one directory would
    // otherwise both sit in the file, one of them saying it is still open.
    WorktreeOrigins.record(WorktreeOrigin(worktree: "/link/repo-two", resolved: "/real/repo-two",
                                          repository: "/real/repo", removedAt: nil),
                           in: ledger)
    WorktreeOrigins.record(WorktreeOrigin(worktree: "/real/repo-two", resolved: nil,
                                          repository: "/real/repo",
                                          removedAt: "2026-08-06T01:00:00Z"),
                           in: ledger)
    let bySpelling = WorktreeOrigins.load(from: ledger).filter { $0.paths.contains("/real/repo-two") }
    check("a record replaces an earlier one that named the same directory by another spelling",
          bySpelling.count == 1 && bySpelling.first?.removedAt != nil)

    // Recording several at once is one read-modify-write, not one per record: the scan side hands
    // over everything it saw in a single call.
    let batchLedger = URL(fileURLWithPath: tempDir()).appendingPathComponent("origins.json")
    WorktreeOrigins.recordAll([
        WorktreeOrigin(worktree: "/b/one", resolved: nil, repository: "/b/repo", removedAt: nil),
        WorktreeOrigin(worktree: "/b/two", resolved: nil, repository: "/b/repo", removedAt: nil),
    ], in: batchLedger)
    check("a batch write keeps every record in it",
          Set(WorktreeOrigins.load(from: batchLedger).map(\.worktree)) == ["/b/one", "/b/two"])
    WorktreeOrigins.recordAll([], in: batchLedger)
    check("an empty batch writes nothing at all",
          WorktreeOrigins.load(from: batchLedger).count == 2)

    // What a repeating writer does instead of writing. The app's scan recomputes the same notes for
    // the same live worktrees on every pass, so only a changed answer is news - and the comparison
    // happens inside the write lock, not against a snapshot read before it.
    let held = WorktreeOrigins.load(from: batchLedger)
    let batchStamp = fileStamp(batchLedger)
    usleep(20_000)
    WorktreeOrigins.recordNew([held[0]], in: batchLedger)
    check("recording what the ledger already holds does not touch the file",
          fileStamp(batchLedger) == batchStamp)
    WorktreeOrigins.recordNew([WorktreeOrigin(worktree: held[0].worktree, resolved: nil,
                                              repository: "/b/elsewhere", removedAt: nil)],
                              in: batchLedger)
    check("but the same directory cut from a different repository is news",
          WorktreeOrigins.load(from: batchLedger)
            .first { $0.worktree == held[0].worktree }?.repository == "/b/elsewhere")

    // The ordering rule between the two kinds of writer. A teardown records that a worktree is gone;
    // a scan that started before it (or `tally claude -w` from a stale read) would then write its
    // own live note over the top, losing the removal time and reopening a line that is closed. The
    // live writer never displaces a stamped record of the same directory and repository.
    let stampedLedger = URL(fileURLWithPath: tempDir()).appendingPathComponent("origins.json")
    WorktreeOrigins.record(WorktreeOrigin(worktree: "/s/repo-feat", resolved: nil,
                                          repository: "/s/repo",
                                          removedAt: "2026-08-06T03:00:00Z"),
                           in: stampedLedger)
    WorktreeOrigins.recordNew([WorktreeOrigin(worktree: "/s/repo-feat", resolved: nil,
                                              repository: "/s/repo", removedAt: nil)],
                              in: stampedLedger)
    let stamped = WorktreeOrigins.load(from: stampedLedger).filter { $0.worktree == "/s/repo-feat" }
    check("a live note does not overwrite the teardown record of the same worktree",
          stamped.count == 1 && stamped.first?.removedAt == "2026-08-06T03:00:00Z")
    // Unless it really is a different parallel line now: the directory name was reused by another
    // repository, and the newest answer is the one that answers for it.
    WorktreeOrigins.recordNew([WorktreeOrigin(worktree: "/s/repo-feat", resolved: nil,
                                              repository: "/s/other", removedAt: nil)],
                              in: stampedLedger)
    check("while the same path cut from another repository still supersedes it",
          WorktreeOrigins.load(from: stampedLedger)
            .first { $0.worktree == "/s/repo-feat" }?.repository == "/s/other")

    // Deleting notes, which is what `--purge-transcripts` does with the note its worktree was
    // opened under: the conversation it pointed at is being deleted, so the record has to go too
    // rather than keep crediting a path whose transcripts no longer exist.
    let purgeLedger = URL(fileURLWithPath: tempDir()).appendingPathComponent("origins.json")
    WorktreeOrigins.recordAll([
        WorktreeOrigin(worktree: "/p/repo-one", resolved: "/private/p/repo-one",
                       repository: "/p/repo", removedAt: nil),
        WorktreeOrigin(worktree: "/p/repo-two", resolved: nil, repository: "/p/repo",
                       removedAt: nil),
    ], in: purgeLedger)
    // Matched on the resolved spelling, which is the one teardown holds when git recorded the other.
    WorktreeOrigins.removeAll(matching: ["/private/p/repo-one"], in: purgeLedger)
    let afterPurge = WorktreeOrigins.load(from: purgeLedger)
    check("removing a note takes the record that answers for that directory in any spelling",
          !afterPurge.contains { $0.worktree == "/p/repo-one" })
    check("and leaves every other repository's notes alone",
          afterPurge.contains { $0.worktree == "/p/repo-two" })

    let purgeStamp = fileStamp(purgeLedger)
    usleep(20_000)
    WorktreeOrigins.removeAll(matching: ["/p/nothing-here"], in: purgeLedger)
    check("removing a note that is not there does not rewrite the file",
          fileStamp(purgeLedger) == purgeStamp)
    WorktreeOrigins.removeAll(matching: [], in: purgeLedger)
    check("and an empty removal is a no-op too", fileStamp(purgeLedger) == purgeStamp)

    // A purge of a worktree from a machine that has no ledger at all must not conjure one, nor the
    // lock file beside it: teardown's bookkeeping never creates the thing it is bookkeeping about.
    let absent = URL(fileURLWithPath: tempDir()).appendingPathComponent("origins.json")
    WorktreeOrigins.removeAll(matching: ["/a/repo-feat"], in: absent)
    check("removing from a ledger that does not exist creates neither it nor its lock",
          !FileManager.default.fileExists(atPath: absent.path)
            && !FileManager.default.fileExists(atPath: WorktreeOrigins.lockURL(for: absent).path))

    // MARK: The launch side writes the same note

    // `tally claude -w` records where a worktree came from when it OPENS one, which is what covers
    // a parallel line that never goes out through teardown (a bare `git worktree remove`, or the
    // directory deleted by hand): by then nothing on disk says whose line it was, and its kept
    // transcripts would pool into Other.
    let launchLedger = URL(fileURLWithPath: tempDir()).appendingPathComponent("origins.json")
    let launched = WorktreeLaunch(mainRepo: "/w/repo", path: "/w/repo-feat", name: "feat",
                                  created: true)
    recordWorktreeOrigin(launched, in: launchLedger)
    let launchNote = WorktreeOrigins.load(from: launchLedger).first { $0.worktree == "/w/repo-feat" }
    check("opening a worktree records the repository it was cut from",
          launchNote?.repository == "/w/repo")
    check("and records it as still open (no removal time)", launchNote?.removedAt == nil)

    // Re-entering the same worktree is the ordinary case (a session resumed day after day) and has
    // nothing new to say, so it must not rewrite the file.
    let launchStamp = fileStamp(launchLedger)
    usleep(20_000)
    recordWorktreeOrigin(launched, in: launchLedger)
    check("re-entering an already recorded worktree does not rewrite the ledger",
          fileStamp(launchLedger) == launchStamp)

    // That the launch is WIRED to it, which the seam above cannot show: `enterWorktree` resolves a
    // worktree, links shared memory into the real account homes and chdirs, so calling it here
    // would write into the user's own ~/.claude. Read from the source instead, the way the map's
    // suite reads the cache version, so removing the one line that records the origin fails here
    // rather than silently going back to teardown being the only writer.
    let launchSource = (try? String(contentsOfFile: repoRoot + "/TallyCLI/Worktree.swift",
                                    encoding: .utf8)) ?? ""
    check("entering a worktree calls the recorder",
          launchSource.contains("func enterWorktree(") &&
          launchSource.range(of: "recordWorktreeOrigin(wt)") != nil)

    // And teardown's own record still wins afterwards: same directory, now with a removal time.
    WorktreeOrigins.record(WorktreeOrigin(worktree: "/w/repo-feat", resolved: nil,
                                          repository: "/w/repo",
                                          removedAt: "2026-08-06T02:00:00Z"),
                           in: launchLedger)
    let afterTeardown = WorktreeOrigins.load(from: launchLedger).filter { $0.worktree == "/w/repo-feat" }
    check("teardown's record supersedes the one the launch wrote",
          afterTeardown.count == 1 && afterTeardown.first?.removedAt != nil)

    // Writers serialise on a lock file beside the ledger. Tearing several parallel lines down at
    // once runs several `tally worktree remove` processes over this one file, each reading it,
    // appending and writing it back: the atomic write alone stops a reader from seeing half a file,
    // it does not stop the later writer from overwriting what the earlier one added (measured
    // before the lock: 40 concurrent writers, 2 surviving records).
    check("writing the ledger takes a lock beside it",
          FileManager.default.fileExists(atPath: WorktreeOrigins.lockURL(for: ledger).path))

    // The race itself, run for real. flock is held per open file description rather than per
    // process, so writers racing inside this one contend exactly as separate processes do: every
    // writer's record has to survive, which is deterministic while the lock is there and lossy
    // without it.
    // The repository is a directory that really exists, so that what this measures is the locking
    // and nothing else: a record dropped here can only have been overwritten by another writer.
    let racers = 24
    let raceRepo = tempDir()
    let raceLedger = URL(fileURLWithPath: tempDir()).appendingPathComponent("origins.json")
    DispatchQueue.concurrentPerform(iterations: racers) { index in
        WorktreeOrigins.record(WorktreeOrigin(worktree: "/race/wt-\(index)", resolved: nil,
                                              repository: raceRepo, removedAt: nil),
                               in: raceLedger)
    }
    check("concurrent teardowns each keep their record (no lost update)",
          Set(WorktreeOrigins.load(from: raceLedger).map(\.worktree))
            == Set((0..<racers).map { "/race/wt-\($0)" }))
}
