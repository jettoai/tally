import Foundation

// Assertion harness for AdvisorConclusion, compiled against the real source. The one hard rule:
// while any plan's pool is forecast to run dry, the advisor row never says "enough".

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

typealias Tier = AdvisorConclusion.Tier
func tier(_ plan: String?, _ demand: Double, _ owned: Int, dry: Bool) -> Tier {
    Tier(plan: plan, demandPerWeek: demand, accountCount: owned, runsDry: dry)
}
func decide(_ verdict: UsageAdvisor.Verdict, _ days: Double, _ tiers: [Tier],
            split: Bool, starved: Double = 0) -> AdvisorConclusion {
    AdvisorConclusion.decide(verdict: verdict, daysOfData: days, tiers: tiers, split: split,
                             starvedHoursPerWeek: starved)
}

// T1: the demo Codex fleet, sufficient on the pooled four weeks while the Team pool runs dry.
check("T1 demo Codex names the short plan",
      decide(.sufficient, 14, [tier("Pro", 1.7, 3, dry: false), tier("Team", 0.9, 1, dry: true)],
             split: true) == .shortAtPace(plans: ["Team"]))
// T2: the demo Claude fleet, 5.8 account-weeks over 5 accounts.
check("T2 demo Claude asks for one more",
      decide(.addAccount, 14, [tier(nil, 5.8, 5, dry: true)], split: false) == .add(count: 1, plan: nil))
// T3: split and nothing dry, nothing starved: the tightest tier is near capacity, not short.
check("T3 split near capacity names the tightest tier",
      decide(.addAccount, 14, [tier("Pro", 1.7, 3, dry: false), tier("Team", 0.9, 1, dry: false)],
             split: true) == .nearCapacity(demandPerWeek: 0.9, owned: 1, plan: "Team"))
check("T3b split, nothing dry but starved 3h/wk, adds the tightest tier",
      decide(.addAccount, 14, [tier("Pro", 1.7, 3, dry: false), tier("Team", 0.9, 1, dry: false)],
             split: true, starved: 3) == .add(count: 1, plan: "Team"))
// T4: a dry tier wins over a tighter one that still lasts.
check("T4 split add prefers the dry tier",
      decide(.addAccount, 14, [tier("Pro", 1.7, 3, dry: true), tier("Team", 0.9, 1, dry: false)],
             split: true) == .add(count: 1, plan: "Pro"))
check("T5 sufficient and nothing dry reads enough",
      decide(.sufficient, 14, [tier(nil, 2.0, 4, dry: false)], split: false) == .enough)
check("T6 collecting 5.2 days leaves 2",
      decide(.collecting, 5.2, [tier(nil, 1, 2, dry: false)], split: false) == .collecting(daysLeft: 2))
check("T6 collecting 6.4 days leaves 1",
      decide(.collecting, 6.4, [tier(nil, 1, 2, dry: false)], split: false) == .collecting(daysLeft: 1))
check("T6 collecting 6.99 days leaves 1",
      decide(.collecting, 6.99, [tier(nil, 1, 2, dry: false)], split: false) == .collecting(daysLeft: 1))
check("T7 a dry pool overrides collecting",
      decide(.collecting, 3, [tier(nil, 1, 2, dry: true)], split: false) == .shortAtPace(plans: []))
check("T8 every tier dry names none",
      decide(.sufficient, 14, [tier("Pro", 1, 3, dry: true), tier("Team", 1, 1, dry: true)],
             split: true) == .shortAtPace(plans: []))

