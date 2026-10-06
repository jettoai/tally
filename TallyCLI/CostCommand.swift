import Foundation

// `tally cost [--json] [--days N | --range today|7d|30d|all]`: what each project's tokens cost, read
// from the snapshot Tally.app writes after every token scan (Tally/Core/TokenStats/CostReport.swift
// has the contract). This never scans transcripts itself. No snapshot means the app has not scanned
// on this machine yet: exit 1 with one line on stderr, as `tally status` does without its snapshot.

func runCost(args: [String]) -> Int32 {
    let result = costCommand(args: args, data: try? Data(contentsOf: CostReportFile.url(unshipped: false)),
                             now: Date())
    if !result.out.isEmpty { print(result.out) }
    if let err = result.err { FileHandle.standardError.write(Data("tally: \(err)\n".utf8)) }
    return result.code
}

struct CostCommandResult: Equatable {
    var code: Int32
    var out = ""
    var err: String?
}

let costUsage = "usage: tally cost [--json] [--days N (1-\(CostReportFile.cellDays)) | --range today|7d|30d|all]"

/// The whole command but the file read and the printing, so a test can drive it.
func costCommand(args: [String], data: Data?, now: Date) -> CostCommandResult {
    var json = false
    var days: Int?
    var range: String?
    var rest = args[...]
    while let arg = rest.popFirst() {
        switch arg {
        case "--json": json = true
        case "--days":
            guard let n = rest.popFirst().flatMap(Int.init), (1 ... CostReportFile.cellDays).contains(n)
            else { return CostCommandResult(code: 2, err: costUsage) }
            days = n
        case "--range":
            guard let name = rest.popFirst()?.lowercased(),
                  CostReportFile.presets.contains(where: { $0.name == name })
            else { return CostCommandResult(code: 2, err: costUsage) }
            range = name
        default: return CostCommandResult(code: 2, err: costUsage)
        }
    }
    if days != nil, range != nil { return CostCommandResult(code: 2, err: costUsage) }

    guard let data, let snapshot = try? JSONDecoder().decode(CostSnapshot.self, from: data),
          snapshot.schema == CostReportFile.schema
    else {
        return CostCommandResult(code: 1, err: "no cost snapshot at ~/.tally/project-cost.json: "
                                     + "open Tally and its Tokens or Cost tab once to write it")
    }
    var report: CostReport
    if let days {
        report = CostReportBuilder.report(cells: snapshot.cells, days: days, today: snapshot.today,
                                          names: snapshot.names, generatedAt: snapshot.generatedAt,
                                          timeZone: snapshot.timeZone)
    } else if let preset = snapshot.ranges[range ?? "7d"] {
        report = preset
    } else {
        return CostCommandResult(code: 1, err: "the cost snapshot has no \(range ?? "7d") range")
    }
    report.stale = CostDate.parse(snapshot.generatedAt).map { now.timeIntervalSince($0) > CostReportFile.staleAfter } ?? true

    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let text = (try? encoder.encode(report)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return CostCommandResult(code: 0, out: text)
    }
    return CostCommandResult(code: 0, out: costTable(report))
}

/// The human report: the total, then the top 15 projects.
func costTable(_ r: CostReport) -> String {
    let span = r.range.days.map { $0 == 1 ? "today" : "last \($0) days" } ?? "all time"
    var lines = ["Cost, \(span) (\(r.range.from ?? r.range.to) to \(r.range.to)): \(costDollars(r.totals.costUSD))"
                 + (r.stale ? "  [stale: snapshot from \(r.generatedAt)]" : "")]
    if !r.pricing.unpricedProviders.isEmpty {
        lines.append("Not priced: " + r.pricing.unpricedProviders.joined(separator: ", "))
    }
    let shown = r.projects.prefix(15)
    let width = min(28, shown.map(\.name.count).max() ?? 7)
    func pad(_ s: String, _ n: Int, left: Bool = false) -> String {
        let fill = String(repeating: " ", count: max(0, n - s.count))
        return left ? s + fill : fill + s
    }
    lines.append(pad("Project", width, left: true) + pad("Cost", 11) + pad("Share", 7) + pad("Tokens", 9))
    for p in shown {
        let name = p.name.count > width ? String(p.name.prefix(width - 1)) + "…" : p.name
        lines.append(pad(name, width, left: true) + pad(p.costUSD.map(costDollars) ?? "-", 11)
                     + pad(p.share.map { "\(Int(($0 * 100).rounded()))%" } ?? "-", 7)
                     + pad(costCount(p.tokens.total), 9))
    }
    if r.projects.count > shown.count { lines.append("… \(r.projects.count - shown.count) more (--json lists all)") }
    return lines.joined(separator: "\n")
}

func costCount(_ n: Int64) -> String {
    let v = Double(n)
    for (limit, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] where v >= limit {
        return String(format: "%.1f%@", v / limit, suffix)
    }
    return "\(n)"
}
