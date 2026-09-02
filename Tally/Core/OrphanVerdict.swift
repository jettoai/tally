import Darwin
import Foundation

/// WHAT TO DO ABOUT ONE TREE, and what has to have been true TWICE before the answer can be "end
/// it" (the tiers and the thresholds are next door, `OrphanReclaim`).
///
/// THIS FILE IS THE HALF THAT NEEDS A MEMORY, and it is written as a value rather than as state so
/// the assertion harness can hand it two rounds and read the verdict out. Everything that decides a
/// kill is here: the pair of sightings, the identity test that keeps a recycled pid from inheriting
/// the previous holder's evidence, and the sleep that throws a pair away rather than believing it.
extension OrphanReclaim {

    /// WHAT THE SCAN DOES ABOUT A TREE THIS ROUND.
    enum Verdict: Equatable {
        /// End it, and why (which is what the record and the message both say).
        case reclaim(Reason)
        /// Say so and do nothing: the tier-C answer, and the answer to anything this app cannot be
        /// sure about (`Veto.hard` is false for exactly those).
        case notify
        /// Evidence so far, nothing said and nothing done: the first sighting of something that
        /// might qualify next round.
        case wait
        /// Not this app's business: somebody is at it, or it is not costing anything.
        case leave
    }

    enum Reason: Equatable {
        /// A dev-watch lease named this tree and the supervisor that wrote it is gone
        /// (`OrphanLease`).
        case leaseOwnerGone
        /// Two rounds of strong evidence with nothing speaking against it.
        case sustained
    }

    /// One round's memory of a tree, which is all the state a verdict needs to carry forward.
    struct Sighting: Equatable {
        /// The root's start time, which is what makes the pid a name for the same tree next round.
        var rootStartedAt: Int64
        var at: Date
        /// What it was burning then, so the runaway bar can be asked of BOTH rounds rather than of
        /// the latest one (`runawayPercent`).
        var cpuPercent: Double?
    }

    /// What a second sighting is worth.
    enum Continuity: Equatable {
        /// The same tree, far enough apart to mean something, and the machine was awake for it.
        case sustained
        /// Keep the earlier sighting and wait: not enough time has passed yet.
        case tooSoon
        /// Start again from this round: a first sighting, a recycled pid, or a machine that slept.
        case restart
    }

    /// WHETHER TWO SIGHTINGS ARE EVIDENCE OF THE SAME THING GOING ON.
    ///
    /// THREE WAYS TO ANSWER NO, and each of them is a defect this rule exists to refuse:
    ///
    ///   - A PID THE MACHINE HANDED OUT AGAIN. The round before saw a build at 100% under pid 4711;
    ///     that build finished, and 4711 is now somebody's editor. By number alone the second round
    ///     confirms the first, and what gets ended is the editor. The start time is compared as
    ///     well as the number, which is the identity rule this whole repository uses
    ///     (`ProcessIdentity.startedAt`, `SessionProcessGroup.leaderStartedAt`).
    ///   - TWO READINGS OF ONE MOMENT. Rounds closer together than `roundInterval` say only that
    ///     the process was busy just now, which is what a link step looks like.
    ///   - A MACHINE THAT WAS ASLEEP. The gap is wall-clock and the work is cumulative counters, so
    ///     a lid closed for six hours makes a pair whose interval is six hours: the rate reads near
    ///     zero (harmless) and "still doing it five minutes later" is a sentence nobody observed
    ///     (not harmless). Past `sleepGap` the pair is discarded and this round becomes the first.
    static func continuity(from previous: Sighting?, to current: Sighting) -> Continuity {
        guard let previous, previous.rootStartedAt == current.rootStartedAt else { return .restart }
        let gap = current.at.timeIntervalSince(previous.at)
        if gap > sleepGap { return .restart }
        return gap >= roundInterval ? .sustained : .tooSoon
    }

    /// WHETHER THIS READING CLEARS THE RESOURCE BAR AT ALL.
    ///
    /// A rate that has not been established is not a zero: a first sighting has no interval behind
    /// it, so it clears nothing and waits (`Verdict.wait`).
    static func heavy(_ reading: Reading) -> Bool {
        if reading.memoryBytes >= heldBytes { return true }
        guard let percent = reading.cpuPercent else { return false }
        // A TREE HOLDING NO PORT HAS TO BE BURNING MUCH MORE, which is the one asymmetry in this
        // rule and the reason the 2026-09-01 runaway is in scope at all (`runawayPercent`).
        return percent >= (reading.listeningPorts.isEmpty ? runawayPercent : busyPercent)
    }

