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
check("Compact cost comparison heading fits its column", L("vs prev") == "Değişim")
check("New-session choice is localized", L("new") == "Yeni")
check("Continue choice is localized", L("continue") == "Devam et")
check("Permission bypass remains explicit", L("bypass") == "İzin denetimlerini atla")
check("Codex full access remains explicit", L("full access") == "Tam erişim")
check("Effort choice is localized", L("medium") == "Orta")
check("Seven-day range is localized", TokenStatsRange.sevenDays.label == "7 gün")
check("Thirty-day range is localized", TokenStatsRange.thirtyDays.label == "30 gün")
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

language("tr-TR")
check("Regional Turkish resolves to Turkish", L("Language") == "Dil")
language("en")
check("Live switch to English invalidates the cached bundle", L("Language") == "Language")
check("English duration units are unchanged", UsageFormat.durationBody(90_000) == "1d 1h")
check("English absolute reset dates are unchanged", UsageFormat.absoluteBody(october) == "10/23 18:05")
language("tr")
check("Live switch back to Turkish invalidates the cached bundle", L("Language") == "Dil")

let display = try String(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])
    .appendingPathComponent("Tally/Views/SettingsDisplayPane.swift"), encoding: .utf8)
check("The picker names Turkish in its own language", display.contains("case \"tr\": return \"Türkçe\""))
let project = try String(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])
    .appendingPathComponent("project.yml"), encoding: .utf8)
check("The build includes Turkish resources", project.contains("    - tr\n"))

exit(failed == 0 ? 0 : 1)
