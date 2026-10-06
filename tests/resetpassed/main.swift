import Foundation

// Assertion harness for the held-over reset judge (Tally/Core/HeldOverReset.swift) and its app
// wrapper (Tally/Core/HeldOverResetUsage.swift).
//
// THE BEHAVIOUR UNDER TEST: a window whose figure was read before its reset, on an account whose
// polls have failed since, must read as unknown rather than as the old percentage. On 2026-09-28 a
// five-hour window showed 0% left seventy minutes after it had refilled and was read as a spent
// quota. A row that is not held over, or whose reading already postdates the reset, keeps its
// number, and a later good round clears the state with nothing left behind.

/// The fold localizes its retrying line; the app bundle is not compiled in, so the key reads as-is.
func L(_ key: String) -> String { key }

var passed = 0, failed = 0
func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

let now = Date(timeIntervalSince1970: 1_800_000_000)
func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

// MARK: - The truth table, row for row

struct Row { let name: String; let stale: Bool; let failedPoll: Bool?; let read: Date?; let reset: Date?; let expected: Bool }
let rows = [
    Row(name: "#1 the reported sample: held over, reset 70m ago", stale: true, failedPoll: true, read: at(-84), reset: at(-70), expected: true),
    Row(name: "#2 reset exactly now", stale: true, failedPoll: true, read: at(-84), reset: now, expected: true),
    Row(name: "#3 reset one second ahead", stale: true, failedPoll: true, read: at(-84), reset: now.addingTimeInterval(1), expected: false),
    Row(name: "#4 no reset instant (5h not started)", stale: true, failedPoll: true, read: at(-84), reset: nil, expected: false),
    Row(name: "#5 fresh account just past its reset", stale: false, failedPoll: false, read: at(-84), reset: at(-70), expected: false),
    Row(name: "#6 read after the reset", stale: true, failedPoll: true, read: at(-60), reset: at(-70), expected: false),
    Row(name: "#7 read at the reset instant itself", stale: true, failedPoll: true, read: at(-70), reset: at(-70), expected: false),
    Row(name: "#8 first failure, badge not raised yet", stale: false, failedPoll: true, read: at(-84), reset: at(-70), expected: true),
    Row(name: "#9 badge without the flag", stale: true, failedPoll: false, read: at(-84), reset: at(-70), expected: true),
    Row(name: "#10 old snapshot, reset passed", stale: true, failedPoll: nil, read: nil, reset: at(-70), expected: true),
    Row(name: "#11 old snapshot, reset ahead", stale: true, failedPoll: nil, read: nil, reset: at(60), expected: false),
    Row(name: "#12 old snapshot, not stale", stale: false, failedPoll: nil, read: nil, reset: at(-70), expected: false),
]
for row in rows {
    let heldOver = row.stale || row.failedPoll == true
    check(row.name, HeldOverReset.passed(resetsAt: row.reset, refreshedAt: row.read,
                                         heldOver: heldOver, now: now) == row.expected)
}

// MARK: - The app wrapper counts both flags

func session(used: Double, resetsAt: Date?) -> UsageMetric {
    UsageMetric(id: "session", kind: .session, label: "Session", modelName: nil, usedPercent: used,
                severity: .fromUsedPercent(used), resetsAt: resetsAt, isActive: true)
}
var firstFailure = AccountUsage(id: "claude:a", providerID: "claude", accountLabel: "A",
                                metrics: [session(used: 100, resetsAt: at(-70))], refreshedAt: at(-84))
firstFailure.lastRefreshFailed = true
check("wrapper: a first failure past its reset reads as passed",
      firstFailure.resetPassed(firstFailure.metrics[0], now: now))
var clean = firstFailure
clean.lastRefreshFailed = false
check("wrapper: neither flag set keeps the number", !clean.resetPassed(clean.metrics[0], now: now))

// MARK: - Replay: the failure fold, then a good round

let good = AccountUsage(id: "claude:a", providerID: "claude", accountLabel: "A",
                        metrics: [session(used: 100, resetsAt: at(-70))], refreshedAt: at(-84))
let failure = AccountUsage.failure(account: ProviderAccount(id: "claude:a", providerID: "claude",
                                                            label: "A", locator: [:]),
                                   providerID: "claude", message: "No quota returned")
let held = foldLastGood(failure, previous: good, failureStreak: 2, staleAfterFailures: 2, bareErrorAfterFailures: 3)
check("replay: the held-over session window reads as passed",
      held.metrics.first.map { held.resetPassed($0, now: now) } == true)
let recovered = AccountUsage(id: "claude:a", providerID: "claude", accountLabel: "A",
                             metrics: [session(used: 3, resetsAt: at(300))], refreshedAt: now)
let next = foldLastGood(recovered, previous: held, failureStreak: 0, staleAfterFailures: 2, bareErrorAfterFailures: 3)
check("replay: a good round afterwards leaves no window marked passed",
      !next.metrics.isEmpty && next.metrics.allSatisfy { !next.resetPassed($0, now: now) })

// MARK: - Every new line is translated

let catalogue = (try? Data(contentsOf: URL(fileURLWithPath: "Tally/Resources/Localizable.xcstrings")))
    .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
let strings = catalogue?["strings"] as? [String: Any] ?? [:]
let newKeys = [
    "Reset passed, awaiting refresh",
    "No quota returned: if it persists, run /login",
    "Claude Code answered /usage for this account without its limits. It usually clears on a later refresh; if it keeps happening, run /login in a Claude Code session on this account.",
]
for key in newKeys {
    let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
    check("\(key.prefix(30)) is in all four translations",
          ["zh-Hant", "zh-Hans", "ja", "ko"].allSatisfy { localizations[$0] != nil })
}

// MARK: - Every surface asks the judge (source wiring)

func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
check("card rows ask usage.resetPassed", source("Tally/Views/AccountCardView.swift").contains("usage.resetPassed("))
check("list rows ask usage.resetPassed", source("Tally/Views/AccountListRowView.swift").contains("usage.resetPassed("))
check("settings rows ask account.resetPassed", source("Tally/Views/SettingsAccountRowStatus.swift").contains("account.resetPassed("))
check("menu-bar hover asks account.resetPassed", source("Tally/Stores/UsageStorePresentation.swift").contains("account.resetPassed("))
check("an empty /usage says what to do",
      source("Tally/Providers/Claude/ClaudeProvider.swift").contains("L(\"No quota returned: if it persists, run /login\")"))

print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
