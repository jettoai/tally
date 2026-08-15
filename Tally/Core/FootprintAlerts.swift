import Foundation

/// WHEN A SESSION'S FOOTPRINT IS WORTH A WARNING, which is a question about a MISMATCH rather than
/// about the size of a number.
///
/// A session at 300% of a core is not a problem, it is a build. The thing worth somebody's eye is
/// activity with nobody asking for it: a session that finished its turn twenty seconds ago and is
/// still burning a core, or still writing to the disk, because something under it did not stop.
/// That is the residue this whole line exists to find (`ProcessTreeStats.swift`), and it is exactly
/// what no absolute threshold can see - the same number is ordinary on a working session and is the
/// bug on an idle one. So every rate rule here is gated on the session's own state.
///
/// MEMORY IS UNDER THE SAME RULE, and used not to be. It was argued as the exception - memory is a
/// claim being held rather than work being done, so a tree holding four gigabytes holds them
/// whether or not a turn is running - and the argument is true about the NUMBER and wrong about the
/// warning. Four gigabytes under a build is the build; it is what a language server, a bundler and
/// a test runner cost, and warning about it says only that the session is working hard, which the
/// person who started it already knows. The same four gigabytes with nothing running is a tree that
/// did not let go, which is the one thing on this line nobody can see any other way. So the
/// mismatch is the subject here too, and the reading alone never is.
///
/// SUSTAINED, NOT INSTANTANEOUS, AND MEASURED IN SECONDS RATHER THAN IN TICKS. Single readings
/// bounce: a compaction, a garbage collection, one `rg` over a large repo. A warning that appeared
/// for one reading and vanished would be noise on a card that is watched continuously, so every
/// rule here has to hold for ten seconds before anything is drawn. Memory used to light on the
/// FIRST reading it was met, which is the other half of the same correction: an idle session's
/// memory is not falling, so waiting the same ten seconds buys the same freedom from a card that
/// blinks as somebody's build finishes.
///
/// THE SECONDS ARE WHY THIS COUNTS TIME AND NOT TICKS, which it used to. A tick is two seconds with
/// the board on screen and ten behind it (`ProcessFootprintStore`), so five of them was ten seconds
/// or fifty depending on whether anybody was looking - and a warning could be earned by four fast
/// readings and one slow one, which is evidence over two different spans of time added together.
/// The thresholds are held in seconds and the sampler's rate is nobody's business here.
///
/// AND IT LEAVES MORE SLOWLY THAN IT ARRIVES, which is what stops a condition sitting on the
/// threshold from blinking: four quiet seconds put it out, so one dip does not. The one thing that
/// puts a rate warning out immediately is the session going back to work, because at that instant
/// the warning is not merely unproven, it is about a state the session is no longer in.
struct FootprintAlerts: Equatable {
    var cpu = false
    var memory = false
    var disk = false
}

/// One condition's memory across readings: whether it is currently drawn, and since when it has
/// been continuously met or continuously missed. Both instants are kept because the two thresholds
/// differ, and they are instants rather than counts so the answer does not depend on how often the
/// sampler happened to be looking.
struct FootprintAlertTrack: Equatable {
    var lit = false
    /// When the reading first met the condition in the run it is in now, or nothing when the last
    /// reading missed it.
    var metSince: Date?
    /// And the same for the run of readings that missed it.
    var missedSince: Date?
}

/// Everything a session has to remember between ticks to decide what its card warns about. Held by
/// the sampler (`ProcessFootprintStore`), which is the only thing here that knows what a tick is.
struct FootprintAlertState: Equatable {
    var cpu = FootprintAlertTrack()
    var memory = FootprintAlertTrack()
    var disk = FootprintAlertTrack()

    var alerts: FootprintAlerts {
        FootprintAlerts(cpu: cpu.lit, memory: memory.lit, disk: disk.lit)
    }
}

enum FootprintAlarm {

    /// What counts as burning a core while nobody is asking: half of one, which a shell prompt, a
    /// language server or an editor at rest never reaches, and a runaway loop passes instantly.
    static let idleCPUPercent = 50.0
    /// What counts as too much for a session to be holding with nothing running. Four gigabytes is
    /// where a tree stops being a cost of working and starts being the reason the machine swaps.
    static let heavyMemoryBytes: UInt64 = 4_000_000_000
    /// How long a condition has to hold before it is drawn.
    static let sustainedFor: TimeInterval = 10
    /// And how long it has to be gone before it is undrawn. Shorter than the wait to gain it, on
    /// purpose: a warning should be easy to lose and hard to earn.
    static let calmFor: TimeInterval = 4

    /// What this session's card warns about after this reading.
    ///
    /// - Parameters:
    ///   - idle: whether nothing is running on the session's behalf. Read from the state its own
    ///     supervisor publishes rather than inferred here (`SupervisedState`); a session whose
    ///     state is not known yet is not idle, because "unknown" is not a reading.
    ///   - at: when the reading was taken, which is the whole of what the thresholds are measured
    ///     against.
    static func advance(_ state: FootprintAlertState, reading: ProcessFootprint, idle: Bool,
                        at: Date) -> FootprintAlertState {
        var next = state
        guard idle else {
            // Back at work: not "the condition was not met this time" but "the condition does not
            // apply", so the clock starts again from nothing rather than draining away.
            return FootprintAlertState()
        }
        next.cpu = advance(state.cpu, met: (reading.cpuPercent ?? 0) >= idleCPUPercent, at: at)
        next.disk = advance(state.disk,
                            met: (reading.diskWriteBytesPerSecond ?? 0) >= ProcessTree.diskFloor,
                            at: at)
        next.memory = advance(state.memory, met: reading.memoryBytes >= heavyMemoryBytes, at: at)
        return next
    }

    /// One condition, one reading. Lights once it has been met without a break for `sustainedFor`
    /// and goes out once it has been missed without a break for `calmFor`; in between, it stays as
    /// it was.
    ///
    /// HELD-NESS IS MEASURED FROM THE FIRST READING THAT SAW IT, which is the only thing anything
    /// here can know: a condition that began between two samples began, as far as this is
    /// concerned, at the second of them. So a slow sampler is slower to warn in wall-clock terms
    /// and never warns on LESS evidence than a fast one, which is the right way round for a card
    /// nobody is currently looking at.
    static func advance(_ track: FootprintAlertTrack, met: Bool, at: Date) -> FootprintAlertTrack {
        var next = track
        if met {
            let since = track.metSince ?? at
            next.metSince = since
            next.missedSince = nil
            if at.timeIntervalSince(since) >= sustainedFor { next.lit = true }
        } else {
            let since = track.missedSince ?? at
            next.missedSince = since
            next.metSince = nil
            if at.timeIntervalSince(since) >= calmFor { next.lit = false }
        }
        return next
    }
}
