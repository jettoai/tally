import Foundation

// `tally status --history [--minutes N] [--days D] [--gate X]... [--mem-min P] [--json]`: the last
// N minutes of the one-minute load and CPU share and, per local day, how often each gate would have let a new
// session open during working hours. It reads the files Tally.app writes to ~/.tally/host-load/
// (Tally/Core/HostLoadHistory.swift is the format, HostLoadStats.swift the arithmetic) and never
// samples anything itself, so a closed app means a gap, not a guess. TALLY_HOST_LOAD_DIR points the
// read at another folder (a fixture, or ~/.tally/host-load-dev).

let hostHistoryUsage = "usage: tally status --history [--minutes N (1-10080)] [--days D (1-8)] "
    + "[--gate X]... [--mem-min P (0-100)] [--json]"

struct HostHistoryResult: Equatable {
    var code: Int32
    var out = ""
    var err: String?
}

func runHostHistory(args: [String]) -> Int32 {
    let override = ProcessInfo.processInfo.environment["TALLY_HOST_LOAD_DIR"]
    let directory = override.map { URL(fileURLWithPath: $0) } ?? hostLoadDirectory(unshipped: false)
    let result = hostHistoryCommand(args: args, read: readHostLoadSamples(in: directory), now: Date(),
                                    calendar: hostLoadCalendar())
    if !result.out.isEmpty { print(result.out) }
    if let err = result.err { FileHandle.standardError.write(Data("tally: \(err)\n".utf8)) }
    return result.code
}

/// The whole command but the folder read and the printing, so a harness can drive it.
func hostHistoryCommand(args: [String], read: HostLoadRead, now: Date, calendar: Calendar) -> HostHistoryResult {
    var json = false
    var minutes = 60, days = 7
    var gates: [Double] = []
    var memMin: Int?
    var rest = args[...]
    let usage = HostHistoryResult(code: 2, err: hostHistoryUsage)
    while let arg = rest.popFirst() {
        switch arg {
        case "--history": continue
        case "--json": json = true
        case "--minutes":
            guard let n = rest.popFirst().flatMap(Int.init), (1...10080).contains(n) else { return usage }
            minutes = n
        case "--days":
            guard let n = rest.popFirst().flatMap(Int.init), (1...8).contains(n) else { return usage }
            days = n
        case "--gate":
            guard let g = rest.popFirst().flatMap(Double.init), g.isFinite, g > 0 else { return usage }
            gates.append(g)
        case "--mem-min":
            guard let n = rest.popFirst().flatMap(Int.init), (0...100).contains(n) else { return usage }
            memMin = n
        default: return usage
        }
    }
    guard let cores = read.samples.last?.cores else {
        if json { return HostHistoryResult(code: 0, out: HostLoadStats.jsonUnavailable) }
        return HostHistoryResult(code: 1, err: "no load history yet: Tally records one line a minute to "
                                     + "~/.tally/host-load/ while it runs")
    }
    if gates.isEmpty { gates = [HostHealthLogic.loadLimit(cores: cores)] }
    guard let report = HostLoadStats.report(read, now: now, minutes: minutes, days: days, gates: gates,
                                            memMin: memMin, calendar: calendar)
    else { return HostHistoryResult(code: 1, err: "no load history yet") }
    return HostHistoryResult(code: 0, out: json ? HostLoadStats.json(report, calendar: calendar)
                                                 : HostLoadStats.text(report, calendar: calendar))
}
