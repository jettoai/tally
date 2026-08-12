import Foundation

// Assertion harness for the menu-bar strip's two layouts (Tally/Core/MenuBarSegments.swift),
// compiled with the fleet math it pools through. What is checked here is the thing a screenshot
// cannot: that the pooled layout's numbers ARE the panel gauge's numbers, over the same members.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let now = Date(timeIntervalSince1970: 1_800_000_000)

func metric(_ kind: MetricKind, used: Double, label: String? = nil, model: String? = nil,
            resetIn: TimeInterval? = nil) -> UsageMetric {
    let name = label ?? (kind == .session ? "Session" : kind == .weeklyAll ? "Weekly" : (model ?? "Model"))
    return UsageMetric(id: "\(kind.rawValue):\(name)", kind: kind, label: name, modelName: model,
                       usedPercent: used, severity: .normal,
                       resetsAt: resetIn.map { now.addingTimeInterval($0) }, isActive: false)
}

func account(_ id: String, provider: String = "claude", metrics: [UsageMetric],
             error: String? = nil, stale: Bool = false) -> AccountUsage {
    AccountUsage(id: id, providerID: provider, accountLabel: id, planName: nil,
                 metrics: metrics, refreshedAt: now, error: error, isStale: stale)
}

/// The app's own resolver, wired the way `UsageStore.focusedModel` wires it: no declared primary
/// model, so the flagship window leads.
func flagshipFocus(_ providerID: String, _ available: [String]) -> String? {
    FleetFocus.focusedModel(.all, primaryModel: nil, available: available,
                            flagshipOrder: ["fable", "opus"])
}

/// No model focus at all - the account-wide weekly leads (the `weekly` gauge focus).
func weeklyFocus(_ providerID: String, _ available: [String]) -> String? { nil }

func panelSummaries(_ accounts: [AccountUsage]) -> [FleetSummary] {
    FleetMath.summaries(accounts: accounts, now: now) { $0.accountLabel }
}

func stripSummaries(_ accounts: [AccountUsage]) -> [FleetSummary] {
    FleetMath.summaries(accounts: accounts, now: now, minMembers: 1) { $0.accountLabel }
}

func pooled(_ accounts: [AccountUsage], mode: DisplayMode = .remaining,
            focus: @escaping (String, [String]) -> String? = flagshipFocus) -> [MenuBarSegment] {
    MenuBarSegments.pooled(accounts, summaries: stripSummaries(accounts), mode: mode,
                           focusedModel: focus)
}

func perAccount(_ accounts: [AccountUsage], mode: DisplayMode = .remaining,
                focus: @escaping (String, [String]) -> String? = flagshipFocus) -> [MenuBarSegment] {
    MenuBarSegments.perAccount(accounts, mode: mode, focusedModel: focus)
}

/// Two Claude accounts and one Codex, the shape the pooled strip exists for.
let fleet: [AccountUsage] = [
    account("c1", metrics: [metric(.session, used: 20), metric(.weeklyAll, used: 40),
                            metric(.weeklyModel, used: 90, model: "Fable")]),
    account("c2", metrics: [metric(.session, used: 60), metric(.weeklyAll, used: 60),
                            metric(.weeklyModel, used: 70, model: "Fable")]),
    account("x1", provider: "codex", metrics: [metric(.session, used: 25),
                                               metric(.weeklyAll, used: 45)]),
]

// 1. One segment per provider, in the accounts' display order - not one per account.
do {
    let segments = pooled(fleet)
    expect(segments.count == 2, "pooled: one segment per provider")
    expect(segments.map(\.providerID) == ["claude", "codex"],
           "pooled: providers keep the accounts' display order")
    expect(perAccount(fleet).count == 3, "per-account: still one segment per account")
}

