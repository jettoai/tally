import Darwin
import Foundation

/// WHAT TWO READINGS SAY, which is the half of the footprint that needs TIME to mean anything.
///
/// Split from `ProcessTreeStats.swift` when it ran out of room, along the seam that file was already
/// organised by: over there is what a reading IS at one instant (which pids are in a tree, which of
/// them are Tally's own, what the tree is holding); here is what a PAIR of them says, which is every
/// rate on the card and the blame that goes with it. `ProcessTreeCensus.swift` was the first cut
/// along that same line and says so at its own head - it took the instant-only rules that had no
/// difference in them, and this takes the differences.
///
/// PURE, like both of its neighbours, so the assertion harness can state every case with no
/// processes around it.

/// What a pair of readings says about CPU: the percentage, who to blame for it, and the credit this
/// pair could not settle (see `cpuPercent`).
struct ProcessCPUReading: Equatable {
    var percent: Double?
    var carry: ProcessCPUCarry = ProcessCPUCarry()
    var leader: pid_t?
}

/// The credit a pair of readings could not settle, HELD APART BY WHOSE SECONDS IT IS.
///
/// ONE NUMBER WAS WRONG BECAUSE THE TWO KINDS SETTLE DIFFERENTLY. A departure's credit exists to
/// cancel an ARRIVAL: the seconds a child spent land in whoever collected it, and taking them off
/// stops the collection being counted as fresh work. For a process the tree measures, the collector
/// is the parent standing right there and the arrival is certain. For one of TALLY'S OWN it is not:
/// they are sampled precisely so their departures can cancel what they hand their collector
/// (`ProcessResourceSample.ours`), and that collector is Claude Code in the ordinary case - but when
/// one of ours is orphaned first, launchd buries it and the arrival never comes. Summed into one
/// credit, those seconds cancelled OTHER, REAL arrivals in the same tick and then went on through
/// the carry to suppress the next one: a session's CPU read low for two ticks because a hook of ours
/// died with the wrong parent (codex review of `b7df307`).
///
/// So ours' credit is capped at the arrivals actually observed, and what it cannot spend is written
/// off rather than allowed to eat somebody's work.
struct ProcessCPUCarry: Equatable {
    /// What the tree's own departures left unsettled, which behaves exactly as the single carry
    /// always did: it may exceed the arrivals of its tick, because a death and its collection land
    /// on different ticks and the clamp at zero costs nothing in between.
    var theirs: Double = 0
    /// And what TALLY'S OWN departures left unsettled, which may only ever be spent against an
    /// arrival. Carried for one tick, on the same bound the credit beside it keeps: a hook that died
    /// just before a reading is collected just after it, and if the arrival still has not come by
    /// then it is never coming.
    var ours: Double = 0
}

/// What a pair of readings says about disk writing: the rate and who to blame for it.
struct ProcessDiskReading: Equatable {
    var bytesPerSecond: Double?
    var leader: pid_t?
}

extension ProcessTree {

