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
    struct Sampler {
        var state = FootprintAlertState()
        var now: Date
        var every: TimeInterval = 2
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
            state = FootprintAlarm.advance(state, reading: reading, idle: idle, at: now)
            return state.alerts
        }
    }
    func run(_ ticks: Int, _ state: FootprintAlertState, _ reading: ProcessFootprint, idle: Bool,
             every: TimeInterval = 2, from: Date? = nil) -> FootprintAlertState {
        var sampler = Sampler(state: state, now: from ?? t0, every: every)
        sampler.run(ticks, reading, idle: idle)
        return sampler.state
    }
    let hot = reading(cpu: 300)
    check("a working session burning three cores is a build, and says nothing",
          run(20, FootprintAlertState(), hot, idle: false).alerts == FootprintAlerts())
    // TEN SECONDS OF IT: a single reading over the line is a compaction or one `rg`, and a warning
    // that came and went inside two seconds would be noise on a card somebody is watching. Held
    // from the first reading that SAW it, so on a two-second beat the fifth is eight seconds in.
    check("an idle session burning a core says nothing eight seconds in",
          run(5, FootprintAlertState(), hot, idle: true).alerts.cpu == false)
    check("…and says it once it has held for ten",
          run(6, FootprintAlertState(), hot, idle: true).alerts.cpu)
    // THE SAME TEN SECONDS AT THE OTHER RATE, which is the defect the seconds fix: five ticks meant
    // ten seconds with the panel open and fifty behind it, and a warning could be earned by four
    // fast readings and one slow one - evidence over two spans of time added together.
    check("a slower sampler warns on the same ten seconds of evidence, not on the same five ticks",
          run(1, FootprintAlertState(), hot, idle: true, every: 10).alerts.cpu == false
              && run(2, FootprintAlertState(), hot, idle: true, every: 10).alerts.cpu)
    // Slower to leave than to arrive, so a condition sitting on the threshold does not blink.
    let burning = run(6, FootprintAlertState(), hot, idle: true)
    let quiet = reading(cpu: 2)
    check("one quiet reading does not put it out",
          run(1, burning, quiet, idle: true).alerts.cpu)
    check("…and four seconds of them do",
          run(2, burning, quiet, idle: true, from: t0).alerts.cpu
              && run(3, burning, quiet, idle: true, from: t0).alerts.cpu == false)
    check("…on the same four seconds whatever the rate",
          run(1, burning, quiet, idle: true, every: 10, from: t0).alerts.cpu
              && run(2, burning, quiet, idle: true, every: 10, from: t0).alerts.cpu == false)
    // THE ONE THING THAT PUTS IT OUT AT ONCE is the session going back to work: at that instant the
    // warning is not unproven, it is about a state the session is no longer in.
    check("a turn starting puts it out on that very reading, whatever the number says",
          run(1, burning, hot, idle: false).alerts.cpu == false)
    check("…and the clock starts again from nothing rather than draining away",
          run(5, run(1, burning, hot, idle: false), hot, idle: true).alerts.cpu == false)
    // The disk rule is the same shape and counts from the same megabyte a second the segment
    // becomes visible at, so "shown" and "worth watching" cannot drift apart.
    check("an idle session writing to disk says so once it has held for ten seconds",
          run(5, FootprintAlertState(), reading(disk: 4_000_000), idle: true).alerts.disk == false
              && run(6, FootprintAlertState(), reading(disk: 4_000_000), idle: true).alerts.disk)
    check("…and writing below the rate the segment is drawn at is not writing",
          run(20, FootprintAlertState(), reading(disk: ProcessTree.diskFloor - 1), idle: true)
              .alerts.disk == false)
    check("…while a working session writing hard is just working",
          run(20, FootprintAlertState(), reading(disk: 40_000_000), idle: false).alerts.disk == false)
    // MEMORY IS UNDER THE SAME RULE, and used to be the exception. Four gigabytes under a build IS
    // the build - a language server, a bundler and a test runner - and saying so tells the person
    // who started it what they already know. The same four gigabytes with nothing running is a tree
    // that did not let go, which is the one thing on this line nobody can see another way.
    let heavy = reading(memory: 4_000_000_000)
    check("a working session holding four gigabytes is a build, and says nothing",
          run(20, FootprintAlertState(), heavy, idle: false).alerts.memory == false)
    check("an idle session holding four gigabytes says nothing eight seconds in",
          run(5, FootprintAlertState(), heavy, idle: true).alerts.memory == false)
    check("…and says it once it has held for ten seconds",
          run(6, FootprintAlertState(), heavy, idle: true).alerts.memory)
    check("…and just under it says nothing at all",
          run(20, FootprintAlertState(), reading(memory: 3_999_999_999), idle: true)
              .alerts.memory == false)
    let holding = run(6, FootprintAlertState(), heavy, idle: true)
    check("…and it leaves on the same four quiet seconds as the others",
          run(2, holding, reading(memory: 1_000_000), idle: true).alerts.memory
              && run(3, holding, reading(memory: 1_000_000), idle: true).alerts.memory == false)
    // A turn starting clears every counter, memory's included: what a rate rule and this one now
    // share is that the condition does not APPLY while the session is working.
    check("a turn starting puts the memory warning out on that very reading too",
          run(1, holding, heavy, idle: false).alerts.memory == false)
    check("…and the clock starts again from nothing rather than draining away",
          run(5, run(1, holding, heavy, idle: false), heavy, idle: true).alerts.memory == false)

    // MARK: a silence long enough to be a different afternoon

    // THE DEFECT THE GAP GUARD PREVENTS, which the seconds alone introduced: held-ness is the
    // distance between two instants, so a lid closed on an idle tree holding four gigabytes and
    // opened the next morning met the condition "without a break" for eight hours - across exactly
    // two readings, with nothing sampled in between. The card lit on the first reading after the
    // wake, and App Nap stretching the background timer is the same shape less dramatically.
    var slept = Sampler(now: t0)
    check("six seconds of a heavy idle tree is not yet a warning",
          slept.run(3, heavy, idle: true).memory == false)
    check("…and a reading from the other side of a night is new evidence, not eight hours of it",
          slept.step(after: 8 * 3600, heavy, idle: true).memory == false)
    check("…so the card lights once the machine has been awake for the ten seconds",
          slept.run(5, heavy, idle: true).memory)
    // AND WHAT IT MUST NOT THROW AWAY: a missed tick or two is a busy main thread, and the run of
    // evidence carries across it exactly as the trend ring's does (`FootprintTrendSeries.staleAfter`
    // is the same rule about the same silence).
    var dozed = Sampler(now: t0)
    dozed.run(3, heavy, idle: true)
    check("a silence a busy main thread can cause is still one run of evidence",
          dozed.step(after: FootprintAlarm.gapAfter, heavy, idle: true).memory)
    check("the two clocks agree on what a silence is",
          FootprintAlarm.gapAfter == FootprintTrendSeries.staleAfter)
    // A WARNING ALREADY DRAWN GOES WITH THE EVIDENCE THAT EARNED IT: what was true before the night
    // is not what this reading is about, and the card has to earn it again from here.
    var lit = Sampler(now: t0)
    check("a warning that has been earned is drawn", lit.run(6, heavy, idle: true).memory)
    check("…and a reading after a night puts it out rather than carrying it over",
          lit.step(after: 8 * 3600, heavy, idle: true).memory == false)
    // THE RATES MIX INSIDE ONE RUN OF EVIDENCE, which is what the seconds were for and what the gap
    // guard must not undo: four fast readings and one slow one is sixteen seconds of evidence
    // rather than five ticks of it, and the slow one is well inside the silence a run survives.
    var opened = Sampler(now: t0)
    check("four fast readings are not the ten seconds yet",
          opened.run(4, heavy, idle: true).memory == false)
    check("…and a slow reading after them is judged on the seconds it adds, not as a fifth tick",
          opened.step(after: 10, heavy, idle: true).memory)

    // MARK: how a warned line is drawn

    let warned = ProcessFootprint(processes: 4, cpuPercent: 92, memoryBytes: 5_000_000_000,
                                  listeningPorts: [3000],
                                  alerts: FootprintAlerts(cpu: true, memory: true))
    let drawn = ProcessTree.segments(warned, unit: "procs")
    check("the line is handed over in pieces, each saying what it is",
          drawn.map(\.kind) == [.processes, .cpu, .memory, .ports])
    check("…with the warned ones marked and the rest not",
          drawn.map(\.alert) == [false, true, true, false])
    // A warning changes how a field is DRAWN and never what it says, so the sentence is the same
    // one either way - which is what lets the spoken line be built from the same pieces.
    check("…and the words are the line, unchanged",
          ProcessTree.line(warned, unit: "procs") == drawn.map(\.text)
              .joined(separator: pickEffortSeparator))
    // A WARNING COMES FORWARD, and what falls off the end of a narrow card is the healthy fields.
    // A card is 182pt of content at its narrowest and the line truncates at the tail, so the full
    // sentence does not fit: in reading order the disk warning's MARK survives and its number does
    // not, leaving a triangle stranded beside the memory figure (measured 2026-08-15, codex review
    // of 57c9795: `4 procs · 100% CPU · 3.9 GB · ` is 165.6pt of the 182 on its own).
    let stranded = ProcessFootprint(processes: 4, cpuPercent: 100, memoryBytes: 3_900_000_000,
                                    diskWriteBytesPerSecond: 12_000_000, diskLeader: "esbuild",
                                    listeningPorts: [3000],
                                    alerts: FootprintAlerts(disk: true))
    check("the warned field is drawn before the healthy ones, whatever order it is written in",
          ProcessTree.segments(stranded, unit: "procs").map(\.kind)
              == [.processes, .disk, .cpu, .memory, .ports])
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
                                                alerts: FootprintAlerts(cpu: true, disk: true)),
                               unit: "procs").map(\.kind)
              == [.processes, .cpu, .disk, .memory, .ports])
    // Nothing warned is the ordinary card, and it reads exactly as it is written.
    check("a card with nothing wrong is in reading order, front to back",
          ProcessTree.segments(ProcessFootprint(processes: 4, cpuPercent: 100,
                                                memoryBytes: 3_900_000_000,
                                                diskWriteBytesPerSecond: 12_000_000,
                                                listeningPorts: [3000]),
                               unit: "procs").map(\.kind)
              == [.processes, .cpu, .memory, .disk, .ports])
    // The stated line is the same pieces joined, so the sentence a reader HEARS moves with them
    // rather than describing an order the card is not in.
    check("…and the stated line follows the pieces rather than a second order of its own",
          ProcessTree.line(stranded, unit: "procs")
              == "4 procs · 12 MB/s (esbuild) · 100% CPU · 3.9 GB · :3000")
    check("a tree with nothing to say has no pieces either",
          ProcessTree.segments(ProcessFootprint(processes: 0, cpuPercent: 9, listeningPorts: []),
                               unit: "procs").isEmpty)
}
