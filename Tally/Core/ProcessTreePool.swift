import Darwin
import Foundation

/// WHAT A POOL IS, WHICH A TREE IS NOT, and everything that follows from the difference.
///
/// Split from `ProcessTreeStats.swift` when that file ran out of room, along the seam its own head
/// note already draws: over there a reading is taken of a CLOSED set, where a pid missing from the
/// next one has died and nothing else. A stray pool is open (`ProjectLoadAccounting`): a process
/// joins it by being unclaimed in a project's directory and leaves it by dying, by being adopted
/// back onto a card, or by ceasing to be either of those. Those three read identically from inside
/// the pool, and reading them as one produced every wrong number this file's comments cite.
///
/// So what lives here is the pair of things only an open set needs - what became of a departure, and
/// how two readings of a pool are paired given that answer - while the reading itself, the tree
/// rules, and the rates stay where they are. `ProcessTreeRates.swift` and `ProcessTreeCensus.swift`
/// were the first two cuts along the same line and say so at their own heads.
///
/// PURE, like all three of its neighbours: no process has to exist for the harness to state a case.

/// WHAT BECAME OF A PID A POOL WAS COUNTING AND NO LONGER HOLDS, which is three different things
/// wearing one face (`ProcessResourceSample.pairing(with:departure:)`).
///
/// TWO READERS ANSWER IT AND NEITHER ALONE CAN, because they stop answering at different instants.
/// The process table drops a process the moment it EXITS; `proc_pid_rusage` goes on answering for it
/// until it is COLLECTED, and that second instant is the one where its seconds land in whoever
/// collected it. Measured on this machine (2026-09-01) on a child burning a known 0.765s, read
/// through the very calls this app makes:
///
///     alive                   table Y   rusage Y   collector's child counter 0.000s
///     exited, not collected   table n   rusage Y   collector's child counter 0.000s
///     collected               table n   rusage n   collector's child counter 0.765s
///
/// So a rule that settles on the table settles a tick or more BEFORE the arrival it exists to
/// cancel, and one that settles on `rusage` settles in the same reading as it - except across the
/// microseconds between the two questions, which is the one window this cannot close and which the
/// pool's own credit is carried for (`ProcessTree.cpuPercent`, and `pairing(with:departure:)` below
/// states the width).
enum ProcessDeparture: Equatable {
    /// The table still holds it: it left the pool without dying, which is this app's own feature
    /// succeeding (a job adopted back onto a card) or a process that stopped being unclaimed.
    /// Nothing to settle, and nothing to wait for.
    ///
    /// - Parameter startedAt: when the process ANSWERING NOW began. A pid is handed out again, so
    ///   "the table still holds that number" and "that member is still alive" are two claims and
    ///   only the first was asked; the stamp comes out of the very `proc_bsdinfo` record the answer
    ///   came from, so it costs nothing. Nil only for a fixture that models no identity.
    case living(startedAt: Int64?)
    /// Gone from the table and still answering: it has died and nobody has collected it. Its
    /// seconds are in nobody else's counter yet, so there is nothing to take off yet either.
    case ended
    /// Gone from both, which is the same instant its seconds landed in whoever collected it.
    case collected
}

extension ProcessResourceSample {

