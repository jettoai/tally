import Darwin
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
/// ITS CONTINUITY IS, THOUGH, and that is the one thing seconds alone get wrong: the distance
/// between two instants is evidence only while something was sampling in between, so a lid closed
/// on a heavy idle tree and opened the next morning is not eight hours of held-ness - it is one
/// reading, then another (`FootprintAlarm.gapAfter`).
///
/// AND IT LEAVES MORE SLOWLY THAN IT ARRIVES, which is what stops a condition sitting on the
/// threshold from blinking: four quiet seconds put it out, so one dip does not. The one thing that
/// puts a rate warning out immediately is the session going back to work, because at that instant
/// the warning is not merely unproven, it is about a state the session is no longer in.
///
/// AND THERE IS ONE QUESTION ALL OF THAT IS STRUCTURALLY BLIND TO, which is the second tier below:
/// a session eating the MACHINE. The mismatch rule is right about a working session's numbers being
/// its work, and it follows from that rule that a tree can hold half the RAM and every core for an
/// hour and never say a word, because a turn is running the whole time. That is the state somebody
/// opens this board during (Albert, 2026-08-17: "why is it only white and amber, near-saturation
/// should be red"), and no threshold gated on idleness can ever reach it. So the machine-level
/// tier is judged on every reading, working or not, and it is stated in SHARES of what the machine
/// has rather than in absolute numbers (`MachineCapacity`).
///
/// AND THE MEMORY HALF OF IT TAKES TWO WITNESSES, WHICH IS NOT BELT AND BRACES. The tree's memory
/// figure counts a shared page once per process that maps it (`ProcessResourceSample.memoryBytes`
/// says so, and is right to: it answers "which session is the heavy one"), so a tree of eight node
/// workers or a browser's helpers reads far above what killing it would hand the machine back. A
/// red drawn on that number alone would be red on sessions that have taken nothing, and a tier
/// whose whole promise is "rare and real" cannot spend its credibility on a ruler that overstates.
/// So the machine's OWN pressure reading has to agree (`MachineMemoryPressure`): the kernel counts
/// a shared page once, which is exactly the arithmetic this card cannot do, and the two together
/// say what neither says alone - this tree reads as half the machine, AND the machine is
/// complaining. The CPU needs no second witness: processor time is not shared, so summing it over
/// a tree is honest arithmetic.
struct FootprintAlerts: Equatable {
    var cpu: FootprintAlertLevel = .calm
    var memory: FootprintAlertLevel = .calm
    var disk: FootprintAlertLevel = .calm
}

/// HOW LOUD ONE READING IS. Two conditions rather than one with a volume knob, and they are ranked
/// rather than mixed because a field is drawn once and has to pick.
///
/// `residue` is the mismatch this file is about: spending with nobody asking for it. `saturation`
/// is the machine-level condition above: a share of the whole machine, judged whatever the session
/// says it is doing. A reading can meet both at once (an idle tree still holding half the RAM), and
/// the more urgent of the two is what the card says, because "this is taking the machine" is what a
/// person acts on first and it already implies the tree is heavy.
enum FootprintAlertLevel: Int, Comparable {
    /// Nothing worth an eye.
    case calm
    /// Spending while nothing is running: the residue this whole line exists to find.
    case residue
    /// A share of the machine itself, working or idle (`MachineCapacity`).
    case saturation

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// WHAT THE MACHINE HAS, which is the only thing a saturation threshold can honestly be stated
/// against. Eight gigabytes is a third of a laptop and a rounding error on a Mac Studio; four
/// hundred per cent of a core is every core of a four-core machine and a quarter of a sixteen. So
/// the rules next door are SHARES, and this is what they are shares of.
///
/// READ AT THE POINT OF USE rather than held: both properties are cheap, and a cached copy is a
/// number that can be wrong (a Mac can park cores) for no saving worth having.
struct MachineCapacity: Equatable {
    var physicalMemoryBytes: UInt64
    /// The cores this machine will schedule on. It is what a tree's CPU reading is a multiple of:
    /// that figure is a share of ONE core and adds up across the tree (`ProcessTree.cpuPercent`),
    /// so a fully committed machine reads a hundred times this.
    var cores: Int

