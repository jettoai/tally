import Foundation

// Assertion harness for the status line's rate-limit facts (TallyCLI/LiveRates.swift) and for how the
// probe cadence and the row overlay read them (Tally/Core/ProbeCadence.swift).

var passed = 0, failed = 0
func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

let now = Date(timeIntervalSince1970: 1_790_440_000)
let id = "claude:.claude3"

// MARK: - Parsing (shape captured from a real CC 2.1.283 status-line render)

let sample = #"{"model":{"display_name":"Opus 5.5"},"rate_limits":{"five_hour":{"used_percentage":9,"resets_at":1790441340},"seven_day":{"used_percentage":34,"resets_at":1790873940}}}"#
let parsed = parseLiveRateWindows(
    try! JSONSerialization.jsonObject(with: Data(sample.utf8)) as? [String: Any])
check("B1 both windows parse, resets in unix seconds",
      parsed?.fiveHour == LiveRateWindow(usedPercent: 9, resetsAt: Date(timeIntervalSince1970: 1790441340))
          && parsed?.sevenDay == LiveRateWindow(usedPercent: 34, resetsAt: Date(timeIntervalSince1970: 1790873940)))
check("B2 no rate_limits, or neither window, is nothing",
      parseLiveRateWindows(["model": ["display_name": "Opus 5.5"]]) == nil
          && parseLiveRateWindows(["rate_limits": ["other": 1]]) == nil
          && parseLiveRateWindows(nil) == nil)

// MARK: - Merging

func window(_ used: Double, _ resetsIn: TimeInterval) -> LiveRateWindow {
    LiveRateWindow(usedPercent: used, resetsAt: now.addingTimeInterval(resetsIn))
}
let base = LiveRateFact(accountID: id, observedAt: now.addingTimeInterval(-60),
                        changedAt: now.addingTimeInterval(-60), fiveHour: window(40, 3600),
                        sevenDay: window(30, 86400), flagshipAt: now.addingTimeInterval(-600))
let lower = mergeLiveRateFact(previous: base, accountID: id, windows: (window(35, 3600), nil),
                              onFlagship: false, now: now)
check("B3 an idle session repeating a lower number in the same period keeps the higher, changedAt holds",
      lower.fiveHour?.usedPercent == 40 && lower.changedAt == base.changedAt && lower.observedAt == now)
let period = mergeLiveRateFact(previous: base, accountID: id, windows: (window(2, 5 * 3600), nil),
                               onFlagship: false, now: now)
check("B4 a later reset is a new period and wins, changedAt moves",
      period.fiveHour?.usedPercent == 2 && period.changedAt == now)
let flag = mergeLiveRateFact(previous: base, accountID: id, windows: (nil, nil), onFlagship: true, now: now)
check("B5 a flagship render stamps flagshipAt, a plain one keeps the old stamp",
      flag.flagshipAt == now && lower.flagshipAt == base.flagshipAt)

// MARK: - Writing

let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("liverates-\(UUID().uuidString)", isDirectory: true)
recordLiveRateFact(base, previous: nil, dir: dir)
var same = base; same.observedAt = base.observedAt.addingTimeInterval(10)
recordLiveRateFact(same, previous: base, dir: dir)
let afterTen = readLiveRateFact(accountID: id, dir: dir)
var later = base; later.observedAt = base.observedAt.addingTimeInterval(21)
recordLiveRateFact(later, previous: base, dir: dir)
let afterTwentyOne = readLiveRateFact(accountID: id, dir: dir)
check("B6 unchanged numbers within 20 seconds skip the write, 21 seconds writes",
      afterTen == base && afterTwentyOne == later)
check("B6b a file names only its own account", readLiveRateFact(accountID: "claude:.claude4", dir: dir) == nil)
try? FileManager.default.removeItem(at: dir)

// MARK: - Overlay

func metric(_ kind: MetricKind, _ used: Double, _ resetsIn: TimeInterval) -> UsageMetric {
    UsageMetric(id: kind.rawValue, kind: kind, label: kind.rawValue, modelName: nil, usedPercent: used,
                severity: .fromUsedPercent(used), resetsAt: now.addingTimeInterval(resetsIn), isActive: false)
}
let probed = AccountUsage(id: id, providerID: "claude", accountLabel: "Claude 3", planName: nil,
                          accountEmail: nil,
                          metrics: [metric(.session, 10, 3600), metric(.weeklyAll, 20, 86400),
                                    metric(.weeklyModel, 30, 86400)],
                          refreshedAt: now.addingTimeInterval(-120))