    /// What share of one core the tree spent between two readings, as a percentage, or nil when the
    /// pair cannot say: no elapsed time, or no earlier reading at all (the first tick after a panel
    /// opens is exactly that, and it draws no CPU segment rather than a zero).
    ///
    /// THREE TERMS, and the second two exist because a session's work is mostly processes that are
    /// born and buried between two ticks:
    ///
    ///   - What the processes still here have spent since the last reading. A pid the earlier
    ///     reading never saw counts everything it has spent, because it did not exist before that
    ///     instant. A reading that went backwards counts as nothing: the only way that happens is
    ///     the number naming a different process now, and a negative is not a measurement.
    ///   - What their REAPED CHILDREN spent, which is the same difference taken over the kernel's
    ///     child counters. This is the whole of a short command's cost: `yes` burning half a core
    ///     for half a second between two ticks was reported as 0.007% before this term existed
    ///     (measured 2026-08-15), because no sample ever saw it alive.
    ///   - MINUS what the processes that have GONE had already been counted for. A child's whole
    ///     life lands in its parent's counter at the instant it is collected, and the part of that
    ///     life before the previous reading was counted then, as its own. Both of its counters come
    ///     off: the child counter too, or the work of a grandchild it had itself already buried
    ///     would be counted once when it collected it and again when it was collected.
    ///
    /// Clamped at zero as a whole, for the two windows where a subtraction has no counter to answer
    /// it: a process that has died and not yet been collected, and one whose collector is outside
    /// the tree (an orphan is buried by launchd, whose counters are nobody's business here). Both
    /// read low for a tick rather than negative, which is the honest price of never double counting
    /// the ordinary case, where the collector is the parent standing right there in the tree.
    ///
    /// AND THE UNSETTLED PART OF THAT SUBTRACTION SURVIVES THE TICK, which is the whole reason this
    /// returns a carry rather than a number. Death and collection are two events, and nothing makes
    /// them land in the same interval: a child that died just before a reading is collected just
    /// after it, so its credit is taken off a tick that has nothing to take it off (clamped to zero,
    /// costing nothing) and its whole life then arrives in the parent's child counter on the NEXT
    /// one, where it is counted a second time. Measured as a single tick reading several hundred
    /// percent for work that was already reported while the child was alive. Handed back and applied
    /// to the next pair, the arrival meets the credit and cancels.
    ///
    /// THE CARRY SURVIVES EXACTLY ONE TICK, and the bound is not tidiness. A credit that nothing
    /// will ever settle is entirely possible - an orphan is collected by launchd, so the seconds it
    /// spent never arrive in any counter this tree can read - and an unbounded carry would then
    /// silently suppress that many seconds of REAL work, which is a worse lie than the spike it was
    /// added to prevent, and a quieter one. So only what departed in THIS interval is handed on;
    /// whatever the previous tick handed in and could not be spent is written off.
    ///
    /// AND TALLY'S OWN ARE IN THE SAMPLE BUT NOT IN THE ANSWER, which is the one asymmetry here that
    /// is not about time. They contribute no work and no arrivals - a card measuring the meter is
    /// the defect `ownFamily` exists for - but every departure counts, theirs included, and that is
    /// the whole repair: a Tally hook that ends between two ticks has its life folded into the
    /// counters of whoever collected it, which is Claude Code, so its seconds arrive on a process
    /// this card IS measuring. Sampled, it departs and the credit cancels the arrival; filtered out
    /// by pid before the sample, it was never in either reading, never departed, and the arrival
    /// stood as session work. (`ProcessResourceSample.ours` carries the measurement.)
    ///
    /// OURS' CREDIT MAY ONLY EVER CANCEL AN ARRIVAL, which is the correction to that repair
    /// (`ProcessCPUCarry`). The repair assumed the collector is inside the tree; when one of ours is
    /// orphaned first, launchd collects it and nothing ever arrives, so the credit went on to cancel
    /// somebody ELSE's real arrival and then to suppress the following tick. Capped, seconds that
    /// have nowhere to land are simply written off, which costs at most the double count this whole
    /// mechanism exists to prevent and only in the case where it was already impossible to settle.
    ///
    /// WHAT THAT STILL DOES NOT REACH, said rather than implied: one of ours BORN AND ENDED inside a
    /// single interval appears in neither reading, so there is nothing to depart and its seconds
    /// stay on the collector. Nothing measured from outside the process can see it - the honest
    /// bound is the sampling interval, and closing it would mean Tally's own processes writing down
    /// what they spent as they exit.
    ///
    /// - Parameter carry: what the previous pair could not settle, in seconds, of each kind. Zero
    ///   for the first pair of a session, and the reason the store keeps one of these per session.
    static func cpuPercent(from previous: ProcessResourceSample?, to current: ProcessResourceSample,
                           carry: ProcessCPUCarry = ProcessCPUCarry()) -> ProcessCPUReading {
        guard let previous else { return ProcessCPUReading(percent: nil) }
        // Per pid rather than one running total, because the same pass has to answer two questions:
        // what the tree burned, and whether one process burned most of it. And OWN WORK IS KEPT
        // APART FROM ARRIVALS, which the blame below depends on: the kernel credits a reaped child
        // to whoever collected it, so a shell that ran the build is named for the build - but the
        // very same counter is where a life ALREADY COUNTED lands when it is finally collected, and
        // those two are the same number until they are held separately.
        var own: [pid_t: Double] = [:]
        var arrived: [pid_t: Double] = [:]
        // Ours are read and then left out of both, which is what makes the departure below able to
        // cancel what one of them left in somebody else's counter (see the note above).
        for (pid, time) in current.times where !current.ours.contains(pid) {
            let mine = max(0, time - (previous.times[pid] ?? 0))
            let buried = max(0, (current.childTimes[pid] ?? 0) - (previous.childTimes[pid] ?? 0))
            // Absent rather than zero, so an idle pid is not a candidate for the blame below.
            if mine > 0 { own[pid] = mine }
            if buried > 0 { arrived[pid] = buried }
        }
        // EVERY departure, ours included, and told apart by WHICH READING SAW IT. A departed pid is
        // absent from the current sample by definition, so the only reading that can say whose it
        // was is the earlier one - which is also the reading whose seconds are being taken off.
        var departedTheirs = 0.0
        var departedOurs = 0.0
        for (pid, time) in previous.times where current.times[pid] == nil {
            let credit = time + (previous.childTimes[pid] ?? 0)
            if previous.ours.contains(pid) { departedOurs += credit } else { departedTheirs += credit }
        }
        let elapsed = current.at.timeIntervalSince(previous.at)
        // Two readings at the same instant say nothing about a rate, but a departure between them
        // is still a departure: its credit goes forward rather than being lost with the pair.
        guard elapsed > 0 else {
            return ProcessCPUReading(percent: nil,
                                     carry: ProcessCPUCarry(theirs: carry.theirs + departedTheirs,
                                                            ours: carry.ours + departedOurs))
        }
        let arrivals = arrived.values.reduce(0, +)
        // Ours' credit spends what was carried in first and then what left this tick, and only ever
        // against an arrival. What THIS tick's departures cannot spend is handed on for one tick;
        // what was carried in and still cannot be spent is written off, which is the same bound the
        // credit beside it keeps and for the same reason.
        let carriedSpent = min(carry.ours, arrivals)
        let departedSpent = min(departedOurs, arrivals - carriedSpent)
        let spentOurs = carriedSpent + departedSpent
        let theirs = carry.theirs + departedTheirs
        let net = own.values.reduce(0, +) + arrivals - theirs - spentOurs
        return ProcessCPUReading(
            percent: max(0, net) / elapsed * 100,
            carry: ProcessCPUCarry(theirs: net < 0 ? min(-net, departedTheirs) : 0,
                                   ours: departedOurs - departedSpent),
            leader: net > 0 ? leader(of: blame(own: own, collected: arrived,
                                               settling: theirs + spentOurs))
                            : nil)
    }

