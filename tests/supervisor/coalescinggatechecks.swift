import Foundation

// THE MAIN-THREAD SCANS THAT WENT TO THE BACKGROUND (2026-09-26, App Hanging on a loaded machine).
// The gate is pure and stated directly; that each store's IO sits inside its detached hop, and that
// each store runs one pass at a time, is stated off the sources, the only place an offline harness
// with no run loop can see it. Whether the main thread is actually free is measured with `sample`.
func runCoalescingGateChecks() {
    var idle = CoalescingGate()
    check("an idle gate starts a pass", idle.request() == true)

    var busy = CoalescingGate()
    _ = busy.request()
    let folded = (busy.request(), busy.request(), busy.request())
    check("requests during a pass fold into one follow-up",
          folded == (false, false, false) && busy.finish() == true && busy.finish() == false)

    var done = CoalescingGate()
    _ = done.request()
    _ = done.finish()
    check("a finished gate is idle again", done.request() == true && !done.pending)

    func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
    let roster = read("Tally/Stores/SessionRosterStore.swift")
    let scan = read("Tally/Stores/SessionRosterScan.swift")
    let login = read("Tally/Stores/LoginHealthStore.swift")
    let timing = read("Tally/Stores/ProcessFootprintTiming.swift")
    let pass = read("Tally/Stores/ProcessFootprintPass.swift")
    let treeReads = read("Tally/Core/FootprintMachineRead.swift")
    check("the roster sources this check reads are readable",
          !roster.isEmpty && !scan.isEmpty && !login.isEmpty)

    check("the roster's reading happens off the main thread",
          scan.contains("await Task.detached(priority: .utility) { Self.scan() }.value")
              && scan.contains("liveSessionStates().map(row)")
              && !roster.contains("liveSessionStates()"))
    check("one roster scan in flight, the rest folded",
          roster.contains("guard scanGate.request() else { return }")
              && scan.contains("if scanGate.finish() { startScan() }"))
    check("the seats are taken at publish time, from the seating then",
          roster.contains("func publish(_ scanned: [SessionRow])")
              && roster.contains("Self.seat(fixtured, seating: self.seating)"))
    check("opening the board reseats what is already scanned",
          roster.components(separatedBy: "if let lastScanned { publish(lastScanned) }").count == 3)
    check("login health waits for a fresh roster rather than reading a stale one",
          login.components(separatedBy: "await SessionRosterStore.shared.scanNow()").count == 3
              && !login.contains("SessionRosterStore.shared.refresh()"))

    check("the footprint sources this check reads are readable",
          !timing.isEmpty && !pass.isEmpty && !treeReads.isEmpty)
    check("one footprint pass at a time",
          timing.contains("guard sampleGate.request() else { return }")
              && timing.contains("repeat { await sample() } while sampleGate.finish()")
              && timing.contains("ProcessFootprintStore.shared.tick()")
              && !timing.contains("ProcessFootprintStore.shared.sample()"))
    check("the footprint pass waits for a fresh roster rather than reading a stale one",
          pass.contains("if viewers == 0 { await SessionRosterStore.shared.scanNow() }"))
    // Each IO call appears once in the pass, and inside a detached hop: after `Task.detached` and
    // before that hop's closing `}.value`.
    func insideHop(_ call: String, of source: String) -> Bool {
        guard let at = source.range(of: call) else { return false }
        let before = source[..<at.lowerBound]
        guard let hop = before.range(of: "await Task.detached(priority: .utility) {",
                                     options: .backwards) else { return false }
        return !source[hop.upperBound..<at.lowerBound].contains("}.value")
            && source.components(separatedBy: call).count == 2
    }
    check("the process table, the memory pressure and the leases are read off the main thread",
          insideHop("ProcessTree.liveProcesses()", of: pass)
              && insideHop("MachineMemoryPressure.current", of: pass)
              && insideHop("leaseReader?()", of: pass))
    check("the strays and every tree's readings are read off the main thread",
          insideHop("ProjectLoadAccounting.strayScan(", of: pass)
              && insideHop("FootprintTreeReads.take(", of: pass)
              && !pass.contains("ProcessTree.resourceSample(") && !pass.contains("readSessionAgents(")
              && !pass.contains("ProcessTree.listeningPorts(")
              && treeReads.contains("nonisolated static func take("))
}
