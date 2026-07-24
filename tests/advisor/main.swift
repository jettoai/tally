import Foundation

// Assertion harness for UsageAdvisor's pure math, compiled against the real source. Every
// scenario uses a FIXED `now` so the math is deterministic.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}
func near(_ a: Double, _ b: Double, _ tol: Double = 0.001) -> Bool { abs(a - b) < tol }

let now = Date(timeIntervalSince1970: 1_800_000_000)
func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }
let resetA = now.addingTimeInterval(3 * 86_400)   // two distinct reset periods
let resetB = now.addingTimeInterval(10 * 86_400)

typealias Sample = UsageAdvisor.Sample
func s(_ account: String, _ window: String, used: Double, at: Date,
       reset: Date? = resetA, model: String? = nil) -> Sample {
    Sample(ts: at, account: account, provider: "claude", window: window, model: model,
           used: used, resetAt: reset)
}
func reading(_ samples: [Sample]) -> UsageAdvisor.Reading? {
    UsageAdvisor.reading(provider: "claude", samples: samples, now: now)
}

// 1. Weekly demand + sufficient verdict: one account burns 50% over two weeks (0.25 account-weeks
//    of weekly demand), well under the 0.9 trigger.
let sufficient = [
    s("a1", "weeklyAll", used: 0, at: daysAgo(14)),
    s("a1", "weeklyAll", used: 50, at: daysAgo(1)),
]
if let r = reading(sufficient) {
    check("weekly demand = burn / weeks / 100", near(r.demandPerWeek, 50 / 2 / 100))
    check("light demand reads as sufficient", r.verdict == .sufficient)
    check("account count counted", r.accountCount == 1)
} else { check("sufficient reading exists", false) }

// 2. Add-account by demand: one account fully spends its weekly window each week (1.0 account-week
//    of demand ≥ the 0.9 trigger). Two reset periods so both 0→100 runs count.
let heavy = [
    s("a1", "weeklyAll", used: 0, at: daysAgo(14), reset: resetA),
    s("a1", "weeklyAll", used: 100, at: daysAgo(8), reset: resetA),
    s("a1", "weeklyAll", used: 0, at: daysAgo(7), reset: resetB),
    s("a1", "weeklyAll", used: 100, at: daysAgo(1), reset: resetB),
]
if let r = reading(heavy) {
    check("full weekly spend = 1.0 account-week demand", near(r.demandPerWeek, 1.0))
    check("demand at capacity recommends adding", r.verdict == .addAccount)
} else { check("heavy reading exists", false) }

// 3. Reset skip: a rise ACROSS a reset boundary (90 → 95 with a different resetAt) is not
//    consumption. Only the within-period rises count: +90 then +4 = 94, never 99.
let rollover = [
    s("a1", "weeklyAll", used: 0, at: daysAgo(7), reset: resetA),
    s("a1", "weeklyAll", used: 90, at: daysAgo(5), reset: resetA),
    s("a1", "weeklyAll", used: 95, at: daysAgo(4), reset: resetB),   // rollover: not a +5 spend
    s("a1", "weeklyAll", used: 99, at: daysAgo(1), reset: resetB),
]
if let r = reading(rollover) {
    check("rise across a reset is skipped (0.94, not 0.99)", near(r.demandPerWeek, 0.94))
} else { check("rollover reading exists", false) }

// 4. Idle-break cap: a 30% rise spread over 2 real hours counts as only 30 min of active time,
//    so the active pace is 60%/active-hour (not 15).
let idle = [
    s("a1", "weeklyAll", used: 0, at: now.addingTimeInterval(-7_200)),
    s("a1", "weeklyAll", used: 30, at: now),
]
if let r = reading(idle) {
    check("active burn caps the idle gap at 30 min (60%/h)", near(r.activeBurnPerHour, 60))
} else { check("idle reading exists", false) }

// 5a. Starved to now: a single account's last sample sits at 100%, so it stays starved from that
//     sample until now (change-only recorder: no news = still pinned). 48h over two weeks = 24h/wk.
let starvedSolo = [
    s("a1", "weeklyAll", used: 0, at: daysAgo(14)),
    s("a1", "weeklyAll", used: 100, at: daysAgo(2)),
]
if let r = reading(starvedSolo) {
    check("last sample ≥99 stays starved to now (48h / 2wk = 24h)", near(r.starvedHoursPerWeek, 24, 0.1))
    check("sustained single-account starvation recommends adding", r.verdict == .addAccount)
} else { check("starvedSolo reading exists", false) }

