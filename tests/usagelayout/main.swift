import Foundation

// THE SHARED LAYER BEHIND THE USAGE-TAB PREVIEW LAYOUTS (B-2625): the tightest-window rule the layouts
// print one number from, and the flag that switches them on. Asserted on values where the code can be
// compiled here (LaunchPolicyStore, UsageLayout) and on source text where it cannot (the SwiftUI
// files), the same split the other suites make.

var passed = 0, failed = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

/// The body `headroom` had BEFORE `bindingWindow` was pulled out of it, kept verbatim as the
/// reference the refactor must reproduce value for value.
func legacyHeadroom(_ usage: AccountUsage, primaryModel: String? = nil) -> Double? {
    var windows = [
        usage.metrics.first { $0.kind == .session }?.remainingPercent,
        usage.metrics.first { $0.kind == .weeklyAll }?.remainingPercent,
    ].compactMap { $0 }
    let model = usage.headline.flatMap { $0.isModelScoped ? $0 : nil }
    let windowModel = model?.modelName?.lowercased()
    let primary = primaryModel?.lowercased()
    let modelWindowCounts = primary == nil || windowModel == nil
        || windowModel!.contains(primary!) || primary!.contains(windowModel!)
    if modelWindowCounts, let remaining = model?.remainingPercent { windows.append(remaining) }
    return windows.min()
}

func window(_ id: String, _ kind: MetricKind, left: Double, name: String? = nil, reset: Date? = nil)
    -> UsageMetric {
    UsageMetric(id: id, kind: kind, label: name ?? id, modelName: name, usedPercent: 100 - left,
                severity: .fromUsedPercent(100 - left), resetsAt: reset, isActive: false)
}

func account(session: Double? = nil, weekly: Double? = nil, model: (String, Double)? = nil,
             id: String = "claude:t", plan: String? = "Max 20x", weeklyReset: Date? = nil)
    -> AccountUsage {
    var metrics: [UsageMetric] = []
    if let model { metrics.append(window("weekly_model:\(model.0)", .weeklyModel, left: model.1, name: model.0)) }
    if let session { metrics.append(window("session", .session, left: session)) }
    if let weekly { metrics.append(window("weekly_all", .weeklyAll, left: weekly, reset: weeklyReset)) }
    return AccountUsage(id: id, providerID: "claude", accountLabel: id, planName: plan,
                        accountEmail: nil, metrics: metrics, refreshedAt: Date())
}