    /// WHO IS ACTUALLY DOING THE WORK THIS TICK, which is not the same question as how much work the
    /// tick holds, and the difference is exactly the credit being cancelled.
    ///
    /// A departure's credit cancels an ARRIVAL: the seconds coming off are seconds that were counted
    /// while the child was alive and are now landing in whoever collected it. Left in, they name the
    /// collector - so a parent that reaped a hundred-second child would be blamed for a hundred
    /// seconds it did not spend, over a process beside it that really did spend one (measured as
    /// `percent=50, leader=<the collector>` before this existed). Taking the same seconds off the
    /// arrivals they are cancelling leaves the tick naming the process that actually burned it.
    ///
    /// SHARED OUT IN PROPORTION, because the kernel does not say which collector got which child:
    /// `ri_child_time` is one folded total per process, and the credit is a sum over everything that
    /// left. Proportion is the honest reading of "somewhere in these arrivals", and it degrades the
    /// way it should - a single collector takes the whole cancellation, and a tick with no arrivals
    /// at all cancels nothing here (the seconds still come off the percentage, where they belong,
    /// and the blame is decided on own work alone).
    private static func blame(own: [pid_t: Double], collected: [pid_t: Double],
                              settling credit: Double) -> [pid_t: Double] {
        // Summed here rather than taken as an argument: the caller has the same total for the
        // percentage, and a number that can be passed in is a number that can be passed in stale.
        let arrivals = collected.values.reduce(0, +)
        guard arrivals > 0 else { return own }
        let kept = 1 - min(credit, arrivals) / arrivals
        var blamed = own
        for (pid, seconds) in collected where seconds * kept > 0 {
            blamed[pid, default: 0] += seconds * kept
        }
        return blamed
    }