    /// THE VERDICT, out of this round's reading and last round's sighting.
    ///
    /// THE ORDER OF THE TESTS IS THE POLICY. A hard veto answers first and answers `leave`, before
    /// anything about load is considered: a terminal somebody is typing in can be spending three
    /// cores and is still not this app's business, and a message about it is worse than nothing
    /// because it teaches the reader to ignore the channel. Age comes next, then the resource bar,
    /// and only what has passed all three is sorted into "end it" or "say so" - so tier C is a
    /// report about something that WOULD have been ended but for a doubt, rather than a list of
    /// every process on the machine.
    ///
    /// - Parameter previous: what the last round saw of this tree, if it saw it.
    /// - Returns: the verdict, and the sighting to carry into the next round. The sighting is
    ///   returned even for `leave`, so a tree that stops being vetoed does not start from nothing.
    static func verdict(for reading: Reading, previous: Sighting?)
        -> (verdict: Verdict, keep: Sighting) {
        let now = Sighting(rootStartedAt: reading.tree.rootStartedAt,
                           at: reading.takenAt, cpuPercent: reading.cpuPercent)
        let carried = continuity(from: previous, to: now)
        // A pair that is still open keeps the EARLIER sighting, so a round taken three minutes
        // after the first does not push the confirmation another five minutes out. Anything else
        // starts the pair here.
        let keep = carried == .tooSoon ? (previous ?? now) : now
        guard !reading.blocked else { return (.leave, keep) }
        guard reading.age >= minimumAge, heavy(reading) else { return (.wait, keep) }
        guard reading.vetoes.isEmpty else { return (.notify, keep) }
        guard carried == .sustained else { return (.wait, keep) }
        // AND THE FIRST ROUND HAS TO HAVE SAID THE SAME THING, which only the runaway shape can
        // check: a port-holding server is judged on what it is, and a portless one on what it is
        // doing, so "doing it in both rounds" is the whole of its evidence.
        if reading.listeningPorts.isEmpty, (previous?.cpuPercent ?? 0) < runawayPercent {
            return (.wait, keep)
        }
        return (.reclaim(.sustained), keep)
    }

    /// THE PORTS A SET OF SOCKETS IS WAITING ON, ascending and each named once.
    ///
    /// `SO_REUSEPORT` puts several workers on one port (a node cluster does it by default), so the
    /// raw list repeats itself and a message reading `:3000, :3000, :3000` looks like a defect in
    /// the reporter rather than a fact about the machine.
    static func listening(_ connections: [Connection]) -> [UInt16] {
        Array(Set(connections.filter(\.listening).map(\.localPort))).sorted()
    }

    /// WHAT A TREE BURNED BETWEEN TWO ROUNDS, as a share of one core.
    ///
    /// COUNTED ONLY OVER PROCESSES PRESENT IN BOTH READINGS, WITH THE SAME START TIME, and the
    /// under-reporting that follows is chosen rather than tolerated. Everywhere else in this app a
    /// rate that missed work is a wrong number on a card; here a rate that OVERSTATES is a killed
    /// process, and the two ways a naive difference overstates are both ordinary rather than
    /// exotic:
    ///
    ///   - A WORKER THAT JOINED. Its counter has no previous reading, so its whole life since birth
    ///     is differenced against zero: a compiler worker spawned a minute ago and busy throughout
    ///     reads as sixty seconds of work in an interval that may be five minutes, which is right,
    ///     and one spawned by a tree that has been up for hours after a long build reads as hours.
    ///   - A CHILD THAT WAS REAPED. The kernel credits a dead child's whole life to whoever
    ///     collected it, so a shell that buried a two-hour build shows two hours arriving in one
    ///     interval - the same spike the stray pool next door needs a whole departure protocol to
    ///     cancel (`ProcessResourceSample.pairing`). This does not carry child time at all.
    ///
    /// WHAT IT COSTS, NAMED: a tree that does its work in short-lived children - a build system,
    /// a test runner - reads near zero here and is never reclaimed on CPU. That is the intended
    /// direction. Such a tree is also the one most likely to be somebody waiting for it.
    ///
    /// - Returns: nil on a first sighting, which is not a zero: nothing has been read twice.
    static func rate(from previous: ProcessResourceSample?,
                     to current: ProcessResourceSample) -> Double? {
        guard let previous else { return nil }
        let seconds = current.at.timeIntervalSince(previous.at)
        guard seconds > 0 else { return nil }
        var burned = 0.0
        for (pid, time) in current.times {
            guard let before = previous.times[pid] else { continue }
            // The same number twice is not the same process twice, and a stamp the reader did not
            // supply is not a match: an unstamped pair is skipped rather than believed.
            guard let began = current.startedAt[pid], previous.startedAt[pid] == began else {
                continue
            }
            burned += max(0, time - before)
        }
        return burned / seconds * 100
    }

    /// WHAT A MESSAGE IS ABOUT, so the same leftover is not reported twice a day for a week.
    ///
    /// THE PID IS NOT IN IT, DELIBERATELY. A dev server restarted by its own supervisor is a new
    /// pid every few minutes and the same fact about the machine; keyed by pid, the channel would
    /// carry one message per restart. What identifies the SITUATION is the checkout, the program
    /// and the ports - change any of those and it is worth saying again.
    static func fingerprint(_ reading: Reading) -> String {
        let ports = reading.listeningPorts.map(String.init).joined(separator: ",")
        return "\(reading.tree.project)|\(reading.name ?? "?")|\(ports)"
    }

    /// How long a message silences its own repeat.
    static let noticeInterval: TimeInterval = 24 * 60 * 60

    /// Whether this fingerprint has been said recently enough to stay quiet about.
    static func silenced(_ fingerprint: String, said: [String: Date], at now: Date) -> Bool {
        guard let last = said[fingerprint] else { return false }
        let since = now.timeIntervalSince(last)
        // A clock that went backwards (a manual change, an NTP step) leaves a stamp in the future.
        // Treated as recent rather than as ancient, which is the quiet direction: the cost of the
        // wrong answer here is a message nobody gets, against a channel that repeats itself.
        return since < noticeInterval
    }
}