let fresh = LiveRateFact(accountID: id, observedAt: now, changedAt: now.addingTimeInterval(-30),
                         fiveHour: window(85, 3000), sevenDay: window(60, 80000), flagshipAt: nil)
let laid = ProbeCadence.overlay(probed, fact: fresh, now: now)
check("B7 newer facts replace the session and weekly windows, flagship window and refreshedAt stay",
      laid.metrics[0].usedPercent == 85 && laid.metrics[0].severity == .critical
          && laid.metrics[0].resetsAt == fresh.fiveHour?.resetsAt
          && laid.metrics[1].usedPercent == 60 && laid.metrics[1].severity == .warning
          && laid.metrics[2] == probed.metrics[2] && laid.refreshedAt == probed.refreshedAt)
var older = fresh; older.changedAt = probed.refreshedAt
check("B8 facts no newer than the probe leave the row alone",
      ProbeCadence.overlay(probed, fact: older, now: now) == probed)
var lapsed = fresh; lapsed.fiveHour = window(85, -10)
let lapsedRow = ProbeCadence.overlay(probed, fact: lapsed, now: now)
check("B9 a fact window whose reset has passed is not laid over",
      lapsedRow.metrics[0] == probed.metrics[0] && lapsedRow.metrics[1].usedPercent == 60)

// MARK: - Cadence with the status-line channel

func previousRow(readAgo: TimeInterval) -> AccountUsage {
    var row = probed; row.refreshedAt = now.addingTimeInterval(-readAgo); return row
}
func due(live: Bool = false, _ fact: LiveRateFact?, readAgo: TimeInterval) -> Bool {
    ProbeCadence.isDue(userInitiated: false, live: live, fact: fact, previous: previousRow(readAgo: readAgo),
                       now: now)
}
let calm = LiveRateFact(accountID: id, observedAt: now.addingTimeInterval(-5), changedAt: now,
                        fiveHour: window(40, 3600), sevenDay: window(50, 86400), flagshipAt: nil)
check("B10 a rendering account off the flagship and clear of the wall waits 5 minutes",
      !due(live: true, calm, readAgo: 2 * 60) && due(live: true, calm, readAgo: 5 * 60))
var nearWall = calm; nearWall.fiveHour = window(92, 3600)
check("B11 a window at 90% or more reads every tick", due(nearWall, readAgo: 60))
var onFlagship = calm; onFlagship.flagshipAt = now.addingTimeInterval(-60)
check("B12 a session on the flagship model in the last 3 minutes reads every tick", due(onFlagship, readAgo: 60))
var quiet = calm; quiet.observedAt = now.addingTimeInterval(-10 * 60)
check("B13 a fact nobody has rendered for 10 minutes falls back: idle waits, live reads",
      !due(quiet, readAgo: 5 * 60) && due(live: true, quiet, readAgo: 5 * 60))
check("B13b a manual refresh reads a calm rendering account",
      ProbeCadence.isDue(userInitiated: true, live: true, fact: calm, previous: previousRow(readAgo: 1), now: now))

// MARK: - Wiring (read as text)

func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
let statusline = source("TallyCLI/Statusline.swift")
let project = source("project.yml")
let store = source("Tally/Stores/UsageStore.swift")
let cadence = source("Tally/Core/ProbeCadence.swift")
check("B14 the status line records the fact and the app target compiles LiveRates.swift",
      statusline.contains("recordLiveRateFact(mergeLiveRateFact(")
          && statusline.contains("parseLiveRateWindows(sessionJSON)")
          && project.contains("      - path: TallyCLI/LiveRates.swift"))
check("B14b the store lays facts over Claude rows and the round passes them to isDue",
      store.contains("ProbeCadence.overlay($0, fact: readLiveRateFact(accountID: $0.id)")
          && cadence.contains("fact: facts[$0.id]"))

print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