    /// How fast the tree is writing to disk between two readings, and which process is doing it, or
    /// nothing when the pair cannot say.
    ///
    /// SHORT WRITERS ARE MISSED AND THAT IS THE WHOLE DIFFERENCE FROM CPU. The kernel keeps no
    /// child counterpart of `ri_diskio_byteswritten`, so a command that starts, writes and finishes
    /// between two ticks takes its bytes with it: there is nowhere for them to arrive. A departed
    /// pid is therefore simply dropped - no credit, no carry, no double counting to prevent - and
    /// the reading is an undercount of exactly that traffic. Which is tolerable for what this is
    /// for: the runaway this segment exists to catch (a log loop, a watcher rewriting a bundle) is
    /// long-lived by definition, and short commands write in kilobytes.
    ///
    /// THE SAME ABSENCE IS WHY TALLY'S OWN NEED NOTHING BUT A PID TEST HERE, where the CPU needed a
    /// departure to cancel an arrival. `rusage_info_v6` carries `ri_child_user_time`,
    /// `ri_child_system_time`, `ri_child_pkg_idle_wkups`, `ri_child_interrupt_wkups`,
    /// `ri_child_pageins` and `ri_child_elapsed_abstime`, and NO child counterpart of either disk
    /// counter (read off the SDK header, 2026-08-15). Nothing one of ours wrote can arrive on a
    /// process the card is measuring, so leaving it out of the sum leaves it out entirely.
    static func diskWrite(from previous: ProcessResourceSample?,
                          to current: ProcessResourceSample) -> ProcessDiskReading {
        guard let previous else { return ProcessDiskReading(bytesPerSecond: nil) }
        let elapsed = current.at.timeIntervalSince(previous.at)
        guard elapsed > 0 else { return ProcessDiskReading(bytesPerSecond: nil) }
        // Double before the subtraction: these are unsigned counters, and a pid whose number now
        // names a different process reads backwards - which would trap rather than clamp.
        var written: [pid_t: Double] = [:]
        for (pid, bytes) in current.diskWritten where !current.ours.contains(pid) {
            let delta = Double(bytes) - Double(previous.diskWritten[pid] ?? 0)
            if delta > 0 { written[pid] = delta }
        }
        return ProcessDiskReading(bytesPerSecond: written.values.reduce(0, +) / elapsed,
                                  leader: leader(of: written))
    }

    /// Which single pid accounts for MORE THAN HALF of a set of contributions, or nobody.
    ///
    /// HALF IS NOT ENOUGH, ON PURPOSE. A name beside a number is a claim that one thing is doing
    /// this, and two processes at exactly half each make that claim false about both of them; the
    /// line says nothing rather than picking whichever the dictionary handed over first.
    static func leader(of contributions: [pid_t: Double]) -> pid_t? {
        let total = contributions.values.reduce(0, +)
        guard total > 0, let top = contributions.max(by: { $0.value < $1.value }),
              top.value > total / 2
        else { return nil }
        return top.key
    }
}