// 2. The numbers ARE the pool's, both lines: session (5h) on top, the focused weekly below.
// Claude sessions 80% and 40% left → 60; Fable windows 10% and 30% left → 20.
do {
    let claude = pooled(fleet)[0]
    expect(claude.lines == ["60%", "20%"], "pooled: session pool over the focused model pool")
    let pools = MenuBarSegments.pools(stripSummaries(fleet)[0], focusedModel: flagshipFocus)
    expect(pools.map { "\(Int($0.averageRemaining.rounded()))%" } == claude.lines,
           "pooled: the printed lines are the pools' own averages")
}

// 3. Used mode is the complement of the same average - one arithmetic, not a second one that
// could round the other way.
do {
    expect(pooled(fleet, mode: .used)[0].lines == ["40%", "80%"],
           "pooled: Used shows 100 - the pool average")
    expect(pooled(fleet, mode: .remaining)[0].lines == ["60%", "20%"],
           "pooled: Left shows the pool average")
}

// 4. THE SAME-SOURCE INVARIANT. Every pool the panel's gauge draws (minMembers 2) comes back from
// the strip's pass (minMembers 1) identical, member for member - so the two surfaces cannot print
// different numbers for one window.
do {
    let panel = panelSummaries(fleet)
    let strip = stripSummaries(fleet)
    let stripByProvider = Dictionary(strip.map { ($0.providerID, $0) },
                                     uniquingKeysWith: { first, _ in first })
    var matched = 0
    for summary in panel {
        guard let mirror = stripByProvider[summary.providerID] else {
            expect(false, "pooled: the strip has a summary for every gauged provider"); continue
        }
        for pool in summary.pools {
            guard let same = mirror.pools.first(where: {
                $0.kind == pool.kind && $0.modelName == pool.modelName
            }) else {
                expect(false, "pooled: the strip carries \(pool.kind) too"); continue
            }
            expect(same == pool, "pooled: \(pool.kind.rawValue) pool identical to the gauge's")
            matched += 1
        }
    }
    expect(matched == 3, "pooled: all three Claude pools were compared, none skipped")
    // …and the strip's extra pools are only the ones the gauge declines to draw: pools of one.
    let extra = strip.flatMap { summary in
        summary.pools.filter { pool in
            !(panel.first { $0.providerID == summary.providerID }?.pools.contains(pool) ?? false)
        }
    }
    expect(extra.allSatisfy { $0.members.count == 1 },
           "pooled: what the strip adds are pools of one, nothing else")
}

// 5. A single-account provider is a pool of one, and reads exactly like its own account segment -
// the whole reason the strip's pass asks for minMembers 1.
do {
    let segments = pooled(fleet)
    expect(segments[1].lines == ["75%", "55%"], "pooled: a lone account shows its own numbers")
    expect(segments[1].lines == perAccount(fleet)[2].lines,
           "pooled: and they are the numbers its per-account segment shows")
}

// 6. The badge counts members when there are several, and says nothing when there is one.
do {
    let segments = pooled(fleet)
    expect(segments[0].badge == 2, "pooled: the badge is the fleet size")
    expect(segments[1].badge == nil, "pooled: a lone account gets no badge")
    // Per-account keeps its own reading of that one slot: a 1-based index among siblings.
    expect(perAccount(fleet).map(\.badge) == [1, 2, nil],
           "per-account: the badge is still the account's number")
}

// 7. The weekly line follows the gauge focus, like the per-account layout does: the flagship model
// pool when one resolves, the account-wide weekly when none does.
do {
    expect(pooled(fleet, focus: weeklyFocus)[0].lines == ["60%", "50%"],
           "pooled: no model focus leads with the account-wide weekly pool")
    expect(perAccount(fleet, focus: weeklyFocus)[0].lines == ["80%", "60%"],
           "per-account: unchanged by the same switch")
}

