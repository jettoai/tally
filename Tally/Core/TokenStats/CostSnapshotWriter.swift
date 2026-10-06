import Foundation

/// Writes `~/.tally/project-cost.json` (CostReport.swift has the contract) from a finished scan's
/// samples. Off the main actor, atomically (a temp file renamed over the old one), and never in
/// demo mode, whose fixtures are not this machine's spending.
enum CostSnapshotWriter {
    private static let queue = DispatchQueue(label: "tally.project-cost", qos: .utility)

    static func publish(samples: [TokenSample]) {
        guard !DemoUsage.isActive else { return }
        let url = CostReportFile.url(unshipped: BuildVariant.isUnshipped)
        queue.async {
            let snapshot = make(samples: samples)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    static func make(samples: [TokenSample], now: Date = Date(), zone: TimeZone = .current) -> CostSnapshot {
        let todayDay = LocalDayStamper.today(zone: zone, now: now)
        let today = CostDate.string(day: todayDay)
        let cells = tokenStatsCostCells(samples: samples.map(\.ffi)).map { c in
            CostCell(date: CostDate.string(day: Int(c.day)), project: c.project, provider: c.providerId,
                     model: c.model, subagent: c.subagent, costUSD: c.cost,
                     tokens: CostTokens(input: c.tokens.input,
                                        cacheWrite5m: c.tokens.cacheWrite - min(c.tokens.cacheWrite1h, c.tokens.cacheWrite),
                                        cacheWrite1h: min(c.tokens.cacheWrite1h, c.tokens.cacheWrite),
                                        cacheRead: c.tokens.cacheRead, output: c.tokens.output))
        }
        let keys = Set(cells.map(\.project)).subtracting([TokenProject.otherKey]).sorted()
        let names = Dictionary(uniqueKeysWithValues: zip(keys, tokenProjectNames(keys: keys)))
        let generatedAt = CostDate.timestamp(now, zone: zone)
        var ranges: [String: CostReport] = [:]
        for preset in CostReportFile.presets {
            ranges[preset.name] = CostReportBuilder.report(cells: cells, days: preset.days, today: today, names: names,
                                                           generatedAt: generatedAt, timeZone: zone.identifier)
        }
        let firstKept = CostDate.string(day: todayDay - (CostReportFile.cellDays - 1))
        return CostSnapshot(generatedAt: generatedAt, timeZone: zone.identifier, today: today, names: names,
                            ranges: ranges, cells: cells.filter { $0.date >= firstKept })
    }
}
