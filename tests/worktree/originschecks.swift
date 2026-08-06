import Foundation

// Group 21 of the worktree assertions: the origins ledger every teardown writes through
// (Tally/Core/WorktreeOrigins.swift), split out of teardownchecks.swift for file size. Runs as one
// function that group calls, and uses the shared harness main.swift owns (`check`, `tempDir`).

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