// 8. A model window only one sibling reports still pools (as one) rather than vanishing from the
// strip - the gauge leaves it out, but the strip has nothing else to lead that provider with.
do {
    let mixed = [
        account("c1", metrics: [metric(.session, used: 20), metric(.weeklyAll, used: 40),
                                metric(.weeklyModel, used: 90, model: "Fable")]),
        account("c2", metrics: [metric(.session, used: 60), metric(.weeklyAll, used: 60)]),
    ]
    expect(panelSummaries(mixed)[0].pools.contains { $0.kind == .weeklyModel } == false,
           "the gauge does not draw a Fable pool only one account has")
    expect(pooled(mixed)[0].lines == ["60%", "10%"],
           "pooled: the strip leads with that account's Fable window rather than nothing")
}

// 9. Errors and empty data read the way a lone account's segment reads them.
do {
    let dead = [account("c1", metrics: [], error: "boom"),
                account("c2", metrics: [], error: "boom")]
    let segments = pooled(dead)
    expect(segments.count == 1 && segments[0].lines == ["!"],
           "pooled: a provider whose accounts all failed shows the error mark")
    expect(segments[0].badge == 2, "pooled: …and still says how many accounts it stands for")
    let empty = [account("c1", metrics: []), account("c2", metrics: [])]
    expect(pooled(empty)[0].lines == ["—"], "pooled: nothing reported reads as no data")
}

// 10. Stale members dim the whole segment: their last-good numbers are inside the average, and a
// bright segment would claim the pooled figure is fresh.
do {
    let partly = [
        account("c1", metrics: [metric(.weeklyAll, used: 40)], error: "boom", stale: true),
        account("c2", metrics: [metric(.weeklyAll, used: 60)]),
    ]
    let segment = pooled(partly)[0]
    expect(segment.dimmed, "pooled: one stale member dims the segment")
    expect(segment.lines == ["50%"], "pooled: and the stale account still counts toward the pool")
    expect(perAccount(partly).map(\.dimmed) == [true, false],
           "per-account: dimming stays per account")
}

// 11. AN ACCOUNT MISSING FROM THE POOL STAYS VISIBLE. One that failed its first fetch has no
// last-good numbers, so `FleetMath` never sees it and the average is over the survivors.
//
// This case used to assert the opposite and call it a contract - "the badge counts the accounts the
// gauge counts" - which made the hole invisible on every surface at once: the badge counted only
// the contributors and nothing dimmed, so two accounts with one dead read as ONE healthy account,
// while the same data in the per-account layout showed a "!" segment (codex review, 2026-08-12).
// The pool may be short; it may not look complete and fresh while it is.
do {
    let partial = [
        account("c1", metrics: [metric(.weeklyAll, used: 40)]),
        account("c2", metrics: [metric(.weeklyAll, used: 60)]),
        account("c3", metrics: [], error: "boom"),
    ]
    let segment = pooled(partial)[0]
    expect(segment.badge == 3, "pooled: the badge counts every account the segment stands for")
    expect(segment.dimmed, "pooled: a member missing from the pool dims the segment")
    expect(segment.lines == ["50%"], "pooled: an account with no numbers is not averaged in")
    // The two-account fleet is the case that vanished completely: a badge of 1 is no badge at all.
    let pair = [account("c1", metrics: [metric(.weeklyAll, used: 40)]),
                account("c2", metrics: [], error: "boom")]
    let short = pooled(pair)[0]
    expect(short.badge == 2, "pooled: two accounts with one dead still read as two")
    expect(short.dimmed, "pooled: …dimmed, because the figure is one account's, not two")
    expect(short.lines == ["60%"], "pooled: …over the one account that reported")
    // What the hover is told, decided here so the two surfaces cannot disagree about who is out.
    expect(MenuBarSegments.missingFromPool(pair).map(\.label) == ["c2"]
           && MenuBarSegments.missingFromPool(pair).map(\.reason) == ["boom"],
           "pooled: the hover gets who is missing and why")
    expect(MenuBarSegments.missingFromPool(partial).count == 1,
           "pooled: …counted, not just flagged")
    expect(MenuBarSegments.missingFromPool([account("c1", metrics: [metric(.weeklyAll, used: 40)]),
                                            account("c2", metrics: [metric(.weeklyAll, used: 60)])])
            .isEmpty,
           "pooled: a whole fleet has nothing missing to report")
    // A STALE member is not missing - its last-good numbers are in the average, and the hover
    // already has a word for that state ("Outdated"). Reporting it as failed would double-count it.
    expect(MenuBarSegments.missingFromPool([
        account("c1", metrics: [metric(.weeklyAll, used: 40)], error: "boom", stale: true),
        account("c2", metrics: [metric(.weeklyAll, used: 60)])]).isEmpty,
           "pooled: a stale member is outdated, not missing")
}