    static var current: MachineCapacity {
        MachineCapacity(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                        cores: ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Where a tree stops being an expensive session and starts being the reason the machine swaps
    /// (`FootprintAlarm.saturatedMemoryShare`).
    ///
    /// A MACHINE THAT WILL NOT SAY WHAT IT HAS WARNS ABOUT NOTHING, which is the safe direction of
    /// the two: a zero taken at face value makes every reading a saturation, and a board that is
    /// red on every card says less than one that is red on none.
    var saturatedMemoryBytes: UInt64 {
        guard physicalMemoryBytes > 0 else { return .max }
        return UInt64(Double(physicalMemoryBytes) * FootprintAlarm.saturatedMemoryShare)
    }

    /// The same line for the cores, in the unit the reading is in
    /// (`FootprintAlarm.saturatedCPUShare`), and unreachable on a machine that reports none for the
    /// reason above.
    ///
    /// The whole machine expressed in the reading's own unit is `cores * 100`, and the share is
    /// taken of THAT rather than multiplied through it: the two are the same arithmetic and not the
    /// same double, and a rule whose stated line is 1680 should not be reachable only from below
    /// (`0.7 * 24 * 100` lands a hair under it).
    var saturatedCPUPercent: Double {
        guard cores > 0 else { return .infinity }
        return FootprintAlarm.saturatedCPUShare * Double(cores * 100)
    }
}

/// WHAT THE MACHINE ITSELF SAYS ABOUT ITS MEMORY, which is the second witness the memory tier needs
/// and the one thing this app cannot work out from a process table.
///
/// THE KERNEL COUNTS A SHARED PAGE ONCE. Everything the card measures is per process and therefore
/// counts it once per mapper (`ProcessResourceSample.memoryBytes`), which is the right answer to
/// "which session is the heavy one" and the wrong one to "is the machine short". This level is the
/// same signal Activity Monitor's green, yellow and red pressure graph is drawn from, so a tier
/// that was designed against that graph (`docs/plans`, 2026-08-17) is now actually reading it.
///
/// A LEVEL RATHER THAN A NUMBER OF BYTES, because that is what the kernel publishes: it already
/// folds compression, the file cache and what is reclaimable into one verdict, and any figure this
/// app derived instead would be a second opinion about a question the system has already answered.
enum MachineMemoryPressure: Int32 {
    /// The machine is not short (`kern.memorystatus_vm_pressure_level` == 1).
    case normal = 1
    /// It is working to stay ahead: compressing, evicting, and about to page (== 2).
    case warning = 2
    /// It is not staying ahead (== 4).
    case critical = 4

    /// Whether the machine is complaining at all, which is the whole of what the memory tier asks:
    /// the difference between `warning` and `critical` is a question about the MACHINE and this
    /// card is about a session, so both answer the same way here.
    var isElevated: Bool { self != .normal }

    /// What the machine is saying right now.
    ///
    /// Taken once per tick by the sampler and handed to the rule, rather than read inside it: one
    /// syscall for a board of ten cards instead of ten, and a single reading behind every card of
    /// one tick, which is what "the machine was complaining when this session was measured" means
    /// (`ProcessFootprintStore.sample`).
    static var current: MachineMemoryPressure { reading(of: vmPressureLevel()) }

    /// The pure half of that, so the fail-closed rule below is a thing an assertion can state.
    ///
    /// A MACHINE THAT WILL NOT SAY IS NOT COMPLAINING, which is the safe direction and the same one
    /// `MachineCapacity` takes for a capacity it cannot read: an unreadable sysctl, or a level this
    /// enumeration has no case for, leaves the memory tier's second witness silent and the card
    /// amber at worst. The other direction would turn every heavy tree red on a machine whose
    /// kernel simply answered something new.
    static func reading(of level: Int32?) -> MachineMemoryPressure {
        level.flatMap(MachineMemoryPressure.init(rawValue:)) ?? .normal
    }

    /// The raw level, or nothing when the machine will not say. No entitlement and no privilege:
    /// this sysctl is readable by any process.
    private static func vmPressureLevel() -> Int32? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0,
              size == MemoryLayout<Int32>.size
        else { return nil }
        return level
    }
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

    /// This track's contribution to what its metric says: the level it stands for while it is
    /// drawn, and nothing while it is not. A track does not KNOW which condition it is counting,
    /// which is what lets one implementation serve all five of them, so the level is the caller's
    /// to name (`FootprintAlertState.alerts`).
    func says(_ level: FootprintAlertLevel) -> FootprintAlertLevel { lit ? level : .calm }
}

/// Everything a session has to remember between ticks to decide what its card warns about. Held by
/// the sampler (`ProcessFootprintStore`), which is the only thing here that knows what a tick is.
struct FootprintAlertState: Equatable {
    var cpu = FootprintAlertTrack()
    var memory = FootprintAlertTrack()
    var disk = FootprintAlertTrack()
    /// The machine-level condition on the same two readings, kept on tracks of their own because
    /// they are a different question and answer it under different rules: they are not put out by a
    /// turn starting, the CPU's window is minutes rather than seconds
    /// (`FootprintAlarm.outlastsABuild`), and the memory's asks the machine as well as the tree
    /// (`MachineMemoryPressure`). There is no disk one, on purpose: a write rate has no
    /// machine-level ceiling to be a share of.
    var cpuSaturation = FootprintAlertTrack()
    var memorySaturation = FootprintAlertTrack()
    /// When the last reading judged here was taken, which is the only thing that can say whether the
    /// next one CONTINUES this evidence or begins new evidence (`FootprintAlarm.gapAfter`).
    var lastReadingAt: Date?