MainActor.assumeIsolated {
    // 1. The refactor reproduces `headroom` value for value, over the demo fixtures and hand-made
    //    shapes (flagship that does not match the primary, weekly only, all three equal, nothing).
    let hand: [AccountUsage] = [
        account(session: 80, weekly: 70, model: ("Fable", 10)),
        account(session: 20, weekly: 70, model: ("Opus", 60)),
        account(weekly: 40),
        account(session: 33),
        account(session: 55, weekly: 55, model: ("Opus", 55)),
        account(session: 0, weekly: 90, model: ("Sonnet", 0)),
        account(),
    ]
    let fixtures = DemoUsage.accounts()
    check("the demo fixtures are there to compare", fixtures.count >= 5)
    let primaries: [String?] = [nil, "opus", "fable", "sonnet", "OPUS", "claude-opus-4"]
    var compared = 0, mismatches = 0
    for usage in fixtures + hand {
        for primary in primaries {
            compared += 1
            let now = LaunchPolicyStore.headroom(usage, primaryModel: primary)
            if now != legacyHeadroom(usage, primaryModel: primary) { mismatches += 1 }
            if now != LaunchPolicyStore.bindingWindow(usage, primaryModel: primary)?.remainingPercent {
                mismatches += 1
            }
        }
    }
    check("headroom is unchanged and is the binding window's remaining, over \(compared) pairs",
          compared == (fixtures.count + hand.count) * primaries.count && compared > 60
          && mismatches == 0)

    // 2. KNOWN BEHAVIOUR, pinned: a flagship window only binds when the primary model is that tier.
    //    Primary opus with a window named Fable and 5% left: the account binds on weekly, not on it.
    let drainedFable = account(session: 80, weekly: 70, model: ("Fable", 5))
    check("primary opus, Fable window drained: the binding window is not the flagship",
          LaunchPolicyStore.bindingWindow(drainedFable, primaryModel: "opus")?.kind == .weeklyAll)
    check("and the headroom is the weekly one, not the drained flagship",
          LaunchPolicyStore.headroom(drainedFable, primaryModel: "opus") == 70)
    check("premise guard: primary fable makes that same window bind",
          LaunchPolicyStore.bindingWindow(drainedFable, primaryModel: "fable")?.kind == .weeklyModel)
    check("no declared primary counts the flagship too",
          LaunchPolicyStore.bindingWindow(drainedFable)?.kind == .weeklyModel)

    // 3. Ties and gaps.
    check("three equal windows: the 5h one is named",
          LaunchPolicyStore.bindingWindow(account(session: 55, weekly: 55, model: ("Opus", 55)))?.id == "session")
    check("a plan with only a weekly window binds on it",
          LaunchPolicyStore.bindingWindow(account(weekly: 40))?.kind == .weeklyAll)
    check("an account with no window has no binding window",
          LaunchPolicyStore.bindingWindow(account()) == nil)

    // 4. The flag: case-insensitive, unknown is nil, and a build without DEBUG never reads it.
    check("ledger parses", UsageLayout.parse("ledger") == .ledger)
    check("tray parses", UsageLayout.parse("tray") == .tray)
    check("upper case parses", UsageLayout.parse("LEDGER") == .ledger && UsageLayout.parse("Tray") == .tray)
    check("absent, empty and unknown values are the default layout",
          UsageLayout.parse(nil) == nil && UsageLayout.parse("") == nil
          && UsageLayout.parse("no") == nil && UsageLayout.parse("orbit") == nil)
    check("this (non-DEBUG) build answers nil without a flag", UsageLayout.active == nil)

    // 6. Ledger pools (B-3461). The unknown-plan row draws its OWN pool, never another plan's.
    let now = Date()
    func at(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }
    let fleet = [account(weekly: 70, id: "m1", plan: "Max 20x", weeklyReset: at(10)),
                 account(weekly: 60, id: "m2", plan: "Max 20x", weeklyReset: at(11)),
                 account(weekly: 30, id: "p1", plan: "Pro", weeklyReset: at(12)),
                 account(weekly: 90, id: "u1", plan: nil, weeklyReset: at(5))]
    let split = FleetMath.summaries(accounts: fleet, now: now, byPlan: true) { $0.accountLabel }
    let unknown = UsageLayout.poolSummary(split, providerID: "claude", tier: FleetSummary.Tier(name: nil))
    let unknownWeek = unknown?.pools.first { $0.kind == .weeklyAll }
    check("the unknown-plan row reads its own pool: 90% left", unknownWeek?.averageRemaining == 90)
    check("and its own refill, not the Max plan's",
          unknownWeek?.refills.first?.at == at(5) && unknown?.accountCount == 1)
    check("a named plan row reads that plan's pool",
          UsageLayout.poolSummary(split, providerID: "claude", tier: FleetSummary.Tier(name: "Pro"))?
              .pools.first?.averageRemaining == 30)
    check("a split provider has no whole-provider pool for its heading",
          UsageLayout.poolSummary(split, providerID: "claude", tier: nil) == nil)
    let noReading = Array(fleet.dropLast()) + [account(id: "u2", plan: nil)]
    let noReadingSplit = FleetMath.summaries(accounts: noReading, now: now, byPlan: true) { $0.accountLabel }
    check("an unknown-plan account with no reading has no pool (the row says No reading)",
          UsageLayout.poolSummary(noReadingSplit, providerID: "claude", tier: FleetSummary.Tier(name: nil)) == nil
          && UsageLayout.poolSummary(noReadingSplit, providerID: "claude", tier: FleetSummary.Tier(name: "Pro")) != nil)
    let oneNamed = [fleet[0], fleet[1], fleet[3]]
    let oneNamedSummaries = FleetMath.summaries(accounts: oneNamed, now: now, byPlan: true) { $0.accountLabel }
    check("one named plan plus an unknown one does not split: the layout agrees with FleetMath",
          FleetMath.planTiers(accounts: oneNamed).isEmpty
          && UsageLayout.poolSummary(oneNamedSummaries, providerID: "claude", tier: nil) != nil)
    let fableFleet = FleetMath.summaries(
        accounts: [account(session: 50, weekly: 70, model: ("Fable", 20), id: "f1"),
                   account(session: 40, weekly: 60, model: ("Fable", 30), id: "f2")],
        now: now) { $0.accountLabel }
    check("a flagship-focused pool is the flagship kind and is not named Week",
          fableFleet.first?.headline(focusedModel: "Fable")?.kind == .weeklyModel
          && UsageLayout.windowName(.weeklyModel) == L("Flagship")
          && UsageLayout.windowName(.weeklyModel) != L("Week")
          && UsageLayout.windowName(.weeklyAll) == L("Week")
          && UsageLayout.windowName(.session) == L("5h"))

    // 7. Widths: both layouts fit the narrowest region, from the very numbers the views use.
    check("premise: the narrowest region is the 356pt single card column", UsageLayout.regionWidth == 356)
    check("a ledger row fits the region", UsageLayout.Ledger.rowWidth <= UsageLayout.regionWidth
          && UsageLayout.Ledger.barWidth > 0)
    check("a tray row fits the region", UsageLayout.Tray.rowWidth <= UsageLayout.regionWidth
          && UsageLayout.Tray.columns >= 1)
}