// 11b. EVERY MISSING MEMBER BY NAME, WITH ITS OWN REASON. One count carrying the first account's
// error said one diagnosis for all of them and identified none of them - "2 failed: Login expired"
// when one is signed out and the other never had the CLI installed (codex review of 266c427).
do {
    let mixed = [
        account("c1", metrics: [metric(.weeklyAll, used: 40)]),
        account("c2", metrics: [], error: "Login expired"),
        account("c3", metrics: [], error: "Claude CLI not found"),
    ]
    let missing = MenuBarSegments.missingFromPool(mixed)
    expect(missing.map(\.label) == ["c2", "c3"], "pooled: both missing members are named")
    expect(missing.map(\.reason) == ["Login expired", "Claude CLI not found"],
           "pooled: …each with its own reason, not the first one twice")
    expect(missing.count == 2, "pooled: and the count is still the count")
    // The order is the members' own display order, so the hover reads down the fleet the way the
    // rest of the app lists it.
    expect(MenuBarSegments.missingFromPool([mixed[2], mixed[1]]).map(\.label) == ["c3", "c2"],
           "pooled: named in the order the accounts are listed")
    // The label the user reads everywhere else, not the provider's raw one: the hover takes a
    // renamer, the way FleetMath.summaries does.
    expect(MenuBarSegments.missingFromPool(mixed) { "renamed-\($0.id)" }.map(\.label)
            == ["renamed-c2", "renamed-c3"],
           "pooled: renames reach the hover")
    // THE SENTENCE ITSELF, which is what a reader actually sees. Pure so it can be asserted here;
    // the count and the wrapper around it are the view's, because they are localized.
    expect(MenuBarSegments.missingDetail(missing, noData: "No usage data")
            == "c2 (Login expired), c3 (Claude CLI not found)",
           "pooled: the hover's wording names each account with its own reason")
    expect(MenuBarSegments.missingDetail([], noData: "No usage data") == "",
           "pooled: nothing missing is nothing said")
}

// 11c. THE MEMBERSHIP TEST IS THE POOL'S OWN (`metrics.isEmpty`), not a proxy for it. An account
// that reported nothing WITHOUT failing contributes nothing to the average, exactly like a failed
// one, and the old "has an error and is not stale" test called it present - the mirror of the hole
// case 11 closes. Its reason is nil: it never said why, and the wording for that is the view's.
do {
    let silent = [
        account("c1", metrics: [metric(.weeklyAll, used: 40)]),
        account("c2", metrics: []),
    ]
    let missing = MenuBarSegments.missingFromPool(silent)
    expect(missing.map(\.label) == ["c2"], "pooled: an account with no metrics is missing")
    expect(missing.first?.reason == nil, "pooled: …with no reason of its own to give")
    expect(MenuBarSegments.missingDetail(missing, noData: "No usage data")
            == "c2 (No usage data)",
           "pooled: and the view's own wording fills that gap")
    // FleetMath agrees, which is the whole point of asking its question rather than a proxy: the
    // pool really is over one member here.
    let pool = stripSummaries(silent).first?.pools.first { $0.kind == .weeklyAll }
    expect(pool?.members.count == 1, "pooled: FleetMath left that account out too")
    expect(pooled(silent)[0].dimmed, "pooled: so the segment cannot look complete")
    expect(pooled(silent)[0].lines == ["60%"], "pooled: over the one account that reported")
}