// T9: exhaustive consistency, any dry tier means the conclusion is not "enough".
var t9Cases = 0, t9Bad = 0
for verdict in [UsageAdvisor.Verdict.collecting, .sufficient, .addAccount] {
    for days in [3.0, 14.0] {
        for a in [false, true] {
            let single = [tier(nil, 1.5, 2, dry: a)]
            t9Cases += 1
            if a, decide(verdict, days, single, split: false) == .enough { t9Bad += 1 }
            for b in [false, true] {
                let pair = [tier("Pro", 1.7, 3, dry: a), tier("Team", 0.9, 1, dry: b)]
                t9Cases += 1
                if a || b, decide(verdict, days, pair, split: true) == .enough { t9Bad += 1 }
            }
        }
    }
}
check("T9 no dry combination reads enough (\(t9Cases) cases)", t9Bad == 0 && t9Cases == 36)

check("T10 empty tiers add does not crash", decide(.addAccount, 14, [], split: false) == .add(count: 1, plan: nil))
check("T10 empty tiers sufficient", decide(.sufficient, 14, [], split: false) == .enough)
check("T10 empty tiers split add does not crash", decide(.addAccount, 14, [], split: true) == .add(count: 1, plan: nil))

check("T11 shortfall 8.2 over 5 is 4", AdvisorConclusion.shortfall(demandPerWeek: 8.2, owned: 5) == 4)
check("T11 shortfall 5.8 over 5 is 1", AdvisorConclusion.shortfall(demandPerWeek: 5.8, owned: 5) == 1)
check("T11 shortfall 0.9 over 1 is 1", AdvisorConclusion.shortfall(demandPerWeek: 0.9, owned: 1) == 1)
check("T11 shortfall 3 over 0 counts owned as 1", AdvisorConclusion.shortfall(demandPerWeek: 3, owned: 0) == 2)

check("T12 an unnamed dry plan is kept as nil",
      decide(.sufficient, 14, [tier("Pro", 1, 3, dry: false), tier(nil, 0, 1, dry: true)],
             split: true) == .shortAtPace(plans: [nil]))

// T14: the join with the gauge's dry pools, then the decision. The failure shape: the gauge draws
// the provider unsplit (one of its named-plan accounts has no metrics) and forecasts that pool dry,
// while the history splits into two named plans. The unsplit pool is every plan's.
typealias Demand = UsageAdvisor.TierDemand
typealias Dry = AdvisorConclusion.DryPool
func join(_ verdict: UsageAdvisor.Verdict, _ demands: [Demand], _ dry: [Dry]) -> AdvisorConclusion {
    AdvisorConclusion.join(verdict: verdict, daysOfData: 20, pooledDemandPerWeek: 3.0,
                           tierDemands: demands, ownedAccounts: 4, dryPools: dry,
                           starvedHoursPerWeek: 0)
}
let proTeam = [Demand(plan: "Pro", demandPerWeek: 2.4, accountCount: 3),
               Demand(plan: "Team", demandPerWeek: 0.6, accountCount: 1)]
let unsplitDry = [Dry(byPlan: false, plan: nil, accountCount: 3)]
check("T14 unsplit dry pool under split history is not enough",
      join(.sufficient, proTeam, unsplitDry) != .enough)
check("T14 unsplit dry pool marks every tier short",
      join(.sufficient, proTeam, unsplitDry) == .shortAtPace(plans: []))
check("T14 unsplit dry pool under split history, add names a plan",
      join(.addAccount, proTeam, unsplitDry) == .add(count: 1, plan: "Pro"))
check("T14 split history, nothing dry reads enough", join(.sufficient, proTeam, []) == .enough)
check("T14 split history, one plan's pool dry names it",
      join(.sufficient, proTeam, [Dry(byPlan: true, plan: "team", accountCount: 1)])
        == .shortAtPace(plans: ["Team"]))
check("T14 gauge-only plan still counts",
      join(.sufficient, proTeam, [Dry(byPlan: true, plan: "Max", accountCount: 1)])
        == .shortAtPace(plans: ["Max"]))
check("T14 unsplit history and unsplit dry pool",
      join(.sufficient, [Demand(plan: "Pro", demandPerWeek: 3, accountCount: 4)], unsplitDry)
        == .shortAtPace(plans: []))
