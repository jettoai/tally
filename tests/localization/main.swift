import AppKit
import Foundation

// AppLocale's only app dependency. Never start discovery, login or telemetry in a test.
enum DemoUsage { static let isActive = false }

var failed = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failed += 1 }
}

func language(_ code: String) {
    // Use only the argument domain: the test must not persist a language preference.
    UserDefaults.standard.setVolatileDomain([AppLocale.overrideKey: code],
                                           forName: UserDefaults.argumentDomain)
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
}

check("Turkish is selectable", AppLocale.supported.contains("tr"))
language("tr")
check("Turkish bundle resolves", AppLocale.bundle.bundleURL.lastPathComponent == "tr.lproj")
check("Settings uses the Turkish catalog", L("Settings…") == "Ayarlar…")
check("Language uses the Turkish catalog", L("Language") == "Dil")
check("The developer credit is localized", L("by") == "Geliştiren")
check("Refresh label uses the Turkish catalog", L("Refresh") == "Yenile")
check("Turkish formatting locale", AppLocale.current.identifier == "tr")
check("Cost share is a proportion, not a share action", L("Share") == "Pay")
check("Cost comparison heading is localized", L("vs prev") == "Önceki döneme göre")
check("New-session choice is localized", L("new") == "Yeni")
check("Continue choice is localized", L("continue") == "Devam et")
check("Full access remains explicit", L("Full access") == "Tam erişim")
check("Effort choice is localized", L("medium") == "Orta")
check("Seven-day range is localized", TokenStatsRange.sevenDays.label == "7 g")
check("Thirty-day range is localized", TokenStatsRange.thirtyDays.label == "30 g")
check("Early-start summary does not imply account transfers", L("Relay today") == "Bugünkü erken başlatmalar")
check("Fractional hours use Turkish units and decimal comma", UsageFormat.hoursBody(2.5) == "2,5 sa")
check("Burn rate uses Turkish per-hour notation", UsageFormat.percentPerHour(12) == "%12/sa")
check("Short countdown measures both Turkish unit widths", UsageFormat.updatesInFigureTemplates == ["59 sn", "59 dk"])
check("Turkish day and hour units", UsageFormat.durationBody(90_000) == "1 g 1 sa")
check("Turkish day unit", UsageFormat.durationBody(86_400) == "1 g")
check("Turkish hour and minute units", UsageFormat.durationBody(3_660) == "1 sa 1 dk")
check("Turkish hour unit", UsageFormat.durationBody(3_600) == "1 sa")
check("Turkish minute unit", UsageFormat.durationBody(60) == "1 dk")
check("Sub-minute reset remains floored at one minute", UsageFormat.durationBody(0) == "1 dk")
let now = Date()
check("Turkish short refresh seconds", UsageFormat.updatesInFigure(now.addingTimeInterval(42), now: now) == "42 sn")
check("Turkish short refresh minutes", UsageFormat.updatesInFigure(now.addingTimeInterval(120), now: now) == "2 dk")
check("Countdown width template uses Turkish units", UsageFormat.updatesInTemplates.first?.contains("59 dk") == true)
let october = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 18, minute: 5))!
check("Turkish exact reset date is day first", UsageFormat.absoluteBody(october) == "23.10 18:05")
check("A past reset is not reported as successful", L("Reset passed, awaiting refresh") == "Yenilenme zamanı geçti, güncel veri bekleniyor")

// B-3511: the reset slot's state and words. One state function, three renderers.
check("Turkish single-unit reset caption (days)", UsageFormat.resetCompact(.countdown(now.addingTimeInterval(2 * 86_400 + 5_000)), now: now) == "2 g")
check("Turkish single-unit reset caption (hours)", UsageFormat.resetCompact(.countdown(now.addingTimeInterval(23 * 3_600 + 59 * 60)), now: now) == "23 sa")
check("Turkish single-unit reset caption (minutes)", UsageFormat.resetCompact(.countdown(now.addingTimeInterval(59 * 60 + 30)), now: now) == "59 dk")