// 11d. "!" IS THE ERROR MARK, and stays keyed on errors now that membership is a separate question.
// A provider with no pool at all whose accounts merely reported nothing has failed at nothing.
do {
    let allFailed = [account("c1", metrics: [], error: "boom"),
                     account("c2", metrics: [], error: "boom")]
    expect(pooled(allFailed)[0].lines == ["!"], "pooled: every account failing is the error mark")
    let allSilent = [account("c1", metrics: []), account("c2", metrics: [])]
    expect(pooled(allSilent)[0].lines == ["—"], "pooled: reporting nothing is no data, not an error")
    // Mixed: one failed, one silent. Neither reading is "everything failed", so it is no data.
    expect(pooled([account("c1", metrics: [], error: "boom"), account("c2", metrics: [])])[0].lines
            == ["—"],
           "pooled: a partial failure with no pool does not claim the whole provider failed")
}

/// A provider whose accounts all report the same two windows: the ordinary fleet, and the control
/// for every gap assertion below.
let whole = [
    account("c1", metrics: [metric(.session, used: 60), metric(.weeklyAll, used: 20)]),
    account("c2", metrics: [metric(.session, used: 40), metric(.weeklyAll, used: 40)]),
]
let wholeDrawn = MenuBarSegments.pools(stripSummaries(whole)[0], focusedModel: flagshipFocus)

// 11e. A MEMBER THAT REPORTED SOME WINDOWS, WHICH THE ACCOUNT-LEVEL RULE CANNOT SEE. A provider
// mapper builds metrics per line of the response, so an account can carry a session window and no
// weekly one. `FleetMath` then pools each kind over whoever reported it: the session pool has both
// accounts and the weekly pool legitimately has one, while the badge says two and nothing dimmed -
// the second row drew ONE account's number under a mark claiming to stand for both (codex review of
// 6cd0bde; its probe measured `missing=0 dimmed=false badge=2 lines=["50%","80%"]`).
do {
    let uneven = [
        account("c1", metrics: [metric(.session, used: 60), metric(.weeklyAll, used: 20)]),
        account("c2", metrics: [metric(.session, used: 40)]),
    ]
    let segment = pooled(uneven)[0]
    // The measured shape, asserted first so the case cannot quietly stop being this case.
    expect(segment.lines == ["50%", "80%"] && segment.badge == 2,
           "pooled: the session line pools both accounts, the weekly line only one")
    expect(MenuBarSegments.missingFromPool(uneven).isEmpty,
           "pooled: and the account-level rule has nothing to say - both accounts reported")
    // THE FIX: the second row is one account's figure under a badge that says two, so the segment
    // may not look complete.
    expect(segment.dimmed, "pooled: a member absent from one drawn pool dims the segment")
    // …and the hover says WHICH row is short and WHO is not in it.
    let drawn = MenuBarSegments.pools(stripSummaries(uneven)[0], focusedModel: flagshipFocus)
    let gaps = MenuBarSegments.windowGaps(uneven, pools: drawn)
    expect(gaps.map(\.window) == ["Weekly"] && gaps.map(\.label) == ["c2"],
           "pooled: the gap names the window and the account missing from it")
    expect(MenuBarSegments.windowGapDetail(gaps) { $0 } == "Weekly (c2)",
           "pooled: …and the hover's wording puts the window first")
    // The session pool covers everybody, so it contributes no gap: this is per POOL, not per
    // account, or every gap would name every row.
    expect(!gaps.contains { $0.window == "Session" },
           "pooled: the pool that does cover everybody is not reported")
    // Renames reach it, like every other name in the hover - through the labeller the POOLS were
    // built with, which is how the app wires it (`menuBarPools` and the hover share one).
    let renamedPools = MenuBarSegments.pools(
        FleetMath.summaries(accounts: uneven, now: now, minMembers: 1) { "renamed-\($0.id)" }[0],
        focusedModel: flagshipFocus)
    expect(MenuBarSegments.windowGaps(uneven, pools: renamedPools) { "renamed-\($0.id)" }
            .map(\.label) == ["renamed-c2"],
           "pooled: renames reach the gap note")
    // AND A LABELLER THAT DOES NOT MATCH THE POOLS CANNOT INVENT GAPS, which is the failure mode
    // that would dim every segment for anybody who has renamed an account: the count decides first,
    // so a pool covering everybody reports nothing whatever names arrive.
    expect(MenuBarSegments.windowGaps(whole, pools: wholeDrawn) { "mismatched-\($0.id)" }.isEmpty,
           "pooled: a full pool reports nothing even under a labeller it does not know")
}