    /// THE PAIR A POOL'S NEXT RATE IS TAKEN OVER: the reading to difference `current` against, and
    /// the reading to keep for the tick after this one. For a pool a process can join and leave
    /// without being born or dying.
    ///
    /// A TREE IS A CLOSED SET AND A STRAY POOL IS NOT, which is the whole of why this exists. A pid
    /// leaves a tree by ending, so a pid missing from the second reading has DIED, and taking its
    /// counters off is what stops the collection being counted twice (`ProcessTree.cpuPercent`).
    /// A pid leaves a project's stray pool three ways: it ended, it was adopted back onto a card
    /// (which is this app's own feature succeeding), or it stopped being unclaimed. Only the first
    /// is a death, and the three had been read as one:
    ///
    ///   - CREDITING THEM ALL blanks the pool for two ticks on every successful adoption, because a
    ///     stray's collector is launchd by construction and its credit - a whole life from birth,
    ///     not an interval - has no arrival to cancel against (measured 2026-09-01, and triggered
    ///     BY the adoption working).
    ///   - CREDITING NONE OF THEM reads a pool member reaping another pool member as fresh work:
    ///     the dead one's whole life lands in the survivor's `ri_child_time` with nothing coming
    ///     off. Measured on the same fixture the row is meant to read 50% on: 6050% at the
    ///     ten-second beat and 30050% at the two, the multiplier being the dead process's lifetime
    ///     over the sampling interval and so unbounded. (This note said 3050% at the ten-second
    ///     beat for two rewrites, which its own formula does not produce: the survivor burns half a
    ///     core, so ten seconds of it plus the dead one's 600 over ten is 6050.) A stray pool is
    ///     parents and children by construction - a shell and its job, a dev server and its
    ///     workers - so reaping inside it is the ordinary case rather than an edge of it.
    ///
    /// AND SETTLING ON THE TABLE HANDS THAT SAME NUMBER BACK ONE TICK LATER, which is why what is
    /// asked here is `ProcessDeparture` rather than a membership or a liveness test. The table drops
    /// a process at its EXIT and the seconds arrive at its COLLECTION, so a credit taken on the
    /// table comes off a tick with no arrival to meet it (clamped to zero, and the row reads 0%),
    /// and the arrival lands on the next tick with nothing left to cancel it: 0% and then 30050% on
    /// the very fixture above, with the death and the collection one tick apart rather than in one
    /// interval.
    ///
    /// So a member that has died and NOT been collected is neither settled nor dropped: it is kept,
    /// at the counters it was last read with, until the machine says it has been collected. The
    /// credit is then produced in the same reading as the arrival it cancels, in every case this
    /// pairing can see.
    ///
    /// THE ONE IT CANNOT SEE IS WHY THE POOL STILL KEEPS A CARRY, where this note used to say the
    /// opposite ("no `ProcessCPUCarry` is kept beside this"). The verdict and the counters are not
    /// one instant: the pool is READ first and each departure asked about afterwards, so a member
    /// collected in between is judged `.collected` against a reading taken before its seconds
    /// landed, and its credit is produced with the arrival still a tick away. Measured 2026-09-02:
    /// `proc_pid_rusage` costs 0.63 microseconds, so the window is 3 to 35 microseconds for a pool
    /// of 5 to 60 against a two-second beat. Rare, and unbounded when it happens, so what a pair
    /// cannot spend is handed to the next exactly as a tree's is (`ProjectLoadAccounting.measure`
    /// holds one per project): 30050% becomes 100% on that fixture, bounded by the interval rather
    /// than by the dead process's age.
    ///
    /// A MEMBER THAT LEFT THE POOL ALIVE IS DROPPED AND NEVER WAITED FOR, which assumes - rather
    /// than establishes - that whoever collects it later is not in this pool. True for the case it
    /// exists for (a job adopted onto a card is collected by the card, or by launchd), and there are
    /// three ways out where it is not: the scratchpad signal adopts a process whose PARENT is still
    /// a stray of the same project (`ProjectLoadAccounting.strays` matches arguments, not orphanhood);
    /// the member's working directory moves under another root while its parent's does not; or
    /// `workingDirectory(of:)` does not answer for it on one tick. In each the survivor reaps it
    /// later, the whole life arrives with no credit to meet it, and the clamp at zero does nothing
    /// because the error is POSITIVE: 30050%, asserted as it stands rather than assumed away
    /// (`projectloadchecks.swift`). Not repaired here because settling across a pool boundary means
    /// one ledger for the machine rather than one per project, which is the design this file avoids.
    ///
    /// AND A PID THAT HAS JUST JOINED STARTS FROM WHERE IT IS. Its counters are cumulative from its
    /// birth, so differenced against nothing they state a whole life as one interval's work: a
    /// long-running process reclassified into the pool the tick its session ended read 180050%.
    /// It is given this reading's own figures as its baseline, so it contributes nothing to the
    /// tick that first sees it and a true rate from the next one.
    ///
    /// WHAT THIS STILL COSTS, stated rather than implied: a pool member whose collector is OUTSIDE
    /// the pool (launchd buried it, or its parent is on a card) hands over a credit nothing will
    /// arrive to cancel, and the clamp at zero means the tick it is collected on reads 0% instead of
    /// what the survivors were doing. One tick, bounded by zero rather than unbounded, and the tick
    /// after it is correct. A member nobody ever collects is waited for as long as its project is
    /// watched at all, and is asked about on EVERY tick of that wait rather than once: two calls a
    /// tick (`proc_pidinfo` then `proc_pid_rusage`, 0.29 and 0.63 microseconds measured 2026-09-02),
    /// for as long as the project stays on the books (`ProjectLoadAccounting.watching`). A zombie
    /// can hold its number for hours - a parent stopped on SIGTSTP, or one that waits periodically -
    /// which is why the pool stamps what it is waiting on.
    ///
    /// AND A NUMBER HELD ACROSS TICKS IS CHECKED RATHER THAN TRUSTED, on both sides of that wait: a
    /// member still in the pool by number under a different stamp was collected and its number
    /// reused (old counters settled, the new process starts from where it is), and a departure
    /// answering `.living` under a moved stamp is settled rather than dropped. Untested, the first
    /// read as a survivor whose work clamped to nothing and the second as a member that left alive,
    /// and both then met their arrival with no credit: 30050% on the fixture above. Same rule the
    /// rest of the repository holds pids to (`ProcessIdentity.startedAt`, `ProcessPortHolder`), and
    /// no syscall on either side.
    ///
    /// - Parameter departure: what became of a pid this reading holds and `current` does not. Asked
    ///   once per tick per departure, and never of a member still in the pool under its own stamp.
    /// - Returns: `basis`, to difference `current` against; `keep`, to pair the reading after
    ///   `current` with; and `settled`, the seconds of a member whose number a live process has
    ///   taken over, which no per-pid basis can express because that pid is in both readings.
    func pairing(with current: ProcessResourceSample, departure: (pid_t) -> ProcessDeparture)
        -> (basis: ProcessResourceSample, keep: ProcessResourceSample, settled: Double) {
        var collected: Set<pid_t> = []
        var waiting: Set<pid_t> = []
        // Members whose NUMBER survived into `current` while the process behind it did not. Their
        // credit cannot travel in `basis` - `cpuPercent` reads a pid present in both readings as a
        // survivor and never as a departure - so it is handed back separately and spent as a carry.
        var reused: Set<pid_t> = []
        var settled = 0.0
        for pid in times.keys {
            if current.times[pid] != nil {
                guard let was = startedAt[pid], let now = current.startedAt[pid], was != now
                else { continue }
                reused.insert(pid)
                settled += times[pid, default: 0] + childTimes[pid, default: 0]
                continue
            }
            switch departure(pid) {
            case .living(let stamp):
                // The number answers. Whether the MEMBER does is a second question, and one only a
                // stamp can settle; with no stamp on either side this is the drop it always was.
                guard let was = startedAt[pid], let stamp, was != stamp else { continue }
                collected.insert(pid)
            case .ended: waiting.insert(pid)
            case .collected: collected.insert(pid)
            }
        }
        var basis = narrowed(to: Set(current.times.keys).union(collected))
        for (pid, time) in current.times where times[pid] == nil || reused.contains(pid) {
            basis.times[pid] = time
            basis.childTimes[pid] = current.childTimes[pid]
        }
        var keep = current
        // The two cumulative counters a credit is made of, the stamp that says whose they are, and
        // whether they were ours: all four are read of the WAITING member next tick rather than of
        // whatever holds its number by then. `memory` and `diskWritten` are deliberately not
        // carried - memory is an instant and a dead process holds none, and a stray pool states no
        // disk rate at all (`MachineLoadRollup.StrayReading`).
        for pid in waiting {
            keep.times[pid] = times[pid]
            keep.childTimes[pid] = childTimes[pid]
            keep.startedAt[pid] = startedAt[pid]
            if ours.contains(pid) { keep.ours.insert(pid) }
        }
        return (basis, keep, settled)
    }
}