check("T14 unsplit history, nothing dry reads enough",
      join(.sufficient, [Demand(plan: "Pro", demandPerWeek: 3, accountCount: 4)], []) == .enough)

// T15-T19: the row's second line reads one window, cycled by a click, split by plan like the
// pool rows above it (2026-09-28: the ladder pooled Codex Pro and Team into one figure).
typealias Window = UsageAdvisor.WindowDemand
typealias Figure = AdvisorConclusion.WindowFigure
check("T15 28 -> 1", AdvisorConclusion.nextWindow(after: 28) == 1)
check("T15 1 -> 3", AdvisorConclusion.nextWindow(after: 1) == 3)
check("T15 3 -> 7", AdvisorConclusion.nextWindow(after: 3) == 7)
check("T15 7 -> 28", AdvisorConclusion.nextWindow(after: 7) == 28)
check("T15 off-ladder value lands on the shortest", AdvisorConclusion.nextWindow(after: 5) == 1)

let maxOnly = [Demand(plan: "Max 20x", demandPerWeek: 5.8, accountCount: 5)]
let single = AdvisorConclusion.windowFigures(
    Window(days: 7, demandPerWeek: 6.0, tierDemands: [Demand(plan: "Max 20x", demandPerWeek: 6.0, accountCount: 5)],
           minimumDays: 1),
    readingTiers: maxOnly, planOrder: ["Max 20x"])
check("T16 one plan does not split", !single.split)
check("T16 one plan reads the pooled window figure", single.figures == [Figure(plan: nil, demandPerWeek: 6.0)])

let codexTiers = [Demand(plan: "Pro", demandPerWeek: 1.7, accountCount: 3),
                  Demand(plan: "Team", demandPerWeek: 0.9, accountCount: 1)]
let threeDay = Window(days: 3, demandPerWeek: 2.8,
                      tierDemands: [Demand(plan: "Pro", demandPerWeek: 1.8, accountCount: 3),
                                    Demand(plan: "Team", demandPerWeek: 1.0, accountCount: 1)],
                      minimumDays: 1)
let gaugeOrder = AdvisorConclusion.windowFigures(threeDay, readingTiers: codexTiers, planOrder: ["Team", "Pro"])
check("T17 two plans split", gaugeOrder.split)
check("T17 split follows the gauge's order",
      gaugeOrder.figures == [Figure(plan: "Team", demandPerWeek: 1.0), Figure(plan: "Pro", demandPerWeek: 1.8)])
let noOrder = AdvisorConclusion.windowFigures(
    threeDay, readingTiers: [Demand(plan: nil, demandPerWeek: 0.1, accountCount: 1)] + codexTiers, planOrder: [])
check("T17b no gauge order keeps the reading's, unnamed plan last",
      noOrder.figures.map(\.plan) == ["Pro", "Team", nil])
check("T17b plan absent from the window reads zero", noOrder.figures.last?.demandPerWeek == 0)

let collectingDay = AdvisorConclusion.windowFigures(
    Window(days: 1, demandPerWeek: nil, tierDemands: [], minimumDays: 1),
    readingTiers: codexTiers, planOrder: ["Pro", "Team"])
check("T18 collecting window keeps the plan names", collectingDay.split
      && collectingDay.figures == [Figure(plan: "Pro", demandPerWeek: nil), Figure(plan: "Team", demandPerWeek: nil)])

let ladderReading = UsageAdvisor.Reading(
    provider: "codex", verdict: .sufficient, demandPerWeek: 2.6, activeBurnPerHour: 10,
    starvedHoursPerWeek: 0, daysOfData: 14, accountCount: 4, tierDemands: codexTiers,
    windowDemands: [Window(days: 1, demandPerWeek: 3.0, minimumDays: 1), threeDay,
                    Window(days: 28, demandPerWeek: 2.6, minimumDays: 7)])