// 11f. A WHOLE FLEET IS STILL A WHOLE FLEET. The rule above must not dim a segment whose pools all
// cover everybody, which is the ordinary case and the one a regression here would spoil for every
// user at once.
do {
    let drawn = wholeDrawn
    expect(MenuBarSegments.windowGaps(whole, pools: drawn).isEmpty,
           "pooled: every pool covering everybody is no gap at all")
    expect(!pooled(whole)[0].dimmed, "pooled: …and the segment stays bright")
    expect(MenuBarSegments.windowGapDetail([]) { $0 } == "",
           "pooled: no gaps is nothing said")
}

// 11g. THE TWO KINDS OF HOLE ARE SAID ONCE EACH. An account with NO metrics is `missingFromPool`'s
// to report; naming it again per window would print the same absence twice in one hover, once for
// every row the segment happens to draw.
do {
    let both = [
        account("c1", metrics: [metric(.session, used: 60), metric(.weeklyAll, used: 20)]),
        account("c2", metrics: [metric(.session, used: 40)]),
        account("c3", metrics: [], error: "Login expired"),
    ]
    let drawn = MenuBarSegments.pools(stripSummaries(both)[0], focusedModel: flagshipFocus)
    expect(MenuBarSegments.missingFromPool(both).map(\.label) == ["c3"],
           "pooled: the absent account is the account-level rule's")
    expect(MenuBarSegments.windowGaps(both, pools: drawn).map(\.label) == ["c2"],
           "pooled: …and the per-window rule names only the partial one")
    expect(pooled(both)[0].dimmed && pooled(both)[0].badge == 3,
           "pooled: the segment dims once and still stands for all three")
}

// 11h. A MODEL WINDOW ONLY ONE SIBLING REPORTS is the same shape one level down: case 8 above shows
// the strip leading with that account's Fable window, and this is what the segment now says about
// it - the row is one account's, and the hover names the other.
do {
    let mixed = [
        account("c1", metrics: [metric(.session, used: 20), metric(.weeklyAll, used: 40),
                                metric(.weeklyModel, used: 90, model: "Fable")]),
        account("c2", metrics: [metric(.session, used: 60), metric(.weeklyAll, used: 60)]),
    ]
    let drawn = MenuBarSegments.pools(stripSummaries(mixed)[0], focusedModel: flagshipFocus)
    let gaps = MenuBarSegments.windowGaps(mixed, pools: drawn)
    expect(gaps.map(\.window) == ["Fable"] && gaps.map(\.label) == ["c2"],
           "pooled: the model row names the sibling that has no such window")
    expect(pooled(mixed)[0].dimmed,
           "pooled: …and that segment is not the whole truth either")
}

// 12. Per-account regression: the error mark, and a stale account keeping its numbers.
do {
    let segments = perAccount([
        account("c1", metrics: [metric(.session, used: 20)], error: "boom"),
        account("c2", metrics: [metric(.session, used: 20)], error: "boom", stale: true),
    ])
    expect(segments[0].lines == ["!"] && !segments[0].dimmed, "per-account: a fresh error is a mark")
    expect(segments[1].lines == ["80%"] && segments[1].dimmed,
           "per-account: a stale account keeps its last-good numbers, dimmed")
}

