import Foundation

// `tally cost` (TallyCLI/CostCommand.swift) against hand-made snapshots: the contract in
// Tally/Core/TokenStats/CostReport.swift, the freshness flag, the exit codes, and `--days` summed
// from the daily cells rather than read off a preset.

var failures = 0
var passes = 0
func check(_ condition: Bool, _ message: String) {
    if condition { passes += 1; print("PASS: \(message)") } else { failures += 1; print("FAIL: \(message)") }
}

func cell(_ date: String, _ project: String, _ provider: String, _ model: String, _ cost: Double?,
          output: Int64, subagent: Bool = false) -> CostCell {
    CostCell(date: date, project: project, provider: provider, model: model, subagent: subagent, costUSD: cost,
             tokens: CostTokens(output: output))
}

let generated = Date(timeIntervalSince1970: 1_791_250_000)   // a fixed instant
let zone = TimeZone(identifier: "Asia/Taipei")!
let cells = [
    cell("2026-09-20", "/w/a", "claude", "claude-opus-5-5", 100, output: 1),   // 30d only
    cell("2026-10-01", "/w/b", "claude", "claude-sonnet-5", 20, output: 2),
    cell("2026-10-05", "/w/a", "claude", "claude-opus-5-5", 5, output: 3, subagent: true),
    cell("2026-10-06", "/w/a", "claude", "claude-opus-5-5", 10, output: 4),
    cell("2026-10-06", "/w/b", "codex", "gpt-6-astra", nil, output: 1000),
    cell("2026-10-06", "", "claude", "claude-haiku-4-5", 1, output: 5),
    cell("2026-10-06", "/w/c", "claude", "claude-mystery-9", nil, output: 7),
]

func snapshot(_ cells: [CostCell], names: [String: String] = ["/w/a": "a", "/w/b": "b"]) -> Data {
    let stamp = CostDate.timestamp(generated, zone: zone)
    var ranges: [String: CostReport] = [:]
    for p in CostReportFile.presets {
        ranges[p.name] = CostReportBuilder.report(cells: cells, days: p.days, today: "2026-10-06", names: names,
                                                  generatedAt: stamp, timeZone: zone.identifier)
    }
    let s = CostSnapshot(generatedAt: stamp, timeZone: zone.identifier, today: "2026-10-06", names: names,
                         ranges: ranges, cells: cells)
    return try! JSONEncoder().encode(s)
}

let data = snapshot(cells)
func run(_ args: [String], data: Data? = data, after minutes: Double = 1) -> CostCommandResult {
    costCommand(args: args, data: data, now: generated.addingTimeInterval(minutes * 60))
}
func report(_ r: CostCommandResult) -> CostReport? {
    try? JSONDecoder().decode(CostReport.self, from: Data(r.out.utf8))
}
func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }

// MARK: - No snapshot

let missing = run(["--json"], data: nil)
check(missing.code == 1 && missing.out.isEmpty && missing.err?.contains("project-cost.json") == true,
      "no snapshot: exit 1, nothing on stdout, one line naming the file")
check(run(["--json"], data: Data("{".utf8)).code == 1, "an unreadable snapshot is the same as none")

// MARK: - The default range and the contract

let week = run(["--json"])
let w = report(week)
check(week.code == 0 && w != nil, "--json prints a report that decodes")
check(w?.range.days == 7 && w?.range.from == "2026-09-30" && w?.range.to == "2026-10-06", "the default range is 7 days")
check(w?.stale == false, "a minute-old snapshot is not stale")
check(close(w?.totals.costUSD, 36), "the total is the priced cells in range (20 + 5 + 10 + 1)")
check(w?.projects.map(\.key) == ["/w/b", "/w/a", "", "/w/c"], "projects ranked by cost, unpriced last, none dropped")
check(w?.projects.first { $0.key == "/w/a" }.map { close($0.bySide.subagent, 5) && close($0.bySide.main, 10) } == true,
      "a project splits main loop from subagents")