    /// WHAT EACH METRIC SAYS, which for two of them is a question about two tracks at once: a reading
    /// can be both a residue and a share of the machine (an idle tree still holding half the RAM),
    /// and a field is drawn once. The louder of the two wins, and "louder" is the ORDER THE LEVELS
    /// THEMSELVES ARE IN rather than an `if` beside it that could come to disagree with them
    /// (`FootprintAlertLevel`).
    var alerts: FootprintAlerts {
        FootprintAlerts(cpu: max(cpu.says(.residue), cpuSaturation.says(.saturation)),
                        memory: max(memory.says(.residue), memorySaturation.says(.saturation)),
                        disk: disk.says(.residue))
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
    /// WHAT COUNTS AS TAKING THE MACHINE'S MEMORY: half of everything it has
    /// (`MachineCapacity.saturatedMemoryBytes`). A share rather than a number of gigabytes, for the
    /// reason that type exists, and half rather than nine tenths because the thing being warned
    /// about is not the moment the machine runs out: it is the approach to it, where the compressor
    /// starts working and every other app on the desktop begins to stall. It is the line macOS
    /// itself reads memory pressure at, and unlike a rate it is worth saying while the session is
    /// working, because a claim being held is held either way.
    ///
    /// THE RULER THIS IS MEASURED WITH OVERSTATES, AND UNDER THE `AND` THAT IS HARMLESS. The tree's
    /// figure counts a shared page once per process that maps it, so a fan-out of workers can read
    /// half a machine it has not taken. On its own this share would therefore be a false red; paired
    /// with the machine's own pressure level (`MachineMemoryPressure`), which counts that page once,
    /// the overstatement can only ever cost a card that WOULD have been red - the share is the half
    /// of the rule that answers "which session", and the kernel is the half that answers "is
    /// anything actually short". Tightening the share to compensate would trade one bias for
    /// another; the second witness removes the need to guess at all.
    static let saturatedMemoryShare = 0.5
    /// And what counts as taking its cores: seven tenths of everything the machine will schedule
    /// (`MachineCapacity.saturatedCPUPercent`). Anchored on the TOTAL rather than on one core, the
    /// way a load average is read against the core count: one core at a hundred per cent is an
    /// ordinary compile on any machine built this decade, and a rule that called it saturation
    /// would cry wolf on every card.
    static let saturatedCPUShare = 0.7
    /// How long that share of the cores has to hold before it is drawn, which is the one threshold
    /// here measured in minutes.
    ///
    /// A BUILD TAKES EVERY CORE AND IS OVER, and that is what the machine is for: a board that went
    /// red whenever somebody compiled would be a board nobody reads. Three minutes is past the far
    /// end of that - a cold `xcodebuild` of this app, a full test run, a dependency install - so
    /// what is still holding the cores after it is the other thing entirely: a fan-out that is not
    /// going to stop on its own, which is the state this tier was asked for (Albert, 2026-08-17,
    /// whose own fan-outs run for tens of minutes). The memory share needs no such wait and keeps
    /// the ordinary ten seconds: a tree holding half the RAM is near the swap it is being warned
    /// about at the instant it is read, whereas a spike of cores is only ever evidence about the
    /// span it lasted.
    static let outlastsABuild: TimeInterval = 180
    /// And how long it has to be gone before it is undrawn. Shorter than the wait to gain it, on
    /// purpose: a warning should be easy to lose and hard to earn.
    static let calmFor: TimeInterval = 4
    /// How long a silence between two readings has to run before the second of them is NEW evidence
    /// rather than the continuation of what the first saw.
    ///
    /// WITHOUT IT, THE CLOCK BELOW COUNTS TIME NOBODY MEASURED. Held-ness is the distance between
    /// two instants, so a lid closed on an idle tree holding four gigabytes and opened the next
    /// morning met the condition "without a break" for eight hours - across exactly two readings,
    /// with nothing sampled in between. The card lit on the first reading after a wake, and App Nap
    /// stretching the background timer is the same shape less dramatically.
    ///
    /// Three of the sampler's slowest beats (`ProcessFootprintStore`), which is the ring's own rule
    /// for the same silence and for the same reason (`FootprintTrendSeries.staleAfter`): one or two
    /// missed ticks are a busy main thread and the evidence carries across them, and anything past
    /// that is the machine having been away.
    static let gapAfter: TimeInterval = 30

    /// What this session's card warns about after this reading.
    ///
    /// - Parameters:
    ///   - idle: whether nothing is running on the session's behalf. Read from the state its own
    ///     supervisor publishes rather than inferred here (`SupervisedState`); a session whose
    ///     state is not known yet is not idle, because "unknown" is not a reading.
    ///   - at: when the reading was taken, which is the whole of what the thresholds are measured
    ///     against.
    ///   - capacity: what the machine has, which the saturation rules are shares of. A parameter
    ///     with a default rather than a constant read inside, so the harness can state the rules on
    ///     a machine of its own choosing instead of on whatever hardware happens to run the suite.
    ///   - pressure: what the machine says about its own memory, which the memory tier's second
    ///     witness is. NO DEFAULT, unlike the capacity beside it, and the difference is what the
    ///     two are: a capacity is a fact about the hardware that a caller can be trusted to leave
    ///     alone, and this is a LIVE READING that has to be the one taken with this tick's sample.
    ///     A default here would let a board of ten cards take ten readings at ten instants, or let
    ///     a caller silently inherit a reading it never took.
    static func advance(_ state: FootprintAlertState, reading: ProcessFootprint, idle: Bool,
                        at: Date, capacity: MachineCapacity = .current,
                        pressure: MachineMemoryPressure) -> FootprintAlertState {
        // A SILENCE LONG ENOUGH TO BE A DIFFERENT AFTERNOON throws the evidence away rather than
        // counting it as more of the same, warning and all: what was true before a night of sleep
        // is not what this reading is about, and it has to be earned again from here (`gapAfter`).
        // ALL FIVE TRACKS, the machine-level pair included: a lid closed on a saturated tree and
        // opened the next morning is one reading and then another, whatever the tree was doing.
        // The tracks below are then advanced from what survived that, which is why they read `next`
        // and not the state this was called with.
        var next = interrupted(state, at: at) ? FootprintAlertState() : state
        next.lastReadingAt = at
        // JUDGED WHETHER OR NOT A TURN IS RUNNING, which is the whole difference between this pair
        // and the three below and the reason they are separate tracks at all. A tree holding half
        // the machine's memory is heading for swap while it works, and a fan-out holding most of
        // its cores for three minutes is why the rest of the desktop has gone slow; gating either
        // on idleness would mean the board could only ever say so once the session had stopped.
        next.cpuSaturation = advance(next.cpuSaturation,
                                     met: (reading.cpuPercent ?? 0) >= capacity.saturatedCPUPercent,
                                     at: at, sustainedFor: outlastsABuild)
        // TWO WITNESSES, AND THE CLOCK ONLY RUNS WHILE BOTH ARE SPEAKING: this tree reads as half
        // the machine's memory, and the machine is telling the kernel it is short. Either alone is
        // a card this board would be wrong to draw red (see the note on `saturatedMemoryShare`),
        // and pressure that falls back to normal stops the run of evidence exactly as a tree that
        // let go of its memory does.
        next.memorySaturation = advance(next.memorySaturation,
                                        met: reading.memoryBytes >= capacity.saturatedMemoryBytes
                                            && pressure.isElevated,
                                        at: at)
        guard idle else {
            // Back at work: not "the condition was not met this time" but "the condition does not
            // apply", so the mismatch clocks start again from nothing rather than draining away.
            next.cpu = FootprintAlertTrack()
            next.disk = FootprintAlertTrack()
            next.memory = FootprintAlertTrack()
            return next
        }
        next.cpu = advance(next.cpu, met: (reading.cpuPercent ?? 0) >= idleCPUPercent, at: at)
        next.disk = advance(next.disk,
                            met: (reading.diskWriteBytesPerSecond ?? 0) >= ProcessTree.diskFloor,
                            at: at)
        next.memory = advance(next.memory, met: reading.memoryBytes >= heavyMemoryBytes, at: at)
        return next
    }

    /// Whether what is held was measured too long ago to be about the same run of readings as this
    /// one (`gapAfter`). A state that has judged nothing yet has no silence to measure.
    private static func interrupted(_ state: FootprintAlertState, at: Date) -> Bool {
        guard let last = state.lastReadingAt else { return false }
        return at.timeIntervalSince(last) > gapAfter
    }

    /// One condition, one reading. Lights once it has been met without a break for `sustainedFor`
    /// and goes out once it has been missed without a break for `calmFor`; in between, it stays as
    /// it was.
    ///
    /// HELD-NESS IS MEASURED FROM THE FIRST READING THAT SAW IT, which is the only thing anything
    /// here can know: a condition that began between two samples began, as far as this is
    /// concerned, at the second of them. So a slow sampler is slower to warn in wall-clock terms
    /// than a fast one, which is the right way round for a card nobody is currently looking at.
    ///
    /// THE DISTANCE IS ONLY EVIDENCE WHILE THE SAMPLING WENT ON, which this pair of instants cannot
    /// see on its own and the caller checks for it (`interrupted`): two readings an hour apart say
    /// nothing about the fifty-nine minutes between them, and taken as held-ness they were the most
    /// evidence this rule ever saw rather than the least.
    ///
    /// - Parameter sustainedFor: how long this particular condition has to hold. A parameter
    ///   because one of the five is measured in minutes rather than seconds (`outlastsABuild`), and
    ///   only the wait to GAIN a warning differs: `calmFor` is shared, so every condition here is
    ///   easy to lose whatever it cost to earn.
    static func advance(_ track: FootprintAlertTrack, met: Bool, at: Date,
                        sustainedFor: TimeInterval = FootprintAlarm.sustainedFor)
        -> FootprintAlertTrack {
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
