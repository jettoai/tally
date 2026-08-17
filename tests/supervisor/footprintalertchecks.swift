import Foundation

// WHEN A SESSION'S FOOTPRINT IS WORTH A WARNING (Tally/Core/FootprintAlerts.swift), and how a
// warned field reads once it is.
//
// SPLIT FROM THE FOOTPRINT'S OWN CHECKS beside it (processtreechecks.swift) the way the rule is
// split from the readings it judges: those state what the numbers MEAN, these state which of them
// somebody should look at - a question about the mismatch between what a session is spending and
// what it says it is DOING, never about the size of a number. What the card DRAWS for one is
// asserted over there, with the rest of the checks that read that source.

func runFootprintAlertChecks() {
    // MARK: what is worth a warning

    // A WARNING IS ABOUT A MISMATCH, NOT ABOUT A NUMBER. The same 300% is a build on a working
    // session and a runaway on one whose turn ended twenty seconds ago, so every rate rule is gated
    // on what the session says it is doing, and the number alone can never light one.
    func reading(cpu: Double? = nil, memory: UInt64 = 0,
                 disk: Double? = nil) -> ProcessFootprint {
        ProcessFootprint(processes: 4, cpuPercent: cpu, memoryBytes: memory,
                         diskWriteBytesPerSecond: disk, listeningPorts: [])
    }
    // A SAMPLER WITH A CLOCK, because the rule is stated in seconds and the sampler's rate is not
    // constant: two seconds with the board on screen, ten behind it (`ProcessFootprintStore`).
    // Every run below says how often it was looking as well as for how long.
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    // AND A MACHINE OF ITS OWN, because half of these rules are shares of one (`MachineCapacity`).
    // Passed in everywhere rather than defaulted, so what a check asserts is a fact about the rule
    // and not about whichever laptop or CI box happened to run the suite: on this fixture the CPU
    // saturates at 560% and the memory at 8 GB, both well clear of the mismatch fixtures below.
    let machine = MachineCapacity(physicalMemoryBytes: 16_000_000_000, cores: 8)
    struct Sampler {
        var state = FootprintAlertState()
        var now: Date
        var every: TimeInterval = 2
        var capacity: MachineCapacity
        /// What the machine is saying about its memory while this run happens. Elevated unless a
        /// check is about the gate itself: it is the second witness the memory tier needs, so a
        /// sampler that left it normal would be asserting the gate rather than the rule behind it.
        var pressure: MachineMemoryPressure = .warning
        @discardableResult
        mutating func run(_ ticks: Int, _ reading: ProcessFootprint,
                          idle: Bool) -> FootprintAlerts {
            for _ in 0 ..< ticks { step(after: every, reading, idle: idle) }
            return state.alerts
        }
        /// ONE READING TAKEN AFTER A STATED SILENCE, rather than at this sampler's own beat, because
        /// the beat is not what the machine does: a rate changes when a panel opens, a main thread
        /// stalls, App Nap stretches a background timer, and a lid opens the next morning.
        @discardableResult
        mutating func step(after: TimeInterval, _ reading: ProcessFootprint,
                           idle: Bool) -> FootprintAlerts {
            now = now.addingTimeInterval(after)
            state = FootprintAlarm.advance(state, reading: reading, idle: idle, at: now,
                                           capacity: capacity, pressure: pressure)
            return state.alerts
        }
    }
    func run(_ ticks: Int, _ state: FootprintAlertState, _ reading: ProcessFootprint, idle: Bool,
             every: TimeInterval = 2, from: Date? = nil,
             on capacity: MachineCapacity? = nil,
             pressure: MachineMemoryPressure = .warning) -> FootprintAlertState {
        var sampler = Sampler(state: state, now: from ?? t0, every: every,
                              capacity: capacity ?? machine, pressure: pressure)
        sampler.run(ticks, reading, idle: idle)
        return sampler.state
    }
    /// The same reading held without a break for a stated span of EVIDENCE, which is one tick more
    /// than the span divided by the beat: held-ness is measured from the first reading that saw the
    /// condition, so six two-second readings are ten seconds of it and not twelve
    /// (`FootprintAlarm.advance(_:met:at:sustainedFor:)`).
    func held(_ reading: ProcessFootprint, idle: Bool, for seconds: TimeInterval,
              every: TimeInterval = 2, on capacity: MachineCapacity? = nil,
              pressure: MachineMemoryPressure = .warning) -> FootprintAlerts {
        run(Int(seconds / every) + 1, FootprintAlertState(), reading, idle: idle, every: every,
            on: capacity, pressure: pressure).alerts
    }
    let hot = reading(cpu: 300)
    check("a working session burning three cores is a build, and says nothing",
          run(20, FootprintAlertState(), hot, idle: false).alerts == FootprintAlerts())
    // TEN SECONDS OF IT: a single reading over the line is a compaction or one `rg`, and a warning
    // that came and went inside two seconds would be noise on a card somebody is watching. Held
    // from the first reading that SAW it, so on a two-second beat the fifth is eight seconds in.
    check("an idle session burning a core says nothing eight seconds in",
          run(5, FootprintAlertState(), hot, idle: true).alerts.cpu == .calm)
    check("…and says it once it has held for ten",
          run(6, FootprintAlertState(), hot, idle: true).alerts.cpu == .residue)
    // THE SAME TEN SECONDS AT THE OTHER RATE, which is the defect the seconds fix: five ticks meant
    // ten seconds with the panel open and fifty behind it, and a warning could be earned by four
    // fast readings and one slow one - evidence over two spans of time added together.
    check("a slower sampler warns on the same ten seconds of evidence, not on the same five ticks",
          run(1, FootprintAlertState(), hot, idle: true, every: 10).alerts.cpu == .calm
              && run(2, FootprintAlertState(), hot, idle: true, every: 10).alerts.cpu == .residue)
    // Slower to leave than to arrive, so a condition sitting on the threshold does not blink.
    let burning = run(6, FootprintAlertState(), hot, idle: true)
    let quiet = reading(cpu: 2)
    check("one quiet reading does not put it out",
          run(1, burning, quiet, idle: true).alerts.cpu == .residue)
    check("…and four seconds of them do",
          run(2, burning, quiet, idle: true, from: t0).alerts.cpu == .residue
              && run(3, burning, quiet, idle: true, from: t0).alerts.cpu == .calm)
    check("…on the same four seconds whatever the rate",
          run(1, burning, quiet, idle: true, every: 10, from: t0).alerts.cpu == .residue
              && run(2, burning, quiet, idle: true, every: 10, from: t0).alerts.cpu == .calm)
    // THE ONE THING THAT PUTS IT OUT AT ONCE is the session going back to work: at that instant the
    // warning is not unproven, it is about a state the session is no longer in.
    check("a turn starting puts it out on that very reading, whatever the number says",
          run(1, burning, hot, idle: false).alerts.cpu == .calm)
    check("…and the clock starts again from nothing rather than draining away",
          run(5, run(1, burning, hot, idle: false), hot, idle: true).alerts.cpu == .calm)
    // The disk rule is the same shape and counts from the same megabyte a second the segment
    // becomes visible at, so "shown" and "worth watching" cannot drift apart.
    check("an idle session writing to disk says so once it has held for ten seconds",
          run(5, FootprintAlertState(), reading(disk: 4_000_000), idle: true).alerts.disk == .calm
              && run(6, FootprintAlertState(), reading(disk: 4_000_000), idle: true).alerts.disk
                  == .residue)
    check("…and writing below the rate the segment is drawn at is not writing",
          run(20, FootprintAlertState(), reading(disk: ProcessTree.diskFloor - 1), idle: true)
              .alerts.disk == .calm)
    check("…while a working session writing hard is just working",
          run(20, FootprintAlertState(), reading(disk: 40_000_000), idle: false)
              .alerts.disk == .calm)
    // MEMORY IS UNDER THE SAME RULE, and used to be the exception. Four gigabytes under a build IS
    // the build - a language server, a bundler and a test runner - and saying so tells the person
    // who started it what they already know. The same four gigabytes with nothing running is a tree
    // that did not let go, which is the one thing on this line nobody can see another way.
    let heavy = reading(memory: 4_000_000_000)
    check("a working session holding four gigabytes is a build, and says nothing",
          run(20, FootprintAlertState(), heavy, idle: false).alerts.memory == .calm)
    check("an idle session holding four gigabytes says nothing eight seconds in",
          run(5, FootprintAlertState(), heavy, idle: true).alerts.memory == .calm)
    check("…and says it once it has held for ten seconds",
          run(6, FootprintAlertState(), heavy, idle: true).alerts.memory == .residue)
    check("…and just under it says nothing at all",
          run(20, FootprintAlertState(), reading(memory: 3_999_999_999), idle: true)
              .alerts.memory == .calm)
    let holding = run(6, FootprintAlertState(), heavy, idle: true)
    check("…and it leaves on the same four quiet seconds as the others",
          run(2, holding, reading(memory: 1_000_000), idle: true).alerts.memory == .residue
              && run(3, holding, reading(memory: 1_000_000), idle: true).alerts.memory == .calm)
    // A turn starting clears every counter, memory's included: what a rate rule and this one now
    // share is that the condition does not APPLY while the session is working.
    check("a turn starting puts the memory warning out on that very reading too",
          run(1, holding, heavy, idle: false).alerts.memory == .calm)
    check("…and the clock starts again from nothing rather than draining away",
          run(5, run(1, holding, heavy, idle: false), heavy, idle: true).alerts.memory == .calm)

    // MARK: a silence long enough to be a different afternoon

    // THE DEFECT THE GAP GUARD PREVENTS, which the seconds alone introduced: held-ness is the
    // distance between two instants, so a lid closed on an idle tree holding four gigabytes and
    // opened the next morning met the condition "without a break" for eight hours - across exactly
    // two readings, with nothing sampled in between. The card lit on the first reading after the
    // wake, and App Nap stretching the background timer is the same shape less dramatically.
    var slept = Sampler(now: t0, capacity: machine)
    check("six seconds of a heavy idle tree is not yet a warning",
          slept.run(3, heavy, idle: true).memory == .calm)
    check("…and a reading from the other side of a night is new evidence, not eight hours of it",
          slept.step(after: 8 * 3600, heavy, idle: true).memory == .calm)
    check("…so the card lights once the machine has been awake for the ten seconds",
          slept.run(5, heavy, idle: true).memory == .residue)
    // AND WHAT IT MUST NOT THROW AWAY: a missed tick or two is a busy main thread, and the run of
    // evidence carries across it exactly as the trend ring's does (`FootprintTrendSeries.staleAfter`
    // is the same rule about the same silence).
    var dozed = Sampler(now: t0, capacity: machine)
    dozed.run(3, heavy, idle: true)
    check("a silence a busy main thread can cause is still one run of evidence",
          dozed.step(after: FootprintAlarm.gapAfter, heavy, idle: true).memory == .residue)
    check("the two clocks agree on what a silence is",
          FootprintAlarm.gapAfter == FootprintTrendSeries.staleAfter)
    // A WARNING ALREADY DRAWN GOES WITH THE EVIDENCE THAT EARNED IT: what was true before the night
    // is not what this reading is about, and the card has to earn it again from here.
    var lit = Sampler(now: t0, capacity: machine)
    check("a warning that has been earned is drawn",
          lit.run(6, heavy, idle: true).memory == .residue)
    check("…and a reading after a night puts it out rather than carrying it over",
          lit.step(after: 8 * 3600, heavy, idle: true).memory == .calm)
    // THE RATES MIX INSIDE ONE RUN OF EVIDENCE, which is what the seconds were for and what the gap
    // guard must not undo: four fast readings and one slow one is sixteen seconds of evidence
    // rather than five ticks of it, and the slow one is well inside the silence a run survives.
    var opened = Sampler(now: t0, capacity: machine)
    check("four fast readings are not the ten seconds yet",
          opened.run(4, heavy, idle: true).memory == .calm)
    check("…and a slow reading after them is judged on the seconds it adds, not as a fifth tick",
          opened.step(after: 10, heavy, idle: true).memory == .residue)

    // MARK: the machine-level tier

    // WHAT THE MISMATCH RULE IS STRUCTURALLY BLIND TO, and the whole reason there is a second tier:
    // a session eating the MACHINE while a turn is running. Every rule above is gated on idleness,
    // correctly, and it follows that a tree can hold half the RAM and most of the cores for an hour
    // and never say a word (Albert, 2026-08-17). So these are judged on every reading, and they are
    // shares of the machine rather than absolute numbers (`MachineCapacity`).
    //
    // THE WHOLE TABLE RATHER THAN THE INTERESTING ROW OF IT: both metrics, all three levels, a
    // working session and an idle one, and each of the two waiting periods asserted from BOTH sides
    // of its edge. That set is enumerable rather than sampled - two metrics by three levels by two
    // states - so nothing here can pass by being the one case somebody happened to think of.
    let calmCPU = 2.0, residueCPU = 300.0, saturatedCPU = 600.0
    let calmMemory: UInt64 = 1_000_000, residueMemory: UInt64 = 4_000_000_000
    let saturatedMemory: UInt64 = 9_000_000_000
    check("the fixture machine's own lines are where the shares put them",
          machine.saturatedCPUPercent == 560 && machine.saturatedMemoryBytes == 8_000_000_000)
    check("…so the fixtures above sit under them and the ones here sit over",
          residueCPU < machine.saturatedCPUPercent && saturatedCPU >= machine.saturatedCPUPercent
              && residueMemory < machine.saturatedMemoryBytes
              && saturatedMemory >= machine.saturatedMemoryBytes)
    struct Row {
        var cpu: Double, memory: UInt64, idle: Bool, seconds: TimeInterval
        var says: FootprintAlerts
        var why: String
        /// Held elevated for this table, which is about the WINDOWS: the memory tier's second
        /// witness is an axis of its own and is enumerated in full in the table below this one.
        var pressure: MachineMemoryPressure = .warning
    }
    let table = [
        Row(cpu: calmCPU, memory: calmMemory, idle: true, seconds: 200,
            says: FootprintAlerts(), why: "an idle session doing nothing says nothing, ever"),
        Row(cpu: residueCPU, memory: residueMemory, idle: true, seconds: 8,
            says: FootprintAlerts(), why: "eight seconds of residue is not the ten"),
        Row(cpu: residueCPU, memory: residueMemory, idle: true, seconds: 10,
            says: FootprintAlerts(cpu: .residue, memory: .residue),
            why: "ten seconds of it is the amber tier on both readings"),
        Row(cpu: saturatedCPU, memory: saturatedMemory, idle: true, seconds: 10,
            says: FootprintAlerts(cpu: .residue, memory: .saturation),
            why: "the memory's share needs the same ten seconds, the CPU's needs minutes"),
        Row(cpu: saturatedCPU, memory: saturatedMemory, idle: true, seconds: 178,
            says: FootprintAlerts(cpu: .residue, memory: .saturation),
            why: "two seconds short of three minutes is still the amber tier for the CPU"),
        Row(cpu: saturatedCPU, memory: saturatedMemory, idle: true, seconds: 180,
            says: FootprintAlerts(cpu: .saturation, memory: .saturation),
            why: "three minutes of held cores outlasts a build, and the card goes red"),
        Row(cpu: residueCPU, memory: residueMemory, idle: false, seconds: 200,
            says: FootprintAlerts(),
            why: "a working session's own spending is its work, however long it runs"),
        Row(cpu: saturatedCPU, memory: saturatedMemory, idle: false, seconds: 8,
            says: FootprintAlerts(), why: "and neither share is earned in eight seconds either"),
        Row(cpu: saturatedCPU, memory: saturatedMemory, idle: false, seconds: 10,
            says: FootprintAlerts(memory: .saturation),
            why: "but half the machine's memory is said while the turn is still running"),
        Row(cpu: saturatedCPU, memory: saturatedMemory, idle: false, seconds: 178,
            says: FootprintAlerts(memory: .saturation),
            why: "and the cores are not, two seconds short"),
        Row(cpu: saturatedCPU, memory: saturatedMemory, idle: false, seconds: 180,
            says: FootprintAlerts(cpu: .saturation, memory: .saturation),
            why: "and are at three minutes, working or not"),
    ]
    for row in table {
        check(row.why,
              held(reading(cpu: row.cpu, memory: row.memory), idle: row.idle, for: row.seconds,
                   pressure: row.pressure) == row.says)
    }

    // THE MEMORY TIER TAKES TWO WITNESSES, and this is the whole cross product of them: the share
    // met or not, each of the three levels the kernel publishes, working or idle. Twelve rows for
    // twelve states, because the set is small enough to state rather than to sample.
    //
    // WHY THE SECOND WITNESS EXISTS AT ALL: the tree's figure counts a shared page once per process
    // that maps it (`ProcessResourceSample.memoryBytes`), so a fan-out of node workers or a
    // browser's helpers reads as half a machine it has not taken - and a red drawn on that alone is
    // a false red on a tier whose whole promise is that it is rare and real (codex review of
    // 1d2ca9d). The kernel counts that page once, so the two together say what neither says alone.
    for pressure in [MachineMemoryPressure.normal, .warning, .critical] {
        for idle in [true, false] {
            // A tree reading over the machine's own line. The residue tier is a separate question
            // and still answers it: an idle tree over four gigabytes is a residue whatever the
            // machine thinks of its own memory.
            let overTheLine: FootprintAlertLevel = pressure.isElevated ? .saturation
                                                                      : (idle ? .residue : .calm)
            check("a tree reading half the machine is \(overTheLine) "
                      + "under \(pressure) pressure while \(idle ? "idle" : "working")",
                  held(reading(cpu: calmCPU, memory: saturatedMemory), idle: idle, for: 10,
                       pressure: pressure).memory == overTheLine)
            // And one that does not read over the line is never red, however loudly the machine is
            // complaining: the pressure says the MACHINE is short and this card is about a session,
            // so the share is what says which session it would be.
            check("…while one that does not is never red under \(pressure) pressure "
                      + "while \(idle ? "idle" : "working")",
                  held(reading(cpu: calmCPU, memory: residueMemory), idle: idle, for: 10,
                       pressure: pressure).memory == (idle ? .residue : .calm))
        }
    }
    // AND THE GATE CLOSES A RUN OF EVIDENCE THE WAY A TREE LETTING GO DOES: nine of the ten seconds
    // under a complaining machine and the last one under a calm one is not ten seconds of the
    // condition, because the condition includes the machine.
    var easing = Sampler(now: t0, capacity: machine, pressure: .warning)
    let overTheLine = reading(cpu: calmCPU, memory: saturatedMemory)
    easing.run(5, overTheLine, idle: false)
    check("eight seconds of both witnesses is not the ten",
          easing.state.alerts.memory == .calm)
    easing.pressure = .normal
    check("…and the machine going quiet at the tenth second leaves nothing to light",
          easing.run(1, overTheLine, idle: false).memory == .calm)
    easing.pressure = .warning
    check("…the run starting again from there rather than resuming",
          easing.run(5, overTheLine, idle: false).memory == .calm
              && easing.run(1, overTheLine, idle: false).memory == .saturation)

    // WHAT THE KERNEL'S LEVELS MEAN, and the one direction an unreadable answer is allowed to fall.
    check("the three levels are the ones the sysctl publishes",
          MachineMemoryPressure.normal.rawValue == 1 && MachineMemoryPressure.warning.rawValue == 2
              && MachineMemoryPressure.critical.rawValue == 4)
    check("…and everything above normal is a machine that is complaining",
          !MachineMemoryPressure.normal.isElevated && MachineMemoryPressure.warning.isElevated
              && MachineMemoryPressure.critical.isElevated)
    // FAIL-CLOSED, the same direction a capacity that cannot be read takes: a machine that will not
    // say is not complaining, so the memory tier's second witness stays silent and the card is
    // amber at worst. The other way round turns every heavy tree red on a kernel that answered
    // something this enumeration has no case for.
    check("a level the machine would not give us is not a complaint",
          MachineMemoryPressure.reading(of: nil) == .normal)
    check("…and neither is one this enumeration has no case for",
          MachineMemoryPressure.reading(of: 0) == .normal
              && MachineMemoryPressure.reading(of: 3) == .normal
              && MachineMemoryPressure.reading(of: 8) == .normal)
    check("…while the three it does have are read as themselves",
          MachineMemoryPressure.reading(of: 1) == .normal
              && MachineMemoryPressure.reading(of: 2) == .warning
              && MachineMemoryPressure.reading(of: 4) == .critical)
    // Read from the machine rather than derived here, which is the one thing a fixture cannot stand
    // in for: this app cannot work out from a process table what the kernel already knows.
    let rule = (try? String(contentsOfFile: "Tally/Core/FootprintAlerts.swift",
                            encoding: .utf8)) ?? ""
    check("the level is read off the machine's own sysctl",
          rule.contains("sysctlbyname(\"kern.memorystatus_vm_pressure_level\","))
    check("…and a read that did not succeed produces no level at all",
          rule.contains("else { return nil }")
              && rule.contains("level.flatMap(MachineMemoryPressure.init(rawValue:)) ?? .normal"))
    // RED OUTRANKS AMBER ON THE SAME READING, which the table above states twice and this states as
    // the rule it comes from: an idle tree over the machine's line meets BOTH conditions, and the
    // card has one colour to spend on it.
    let both = run(6, FootprintAlertState(), reading(memory: saturatedMemory), idle: true)
    check("a reading that meets both conditions is drawn as the louder of the two",
          both.memory.lit && both.memorySaturation.lit && both.alerts.memory == .saturation)
    check("…which is the order the levels themselves are in",
          FootprintAlertLevel.calm < .residue && FootprintAlertLevel.residue < .saturation)

    // A TURN STARTING DOES NOT TOUCH THIS EVIDENCE, which is the difference the separate tracks
    // exist for, and it is asserted BESIDE the mismatch track it differs from: the same interruption
    // on the same tick, one clock kept and one thrown away.
    var mixed = Sampler(now: t0, capacity: machine)
    let saturating = reading(cpu: saturatedCPU, memory: saturatedMemory)
    mixed.run(89, saturating, idle: true)                       // 176 seconds of evidence
    check("176 seconds of held cores is not yet the three minutes",
          mixed.state.alerts.cpu == .residue)
    check("…and the mismatch clock beside it has long since lit",
          mixed.state.memory.lit && mixed.state.cpu.lit)
    mixed.step(after: 2, saturating, idle: false)               // a turn starts
    check("a turn starting throws the mismatch evidence away, warning and all",
          mixed.state.cpu == FootprintAlertTrack() && mixed.state.memory == FootprintAlertTrack())
    check("…and leaves the machine-level clock running, so two more seconds light it",
          mixed.step(after: 2, saturating, idle: false).cpu == .saturation)

    // AND A SILENCE THROWS AWAY BOTH, because the machine-level clock is a distance between two
    // instants on exactly the same terms: a lid closed on a saturated tree and opened the next
    // morning is one reading and then another, whatever the session was doing in between.
    var sleptSaturated = Sampler(now: t0, capacity: machine)
    sleptSaturated.run(89, saturating, idle: false)
    check("…a night between two readings is new evidence for the machine-level clock too",
          sleptSaturated.step(after: 8 * 3600, saturating, idle: false).cpu == .calm)
    check("…and a warning already earned goes with the evidence that earned it",
          sleptSaturated.run(91, saturating, idle: false).cpu == .saturation
              && sleptSaturated.step(after: 8 * 3600, saturating, idle: false).cpu == .calm)
    // It leaves on the same four quiet seconds as everything else here: hard to earn, easy to lose.
    let saturated = run(91, FootprintAlertState(), saturating, idle: false)
    check("the machine-level warning is put out by the same four quiet seconds",
          run(2, saturated, reading(cpu: calmCPU, memory: calmMemory), idle: false,
              from: t0).alerts.cpu == .saturation
              && run(3, saturated, reading(cpu: calmCPU, memory: calmMemory), idle: false,
                     from: t0).alerts.cpu == .calm)

    // THE LINES ARE THE MACHINE'S, WHICH IS THE WHOLE POINT OF THE SHARES: the same reading is a
    // saturation on a small machine and an ordinary afternoon on a large one, and no constant in
    // the rule can say that.
    let laptop = MachineCapacity(physicalMemoryBytes: 8_000_000_000, cores: 4)
    let studio = MachineCapacity(physicalMemoryBytes: 192_000_000_000, cores: 24)
    let sameReading = reading(cpu: 600, memory: 9_000_000_000)
    check("a reading that takes a laptop is a saturation on it",
          held(sameReading, idle: false, for: 180, on: laptop)
              == FootprintAlerts(cpu: .saturation, memory: .saturation))
    check("…and the very same reading says nothing at all on a machine that has the room",
          held(sameReading, idle: false, for: 180, on: studio) == FootprintAlerts())
    check("…the lines moving with the hardware rather than with the rule",
          laptop.saturatedCPUPercent == 280 && studio.saturatedCPUPercent == 1680
              && laptop.saturatedMemoryBytes == 4_000_000_000
              && studio.saturatedMemoryBytes == 96_000_000_000)
    // AND THE MACHINE IS READ FROM THE MACHINE, which is the one thing a fixture cannot stand in
    // for: a share of a constant somebody typed is an absolute threshold wearing a share's clothes.
    check("the capacity the rule defaults to is this machine's own",
          MachineCapacity.current.cores == ProcessInfo.processInfo.activeProcessorCount
              && MachineCapacity.current.physicalMemoryBytes
                  == ProcessInfo.processInfo.physicalMemory)
    // A MACHINE THAT WILL NOT SAY WHAT IT HAS WARNS ABOUT NOTHING, which is the safe direction: a
    // zero taken at face value makes the share zero and every reading a saturation.
    let mute = MachineCapacity(physicalMemoryBytes: 0, cores: 0)
    check("a machine reporting nothing puts the lines out of reach rather than at nought",
          mute.saturatedMemoryBytes == .max && mute.saturatedCPUPercent == .infinity)
    check("…so no reading saturates on it",
          held(reading(cpu: 100_000, memory: 512_000_000_000), idle: false, for: 400, on: mute)
              == FootprintAlerts())

    // MARK: how a warned line is drawn

    let warned = ProcessFootprint(processes: 4, cpuPercent: 92, memoryBytes: 5_000_000_000,
                                  listeningPorts: [3000],
                                  alerts: FootprintAlerts(cpu: .residue, memory: .residue))
    let drawn = ProcessTree.segments(warned, unit: "procs")
    check("the line is handed over in pieces, each saying what it is",
          drawn.map(\.kind) == [.processes, .cpu, .memory])
    check("…with the warned ones marked and the rest not",
          drawn.map(\.alert) == [false, true, true])
    // A warning changes how a field is DRAWN and never what it says, so the sentence is the same
    // one either way - which is what lets the spoken line be built from the same pieces.
    check("…and the words are the line, unchanged",
          ProcessTree.line(warned, unit: "procs") == drawn.map(\.text)
              .joined(separator: pickEffortSeparator))
    // A WARNING COMES FORWARD, and what falls off the end of a narrow card is the healthy fields.
    // A card is 236pt of content at its narrowest and the line truncates at the tail, so the full
    // sentence does not fit: in reading order the disk warning's MARK survives and its number does
    // not, leaving a triangle stranded beside the memory figure (measured 2026-08-15, codex review
    // of 57c9795: `4 procs · 100% CPU · 3.9 GB · ` is 165.6pt on its own).
    let stranded = ProcessFootprint(processes: 4, cpuPercent: 100, memoryBytes: 3_900_000_000,
                                    diskWriteBytesPerSecond: 12_000_000, diskLeader: "esbuild",
                                    listeningPorts: [3000],
                                    alerts: FootprintAlerts(disk: .residue))
    check("the warned field is drawn before the healthy ones, whatever order it is written in",
          ProcessTree.segments(stranded, unit: "procs").map(\.kind)
              == [.processes, .disk, .cpu, .memory])
    // The count is not a reading in the same sense: it is the context every other field is about,
    // so it stays at the front and a line never opens on what is wrong before what it is about.
    check("…and the process count keeps the front of the line regardless",
          ProcessTree.segments(stranded, unit: "procs").first?.kind == .processes)
    // Only across the warning line, never within it: two warned fields keep their reading order,
    // and so do the healthy ones behind them.
    check("fields keep their reading order inside their own group",
          ProcessTree.segments(ProcessFootprint(processes: 4, cpuPercent: 100,
                                                memoryBytes: 3_900_000_000,
                                                diskWriteBytesPerSecond: 12_000_000,
                                                listeningPorts: [3000],
                                                alerts: FootprintAlerts(cpu: .residue,
                                                                        disk: .residue)),
                               unit: "procs").map(\.kind)
              == [.processes, .cpu, .disk, .memory])
    // Nothing warned is the ordinary card, and it reads exactly as it is written.
    check("a card with nothing wrong is in reading order, front to back",
          ProcessTree.segments(ProcessFootprint(processes: 4, cpuPercent: 100,
                                                memoryBytes: 3_900_000_000,
                                                diskWriteBytesPerSecond: 12_000_000,
                                                listeningPorts: [3000]),
                               unit: "procs").map(\.kind)
              == [.processes, .cpu, .memory, .disk])
    // The stated line is the same pieces joined, so the sentence a reader HEARS moves with them
    // rather than describing an order the card is not in.
    check("…and the stated line follows the pieces rather than a second order of its own",
          ProcessTree.line(stranded, unit: "procs")
              == "4 procs · 12 MB/s (esbuild) · 100% CPU · 3.9 GB")
    // A session that has started nothing is the ordinary card, not an empty measurement: the count
    // leads the line at nought exactly as it does at four, and the readings behind it are the
    // session's own (`ProcessTree.dispatched`). The store is what draws no card at all, and it
    // decides that on an empty TREE rather than on this count.
    check("a session that has started nothing still leads with its count",
          ProcessTree.segments(ProcessFootprint(processes: 0, cpuPercent: 9, listeningPorts: []),
                               unit: "procs").map(\.kind) == [.processes, .cpu])
}
