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
    func run(_ ticks: Int, _ state: FootprintAlertState, _ reading: ProcessFootprint,
             idle: Bool) -> FootprintAlertState {
        var next = state
        for _ in 0..<ticks { next = FootprintAlarm.advance(next, reading: reading, idle: idle) }
        return next
    }
    let hot = reading(cpu: 300)
    check("a working session burning three cores is a build, and says nothing",
          run(20, FootprintAlertState(), hot, idle: false).alerts == FootprintAlerts())
    // FIVE TICKS, about ten seconds: a single tick over the line is a compaction or one `rg`, and a
    // warning that came and went inside two seconds would be noise on a card somebody is watching.
    check("an idle session burning a core says nothing on the fourth tick",
          run(4, FootprintAlertState(), hot, idle: true).alerts.cpu == false)
    check("…and says it on the fifth",
          run(5, FootprintAlertState(), hot, idle: true).alerts.cpu)
    // Slower to leave than to arrive, so a condition sitting on the threshold does not blink.
    let burning = run(5, FootprintAlertState(), hot, idle: true)
    check("one quiet tick does not put it out",
          run(1, burning, reading(cpu: 2), idle: true).alerts.cpu)
    check("…and two do",
          run(2, burning, reading(cpu: 2), idle: true).alerts.cpu == false)
    // THE ONE THING THAT PUTS IT OUT AT ONCE is the session going back to work: at that instant the
    // warning is not unproven, it is about a state the session is no longer in.
    check("a turn starting puts it out on that very tick, whatever the reading says",
          run(1, burning, hot, idle: false).alerts.cpu == false)
    check("…and the count starts again from nothing rather than draining away",
          run(4, run(1, burning, hot, idle: false), hot, idle: true).alerts.cpu == false)
    // The disk rule is the same shape and counts from the same megabyte a second the segment
    // becomes visible at, so "shown" and "worth watching" cannot drift apart.
    check("an idle session writing to disk says so once it has held for five ticks",
          run(4, FootprintAlertState(), reading(disk: 4_000_000), idle: true).alerts.disk == false
              && run(5, FootprintAlertState(), reading(disk: 4_000_000), idle: true).alerts.disk)
    check("…and writing below the rate the segment is drawn at is not writing",
          run(20, FootprintAlertState(), reading(disk: ProcessTree.diskFloor - 1), idle: true)
              .alerts.disk == false)
    check("…while a working session writing hard is just working",
          run(20, FootprintAlertState(), reading(disk: 40_000_000), idle: false).alerts.disk == false)
    // MEMORY IS HELD, NOT SPENT: there is nothing to be idle about, and a tree holding four
    // gigabytes is holding them whether or not a turn is running. So it needs no run of ticks.
    check("four gigabytes says so on the first tick, working or not",
          run(1, FootprintAlertState(), reading(memory: 4_000_000_000), idle: false).alerts.memory
              && run(1, FootprintAlertState(), reading(memory: 4_000_000_000), idle: true)
                  .alerts.memory)
    check("…and just under it says nothing",
          run(20, FootprintAlertState(), reading(memory: 3_999_999_999), idle: true)
              .alerts.memory == false)
    check("…and it leaves on the same two quiet ticks as the others",
          run(1, run(1, FootprintAlertState(), reading(memory: 4_000_000_000), idle: true),
              reading(memory: 1_000_000), idle: true).alerts.memory
              && run(2, run(1, FootprintAlertState(), reading(memory: 4_000_000_000), idle: true),
                     reading(memory: 1_000_000), idle: true).alerts.memory == false)

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
    check("a tree with nothing to say has no pieces either",
          ProcessTree.segments(ProcessFootprint(processes: 0, cpuPercent: 9, listeningPorts: []),
                               unit: "procs").isEmpty)
}