language("tr-TR")
check("Regional Turkish resolves to Turkish", L("Language") == "Dil")
language("en")
check("Live switch to English invalidates the cached bundle", L("Language") == "Language")
check("English duration units are unchanged", UsageFormat.durationBody(90_000) == "1d 1h")
check("English absolute reset dates are unchanged", UsageFormat.absoluteBody(october) == "10/23 18:05")
func metric(_ kind: MetricKind, used: Double, resetsAt: Date?) -> UsageMetric {
    UsageMetric(id: "m", kind: kind, label: "m", modelName: nil, usedPercent: used, severity: .normal, resetsAt: resetsAt, isActive: false)
}
let future = now.addingTimeInterval(4 * 86_400 + 17 * 3_600)
check("passed wins over a future reset", UsageFormat.resetState(metric(.weeklyAll, used: 10, resetsAt: future), resetPassed: true) == .passed(future))
check("a reset ahead is a countdown", UsageFormat.resetState(metric(.weeklyAll, used: 10, resetsAt: future), resetPassed: false) == .countdown(future))
check("an untouched session window is not started", UsageFormat.resetState(metric(.session, used: 0, resetsAt: nil), resetPassed: false) == .notStarted)
check("a used session window without a reset says nothing", UsageFormat.resetState(metric(.session, used: 5, resetsAt: nil), resetPassed: false) == .absent)
check("a weekly window without a reset says nothing", UsageFormat.resetState(metric(.weeklyAll, used: 0, resetsAt: nil), resetPassed: false) == .absent)
check("caption: days only", UsageFormat.resetCompact(.countdown(future), now: now) == "4d")
check("caption: hours only", UsageFormat.resetCompact(.countdown(now.addingTimeInterval(17 * 3_600 + 1_800)), now: now) == "17h")
check("caption: minutes only", UsageFormat.resetCompact(.countdown(now.addingTimeInterval(42 * 60 + 10)), now: now) == "42m")
check("caption: a past instant floors at one minute", UsageFormat.resetCompact(.countdown(now.addingTimeInterval(-500)), now: now) == "1m")
check("caption: passed and not started show the no-data glyph", UsageFormat.resetCompact(.passed(nil), now: now) == "\u{2014}" && UsageFormat.resetCompact(.notStarted, now: now) == "\u{2014}")
check("caption: absent is empty", UsageFormat.resetCompact(.absent, now: now) == "")
check("sentence: countdown", UsageFormat.resetSentence(.countdown(future), now: now) == "resets in 4d 17h")
check("sentence: passed and not started", UsageFormat.resetSentence(.passed(nil)) == "Reset passed, awaiting refresh" && UsageFormat.resetSentence(.notStarted) == "5h starts on first use")
check("sentence: absent is nil", UsageFormat.resetSentence(.absent) == nil)
check("hover keeps the exact clock for a countdown", UsageFormat.resetHelp(.countdown(future), now: now) == UsageFormat.resetHover(future, now: now))
check("hover explains a window that has not started", UsageFormat.resetHelp(.notStarted) == "5h starts on first use")

// B-3511: a window from a provider this code has never heard of shows its reset with no display
// code written for it. The state function reads the reset instant, the used share and the kind
// only; labels, ids and model names never reach it, and `.other` (what a new provider's windows
// map to) takes the same path as the named kinds.
let soon = now.addingTimeInterval(6 * 3_600 + 20 * 60)
let invented = [
    UsageMetric(id: "acme.daily-credits", kind: .other, label: "Daily credits", modelName: "acme-1", usedPercent: 40, severity: .normal, resetsAt: soon, isActive: false),
    UsageMetric(id: "acme.burst", kind: .other, label: "Burst (10 min)", modelName: nil, usedPercent: 0, severity: .normal, resetsAt: soon, isActive: true),
    UsageMetric(id: "zzz", kind: .weeklyModel, label: "Some future tier", modelName: "future-9", usedPercent: 95, severity: .critical, resetsAt: soon, isActive: false),
]
for m in invented {
    let state = UsageFormat.resetState(m, resetPassed: false)
    check("invented window '\(m.label)' counts down", state == .countdown(soon))
    check("invented window '\(m.label)' reads 6h in the list caption", UsageFormat.resetCompact(state, now: now) == "6h")
    check("invented window '\(m.label)' reads the card sentence", UsageFormat.resetSentence(state, now: now) == "resets in 6h 20m")
}
let appRoot = URL(fileURLWithPath: CommandLine.arguments[1])
let formatting = try String(contentsOf: appRoot.appendingPathComponent("Tally/Views/UsageFormatting.swift"), encoding: .utf8)
let stateBody = formatting.components(separatedBy: "static func resetState(").dropFirst().first?
    .components(separatedBy: "static func resetCompact").first ?? ""
check("resetState reads no label, id, model or provider", !stateBody.isEmpty
      && !["metric.label", "metric.modelName", "metric.id", "providerID"].contains { stateBody.contains($0) })
let listRow = try String(contentsOf: appRoot.appendingPathComponent("Tally/Views/AccountListRowView.swift"), encoding: .utf8)
check("the list row draws a cluster for every window the account reports",
      listRow.contains("facts.orderedMetrics") && listRow.contains("meterCluster(metric)"))

// The reserved column is built to hold the widest caption in English, and in Turkish after the
// caption's 0.8 minimum scale. The width itself is read from the view's source (the view lives in
// the app target), so a unit that grows past the column fails here rather than clipping on screen.
let rowSource = try String(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])
    .appendingPathComponent("Tally/Views/AccountListRowView.swift"), encoding: .utf8)
let resetWidth = rowSource.components(separatedBy: "static let resetWidth: CGFloat = ").dropFirst().first
    .flatMap { Double($0.prefix(while: { $0.isNumber })) } ?? 0
check("the reset column width is readable from the view", resetWidth > 0)
let captionFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .regular)
func widest(_ strings: [String]) -> Double {
    Double(strings.map { ($0 as NSString).size(withAttributes: [.font: captionFont]).width }.max() ?? .infinity)
}
check("the widest English caption fits the reset column", widest(UsageFormat.resetCompactTemplates) <= resetWidth)
language("tr")
check("the widest Turkish caption fits the reset column after the 0.8 scale", widest(UsageFormat.resetCompactTemplates) * 0.8 <= resetWidth)
check("Live switch back to Turkish invalidates the cached bundle", L("Language") == "Dil")

let display = try String(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])
    .appendingPathComponent("Tally/Views/SettingsDisplayPane.swift"), encoding: .utf8)
check("The picker names Turkish in its own language", display.contains("case \"tr\": return \"Türkçe\""))
let project = try String(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])
    .appendingPathComponent("project.yml"), encoding: .utf8)
check("The build includes Turkish resources", project.contains("    - tr\n"))

exit(failed == 0 ? 0 : 1)