// 5b. Pool-level: one account is pinned at 100% but the other still has quota - the fleet can
//     absorb a handoff, so the POOL is not starved (cross-account intersection is empty → 0h).
let oneStarvedOneNot = [
    s("a1", "weeklyAll", used: 0, at: daysAgo(8)),
    s("a1", "weeklyAll", used: 100, at: daysAgo(2)),
    s("a2", "weeklyAll", used: 0, at: daysAgo(8)),
    s("a2", "weeklyAll", used: 30, at: daysAgo(2)),
]
if let r = reading(oneStarvedOneNot) {
    check("one account starved, the other has quota → pool not starved (0h)",
          near(r.starvedHoursPerWeek, 0))
    check("a pool with headroom doesn't recommend adding", r.verdict == .sufficient)
} else { check("oneStarvedOneNot reading exists", false) }

// 5c. Both accounts starved but over different spans - only the overlap counts. a1 starved for its
//     last 4 days, a2 for its last 3; intersection = 3 days = 72h, over 8/7 weeks = 63h/wk (not
//     a1's 96h alone, nor their 96+72 sum).
let bothStarvedOverlap = [
    s("a1", "weeklyAll", used: 0, at: daysAgo(8)),
    s("a1", "weeklyAll", used: 100, at: daysAgo(4)),
    s("a2", "weeklyAll", used: 50, at: daysAgo(8)),
    s("a2", "weeklyAll", used: 100, at: daysAgo(3)),
]
if let r = reading(bothStarvedOverlap) {
    check("overlapping starvation counts only the intersection (72h / 1.143wk = 63h)",
          near(r.starvedHoursPerWeek, 63, 0.5))
    check("fleet-wide starvation recommends adding", r.verdict == .addAccount)
} else { check("bothStarvedOverlap reading exists", false) }

// 6. Cold-start gate: only five days of history stays "collecting", whatever the demand looks like.
let young = [
    s("a1", "weeklyAll", used: 0, at: daysAgo(5)),
    s("a1", "weeklyAll", used: 100, at: daysAgo(1)),
]
if let r = reading(young) {
    check("under 7 days → collecting", r.verdict == .collecting)
    check("collecting reports the day count", near(r.daysOfData, 5, 0.01))
} else { check("young reading exists", false) }

// 7. Model-window binding: the account-wide weekly looks fine, but a single model window (fable)
//    is fully spent each week → the binding pool triggers add-account.
let modelBound = [
    s("a1", "weeklyAll", used: 0, at: daysAgo(14)),
    s("a1", "weeklyAll", used: 20, at: daysAgo(1)),
    s("a1", "weeklyModel", used: 0, at: daysAgo(14), model: "Fable"),
    s("a1", "weeklyModel", used: 100, at: daysAgo(8), model: "Fable"),
    s("a1", "weeklyModel", used: 0, at: daysAgo(7), reset: resetB, model: "Fable"),
    s("a1", "weeklyModel", used: 100, at: daysAgo(1), reset: resetB, model: "Fable"),
]
if let r = reading(modelBound) {
    check("account-wide demand stays low", r.demandPerWeek < 0.5)
    check("a maxed model window still recommends adding", r.verdict == .addAccount)
} else { check("model-bound reading exists", false) }

// 8. Malformed lines: decode is fail-open - garbage lines cost only themselves.
let jsonl = """
{"ts":"2026-07-19T09:18:53Z","account":"a1","provider":"claude","used":16,"window":"weeklyAll","resetAt":"2026-07-25T11:59:00Z"}
this is not json
{"ts":"2026-07-20T09:18:53Z","account":"a1","provider":"claude","used":40,"window":"weeklyAll"}
{ "partial":
""".data(using: .utf8)!
let decoded = UsageAdvisor.decodeSamples(jsonl, since: Date(timeIntervalSince1970: 0))
check("malformed lines skipped, good ones kept", decoded.count == 2)

// 9. Multiple providers each get their own reading, in stable order.
let multi = [
    s("a1", "weeklyAll", used: 0, at: daysAgo(14)),
    s("a1", "weeklyAll", used: 40, at: daysAgo(1)),
    Sample(ts: daysAgo(14), account: "x1", provider: "codex", window: "weeklyAll",
           model: nil, used: 0, resetAt: resetA),
    Sample(ts: daysAgo(1), account: "x1", provider: "codex", window: "weeklyAll",
           model: nil, used: 30, resetAt: resetA),
]
let readings = UsageAdvisor.readings(samples: multi, now: now)
check("one reading per provider, sorted", readings.map(\.provider) == ["claude", "codex"])

// 10. English headline follows the verdict.
if let r = reading(young) {
    check("collecting headline names the day count",
          UsageAdvisor.englishHeadline(r).contains("collecting data"))
}
if let r = reading(heavy) {
    check("add-account headline", UsageAdvisor.englishHeadline(r).contains("adding an account"))
}

print(failures == 0 ? "\nAll advisor tests passed." : "\n\(failures) advisor test(s) FAILED.")
exit(failures == 0 ? 0 : 1)
