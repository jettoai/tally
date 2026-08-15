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
/// SUSTAINED, NOT INSTANTANEOUS. A reading is a difference of two samples two seconds apart, and
/// single ticks bounce: a compaction, a garbage collection, one `rg` over a large repo. A warning
/// that appeared for one tick and vanished would be noise on a card that is watched continuously,
/// so every rule here has to hold for five ticks (about ten seconds) before anything is drawn.
/// Memory used to light on the FIRST tick it was met, which is the other half of the same
/// correction: an idle session's memory is not falling, so waiting the same five ticks costs ten
/// seconds and buys the same freedom from a card that blinks as somebody's build finishes.
///
/// AND IT LEAVES MORE SLOWLY THAN IT ARRIVES, which is what stops a condition sitting on the
/// threshold from blinking: two quiet ticks put it out, so one dip does not. The one thing that
/// puts a rate warning out immediately is the session going back to work, because at that instant
/// the warning is not merely unproven, it is about a state the session is no longer in.
struct FootprintAlerts: Equatable {
    var cpu = false
    var memory = false
    var disk = false
}

/// One condition's memory across ticks: whether it is currently drawn, and how many ticks in a row
/// it has been met or missed. Both counters are kept because the two thresholds differ.
struct FootprintAlertTrack: Equatable {
    var lit = false
    var met = 0
    var missed = 0
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
    /// How many ticks in a row a rate has to hold before it is drawn (the sampler's tick is two
    /// seconds, so this is about ten).
    static let sustainedTicks = 5
    /// How many ticks in a row it has to be gone before it is undrawn. Smaller than the entry
    /// count on purpose: a warning should be easy to lose and hard to gain.
    static let calmTicks = 2

    /// What this session's card warns about after this tick.
    ///
    /// - Parameter idle: whether nothing is running on the session's behalf. Read from the state
    ///   its own supervisor publishes rather than inferred here (`SupervisedState`); a session
    ///   whose state is not known yet is not idle, because "unknown" is not a reading.
    static func advance(_ state: FootprintAlertState, reading: ProcessFootprint,
                        idle: Bool) -> FootprintAlertState {
        var next = state
        guard idle else {
            // Back at work: not "the condition was not met this tick" but "the condition does not
            // apply", so the counting starts again from nothing rather than draining away.
            return FootprintAlertState()
        }
        next.cpu = advance(state.cpu, met: (reading.cpuPercent ?? 0) >= idleCPUPercent)
        next.disk = advance(state.disk,
                            met: (reading.diskWriteBytesPerSecond ?? 0) >= ProcessTree.diskFloor)
        next.memory = advance(state.memory, met: reading.memoryBytes >= heavyMemoryBytes)
        return next
    }

    /// One condition, one tick. Lights after `sustainedTicks` consecutive ticks meeting it and goes
    /// out after `calmTicks` consecutive ticks missing it; in between, it stays as it was.
    static func advance(_ track: FootprintAlertTrack, met: Bool) -> FootprintAlertTrack {
        var next = track
        if met {
            next.met += 1
            next.missed = 0
            if next.met >= sustainedTicks { next.lit = true }
        } else {
            next.missed += 1
            next.met = 0
            if next.missed >= calmTicks { next.lit = false }
        }
        return next
    }
}
