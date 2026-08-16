import Foundation

// WHICH PROCESSES A READING IS ABOUT, AND WHOSE THE THING BEING HELD IS - the assertions for the
// pure rules next door (Tally/Core/ProcessTreeCensus.swift), split from processtreelinechecks.swift
// along the same seam the source is split on: that file states what a person SEES, and these state
// which processes the numbers on it are about.
//
// All of it is pure, so every case here is stated with no processes and no store around it: the
// count's exclusion, the memory's holder, and who owns a port both when the reading is taken and
// when it is drawn a few ticks later.

func runProcessTreeCensusChecks() {
    // MARK: which processes the count is counting

    // THE SESSION'S OWN CLI IS NOT SOMETHING THE SESSION STARTED, and every card has one by
    // construction: counting it made "2 procs" the reading of a session running a single MCP
    // server (Albert, 2026-08-16).
    check("the process at the head of the tree is not one of the ones it started",
          ProcessTree.dispatched([100, 200, 300], child: 200) == [100, 300])
    // BY THE PUBLISHED PID, NEVER BY THE PROGRAM'S NAME, which is what makes these three true at
    // once: a nested Claude Code the session itself started is still counted…
    check("…and a Claude Code the session started itself is still counted",
          ProcessTree.dispatched([100, 200, 300, 400], child: 200).contains(400))
    // …a Codex session drops its own body under the very same rule, with nothing here knowing what
    // a provider is…
    check("…the rule knowing nothing about which provider the body belongs to",
          ProcessTree.dispatched([7, 8], child: 8) == [7])
    // …and a supervisor too old to publish the field keeps its old reading rather than a guess.
    check("…and a session that published no child keeps every process it holds",
          ProcessTree.dispatched([100, 200, 300], child: nil).count == 3)
    check("…as does one whose published child is not in the tree at all",
          ProcessTree.dispatched([100, 300], child: 200) == [100, 300])

    // MARK: what is holding the memory, and what is holding a port

    let held = ProcessResourceSample(times: [:], childTimes: [:],
                                     memory: [10: 3_000_000_000, 20: 400_000_000],
                                     at: Date(), ours: [])
    check("a process holding more than half the tree's memory is the one named",
          ProcessTree.memoryLeader(held) == 10)
    // HALF IS NOT ENOUGH, the same rule every other blame in this app is made under: a name beside
    // a figure claims one thing is doing this, and two halves make that claim false about both.
    check("…and two holding half each are neither of them named",
          ProcessTree.memoryLeader(ProcessResourceSample(times: [:], childTimes: [:],
                                                         memory: [10: 500, 20: 500],
                                                         at: Date())) == nil)
    // The meter is not the thing metered here either: a card must not answer "what is holding your
    // memory" with the app doing the reading.
    check("…and Tally's own are not eligible to be the answer",
          ProcessTree.memoryLeader(ProcessResourceSample(times: [:], childTimes: [:],
                                                         memory: [10: 3_000_000_000, 20: 400_000],
                                                         at: Date(), ours: [10])) == 20)
    check("…and a tree holding nothing names nobody",
          ProcessTree.memoryLeader(ProcessResourceSample(times: [:], childTimes: [:], memory: [:],
                                                         at: Date())) == nil)
    // A PORT TWO PROCESSES SHARE GOES TO THE LOWEST PID, and the point is that it is DECIDABLE: the
    // walk visits pids in whatever order a Set hands them over, so "the first one seen" would give
    // the card a name that changed every third tick (`SO_REUSEPORT`, a node cluster).
    check("a port several processes are listening on is credited to one of them, always the same one",
          ProcessTree.holders(of: [(port: 3000, pid: 900), (port: 3000, pid: 400),
                                   (port: 5173, pid: 700)]) == [3000: 400, 5173: 700]
              && ProcessTree.holders(of: [(port: 3000, pid: 400), (port: 3000, pid: 900),
                                          (port: 5173, pid: 700)]) == [3000: 400, 5173: 700])
    // Port zero is what an unbound or unreadable socket reports, and a card saying ":0" would be
    // reporting the read rather than the machine.
    check("…and a socket with no port is not a port",
          ProcessTree.holders(of: [(port: 0, pid: 400)]).isEmpty)

    // MARK: a port read three ticks ago, named now

    // A PORT READING IS CACHED AND A PID IS NOT AN IDENTITY. The ports are read every third visible
    // tick and never behind a closed panel, so the pid beside a port can be minutes or hours old,
    // and the machine hands pid numbers out again. What is recorded with the port is therefore what
    // its holder was RUNNING at the time, and a name is printed only while that is still true -
    // otherwise the card states a program that has never held that port (same shape as the fork
    // join-key defect: a stale key looked up in a fresh table).
    let programs = [400: "/opt/homebrew/bin/node", 700: "/usr/local/bin/next-server"]
    let recorded = ProcessTree.held([3000: 400, 5173: 700]) { programs[Int($0)] }
    check("what each port's holder was running is recorded with the port",
          recorded == [3000: ProcessPortHolder(pid: 400, path: "/opt/homebrew/bin/node"),
                       5173: ProcessPortHolder(pid: 700, path: "/usr/local/bin/next-server")])
    check("…and a holder still running it is named",
          ProcessTree.portNames(recorded) { programs[Int($0)] }
              == [3000: "node", 5173: "next-server"])
    // The pid number is now somebody else's, and that somebody is in this very tree - which is the
    // only case that produces a WRONG name rather than a missing one.
    check("…while a pid the machine has handed to another program is not",
          ProcessTree.portNames(recorded) { pid in
              pid == 400 ? "/usr/bin/esbuild" : programs[Int(pid)]
          } == [5173: "next-server"])
    check("…nor is one that has gone altogether",
          ProcessTree.portNames(recorded) { pid in pid == 400 ? nil : programs[Int(pid)] }
              == [5173: "next-server"])
    // A holder whose program could not be read when the port was taken cannot be confirmed later
    // either, so it is never named - absent is not a wildcard.
    check("…and a holder nobody could read then is not named now",
          ProcessTree.portNames([3000: ProcessPortHolder(pid: 400, path: nil)]) { _ in
              "/opt/homebrew/bin/node"
          }.isEmpty)
}