check(w?.projects.first { $0.key == "/w/c" }?.costUSD == nil, "a project on an unpriced model costs null, not 0")
check(w?.projects.first { $0.key == "" }.map { $0.isOther && $0.name == "Other" } == true, "Other is the empty key")
check(w?.providers.map(\.id) == ["claude", "codex"] && w?.providers[1].costUSD == nil
          && w?.providers[1].tokens.output == 1000, "codex keeps its tokens and has no price")
check(w?.pricing.unpricedProviders == ["codex"], "and the pricing block names it")
check(week.out.contains("\"costUSD\" : null"), "null is written as null, not left out")
check(w?.projects.first { $0.key == "/w/b" }?.share.map { abs($0 - 20.0 / 36) < 1e-9 } == true, "share is of the cost")

// MARK: - Freshness

check(report(run(["--json"], after: 16))?.stale == true, "16 minutes old is stale")
check(report(run(["--json"], after: 14))?.stale == false, "14 minutes old is not")

// MARK: - --days from the cells

let two = report(run(["--json", "--days", "2"]))
check(two?.range.days == 2 && two?.range.from == "2026-10-05", "--days 2 is the last two days")
check(close(two?.totals.costUSD, 16), "summed from the cells (5 + 10 + 1)")
check(two?.projects.first { $0.key == "/w/b" }?.costUSD == nil, "a project with only codex tokens in range is null")
let fromCells = report(run(["--json", "--days", "7"]))
check(fromCells == w, "--days 7 from the cells is the 7d preset, field for field")
// The cells are what --days reads: a snapshot whose preset says otherwise does not change it.
var doctored = try! JSONDecoder().decode(CostSnapshot.self, from: data)
doctored.ranges["7d"]?.totals.costUSD = 999
let doctoredData = try! JSONEncoder().encode(doctored)
check(close(report(run(["--json", "--days", "7"], data: doctoredData))?.totals.costUSD, 36),
      "--days never reads the precomputed ranges")
check(close(report(run(["--json", "--days", "30"]))?.totals.costUSD, 136), "--days 30 reaches the older cell")
let all = report(run(["--json", "--range", "all"]))
check(all?.range.days == nil && all?.range.from == "2026-09-20" && close(all?.totals.costUSD, 136),
      "--range all spans every cell")
check(report(run(["--json", "--range", "TODAY"]))?.range.days == 1, "--range is case-insensitive")

// MARK: - Refusals

for bad in [["--days", "0"], ["--days", "91"], ["--days"], ["--days", "x"], ["--range", "week"],
            ["--days", "7", "--range", "7d"], ["--bogus"]] {
    let r = run(bad)
    check(r.code == 2 && r.err == costUsage && r.out.isEmpty, "refused with usage: \(bad.joined(separator: " "))")
}

// MARK: - The human table

let human = run([])
check(human.code == 0 && human.out.hasPrefix("Cost, last 7 days (2026-09-30 to 2026-10-06): $36.00"),
      "the human report opens on the total")
check(human.out.contains("Not priced: codex"), "and says what is not priced")
check(!human.out.contains("stale"), "a fresh snapshot is not called stale")
check(run([], after: 20).out.contains("[stale: snapshot from"), "an old one is")
var many: [CostCell] = []
for i in 0 ..< 17 { many.append(cell("2026-10-06", "/w/p\(i)", "claude", "claude-opus-5-5", Double(i + 1), output: 1)) }
let long = run([], data: snapshot(many, names: [:]))
check(long.out.contains("… 2 more (--json lists all)") && long.out.contains("p16") && !long.out.contains("p1 "),
      "the table shows the top 15 and counts the rest")
check(report(run(["--json"], data: snapshot(many, names: [:])))?.projects.count == 17, "--json lists all 17")

// MARK: - Dates

check(CostDate.string(day: 20_732) == "2026-10-06" && CostDate.day("2026-10-06") == 20_732, "day numbers round-trip")
check(CostDate.parse("2026-10-06T12:50:00+08:00") != nil && CostDate.parse("2026-10-06T12:50:00.5+08:00") != nil,
      "timestamps parse with or without fractional seconds")

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
