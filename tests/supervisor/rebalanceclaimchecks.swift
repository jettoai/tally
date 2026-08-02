import Foundation

// The rebalance claim, split out of rebalancechecks.swift for file size: which supervisor gets to
// make the one move a drought allows, and everything that decides that answer (the record on disk,
// the tolerance that keeps one reported window from reading as two, the refusal to move on a
// directory it cannot read, and the lock the whole decision runs under).
//
// Called from `runRebalanceChecks` rather than from main.swift, so it still runs between the cycle
// key it builds on (26c) and the live tick that takes a claim of its own (26e), and so 26c's weekly
// drought can be handed straight in.

/// What 32 racing threads share while they pile up behind one barrier and then claim at once. Held
/// in a reference because the barrier has to be released AFTER the threads have captured it, which a
/// captured `var` cannot be (Swift warns, correctly, that they would be mutating a copy).
private final class ClaimRace {
    let gate = NSCondition()
    var ready = 0, done = 0, wins = 0, released = false
}

/// Whether a claim for this account and cycle is on disk. Shared with 26e over in
/// rebalancechecks.swift, which takes claims through the live tick.
func claimExists(_ accountID: String, cycle: String, in dir: URL) -> Bool {
    FileManager.default.fileExists(atPath: dir
        .appendingPathComponent(rebalanceClaimName(accountID, cycle: cycle)).path)
}