check("T19 remembered window is read", AdvisorConclusion.window(3, in: ladderReading).days == 3)
check("T19 unknown window falls back to the last", AdvisorConclusion.window(5, in: ladderReading).days == 28)
var bare = ladderReading
bare.windowDemands = []
let fallback = AdvisorConclusion.window(7, in: bare)
check("T19 no ladder falls back to the four weeks", fallback.days == 28 && fallback.demandPerWeek == 2.6
      && fallback.tierDemands == codexTiers)

// T13: source locks. The row goes through the one decision, and the gauge's forecast line reads
// the shared dry predicate instead of calling the forecast math a second time.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}
let advisor = source("Tally/Views/AdvisorStripView.swift")
check("T13 advisor source readable", !advisor.isEmpty)
check("T13 row decides through AdvisorConclusion.join", advisor.contains("AdvisorConclusion.join("))
check("T13 no pips", !advisor.contains("demandPips("))
var rowBody = ""
if let start = advisor.range(of: "func advisorTag") {
    let rest = advisor[start.upperBound...]
    rowBody = String(rest[..<(rest.range(of: "    private ")?.lowerBound ?? rest.endIndex)])
}
check("T13 advisorTag found", !rowBody.isEmpty)
// The panel shows a heading tag only; every window's figure lives in the hover (B-1524).
check("T13 tag hovers the full advice", rowBody.contains(".tallyTooltip(lazyBlocks: { advisorTooltip(state) })"))
check("T13 tag no longer lists every window", !rowBody.contains("ladderLine"))
check("T13 row splits through windowFigures", advisor.contains("AdvisorConclusion.windowFigures("))
check("T13 hover ladder is per plan", advisor.contains("ladderLines(reading)"))

// T20: the panel meets a fresh install with the list, and the advisor window is remembered.
let settingsSource = source("Tally/Stores/SettingsStore.swift")
check("T20 density defaults to list", settingsSource.contains("?? \"\") ?? .list")
    && !settingsSource.contains("?? \"\") ?? .cards"))
check("T20 advisor window persisted", settingsSource.contains("forKey: \"advisorWindowDays\""))

