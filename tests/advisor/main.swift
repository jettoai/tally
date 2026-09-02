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

/// A run of samples ten minutes apart, all reading the same value.
///
/// WHY DENSITY MATTERS TO THESE FIXTURES. Starvation is only counted where the history is evidence
/// the app was awake (`observedSpans`), and one sample vouches for the following 30 minutes. Two
/// samples two days apart therefore describe two half-hours of watching, not two days of drought -
/// which is the whole point of the fix, and which means a fixture that wants to assert real starved
/// hours has to sample the way a running app does.
func run(_ account: String, _ window: String, used: Double, from: Date, to: Date,
         reset: Date? = resetA, model: String? = nil) -> [Sample] {
    var out: [Sample] = []
    var at = from
    while at <= to {
        out.append(s(account, window, used: used, at: at, reset: reset, model: model))
        at = at.addingTimeInterval(600)
    }
    return out
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

// 3. Rollover: a window that rolled over restarted AT ZERO, so the first reading of the new cycle
//    is all burn - it was spent inside that cycle. 90 in the old week, then 95 and a further 4 in
//    the new one = 189 over the week, never the 99 a naive `last - first` would give, and never the
//    94 the old pair-skipping rule gave (which threw the 95 away entirely: the app could be closed
//    over a rollover and come back to a spent week that counted as nothing).
let rollover = [
    s("a1", "weeklyAll", used: 0, at: daysAgo(7), reset: resetA),
    s("a1", "weeklyAll", used: 90, at: daysAgo(5), reset: resetA),
    s("a1", "weeklyAll", used: 95, at: daysAgo(4), reset: resetB),   // new cycle, from zero
    s("a1", "weeklyAll", used: 99, at: daysAgo(1), reset: resetB),
]
if let r = reading(rollover) {
    check("a new cycle's first reading is burn, not a skipped pair (1.89)",
          near(r.demandPerWeek, 1.89))
    check("…and it is not read as one continuous climb to 99", !near(r.demandPerWeek, 0.99))
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

// 5a. Starvation is only counted where the app was there to see it.
//
//     TWO FIXTURES OF THE SAME SHAPE, differing only in whether anything was recorded during the
//     drought. The change-only recorder says a sample's value persists until the next one, which is
//     true while the app runs and false the moment it does not: a laptop closed at 100% for two
//     days used to report 48 starved hours nobody observed, and the test that locked that in was
//     this one. A single recorded 30-minute window is what one sample is evidence of.
let starvedOffline = [
    s("a1", "weeklyAll", used: 0, at: daysAgo(8)),
    s("a1", "weeklyAll", used: 100, at: daysAgo(2)),
]
if let r = reading(starvedOffline) {
    check("a drought nobody was awake for counts one sample's 30 min (0.5h / 1.143wk)",
          near(r.starvedHoursPerWeek, 0.4375, 0.01))
    check("…so an offline stretch cannot recommend an account on its own",
          r.verdict == .sufficient)
} else { check("starvedOffline reading exists", false) }

// 5a-bis. The same 100%, watched: twelve hours of it recorded the way a running app records, plus
//     the last sample's own 30 minutes = 12.5h over 8/7 weeks = 10.94h/wk, past the 2h trigger.
//     The pair above and this one are the scope: what changed is the evidence, not the threshold.
let starvedWatched = [s("a1", "weeklyAll", used: 0, at: daysAgo(8))]
    + run("a1", "weeklyAll", used: 100, from: daysAgo(1), to: daysAgo(0.5))
if let r = reading(starvedWatched) {
    check("starvation the app actually watched is counted in full (12.5h / 1.143wk)",
          near(r.starvedHoursPerWeek, 10.9375, 0.02))
    check("sustained observed starvation recommends adding", r.verdict == .addAccount)
} else { check("starvedWatched reading exists", false) }

// 5a-ter. And it ends at the window's OWN reset, whatever the samples keep saying: quota came back
//     on a schedule the sample itself carries. Same recorded run twice - once with a reset three
//     days out (24h of drought, plus the last sample's half hour), once with one that lands halfway
//     through it (12h, and everything after it counts for nothing).
let droughtDay = run("a1", "weeklyAll", used: 100, from: daysAgo(5), to: daysAgo(4))
let openEnded = [s("a1", "weeklyAll", used: 0, at: daysAgo(9))] + droughtDay
let refills = [s("a1", "weeklyAll", used: 0, at: daysAgo(9), reset: daysAgo(4.5))]
    + run("a1", "weeklyAll", used: 100, from: daysAgo(5), to: daysAgo(4), reset: daysAgo(4.5))
if let open = reading(openEnded), let cut = reading(refills) {
    check("a watched day of drought is a watched day (24.5h / 1.286wk)",
          near(open.starvedHoursPerWeek, 24.5 / (9.0 / 7), 0.02))
    check("…and a reset halfway through ends it there (12h / 1.286wk)",
          near(cut.starvedHoursPerWeek, 12 / (9.0 / 7), 0.02))
} else { check("reset-truncation readings exist", false) }

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

// 5c. Both accounts starved but over different spans - only the overlap counts. a1 is recorded at
//     100% from day 4 to day 2, a2 from day 3 to day 2; the intersection is the last of those days
//     (24h) plus the half hour both last samples vouch for, over 8/7 weeks = 21.44h/wk. Not a1's
//     48h alone, and not their sum.
let bothStarvedOverlap = [s("a1", "weeklyAll", used: 0, at: daysAgo(8)),
                          s("a2", "weeklyAll", used: 50, at: daysAgo(8))]
    + run("a1", "weeklyAll", used: 100, from: daysAgo(4), to: daysAgo(2))
    + run("a2", "weeklyAll", used: 100, from: daysAgo(3), to: daysAgo(2))
if let r = reading(bothStarvedOverlap) {
    check("overlapping starvation counts only the intersection (24.5h / 1.143wk = 21.44h)",
          near(r.starvedHoursPerWeek, 24.5 / (8.0 / 7), 0.02))
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

// 11. Plan tiers: the same weekly demand split by the plan each account is on. Three accounts,
//     two plans - p1 burns 100% over two weeks (0.5 account-weeks), t1 and t2 burn 50% each
//     (0.25 + 0.25 = 0.5). The pooled figure stays 1.0 either way.
let mixedTiers = [
    s("p1", "weeklyAll", used: 0, at: daysAgo(14)),
    s("p1", "weeklyAll", used: 100, at: daysAgo(1)),
    s("t1", "weeklyAll", used: 0, at: daysAgo(14)),
    s("t1", "weeklyAll", used: 50, at: daysAgo(1)),
    s("t2", "weeklyAll", used: 0, at: daysAgo(14)),
    s("t2", "weeklyAll", used: 50, at: daysAgo(1)),
]
let plans = ["p1": "Pro", "t1": "Team", "t2": "Team"]
if let r = UsageAdvisor.reading(provider: "claude", samples: mixedTiers, now: now,
                                planOf: { plans[$0] }) {
    check("pooled demand unchanged by the split", near(r.demandPerWeek, 1.0))
    check("one entry per plan", r.tierDemands.count == 2)
    check("Pro tier is its own accounts' burn only",
          r.tierDemands.first { $0.plan == "Pro" }.map { near($0.demandPerWeek, 0.5) } == true)
    check("Team tier sums its two accounts",
          r.tierDemands.first { $0.plan == "Team" }.map { near($0.demandPerWeek, 0.5) } == true)
    check("each tier counts its own accounts",
          r.tierDemands.first { $0.plan == "Pro" }?.accountCount == 1
              && r.tierDemands.first { $0.plan == "Team" }?.accountCount == 2)
    check("the tiers add back up to the pooled demand",
          near(r.tierDemands.reduce(0) { $0 + $1.demandPerWeek }, r.demandPerWeek))
} else { check("mixed-tier reading exists", false) }

// 11b. Tiers are ordered by demand, largest first, and the unnamed tier goes last.
let ordered = [
    s("p1", "weeklyAll", used: 0, at: daysAgo(14)),
    s("p1", "weeklyAll", used: 20, at: daysAgo(1)),
    s("t1", "weeklyAll", used: 0, at: daysAgo(14)),
    s("t1", "weeklyAll", used: 80, at: daysAgo(1)),
    s("u1", "weeklyAll", used: 0, at: daysAgo(14)),
    s("u1", "weeklyAll", used: 40, at: daysAgo(1)),
]
if let r = UsageAdvisor.reading(provider: "claude", samples: ordered, now: now,
                                planOf: { ["p1": "Pro", "t1": "Team"][$0] }) {
    check("tiers sorted by demand, unnamed last",
          r.tierDemands.map(\.plan) == ["Team", nil, "Pro"])
}

// 11c. No plan supplied (the default, and an older snapshot): one unnamed tier carrying the whole
//      demand, never a split the panel would then have to explain.
if let r = reading(mixedTiers) {
    check("no planOf collapses to a single unnamed tier",
          r.tierDemands.count == 1 && r.tierDemands[0].plan == nil)
    check("that tier IS the pooled demand", near(r.tierDemands[0].demandPerWeek, r.demandPerWeek))
    check("and counts every account", r.tierDemands[0].accountCount == 3)
}

// 11d. The provider-wide entry point carries the same lookup through.
let perProvider = UsageAdvisor.readings(samples: multi, now: now,
                                        planOf: { $0 == "a1" ? "Max 20x" : "Pro" })
check("readings() passes the plan lookup down",
      perProvider.first?.tierDemands.first?.plan == "Max 20x")

// MARK: - 12. The personal account's reserve

// CONSUMER 7 OF THE RESERVE (Tally/Core/AccountReserve.swift). The question this file answers is "do
// these accounts cover the demand", and the honest form of it is about the part of them TALLY MAY
// SPEND: an account with 30 points held back for the browser is 0.7 of an account here. Without
// that, a fleet whose spendable half is saturated reads as comfortable because of quota sitting
// behind a preference nobody is allowed to touch.
//
// 12a. CAPACITY. Two accounts each spending 80 points in each of two weeks - 1.6 account-weeks
//      between them. Against two whole accounts that is 0.80 and comfortable; against the 1.5 a
//      half-reserved account leaves it is 1.07, past the 0.9 trigger. Nothing here ever reaches the
//      starved line, asserted below, so the flip is the CAPACITY arithmetic and can be nothing else.
let sharedLoad = [
    s("a1", "weeklyAll", used: 0, at: daysAgo(14), reset: resetA),
    s("a1", "weeklyAll", used: 80, at: daysAgo(8), reset: resetA),
    s("a1", "weeklyAll", used: 0, at: daysAgo(7), reset: resetB),
    s("a1", "weeklyAll", used: 80, at: daysAgo(1), reset: resetB),
    s("a2", "weeklyAll", used: 0, at: daysAgo(14), reset: resetA),
    s("a2", "weeklyAll", used: 80, at: daysAgo(8), reset: resetA),
    s("a2", "weeklyAll", used: 0, at: daysAgo(7), reset: resetB),
    s("a2", "weeklyAll", used: 80, at: daysAgo(1), reset: resetB),
]
let halfReserved = UsageAdvisor.reading(provider: "claude", samples: sharedLoad, now: now,
                                        reserveOf: { $0 == "a1" ? 50 : 0 })
let unreserved = UsageAdvisor.reading(provider: "claude", samples: sharedLoad, now: now)
check("the reserved fleet reads as tighter than the same fleet without a reserve",
      (halfReserved.map { $0.verdict } ?? .collecting) == .addAccount
          && (unreserved.map { $0.verdict } ?? .collecting) == .sufficient)
check("…and neither reading starves, so the flip is capacity and nothing else",
      halfReserved?.starvedHoursPerWeek == 0 && unreserved?.starvedHoursPerWeek == 0)
check("the same weekly demand either way (1.6 account-weeks)",
      near(halfReserved?.demandPerWeek ?? 0, 1.6) && near(unreserved?.demandPerWeek ?? 0, 1.6))
// 12b. A fleet nobody reserved anything on is untouched, which is every fleet until somebody sets
//      one - the default argument and an explicit zero have to be the same reading.
let explicitZero = UsageAdvisor.reading(provider: "claude", samples: sharedLoad, now: now,
                                        reserveOf: { _ in 0 })
check("no reserve anywhere leaves the verdict exactly where it was",
      explicitZero?.verdict == unreserved?.verdict)
// 12c. STARVATION. An account with 30 points held back can absorb no more work at 69% used, not at
//      99%: the points its owner kept were never work this fleet could absorb. The pool counts as
//      starved only while EVERY account is, so the fixture starves the sibling outright and lets
//      the reserve decide the reserved one.
let brownout = [
    s("a1", "weeklyAll", used: 70, at: daysAgo(9)),
    s("a1", "weeklyAll", used: 70, at: daysAgo(1)),
    s("a2", "weeklyAll", used: 100, at: daysAgo(9)),
    s("a2", "weeklyAll", used: 100, at: daysAgo(1)),
]
let starved = UsageAdvisor.reading(provider: "claude", samples: brownout, now: now,
                                   reserveOf: { $0 == "a1" ? 30 : 0 })
let notStarved = UsageAdvisor.reading(provider: "claude", samples: brownout, now: now)
check("a reserved account starves at its own line, not at the raw one",
      (starved?.starvedHoursPerWeek ?? 0) > 0)
check("…and the same fleet reports no starvation without the reserve",
      (notStarved?.starvedHoursPerWeek ?? -1) == 0)
// 12e. THE ACCOUNT-WIDE POOL IS THE ONLY ONE THAT HAS A RESERVE. The number is a slice of the weekly
//      all-models window and of no other (Albert's ruling, 2026-08-21; Tally/Core/AccountReserve.
//      swift), so a model pool reads it as zero - taking it off there as well would hold the same
//      points back twice and report a flagship pool as saturated on capacity nothing withholds.
let modelOnly = [
    s("a1", "weeklyModel", used: 70, at: daysAgo(9), model: "fable"),
    s("a1", "weeklyModel", used: 70, at: daysAgo(1), model: "fable"),
    s("a2", "weeklyModel", used: 100, at: daysAgo(9), model: "fable"),
    s("a2", "weeklyModel", used: 100, at: daysAgo(1), model: "fable"),
]
check("a reserve moves no reading on a model pool",
      UsageAdvisor.reading(provider: "claude", samples: modelOnly, now: now,
                           reserveOf: { $0 == "a1" ? 30 : 0 })?.starvedHoursPerWeek
          == UsageAdvisor.reading(provider: "claude", samples: modelOnly, now: now)?
              .starvedHoursPerWeek)
// The same rows in the account-wide window DO move, which is what makes the check above a scope
// rather than a fixture that could not have starved either way.
check("…while the identical rows in the account-wide window do",
      (starved?.starvedHoursPerWeek ?? 0) > (notStarved?.starvedHoursPerWeek ?? 0))
// 12d. The provider-wide entry point carries the lookup through, exactly as it does the plan one.
check("readings() passes the reserve lookup down",
      UsageAdvisor.readings(samples: brownout, now: now,
                            reserveOf: { $0 == "a1" ? 30 : 0 })
          .first.map { $0.starvedHoursPerWeek > 0 } ?? false)

// MARK: - 13. The cycle the burn is counted inside

// 13a. A RESET TIME THAT WOBBLES IS THE SAME WEEK. Claude's resets are parsed out of human text
//      whose finest unit is the minute, so one unbroken window is reported a minute either side of
//      itself between polls. Matched by equality, every one of these pairs looked like a fresh
//      cycle and its delta was discarded: 90 points of real spending read as zero.
let jitter = [
    s("a1", "weeklyAll", used: 0, at: daysAgo(14), reset: resetA),
    s("a1", "weeklyAll", used: 30, at: daysAgo(10), reset: resetA.addingTimeInterval(60)),
    s("a1", "weeklyAll", used: 60, at: daysAgo(6), reset: resetA.addingTimeInterval(-60)),
    s("a1", "weeklyAll", used: 90, at: daysAgo(2), reset: resetA.addingTimeInterval(120)),
]
if let r = reading(jitter) {
    check("a reset wobbling by a minute is one cycle, so the burn survives (0.45)",
          near(r.demandPerWeek, 0.45))
    check("…and equality-matching would have thrown all of it away", !near(r.demandPerWeek, 0))
} else { check("jitter reading exists", false) }

// 13b. AND A RESET THAT WALKS is still the same week. Codex's weekly starts at the first request
//      rather than on a calendar, so while a window sits idle its reported reset creeps forward
//      almost every poll. An anchor pinned to the first sighting would call minute 6 a new cycle
//      and bill the whole window again; the anchor follows the drift instead.
var drift: [Sample] = []
for i in 0 ... 20 {
    drift.append(s("a1", "weeklyAll", used: Double(i) * 2, at: daysAgo(14 - Double(i) / 2),
                   reset: resetA.addingTimeInterval(Double(i) * 60)))
}
if let r = reading(drift) {
    check("twenty minutes of creeping reset is one cycle (0.2, not a re-billed window)",
          near(r.demandPerWeek, 0.2))
} else { check("drift reading exists", false) }

// 13c. A DIP AND A RECOVERY IS ONE PURCHASE. Pairwise rectification bills the climb back up a
//      second time (50 + 4 + 10 = 64 here); the running maximum inside the cycle bills what was
//      actually spent (60). On this machine's real 28 days the two differ by 2.5 account-weeks.
let wobble = [
    s("a1", "weeklyAll", used: 0, at: daysAgo(14)),
    s("a1", "weeklyAll", used: 50, at: daysAgo(10)),
    s("a1", "weeklyAll", used: 46, at: daysAgo(9)),
    s("a1", "weeklyAll", used: 50, at: daysAgo(8)),
    s("a1", "weeklyAll", used: 60, at: daysAgo(2)),
]
if let r = reading(wobble) {
    check("a downward wobble is not re-billed on the way back (0.30)", near(r.demandPerWeek, 0.30))
    check("…which is not what pairwise rectification would have said (0.32)",
          !near(r.demandPerWeek, 0.32))
} else { check("wobble reading exists", false) }

// 13d. THE APP WAS CLOSED ACROSS A ROLLOVER and came back to a fresh week already at 40%. Those 40
//      points were spent; the old rule skipped the pair outright and made the new week's opening
//      reading a baseline, losing every one of them.
let reopened = [
    s("a1", "weeklyAll", used: 0, at: daysAgo(14), reset: resetA),
    s("a1", "weeklyAll", used: 90, at: daysAgo(9), reset: resetA),
    s("a1", "weeklyAll", used: 40, at: daysAgo(2), reset: resetB),
]
if let r = reading(reopened) {
    check("a rollover seen only after the fact still counts its opening reading (0.65)",
          near(r.demandPerWeek, 0.65))
} else { check("reopened reading exists", false) }

// 13e. AND THE VERY FIRST SAMPLE IS NOT BURN. Whatever the window already read when the history
//      began was spent before it, and a change-only log cannot reconstruct that tail.
if let r = reading([s("a1", "weeklyAll", used: 40, at: daysAgo(14)),
                    s("a1", "weeklyAll", used: 70, at: daysAgo(1))]) {
    check("history that opens mid-week bills only what it watched (0.15)",
          near(r.demandPerWeek, 0.15))
}

// MARK: - 14. The fleet as it is now, not as the history remembers it

// Two accounts spent 90 points each over two weeks: 0.9 account-weeks of demand between them.
// Against both seats that is 0.45 and comfortable; against the one seat still here it is 0.90,
// which is the trigger exactly.
let departed = [
    s("a1", "weeklyAll", used: 0, at: daysAgo(14)),
    s("a1", "weeklyAll", used: 90, at: daysAgo(1)),
    s("a2", "weeklyAll", used: 0, at: daysAgo(14)),
    s("a2", "weeklyAll", used: 90, at: daysAgo(1)),
]
let bothHere = UsageAdvisor.reading(provider: "claude", samples: departed, now: now)
let oneLeft = UsageAdvisor.reading(provider: "claude", samples: departed, now: now,
                                   liveAccounts: ["a1"])
check("a departed account's capacity goes with it", bothHere?.verdict == .sufficient
          && oneLeft?.verdict == .addAccount)
check("…while its past work stays in the demand, which is what the survivors must absorb",
      near(oneLeft?.demandPerWeek ?? 0, 0.9) && near(bothHere?.demandPerWeek ?? 0, 0.9))
check("…and the account count is the live fleet's",
      bothHere?.accountCount == 2 && oneLeft?.accountCount == 1)

// STARVATION TOO. a1 is watched at 100% for a day; a2 left the machine a fortnight ago and can
// never starve, so a pool that includes it can never be starved either.
let survivorStarved = [s("a1", "weeklyAll", used: 0, at: daysAgo(8)),
                       s("a2", "weeklyAll", used: 0, at: daysAgo(8)),
                       s("a2", "weeklyAll", used: 10, at: daysAgo(7))]
    + run("a1", "weeklyAll", used: 100, from: daysAgo(2), to: daysAgo(1))
check("a departed account cannot hold the pool out of starvation",
      (UsageAdvisor.reading(provider: "claude", samples: survivorStarved, now: now)?
          .starvedHoursPerWeek ?? -1) == 0
          && (UsageAdvisor.reading(provider: "claude", samples: survivorStarved, now: now,
                                   liveAccounts: ["a1"])?.starvedHoursPerWeek ?? 0) > 20)
// And a provider nobody is on any more is not asked the question at all.
check("a provider whose accounts have all gone yields no reading",
      UsageAdvisor.readings(samples: departed, now: now, liveAccounts: ["somebody-else"]).isEmpty)
check("…while the same call with them live still answers",
      UsageAdvisor.readings(samples: departed, now: now,
                            liveAccounts: ["a1", "a2"]).count == 1)

// MARK: - 15. The display windows - and the verdict that does NOT follow them

// A quiet fortnight with a hot last half-day: 20 points spent by day 2, then 70 more. The month
// reads 0.45 account-weeks, the day reads 4.9, and they are the same samples over different spans.
let hotFinish = [
    s("a1", "weeklyAll", used: 0, at: daysAgo(14)),
    s("a1", "weeklyAll", used: 20, at: daysAgo(2)),
    s("a1", "weeklyAll", used: 90, at: daysAgo(0.5)),
]
if let r = reading(hotFinish) {
    check("one rung per display window, shortest first",
          r.windowDemands.map(\.days) == UsageAdvisor.displayWindows)
    check("the month rung IS the published figure",
          near(r.windowDemands.last?.demandPerWeek ?? -1, r.demandPerWeek))
    check("the month reads the whole history's pace (0.45)",
          near(r.windowDemands[3].demandPerWeek ?? 0, 0.45))
    check("the week reads its own seven days (0.90)",
          near(r.windowDemands[2].demandPerWeek ?? 0, 0.90))
    check("three days reads 2.1", near(r.windowDemands[1].demandPerWeek ?? 0, 2.1))
    check("and the day reads only what was spent inside it (4.9)",
          near(r.windowDemands[0].demandPerWeek ?? 0, 4.9))
    // THE POINT OF THE WHOLE FEATURE, asserted: the recommendation is the month's, whatever the
    // reader is looking at. A day reading 4.9 against one account would be `addAccount` if the
    // verdict followed the lens; it does not, so the advice is the same on every rung.
    check("the verdict stays the month's, five times the day's figure notwithstanding",
          r.verdict == .sufficient)
} else { check("hotFinish reading exists", false) }

// 15b. EVERY WINDOW HAS ITS OWN GATE. Five days of history: the day and the three days are real
//      readings, the week and the month are not yet - and no window ever waits longer than the
//      seven days the trend gate has always waited.
let youngWindows = [
    s("a1", "weeklyAll", used: 0, at: daysAgo(5)),
    s("a1", "weeklyAll", used: 70, at: daysAgo(0.5)),
]
if let r = reading(youngWindows) {
    check("gates are the window's own span, capped at the trend minimum",
          r.windowDemands.map(\.minimumDays) == [1, 3, 7, 7])
    check("five days answers the short windows and withholds the long ones",
          r.windowDemands.map { $0.demandPerWeek != nil } == [true, true, false, false])
    check("the day still reads over its own day (4.9)",
          near(r.windowDemands[0].demandPerWeek ?? 0, 4.9))
    check("a withheld window carries no tier split either",
          r.windowDemands[3].tierDemands.isEmpty && !r.windowDemands[0].tierDemands.isEmpty)
    check("and the verdict is still collecting", r.verdict == .collecting)
} else { check("youngWindows reading exists", false) }

// 15c. A window's tiers split that window's own figure, and still add back up to it.
if let r = UsageAdvisor.reading(provider: "claude", samples: mixedTiers, now: now,
                                planOf: { ["p1": "Pro", "t1": "Team", "t2": "Team"][$0] }) {
    for window in r.windowDemands {
        check("the \(Int(window.days))-day tiers sum to the \(Int(window.days))-day figure",
              near(window.tierDemands.reduce(0) { $0 + $1.demandPerWeek },
                   window.demandPerWeek ?? 0))
    }
}

// MARK: - 16. The app's own call site passes what the engine needs

// STATIC, because there is no runtime observation that separates "the panel passed a reserve" from
// "nobody has one set": the whole defect was a call that compiled, ran and answered a subtly
// different question from the CLI's for a month. The lock is on the source line that passes it.
let advisorCallSite = (try? String(contentsOfFile: "Tally/Stores/UsageStoreAdvisor.swift",
                                   encoding: .utf8)) ?? ""
check("the app's advisor call site is readable from this suite", !advisorCallSite.isEmpty)
check("it passes the reserve lookup the CLI has always passed",
      advisorCallSite.contains("reserveOf:"))
check("it passes the live fleet, so a removed account stops counting as capacity",
      advisorCallSite.contains("liveAccounts:"))
check("and it reads the reserve from the shared rule rather than inventing one",
      advisorCallSite.contains("LaunchPolicyStore.shared.reserve(home:"))

print(failures == 0 ? "\nAll advisor tests passed." : "\n\(failures) advisor test(s) FAILED.")
exit(failures == 0 ? 0 : 1)