func runRebalanceClaimChecks(primaryModel primary: String, weeklyCycle: String,
                             afterSessionRefill: Snapshot.Account) {
    // MARK: - 26d. The shared claim

    let recordDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-rebalance-\(UUID().uuidString)")
    let cycleOne = "1800000000", cycleTwo = "1800360000"
    check("the first supervisor to ask for an untouched cycle gets it",
          claimRebalanceCycle("acct-1", cycle: cycleOne, dir: recordDir))
    check("and every one after it is refused",
          !claimRebalanceCycle("acct-1", cycle: cycleOne, dir: recordDir))
    check("another account is unaffected",
          claimRebalanceCycle("acct-2", cycle: cycleOne, dir: recordDir))
    check("and the window resetting re-arms it: a new cycle is a fresh opportunity",
          claimRebalanceCycle("acct-1", cycle: cycleTwo, dir: recordDir))
    check("which is then held in its turn",
          !claimRebalanceCycle("acct-1", cycle: cycleTwo, dir: recordDir))
    // An id with a slash must not write one file and read another (the quarantine's rule next door).
    check("an id with a slash claims once", claimRebalanceCycle("team/acct", cycle: cycleOne,
                                                                dir: recordDir))
    check("and not twice", !claimRebalanceCycle("team/acct", cycle: cycleOne, dir: recordDir))
    // Ids on this machine carry dots ("claude:.claude3"), and the cycle is whole seconds, so the
    // account half of a claim's name is everything before the LAST dot and nothing is ambiguous.
    check("a dotted id claims once", claimRebalanceCycle("claude:.claude3", cycle: cycleOne,
                                                         dir: recordDir))
    check("and not twice", !claimRebalanceCycle("claude:.claude3", cycle: cycleOne, dir: recordDir))
    check("without disturbing the account whose id is its prefix",
          claimRebalanceCycle("claude:", cycle: cycleOne, dir: recordDir))

    // A dying drought does not re-arm when some other window refills under it: the cycle key is the
    // same, so the claim taken during it still holds (26c's weekly drought, five minutes on).
    check("the drought's claim is taken once",
          claimRebalanceCycle("acct-drought", cycle: weeklyCycle, dir: recordDir))
    check("and a session window refilling under it does not hand out a second move",
          !claimRebalanceCycle("acct-drought",
                               cycle: rebalanceCycleKey(afterSessionRefill, primaryModel: primary,
                                                        now: launch.addingTimeInterval(6 * 60))!,
                               dir: recordDir))

    // Claims from cycles that are over are dropped as they are noticed, so the directory does not
    // grow one file per window cycle forever. The cycle being claimed is never swept: a reset time
    // the snapshot has not caught up with is in the past and still the cycle we are in.
    let past = "1000000000"   // a reset in 2001: over by any clock this ever runs on
    _ = claimRebalanceCycle("acct-sweep", cycle: past, dir: recordDir)
    check("a claim lands on disk", claimExists("acct-sweep", cycle: past, in: recordDir))
    _ = claimRebalanceCycle("acct-sweep", cycle: cycleTwo, dir: recordDir)
    check("a claim whose reset has come and gone is swept on the way past",
          !claimExists("acct-sweep", cycle: past, in: recordDir))
    check("but the one just taken is not",
          claimExists("acct-sweep", cycle: cycleTwo, in: recordDir))
    check("and so it still holds", !claimRebalanceCycle("acct-sweep", cycle: cycleTwo,
                                                        dir: recordDir))
    check("a sweep for one account leaves another account's claims alone",
          claimExists("acct-1", cycle: cycleTwo, in: recordDir))

    // Records written before the claim existed (a bare per-account file whose body is the cycle) sit
    // in ~/.tally/rebalance on every machine that has run this feature. One is honoured for the
    // cycle it names, so upgrading mid-drought does not hand out a second move, and dropped once it
    // names a cycle that is over.
    func writeLegacy(_ accountID: String, cycle: String) {
        try? cycle.write(to: recordDir.appendingPathComponent(rebalanceRecordName(accountID)),
                         atomically: true, encoding: .utf8)
    }
    writeLegacy("acct-legacy", cycle: cycleOne)
    check("a record from the old shape still blocks its own cycle",
          !claimRebalanceCycle("acct-legacy", cycle: cycleOne, dir: recordDir))
    check("but not another one", claimRebalanceCycle("acct-legacy", cycle: cycleTwo,
                                                     dir: recordDir))
    check("and it is dropped on the way past, not left to block forever",
          !FileManager.default.fileExists(atPath: recordDir
              .appendingPathComponent(rebalanceRecordName("acct-legacy")).path))

    // MARK: - 26d-jitter. A reported reset that moves is still one drought

    // Reset times are parsed out of `/usage`'s human text, whose finest unit is the minute, so one
    // unbroken window is reported a minute later or earlier as the underlying instant rounds one way
    // or the other. Matching cycles by equality read that wobble as a new cycle and handed the
    // account a second move: Claude 2's session window at 1% moved two sessions ten minutes apart on
    // 2026-08-02, leaving claims for that ONE window at 06:39:00Z and 06:40:00Z, and Claude's spent
    // weekly did the same twenty-four minutes apart (16:59:00Z and 17:00:00Z) the same morning.
    // Dated well ahead so no claim here is ever swept for being over on the wall clock: what these
    // assert is the OFFSETS, and the incident's own two claims were 60s apart in exactly this way.
    // The expired case has its own account below, where being in the past is the point.
    let reported = 1_900_000_000.0
    func jitterClaim(_ accountID: String, _ offset: Double) -> Bool {
        claimRebalanceCycle(accountID, cycle: String(Int(reported + offset)), dir: recordDir)
    }
    check("the drought's claim is taken", jitterClaim("acct-jitter", 0))
    check("the same window reported a minute later is not a second move",
          !jitterClaim("acct-jitter", 60))
    check("nor is a minute earlier", !jitterClaim("acct-jitter", -60))
    check("nor anything else inside the tolerance",
          !jitterClaim("acct-jitter", rebalanceCycleTolerance))
    // Nothing lands on disk for the moves that were refused, so the near miss cannot come back as a
    // record of its own.
    check("a refused near miss leaves no claim behind",
          !claimExists("acct-jitter", cycle: String(Int(reported + 60)), in: recordDir))
    // The re-arm the tolerance must not swallow: windows are hours long, so a genuine new cycle is
    // never a few minutes away. The 5h session window is the shortest one there is.
    check("the window actually resetting five hours on is a new drought",
          jitterClaim("acct-jitter", 5 * 3600))
    check("which is then held in its turn", !jitterClaim("acct-jitter", 5 * 3600))
    check("and the drought before it still holds too", !jitterClaim("acct-jitter", 0))

    // A claim whose reset has passed is normally swept, but not while it is still THIS drought's:
    // a reset time the snapshot has not caught up with is in the past and still the cycle we are in,
    // which is exactly the case the tolerance exists for.
    check("a claim from a past drought is taken", claimRebalanceCycle("acct-jitter-past",
                                                                      cycle: past, dir: recordDir))
    check("and a reading a minute off it is still the same drought, expired or not",
          !claimRebalanceCycle("acct-jitter-past", cycle: String(Int(past)! + 60), dir: recordDir))
    check("so the claim survives the sweep it walked past",
          claimExists("acct-jitter-past", cycle: past, in: recordDir))

    // The pre-claim shape carries a cycle in its BODY and one is live on this machine
    // (~/.tally/rebalance/claude:.claude3), so it must not hand out the second move either.
    writeLegacy("acct-legacy-jitter", cycle: String(Int(reported)))
    check("a record from the old shape blocks a reading a minute off its own",
          !claimRebalanceCycle("acct-legacy-jitter", cycle: String(Int(reported + 60)),
                               dir: recordDir))
    check("and is still dropped once the window really has reset",
          claimRebalanceCycle("acct-legacy-jitter", cycle: String(Int(reported + 5 * 3600)),
                              dir: recordDir))

    // The whole point of the claim: N supervisors whose 2s ticks land in the same window ask at
    // once, and exactly one of them moves. A read followed by a write leaves the gap this closes.
    let racers = 32
    /// How many of `racers` threads win, all of them released from a barrier together. `cycle` names
    /// the key each racer carries, so one round can put them all on one reading of the drought or
    /// split them across two.
    func racedWins(account: String = "acct-race", count: Int = racers,
                   cycle: (Int) -> String) -> Int {
        let race = ClaimRace()
        for racer in 0 ..< count {
            let key = cycle(racer)
            Thread {
                race.gate.lock()
                race.ready += 1
                race.gate.broadcast()
                while !race.released { race.gate.wait() }
                race.gate.unlock()
                let won = claimRebalanceCycle(account, cycle: key, dir: recordDir)
                race.gate.lock()
                if won { race.wins += 1 }
                race.done += 1
                race.gate.broadcast()
                race.gate.unlock()
            }.start()
        }
        race.gate.lock()
        while race.ready < count { race.gate.wait() }   // every thread is parked on the barrier
        race.released = true
        race.gate.broadcast()
        while race.done < count { race.gate.wait() }
        race.gate.unlock()
        return race.wins
    }
    // Repeated, because one round is a weak instrument: waking 32 threads through one lock lets them
    // out in a staggered line, so a read-then-write claim can still happen to hand out exactly one
    // move (measured 5, 2 and 1 winners on three runs of a deliberately broken build). An atomic
    // claim answers 1 in every round by construction, so requiring that of all of them turns a
    // coin-flip into a check that a torn claim cannot pass.
    // An hour apart, because rounds are meant to be DISTINCT droughts and a claim now holds for
    // every key within a few minutes of it (26d-jitter above).
    let rounds = (0 ..< 8).map { round in
        racedWins { _ in String(1_800_000_000 + round * 3600) }
    }
    check("exactly one of 32 simultaneous supervisors claims the cycle, every round (won: \(rounds))",
          rounds.allSatisfy { $0 == 1 })

    // And the harder half of the same question, which the one-syscall claim could not answer: the
    // racers do NOT agree on the key. Supervisors reading either side of a snapshot refresh hold two
    // readings of ONE drought, a minute apart, and `O_EXCL` arbitrates a NAME - so each side found
    // nothing near its own key, each created a different file, and both moved (two winners in every
    // round, 2026-08-02 second review). Exactly one may win however the readings are split.
    let split = (0 ..< 8).map { round in
        racedWins(account: "acct-split-race") { racer in
            String(1_900_100_000 + round * 3600 + (racer % 2) * 60)
        }
    }
    check("exactly one wins even when the supervisors disagree about the minute (won: \(split))",
          split.allSatisfy { $0 == 1 })

    // The same race started from the state a killed supervisor leaves behind. Under a lock the
    // winner created and deleted, that state was a problem to be reaped, and the reaping was itself
    // a race: a reaper deletes whatever sits at the path, which by then can be the NEXT holder's
    // lock. Under `flock` the debris is just a lock file nobody holds, which is also the steady
    // state after any successful claim, so it is not a special case at all - it is asserted here
    // because it was one, and 64 racers because the reaper's window was widest under load.
    let debris = (0 ..< 8).map { round -> Int in
        let lock = recordDir.appendingPathComponent("acct-debris-race.lock")
        try? Data().write(to: lock)   // left behind by a supervisor that never came back
        return racedWins(account: "acct-debris-race", count: 64) { racer in
            String(1_900_200_000 + round * 3600 + (racer % 2) * 60)
        }
    }
    check("exactly one wins from a dead supervisor's leftovers too (won: \(debris))",
          debris.allSatisfy { $0 == 1 })

    // MARK: - 26d-blind. Not being able to look is not the same as nothing being there

    // Every other obstacle in this file answers "stay put", and so must an unreadable directory: a
    // scan read as an empty one is the one way the claim can grant a move it has no evidence for.
    // 0o300 is the shape that makes the difference visible - entries can still be CREATED, so a
    // fail-open claim would sail through and write itself a record it never looked for.
    let blindDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-rebalance-blind-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: blindDir, withIntermediateDirectories: true)
    check("a claim lands while the directory can be read",
          claimRebalanceCycle("acct-blind", cycle: cycleOne, dir: blindDir))
    try? FileManager.default.setAttributes([.posixPermissions: 0o300],
                                           ofItemAtPath: blindDir.path)
    let blindCycle = String(Int(cycleOne)! + 5 * 3600)
    check("a directory that cannot be listed refuses rather than granting a blind move",
          !claimRebalanceCycle("acct-blind", cycle: blindCycle, dir: blindDir))
    try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                           ofItemAtPath: blindDir.path)
    check("and the refusal left nothing behind", !claimExists("acct-blind", cycle: blindCycle,
                                                              in: blindDir))
    check("while the claim it could not see is still there",
          claimExists("acct-blind", cycle: cycleOne, in: blindDir))
    // A refusal is not a strand: the section releases its lock on the way out however it answered,
    // so the account claims normally the moment the directory can be read again.
    check("and the account is free again once it can be read",
          claimRebalanceCycle("acct-blind", cycle: blindCycle, dir: blindDir))
    try? FileManager.default.removeItem(at: blindDir)

    // MARK: - 26d-lock. The lock the decision runs under

    // Contention loses rather than waits: a supervisor already inside the section is about to answer
    // this same question, so waiting for it would only be a slower way to be refused.
    let lockDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-rebalance-lock-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
    let heldLock = lockDir.appendingPathComponent("acct-lock.lock")
    // A supervisor inside the section, held exactly as the code holds it. `flock` excludes per open
    // file description, not per process, so a second descriptor on this same file is refused here
    // for the same reason it would be refused from another process.
    let holder = open(heldLock.path, O_CREAT | O_WRONLY, 0o644)
    check("the lock can be taken at all", holder >= 0 && flock(holder, LOCK_EX | LOCK_NB) == 0)
    check("an account whose decision another supervisor is inside is left alone",
          !claimRebalanceCycle("acct-lock", cycle: cycleOne, dir: lockDir))
    check("and nothing was written while it was locked out",
          !claimExists("acct-lock", cycle: cycleOne, in: lockDir))
    // The release is the kernel's, and it happens on close - which is what a killed supervisor's
    // descriptors do too, so this is also the "died holding it" case. No reaper, no TTL, no debris.
    close(holder)
    check("and claims normally the moment the holder lets go",
          claimRebalanceCycle("acct-lock", cycle: cycleOne, dir: lockDir))
    // INVARIANT: the lock file outlives the section. Two `flock` calls exclude each other only on
    // one inode, so a lock file that gets deleted and re-created is one two holders can both take.
    check("and the lock file is still there afterwards, never unlinked",
          FileManager.default.fileExists(atPath: heldLock.path))
    // Which means the steady state is a lock file nobody holds, on every claim after the first.
    check("a lock file nobody holds does not stand in the way",
          claimRebalanceCycle("acct-lock", cycle: String(Int(cycleOne)! + 5 * 3600), dir: lockDir))
    // And the scan must not read that permanent file as a claim: `lock` is not an epoch. If it did,
    // this account would look like it held a drought it never claimed.
    check("and it is not counted as one of the account's claims",
          !claimRebalanceCycle("acct-lock", cycle: cycleOne, dir: lockDir))
    check("while a genuinely new drought still gets its move",
          claimRebalanceCycle("acct-lock", cycle: String(Int(cycleOne)! + 10 * 3600), dir: lockDir))

    // The one shape that can sit at the lock's path and never open: a DIRECTORY, which is what the
    // lock was while this was a `mkdir` claim, left behind by a supervisor killed holding it. `open`
    // answers EISDIR forever and the reaper went out with the shape, so without this the account
    // would never rebalance again. Only ever seen on a machine that ran that unreleased build, which
    // is exactly the machine this is developed on.
    let debrisLock = lockDir.appendingPathComponent("acct-debris.lock")
    try? FileManager.default.createDirectory(at: debrisLock, withIntermediateDirectories: true)
    check("a directory left at the lock's path does not strand the account",
          claimRebalanceCycle("acct-debris", cycle: cycleOne, dir: lockDir))
    // And it is gone as a directory, replaced by the regular file every other tick expects, so the
    // next tick takes the ordinary path rather than clearing debris again.
    var isDirectory: ObjCBool = true
    check("and the path is a plain lock file from then on",
          FileManager.default.fileExists(atPath: debrisLock.path, isDirectory: &isDirectory)
              && !isDirectory.boolValue)
    check("which the next tick uses without ceremony",
          claimRebalanceCycle("acct-debris", cycle: String(Int(cycleOne)! + 5 * 3600), dir: lockDir))
    // A directory with something in it is somebody else's data: `rmdir` refuses it, so the retry
    // fails too and the account stays put. Refusing is the answer to every obstacle here, and the
    // one thing that must not happen is taking the section without the lock.
    let occupied = lockDir.appendingPathComponent("acct-occupied.lock")
    try? FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
    try? Data().write(to: occupied.appendingPathComponent("someone-elses-file"))
    check("a lock path occupied by a non-empty directory refuses rather than moving",
          !claimRebalanceCycle("acct-occupied", cycle: cycleOne, dir: lockDir))
    check("and nothing was claimed on the way past",
          !claimExists("acct-occupied", cycle: cycleOne, in: lockDir))
    check("while the directory it could not clear is untouched",
          FileManager.default.fileExists(atPath: occupied
              .appendingPathComponent("someone-elses-file").path))
    try? FileManager.default.removeItem(at: lockDir)
    try? FileManager.default.removeItem(at: recordDir)
}