// T21: the hover's strings exist in every shipped language (B-1570: one row per figure).
let catalog = (try? Data(contentsOf: root.appendingPathComponent("Tally/Resources/Localizable.xcstrings")))
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
let strings = catalog?["strings"] as? [String: Any] ?? [:]
for key in ["Account Pool", "4-week average", "Active burn", "Starved", "By window", "acct/wk",
            "%@ acct/wk", "%@/wk", "Next refill", "runs dry in about %@"] {
    let locs = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
    let complete = ["zh-Hant", "zh-Hans", "ja", "ko"].allSatisfy { lang in
        let value = ((locs[lang] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        return !(value ?? "").isEmpty
    }
    check("T21 \(key) translated", complete)
}
// T22-T28: "add" must be backed by something visible this week (2026-09-28, TG 2810: "this pace
// holds" sat above "add 1 account"). Replays the live readings from `tally status --json`.
func joinLive(_ verdict: UsageAdvisor.Verdict, pooled: Double, _ demands: [Demand], owned: Int,
              _ dry: [Dry], starved: Double) -> AdvisorConclusion {
    AdvisorConclusion.join(verdict: verdict, daysOfData: 28, pooledDemandPerWeek: pooled,
                           tierDemands: demands, ownedAccounts: owned, dryPools: dry,
                           starvedHoursPerWeek: starved)
}
let claudeLive = [Demand(plan: "Max 20x", demandPerWeek: 4.7975, accountCount: 5)]
check("T22 Claude 4.8 over 5, pool lasts, 0 starved: near capacity",
      joinLive(.addAccount, pooled: 4.7975, claudeLive, owned: 5, [], starved: 0)
        == .nearCapacity(demandPerWeek: 4.7975, owned: 5, plan: nil))
let codexLive = [Demand(plan: "Pro", demandPerWeek: 1.9725, accountCount: 1),
                 Demand(plan: "Team", demandPerWeek: 1.8375, accountCount: 1)]
let proDry = Dry(byPlan: true, plan: "Pro", accountCount: 1)
let teamDry = Dry(byPlan: true, plan: "Team", accountCount: 1)
check("T23 Codex, both pools dry: still adds the tightest, Pro",
      joinLive(.addAccount, pooled: 3.81, codexLive, owned: 2, [proDry, teamDry], starved: 0.009)
        == .add(count: 1, plan: "Pro"))
check("T23b Codex, only Team dry: adds Team",
      joinLive(.addAccount, pooled: 3.81, codexLive, owned: 2, [teamDry], starved: 0.009)
        == .add(count: 1, plan: "Team"))
check("T24 starved 3h/wk with nothing dry still adds",
      joinLive(.addAccount, pooled: 4.7975, claudeLive, owned: 5, [], starved: 3)
        == .add(count: 1, plan: nil))
check("T24b exactly 2h/wk starved is not past the trigger",
      joinLive(.addAccount, pooled: 4.7975, claudeLive, owned: 5, [], starved: 2)
        == .nearCapacity(demandPerWeek: 4.7975, owned: 5, plan: nil))
check("T25 split, nothing dry: near capacity quotes the tightest tier's own figure",
      joinLive(.addAccount, pooled: 3.81, codexLive, owned: 2, [], starved: 0)
        == .nearCapacity(demandPerWeek: 1.9725, owned: 1, plan: "Pro"))
check("T26 a verdict the weekly figure did not trip quotes no figure",
      joinLive(.addAccount, pooled: 2.0, [Demand(plan: nil, demandPerWeek: 2.0, accountCount: 5)],
               owned: 5, [], starved: 0) == .nearCapacity(demandPerWeek: nil, owned: 5, plan: nil))

// T27: exhaustive, addAccount reads "add" exactly when a pool is dry or the fleet starved.
func isAdd(_ c: AdvisorConclusion) -> Bool { if case .add = c { return true }; return false }
var t27Cases = 0, t27Bad = 0
for starved in [0.0, 2.0, 3.0] {
    for a in [false, true] {
        t27Cases += 1
        if isAdd(decide(.addAccount, 28, [tier(nil, 4.8, 5, dry: a)], split: false, starved: starved))
            != (a || starved > 2) { t27Bad += 1 }
        for b in [false, true] {
            t27Cases += 1
            let pair = [tier("Pro", 1.97, 1, dry: a), tier("Team", 1.84, 1, dry: b)]
            if isAdd(decide(.addAccount, 28, pair, split: true, starved: starved))
                != (a || b || starved > 2) { t27Bad += 1 }
        }
    }
}
check("T27 add iff dry or starved (\(t27Cases) cases)", t27Bad == 0 && t27Cases == 18)

// T28: the near-capacity strings exist in every shipped language, and the tint is one step under add.
for key in ["near limit over 4 wks", "5-hour pool",
            "lasts at this pace", "runs dry in about %@"] {
    let locs = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
    let complete = ["zh-Hant", "zh-Hans", "ja", "ko"].allSatisfy { lang in
        let value = ((locs[lang] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        return !(value ?? "").isEmpty
    }
    check("T28 \(key) translated", complete)
}
// Every add tag shown, Claude's four-week one (near capacity past the accounts owned) and
// Codex's dry-pool one alike, is the same action in the same words, so it takes the same amber
// (B-1544 r4: one grey and one amber "add 1 account" read as two different kinds of advice).
check("T28 every add tag shown is drawn in the one purchase amber",
      advisor.contains("case .add, .nearCapacity, .shortAtPace: return TallyColor.warning")
          && !advisor.contains("case .nearCapacity: return .primary"))
// T29: near capacity's tag states the four-week figures, the hover's first line word for word,
// instead of a "near limit" verdict that sat over a row reading "won't run dry" (B-1544).
check("T29 the figure sentences carry no verdict",
      !advisor.contains("\"near limit over 4 wks: \\(") && !advisor.contains("weekly pool near limit"))
check("T28 row passes starved hours to the join",
      advisor.contains("starvedHoursPerWeek: reading.starvedHoursPerWeek"))
let fleet = source("Tally/Views/FleetStripView.swift")
var phraseBody = ""
if let start = fleet.range(of: "private func forecastPhrase") {
    let rest = fleet[start.upperBound...]
    let ends = ["    /// ", "    private func"].compactMap { rest.range(of: $0)?.lowerBound }
    phraseBody = String(rest[..<(ends.min() ?? rest.endIndex)])
}
check("T13 forecastPhrase found", !phraseBody.isEmpty)
check("T13 forecastPhrase reads poolDryDate", phraseBody.contains("poolDryDate("))
check("T13 forecastPhrase does not call depletion itself", !phraseBody.contains("FleetForecast.depletion("))
// T30: the 5-hour window's pool row is named for its length, in the words the rest of the app uses
// for that window ("5 hours"), not "Session pool" (B-1544).
check("T30 the session pool row reads 5-hour pool",
      fleet.contains("return L(\"5-hour pool\")") && !fleet.contains("L(\"Session pool\")")
          && strings["Session pool"] == nil)

// T31: a split provider names its plan on a title line of its own, so every pool row under it,
// the first one too, names its window (B-1544 r3: "Pro ×1" stood where "Weekly pool" belonged).
var gaugeBody = ""
if let start = fleet.range(of: "func fleetGauge(") {
    let rest = fleet[start.upperBound...]
    gaugeBody = String(rest[..<(rest.range(of: "    /// Provider identity")?.lowerBound ?? rest.endIndex)])
}
check("T31 the plan has its own title line above the pool rows",
      gaugeBody.contains("if let tier = summary.planTier") && gaugeBody.contains("planName(tier)"))
check("T31 every pool row is labelled with its pool name",
      fleet.contains("Text(poolDisplayName(pool)).foregroundStyle(Color.secondary)")
          && !fleet.contains("if index == 0, let tier = summary.planTier"))
// T32: "All pools" with no 5-hour reading says so on a row of its own instead of drawing one row fewer.
check("T32 a missing 5-hour window draws a no-reading row",
      gaugeBody.contains("!pools.contains(where: { $0.kind == .session })")
          && fleet.contains("L(\"No reading\")"))
// T33: the no-reading row's string ships in every language.
for key in ["No reading", "add 1 %@ account"] {
    let locs = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
    let complete = ["zh-Hant", "zh-Hans", "ja", "ko"].allSatisfy { lang in
        let value = ((locs[lang] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        return !(value ?? "").isEmpty
    }
    check("T33 \(key) translated", complete)
}
let jaAdd = (((strings["add 1 %@ account"] as? [String: Any])?["localizations"] as? [String: Any])?["ja"]
    as? [String: Any]).flatMap { ($0["stringUnit"] as? [String: Any])?["value"] as? String } ?? ""
check("T33 ja add-one badge is short enough for the heading row", !jaAdd.isEmpty && jaAdd.count <= 12)

// T34: the tag appears only when it asks for something AND nothing beside it says otherwise (B-1544
// r4: "avg 7.1/wk of 7" beside "won't run dry"; r5: amber "add 1" beside green "won't run dry"). A
// tag needs both: four-week use past the accounts owned, and the plan's pools running dry this
// week. The hover's first line states both time scales, its this-week half from the same forecast.
let anyDry = Dry(byPlan: false, plan: nil, accountCount: 7)
func tagCount(_ c: AdvisorConclusion, _ fourWeek: (Double, Int)? = nil, _ dry: [Dry]) -> String {
    c.tagAdd(fourWeek: fourWeek.map { (demand: $0.0, owned: $0.1) }, dryPools: dry)
        .map { "\($0.count) \($0.plan ?? "-")" } ?? "none"
}
check("T34a past the accounts owned and running dry asks to add",
      tagCount(.nearCapacity(demandPerWeek: 7.1, owned: 7, plan: nil), nil, [anyDry]) == "1 -"
          && tagCount(.nearCapacity(demandPerWeek: 2.4, owned: 1, plan: "Pro"), nil, [proDry]) == "2 Pro"
          && tagCount(.add(count: 1, plan: "Pro"), (1.6, 1), [proDry]) == "1 Pro")
check("T34b past the accounts owned but lasting this week has no tag (today's Claude row)",
      tagCount(.nearCapacity(demandPerWeek: 7.1, owned: 7, plan: nil), nil, []) == "none"
          && tagCount(.add(count: 1, plan: "Pro"), (1.6, 1), []) == "none"
          && tagCount(.add(count: 1, plan: "Pro"), (1.6, 1), [teamDry]) == "none"
          && tagCount(.add(count: 1, plan: nil), (7.1, 7), []) == "none")
check("T34b running dry but at or under the accounts owned has no tag",
      tagCount(.nearCapacity(demandPerWeek: 6.5, owned: 7, plan: nil), nil, [anyDry]) == "none"
          && tagCount(.nearCapacity(demandPerWeek: 7.0, owned: 7, plan: nil), nil, [anyDry]) == "none"
          && tagCount(.nearCapacity(demandPerWeek: nil, owned: 7, plan: nil), nil, [anyDry]) == "none"
          && tagCount(.add(count: 1, plan: "Pro"), (0.9, 1), [proDry]) == "none"
          && tagCount(.add(count: 1, plan: "Pro"), nil, [proDry]) == "none"
          && tagCount(.enough, nil, [anyDry]) == "none")
check("T34c this week's half follows the dry forecast of the named plan",
      AdvisorConclusion.runsDryThisWeek(plan: "Pro", dryPools: [proDry])
          && !AdvisorConclusion.runsDryThisWeek(plan: "Pro", dryPools: [teamDry])
          && AdvisorConclusion.runsDryThisWeek(plan: "pro", dryPools: [Dry(byPlan: false, plan: nil, accountCount: 2)])
          && !AdvisorConclusion.runsDryThisWeek(plan: nil, dryPools: [])
          && AdvisorConclusion.runsDryThisWeek(plan: nil, dryPools: [teamDry]))
check("T34c the hover's first line picks its this-week half from that forecast",
      advisor.contains("AdvisorConclusion.runsDryThisWeek(plan: plan, dryPools: dry)")
          && advisor.contains("conclusion.tagAdd"))
let twoScaleKeys = [
    "Past 4 weeks averaged %@ accounts a week, you have %@; at this week's pace it lasts until the refill",
    "Past 4 weeks averaged %@ accounts a week, you have %@; at this week's pace it runs dry before the refill",
    "%@: past 4 weeks averaged %@ accounts a week, you have %@; at this week's pace it lasts until the refill",
    "%@: past 4 weeks averaged %@ accounts a week, you have %@; at this week's pace it runs dry before the refill",
]
for key in twoScaleKeys {
    let locs = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
    let complete = ["zh-Hant", "zh-Hans", "ja", "ko"].allSatisfy { lang in
        let value = ((locs[lang] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        return !(value ?? "").isEmpty
    }
    check("T34d \(key.prefix(40)) translated", complete)
}
check("T34d the figure-only tag keys are gone",
      strings["avg %@/wk of %@"] == nil && strings["%@ avg %@/wk of %@"] == nil
          && !advisor.contains("wk of \\(count)"))

// T35 (B-1544 r6): "runs dry" is the gauge's forecast with every refill already counted
// (`FleetForecast.depletion`, fleet suite 13b), so the row's next refill, one account's window,
// does not cancel it. A pool its refills carry through is not in `dryPools` and gets no tag; a
// pool still dry after them, past the accounts owned, does; one tag per provider, on the pool
// that runs dry first.
let day = 86_400.0, t0 = Date(timeIntervalSince1970: 1_800_000_000)
func dryAt(_ plan: String, days: Double) -> Dry {
    Dry(byPlan: true, plan: plan, accountCount: 1, dryAt: t0.addingTimeInterval(days * day))
}
check("T35a refills outlast the drain: no dry pool, no tag",
      tagCount(.nearCapacity(demandPerWeek: 5.8, owned: 5, plan: nil), nil, []) == "none")
check("T35b dry after the refills, past the accounts owned: tag",
      tagCount(.nearCapacity(demandPerWeek: 5.8, owned: 5, plan: nil), nil,
               [Dry(byPlan: false, plan: nil, accountCount: 5, dryAt: t0.addingTimeInterval(4.4 * day))])
        == "1 -")
// Today's Codex: Pro dry in 3d13h, Team in 5d19h, both past one account each. Then the dates swapped,
// so the pool that runs dry first is no longer the one most over its own capacity.
let codexToday = joinLive(.addAccount, pooled: 3.81, codexLive, owned: 2,
                          [dryAt("Pro", days: 3.54), dryAt("Team", days: 5.79)], starved: 0)
let codexSwapped = joinLive(.addAccount, pooled: 3.81, codexLive, owned: 2,
                            [dryAt("Pro", days: 5.79), dryAt("Team", days: 3.54)], starved: 0)
check("T35c both plans dry: one tag, on the plan that runs dry first",
      codexToday == .add(count: 1, plan: "Pro") && codexSwapped == .add(count: 1, plan: "Team")
          && tagCount(codexSwapped, (1.8375, 1), [dryAt("Pro", days: 5.79), dryAt("Team", days: 3.54)])
            == "1 Team")
check("T35c the row hands the gauge's dry date to the join",
      advisor.contains("dryAt: entry.dry"))

// T36: the refill wording says how much comes back ("refill +82% in 19h 11m"); a bare "refill in
// 19h" read as the whole pool refilling (B-1544 r7). The hover reuses it, so no second suffix.
check("T36 refill text carries the gain",
      fleet.contains("String(localized: \"refill +\\(gain) in \\(body)\"")
          && fleet.contains("String(localized: \"next refill \\(account) +\\(gain) in \\(body)\"")
          && fleet.contains("let gain = \"\\(Int(refill.gain.rounded()))%\""))
check("T36 advisor hover does not append the gain twice", !advisor.contains("(+\\(Int(refill.gain"))
for (key, gainArg, args) in [("refill +%@ in %@", 1, 2), ("next refill %@ +%@ in %@", 2, 3)] {
    let locs = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
    let complete = ["zh-Hant", "zh-Hans", "ja", "ko"].allSatisfy { lang in
        let value = ((locs[lang] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
        return value.contains("+%\(gainArg)$@") && (1...args).allSatisfy { value.contains("%\($0)$@") }
    }
    check("T36 \(key) translated with the gain", complete)
}
check("T36 the gainless refill keys are gone",
      strings["refill in %@"] == nil && strings["next refill %@ in %@"] == nil)

// T37: the hover has a home without the tag (B-1570). A heading with nothing to act on still answers
// on the provider's name, and while the tag is showing the hover stays on the tag alone (one target,
// one callout: the name and the tag never both claim the single slot).
let header = source("Tally/Views/ProviderSectionHeader.swift")
check("T37 header source readable", !header.isEmpty)
check("T37 the provider's name holds the advisor hover when there is no tag",
      header.contains(".tallyTooltip(lazyBlocks: { advisorHeadingTooltip(providerID) }"))
check("T37 the name's hover stands down while the tag is showing",
      advisor.contains("func advisorHeadingTooltip(")
          && advisor.contains("guard let state = advisorState(providerID), state.tag == nil else { return [] }"))

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
