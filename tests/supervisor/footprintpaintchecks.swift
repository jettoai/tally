import Foundation

// WHAT A TICK PUBLISHES ONCE EVERY CARD HAS BEEN READ
// (Tally/Stores/ProcessFootprintTiming.swift, `ProcessFootprintStore.painted`).
//
// WRITTEN BECAUSE THE PIECE MOVED AND NOTHING BEHAVIOURAL WAS WATCHING IT. The sampling pass has no
// harness of its own and never could have one cheaply: it walks the real process table and reads a
// real roster, so everything asserted about it in this repository is a source-string lock
// (processtreelinechecks.swift, footprinttrendsurfacechecks.swift). Those locks say the right lines
// are present in the right order; they cannot say what the code computes. Measured directly
// (2026-09-02): with `painted` gutted to `return ([:], [:])` the whole 5,000-assertion supervisor
// suite stayed green, which is the exact shape of hole this file closes for the part that moved.
//
// THE STEP IS REACHABLE ON ITS OWN because it takes what it needs as parameters: a list of
// measurements, the machine's memory pressure and the ring. So the fixtures are ordinary values and
// nothing here touches a process.
@MainActor
func runFootprintPaintChecks() {
    let store = ProcessFootprintStore.shared
    // The singleton's warning memory is shared, and the sampling pass never runs in this suite, so
    // it starts empty and is put back empty. Stated rather than assumed: a suite that left state on
    // a singleton would be a defect in exactly the direction this file exists to catch.
    let held = store.alertState
    defer { store.alertState = held }
    store.alertState = [:]

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func reading(_ key: String, memory: UInt64, cpu: Double? = 12,
                 interval: TimeInterval? = 2) -> FootprintMeasurement {
        FootprintMeasurement(
            key: key,
            footprint: ProcessFootprint(processes: 3, cpuPercent: cpu, memoryBytes: memory,
                                        listeningPorts: []),
            interval: interval, idle: false)
    }

    var trends = FootprintHistory()
    let painted = store.painted([reading("100", memory: 400_000_000),
                                 reading("200", memory: 900_000_000)],
                                pressure: .normal, trends: &trends, at: now)
    // THE GUTTING MUTATION DIES HERE: a step that returns nothing leaves every card on the board
    // without a footprint, which reads as "no session has a live tree" - a blank page rather than
    // an error.
    check("every card that was read comes back with something to draw",
          painted.drawn.keys.sorted() == ["100", "200"])
    check("…and the figures are the ones it was handed, on an ordinary launch",
          painted.drawn["200"]?.memoryBytes == 900_000_000
              && painted.drawn["100"]?.cpuPercent == 12)
    // The counting a warning needs is per session and has to survive the tick that took it, which
    // is the whole reason this hands one back rather than keeping it (`FootprintAlarm`).
    check("…and each of them has a warning state to carry into the next tick",
          painted.alerts.keys.sorted() == ["100", "200"])
    // THE RING IS OFFERED THE FOOTPRINT THE CARD DRAWS, and only where there is a rate to record:
    // a first pair has no interval yet, and a point written from one would state a span nobody
    // measured.
    check("the trend takes a point for the card that has an interval behind it",
          trends["100"] != nil && trends["200"] != nil)
    var first = FootprintHistory()
    _ = store.painted([reading("100", memory: 400_000_000, cpu: nil, interval: nil)],
                      pressure: .normal, trends: &first, at: now)
    check("…and none at all for a card whose rate has not been established",
          first["100"] == nil)
    // A board with nothing on it is not a special case, only an empty one.
    var quiet = FootprintHistory()
    let nothing = store.painted([], pressure: .normal, trends: &quiet, at: now)
    check("an empty board publishes nothing and warns about nothing",
          nothing.drawn.isEmpty && nothing.alerts.isEmpty && quiet == FootprintHistory())
}