// 13. THE LAYOUT THE STRIP STARTS IN, and the wiring of the hover, checked as text: neither the
// settings store (@MainActor, @Observable, UserDefaults) nor the tooltip (needs the store) compiles
// into this harness, and both rules are only worth having if they are really wired up - the same
// technique tests/accountrow uses on the same two kinds of file. Run from the repo root, which
// run-menubar-tests.sh guarantees; an unreadable file FAILS rather than quietly passing.
func readSource(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}
do {
    let settingsSource = readSource("Tally/Stores/SettingsStore.swift")
    expect(!settingsSource.isEmpty, "the settings store is readable from these checks")
    // POOLED IS WHAT AN UNSET PREFERENCE MEANS. The bar is glanced at to answer "how much is
    // left", and one figure per provider is that answer where N marks are its raw material.
    expect(settingsSource.contains("""
        menuBarLayout = MenuBarLayout(rawValue: defaults.string(forKey: "menuBarLayout") ?? "")
            ?? .pooled
"""),
           "the strip defaults to the pooled layout")
    // AND ONLY AN UNSET ONE. The flip moves everybody who never chose and nobody who did, which
    // holds exactly as long as this key is written from one place - the picker's own observer.
    // (Property observers do not run during init, so reading it above writes nothing.)
    expect(settingsSource.components(separatedBy: "forKey: \"menuBarLayout\"").count == 3,
           "the key is read in one place and written in one place, nowhere else")
    expect(settingsSource.contains("""
        didSet {
            UserDefaults.standard.set(menuBarLayout.rawValue, forKey: "menuBarLayout")
"""),
           "…and the one writer is the picker's own observer")
}
do {
    let hoverSource = readSource("Tally/Stores/UsageStorePresentation.swift")
    expect(!hoverSource.isEmpty, "the hover is readable from these checks")
    // The note is built from the two functions above rather than from a second reading of the
    // members, so who is out and how they are named cannot drift from what dims the segment.
    expect(hoverSource.contains("MenuBarSegments.missingDetail(missing, noData: L(\"No usage data\"))"),
           "the hover words the missing members through the rule that decides them")
    expect(hoverSource.contains("String(missing.count)"),
           "…and interpolates the count as a String, so the catalog key is not \"%lld …\"")
    // BOTH hover branches name the accounts: the no-pool branch had the same one-error-for-all
    // shape the note just lost, one line further down.
    expect(hoverSource.contains("Self.missingNamed(members)")
           && hoverSource.contains("Self.missingNote(members)"),
           "both branches of the hover ask who is missing")
    expect(!hoverSource.contains("members.compactMap(\\.error).first"),
           "…and neither of them stands one account's error in for the rest")
    // …through ONE resolution of the names, so a rename cannot reach one branch and not the other.
    expect(hoverSource.components(separatedBy: "MenuBarSegments.missingFromPool").count == 2,
           "…and both go through one place that resolves the labels")
    // THE SAME NAME THE POOLS WERE BUILT WITH, everywhere: `FleetPool.Member` records a label, so a
    // note labelling accounts differently from the pools it compares them against matches nobody.
    // Asserted as "one labeller, three uses" rather than per site, because the next reading someone
    // adds is the one that would quietly pass a second one.
    expect(hoverSource.components(separatedBy: "displayLabel(accountID:").count == 3,
           "the fleet readings name accounts through one labeller (the per-account hover has its own)")
    for site in ["FleetMath.summaries(accounts: orderedAccounts, minMembers: 1, label: Self.displayName)",
                 "MenuBarSegments.windowGaps(members, pools: pools, label: displayName)",
                 "MenuBarSegments.missingFromPool(members, label: displayName)"] {
        expect(hoverSource.contains(site), "…and it is the one passed to `\(site.prefix(34))…`")
    }
    // The gap note is wired to the pools the row actually draws, and localizes the WINDOW name.
    expect(hoverSource.contains("Self.windowGapNote(members, pools: drawn)")
           && hoverSource.contains("MenuBarSegments.windowGapDetail(gaps) { L($0) }"),
           "the hover says which drawn row is short, with the window name localized")
}

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("all menu-bar layout tests passed")