// 5. Source locks for the files that cannot be compiled here.
func code(_ path: String) -> [String]? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
}
func has(_ lines: [String], _ pattern: String) -> Bool {
    lines.contains { $0.range(of: pattern, options: .regularExpression) != nil }
}

// The layouts take the tightest window and its colour from the one place; none may compute its own.
let ownMath = #"\.min\(|headroom\(|<\s*(20|50)\b|>=?\s*(20|50)\b|remainingPercent\s*\}"#
for path in ["Tally/Views/UsageLayoutParts.swift", "Tally/Views/UsageLedgerView.swift",
             "Tally/Views/UsageTrayView.swift"] {
    guard let lines = code(path) else {
        print("SKIP \(path) is not written yet"); continue
    }
    check("\(path) takes no minimum and spells no threshold of its own", !has(lines, ownMath))
}
if let lines = code("Tally/Views/UsageLayoutParts.swift") {
    check("the bar colour comes from MetricSeverity.fromUsedPercent",
          has(lines, #"MetricSeverity\.fromUsedPercent\("#))
}
if let lines = code("Tally/Views/AccountFacts.swift") {
    check("AccountFacts.bindingWindow asks the pick gate's own function",
          has(lines, #"LaunchPolicyStore\.bindingWindow\("#)
          && has(lines, #"MetricSeverity\.fromUsedPercent\("#))
}
if let lines = code("Tally/Stores/LaunchPolicyScoring.swift") {
    check("headroom is one call to bindingWindow",
          has(lines, #"bindingWindow\(usage, primaryModel: primaryModel\)\?\.remainingPercent"#))
}
if let lines = code("Tally/Core/UsageLayout.swift") {
    check("the flag is only read under #if DEBUG, with nil in the other branch",
          has(lines, #"^\s*#if DEBUG"#) && has(lines, #"^\s*#else"#)
          && has(lines, #"static let active: UsageLayout\? = nil"#))
}
// B-3461: the ledger and tray views take their pools, window names and widths from the layout maths.
if let lines = code("Tally/Views/UsageLedgerView.swift") {
    check("the ledger no longer lets a nil plan match any plan", !has(lines, #"plan == nil \|\|"#))
    check("the ledger never prints the week for a pool of another window", !has(lines, #"Text\(L\("Week"\)\)"#))
    check("the ledger picks its pool through poolSummary and names it by its kind",
          has(lines, #"UsageLayout\.poolSummary\("#) && has(lines, #"UsageLayout\.windowName\(pool\.kind\)"#))
    check("the ledger splits by plan on FleetMath's own rule", has(lines, #"FleetMath\.planTiers\("#))
    check("the ledger's pool bar has no width of its own", !has(lines, #"width: 120"#))
}
if let lines = code("Tally/Views/UsageLayoutParts.swift") {
    check("the column names come from windowName", has(lines, #"UsageLayout\.windowName"#))
}
if let lines = code("Tally/Views/UsageTrayView.swift") {
    check("the tray seats its tiles by UsageLayout.Tray.columns, not a fixed count",
          !has(lines, #"columns: [0-9]"#) && has(lines, #"UsageLayout\.Tray\.columns"#))
}

// The flag's spelling stays in the one reader and the launch-flag list.
var spellers: [String] = []
if let walker = FileManager.default.enumerator(atPath: "Tally") {
    for case let rel as String in walker where rel.hasSuffix(".swift") {
        if let text = try? String(contentsOfFile: "Tally/" + rel, encoding: .utf8),
           text.contains("\"TallyUsageLayout\"") { spellers.append(rel) }
    }
}
check("only UsageLayout and CaptureLaunch spell the flag", Set(spellers) == ["Core/UsageLayout.swift", "Core/CaptureLaunch.swift"])

// The four wiring sites: each asks `UsageLayout.active` a counted number of times, so a fifth,
// unreviewed branch (or a dropped guard) changes the count and fails here. The default branch of the
// account grid is a separate property the switch's `case nil` returns, left as it was.
let wiring: [(String, Int)] = [("Tally/Views/PopoverCardGrid.swift", 1),
                               ("Tally/Views/ProviderSectionHeader.swift", 1),
                               ("Tally/Views/PopoverHeaderView.swift", 2),
                               ("Tally/Views/PopoverFooterView.swift", 1)]
for (path, expected) in wiring {
    let n = (code(path) ?? []).filter { $0.contains("UsageLayout.active") }.count
    check("\(path) asks UsageLayout.active \(expected) time(s)", n == expected)
}
if let lines = code("Tally/Views/PopoverCardGrid.swift") {
    check("the grid's nil case returns the untouched default layout",
          has(lines, #"case nil: defaultAccountLayout"#))
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
