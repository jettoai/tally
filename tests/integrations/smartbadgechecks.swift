import Foundation

// THE SMART-PICK BADGE'S ELIGIBILITY GATE, asserted on the value rather than on the source text.
//
// The badge exists to PREDICT THE LAUNCH: the panel marks the card `tally` would pick, and a badge
// that names a different account than the launcher takes is worse than no badge (2026-07-25, when
// the badge sat on a quarantined account and its reader concluded the picker was broken). So the
// app runs its own copy of the launcher's gate, and the copies must not drift.
//
// THE CONDITION THIS FILE EXISTS FOR is `lastRefreshFailed`, the half of that gate the app was
// missing (P2-15). `isStale` waits for a SECOND consecutive failure so the "Outdated" badge cannot
// flicker on the token rotation a one-minute poll reliably catches - which leaves a whole poll
// interval in which held-over numbers are published looking freshly fetched, and the badge was
// deciding eligibility on them. The launcher's own gate (`eligible`, TallyCLI/AccountPick.swift)
// asks the flag rather than the badge for exactly that reason.
//
// Asserted HERE rather than in the smartpick suite because this is the only suite that compiles the
// app's store; that one compiles the CLI and can only read this file as text.
@MainActor
func runSmartBadgeChecks() {
    let policy = LaunchPolicyStore.shared

    /// A Claude account with a session and a weekly window and NOTHING MODEL-SCOPED.
    ///
    /// No flagship window on purpose: the gate weighs one only when the declared primary model is
    /// that tier, and the primary comes from this machine's own `~/.tally/state.json` (the store is
    /// a singleton reading the real file). A fixture that depended on it would pass or fail by
    /// whichever model the person running these checks happens to launch on.
    func account(_ id: String, session: Double, weekly: Double, weeklyResetDays: Double = 3,
                 failed: Bool = false, stale: Bool = false,
                 error: String? = nil) -> AccountUsage {
        let now = Date()
        var usage = AccountUsage(
            id: id, providerID: "claude", accountLabel: id, planName: "Max 20x",
            accountEmail: nil,
            metrics: [
                UsageMetric(id: "session", kind: .session, label: "Session", modelName: nil,
                            usedPercent: 100 - session, severity: .normal,
                            resetsAt: now.addingTimeInterval(3 * 3600), isActive: false),
                UsageMetric(id: "weekly_all", kind: .weeklyAll, label: "Weekly", modelName: nil,
                            usedPercent: 100 - weekly, severity: .normal,
                            resetsAt: now.addingTimeInterval(weeklyResetDays * 86_400),
                            isActive: false),
            ],
            refreshedAt: now)
        usage.error = error
        usage.isStale = stale
        usage.lastRefreshFailed = failed
        return usage
    }

    // Live session counts go in directly (`occupancy`): every account below is empty unless a cell
    // says otherwise, and nil is the app before its first background read.
    func pick(_ accounts: [AccountUsage], reserves: [String: Double] = [:],
              occupancy: [String: Int]? = [:]) -> String? {
        policy.autoPickID(providerID: "claude", accounts: accounts,
                          launchable: Set(accounts.map(\.id)), reserves: reserves,
                          occupancy: occupancy)
    }

    let healthy = account("healthy", session: 40, weekly: 40)
    // The premise every check below rests on: with nothing wrong, the richer account wins outright.
    let rich = account("rich", session: 95, weekly: 95)
    check("the badge picks the account with the most room (guard the premise)",
          pick([healthy, rich]) == "rich")

    // THE ONE THIS FILE IS ABOUT. Same numbers, same everything, except that the richer account's
    // latest poll failed - so those 95s are last-good figures nobody has confirmed, and the badge
    // must not send a launch at them.
    var heldOver = rich
    heldOver.lastRefreshFailed = true
    check("an account whose latest poll failed is not the badge's pick",
          pick([healthy, heldOver]) == "healthy")
    // …and the other two exclusions it stands beside, so the flag is not carrying the whole gate on
    // its own in these checks.
    var outdated = rich
    outdated.isStale = true
    check("…nor is one the debounce has already called outdated", pick([healthy, outdated]) == "healthy")
    var errored = rich
    errored.error = "no credentials"
    check("…nor is one that came back with an error", pick([healthy, errored]) == "healthy")

    // AND WHEN IT EMPTIES THE FIELD, NO CARD IS MARKED - which is not the badge giving up, it is the
    // badge still predicting: `tally` with nothing eligible does not steer at all, it warns "no
    // eligible claude account" and launches bare on the default home (TallyCLI/main.swift). A card
    // marked in that state would promise a steer that is not going to happen.
    //
    // The quarantine step's own fallback is deliberately not this: an account held out by a cap
    // record is still one the launcher would fall back to (`launchPick` retries without the
    // exclusions), while a reading nobody confirmed does not become confirmed for want of a rival.
    check("a fleet where every poll failed marks nobody, exactly as no launch is steered",
          pick([heldOver]) == nil)

    // WHICH BARS DRAW THE WATER LINE, asked of the app's own translation of the ruling rather than
    // of its source text (`PersonalAccount.reserved`, the reading both meters take per bar). The
    // scope is settled once in Tally/Core/AccountReserve.swift and covers the three windows the
    // account shares with its owner's browser: the weekly all-models one, the 5h session one and
    // the flagship model's. A hatch outside that scope would be a line nothing enforces, and the bar
    // is the only place a person ever sees what the number does.
    //
    // THE FIXTURE CARRIES A FLAGSHIP WINDOW AND A SECOND TIER, because a kind alone cannot tell
    // them apart and the first version of this check asked one (codex review, 2026-09-05): "Show
    // every model tier" puts the account's other model windows on the card and in the row, they are
    // the same `.weeklyModel` kind as the flagship one, and the launcher never sees them - the
    // snapshot publishes exactly ONE model window per account, the headline one. A line on the
    // second tier would tell its owner that quota is protected when no pick protects it.
    let twoTier = AccountUsage(
        id: "two-tier", providerID: "claude", accountLabel: "two-tier", planName: "Max 20x",
        accountEmail: nil,
        metrics: [
            UsageMetric(id: "session", kind: .session, label: "Session", modelName: nil,
                        usedPercent: 20, severity: .normal, resetsAt: nil, isActive: false),
            UsageMetric(id: "weekly_all", kind: .weeklyAll, label: "Weekly", modelName: nil,
                        usedPercent: 20, severity: .normal, resetsAt: nil, isActive: false),
            UsageMetric(id: "weekly_fable", kind: .weeklyModel, label: "Fable", modelName: "fable",
                        usedPercent: 20, severity: .normal, resetsAt: nil, isActive: true),
            UsageMetric(id: "weekly_opus", kind: .weeklyModel, label: "Opus", modelName: "opus",
                        usedPercent: 20, severity: .normal, resetsAt: nil, isActive: false),
        ],
        refreshedAt: Date())
    /// Exactly the expression the list row's bar takes (`AccountListRowView.barReserve`), so this
    /// asserts the composition both meters perform and not just the rule underneath it.
    func hatches(_ metric: UsageMetric) -> Bool {
        PersonalAccount.reserved(metric.kind, isHeadline: metric.id == twoTier.headline?.id)
    }
    check("the fixture's headline IS the flagship model window (guard the premise)",
          twoTier.headline?.id == "weekly_fable"
              && twoTier.metrics.filter(\.isModelScoped).count == 2)
    check("the flagship bar draws the water line, along with the weekly and 5h ones",
          hatches(twoTier.metrics[2]) && hatches(twoTier.metrics[0]) && hatches(twoTier.metrics[1]))
    check("…while the second model tier beside it draws none",
          !hatches(twoTier.metrics[3]))
    check("…and a kind the launcher rates nothing on draws none",
          !PersonalAccount.reserved(.other, isHeadline: false)
              && !PersonalAccount.reserved(.other, isHeadline: true))

    // MARK: - The personal account's reserve, on the same terms the launcher ranks by
    //
    // The badge predicts the launch, and the launcher ranks on what it may SPEND of each account
    // (`ratedWindows`, TallyCLI/AccountPick.swift, asserted end to end in tests/smartpick). A badge
    // that ranked on the raw percentage would sit on the personal account right up until it crossed
    // the line - so the water line on the card and the badge above it would be telling the reader
    // two different things about the same account.

    let personal = account("personal", session: 90, weekly: 90)
    let sibling = account("sibling", session: 70, weekly: 70)
    // LISTED FIRST, so it is the incumbent leader and the sibling has to clear both hysteresis
    // gates to take the badge off it - the same push the launcher demands.
    let field = [personal, sibling]
    check("without a reserve the badge sits on the fuller account (guard the premise)",
          pick(field) == "personal")
    check("a fleet nobody marked ranks exactly as it did before the feature",
          pick(field, reserves: ["personal": 0]) == "personal")
    // THE ONE THIS SECTION IS ABOUT: 90% with 30 points held back is 60 points Tally may spend,
    // which is thinner than the sibling's whole 70 - and the badge has to follow the second reading.
    check("a reserve moves the badge onto the sibling the launch would spend instead",
          pick(field, reserves: ["personal": 30]) == "sibling")
    check("…and a reserve small enough to leave it the fuller account does not",
          pick(field, reserves: ["personal": 5]) == "personal")

    // B-1213 (2026-10-07): personal at 7% of its week with 10 held back, listed first, beside a
    // sibling that still has quota but is thin itself. Neither is comfortable, so the field stays
    // whole, and the personal account's slightly negative rate used to hold the badge through the
    // hysteresis gates. Anybody above their line leaves the ones under it out of the field.
    let thinField = [account("personal", session: 90, weekly: 7, weeklyResetDays: 6.7),
                     account("sibling", session: 90, weekly: 4, weeklyResetDays: 6.7)]
    check("the badge leaves a personal account under its line while a sibling has quota",
          pick(thinField, reserves: ["personal": 10]) == "sibling")
    check("…and sits on it on the same field with no reserve (guard the premise)",
          pick(thinField) == "personal")

    // NO BADGE WHEN EVERY LAUNCHABLE ACCOUNT IS UNDER ITS LINE (B-1213, 2026-10-07): the launcher
    // refuses that launch and says when the first account is back, so a badge on any card would be
    // predicting a launch that will not happen.
    //
    // The fixture is the real shape of that situation, for the reason the CLI suite states: an
    // account with no reserve is under its own line only when it is empty, and an empty account is
    // not eligible at all. So the field empties exactly when every account still launchable
    // carries a reserve - here, beside a sibling that is genuinely spent.
    let underWater = account("personal", session: 90, weekly: 20)
    let drought = [underWater, account("spent", session: 0, weekly: 0)]
    check("a fleet under its own water lines marks no card",
          pick(drought, reserves: ["personal": 30]) == nil)
    check("…while the same fleet with no reserve marks the personal card (guard the premise)",
          pick(drought) == "personal")
    // Two accounts under a line at once takes a hand-edited document - the stepper only marks one -
    // and both under their lines is still nobody to launch on.
    let doubleMarked = [account("marked", session: 90, weekly: 36),
                        account("marked2", session: 90, weekly: 40.5)]
    check("…and neither does a fleet where every card is under its own line",
          pick(doubleMarked, reserves: ["marked": 60, "marked2": 60]) == nil)
    check("…which with no reserve ranks as it always did (guard the premise)",
          pick(doubleMarked) == "marked")

    // AND THE LINE IS DRAWN ON EVERY WINDOW THE BROWSER SHARES, here as in the launcher (Albert's
    // ruling, 2026-09-05, which widened it to the flagship window; Tally/Core/AccountReserve.swift).
    // This fixture carries no flagship window of its own, for the reason the account builder at the
    // top of this file gives, so what is asserted here is the 5h half: claude.ai and the CLI draw on
    // ONE 5h window, so a badge that stayed on an account whose session share was gone would be
    // predicting a launch the CLI no longer makes - the drift this whole file exists to catch.
    // THE FIXTURE DISCRIMINATES ON THE 5H WINDOW ALONE: 95% of the week less 30 points is still
    // fuller than the sibling's 60, so the week leaves the badge where it is, and the session at 20%
    // less 30 points (-3.3 %/h, which loses to anything) is the only thing that can move it.
    let sessionField = [account("personal", session: 20, weekly: 95),
                        account("sibling", session: 70, weekly: 60)]
    check("without a reserve the badge sits on the fuller week (guard the premise)",
          pick(sessionField) == "personal")
    check("a reserve moves the badge off an account whose 5h share is spent",
          pick(sessionField, reserves: ["personal": 30]) == "sibling")
    // The app half of `aboveReserve` reads BOTH windows, and reads them the same way round: it asks
    // every window carrying the number rather than the first one it finds, so which line binds does
    // not depend on the order the array happens to be built in. These two are that pair, and each is
    // the one a first-match reading of the OTHER window would get wrong.
    check("an account whose 5h share is spent is under its water line",
          !LaunchPolicyStore.aboveReserve(account("personal", session: 0, weekly: 90),
                                          primaryModel: nil, reserve: 30, now: Date()))
    check("…and so is one whose week is under the line",
          !LaunchPolicyStore.aboveReserve(account("personal", session: 90, weekly: 25),
                                          primaryModel: nil, reserve: 30, now: Date()))
    check("…while an account clear of both lines is above its water line",
          LaunchPolicyStore.aboveReserve(account("personal", session: 90, weekly: 90),
                                         primaryModel: nil, reserve: 30, now: Date()))
    check("…and every account is, when nobody reserved anything on it",
          LaunchPolicyStore.aboveReserve(account("personal", session: 1, weekly: 1),
                                         primaryModel: nil, reserve: 0, now: Date()))

    // A12: THE CLEARANCE LANE (B-1360). The launcher takes an account whose weekly leftovers are about
    // to be lost to a reset within a day ahead of the ranking (`launchPick`), so the badge has to
    // name it too, or the panel marks one card and a launch lands on another.
    let clearing = account("clearing", session: 99, weekly: 3, weeklyResetDays: 18.4 / 24)
    check("A12 the badge names the account whose 3% resets in 18 hours, as the launcher does",
          pick([rich, clearing]) == "clearing")
    check("A12 a reset 30 hours out is not about to be lost, so the badge stays put",
          pick([rich, account("clearing", session: 99, weekly: 3, weeklyResetDays: 30.0 / 24)])
              == "rich")
    // A quarantine that holds out every account leaves the launcher only the ranking (`launchPick`),
    // so the badge's retry does not reach for the clearance lane either (P2-of: bcca813).
    check("A12 an all-quarantined fleet badges the ranking's pick, as the launcher does",
          policy.autoPickID(providerID: "claude", accounts: [rich, clearing],
                            launchable: ["rich", "clearing"], reserves: [:],
                            quarantined: ["rich", "clearing"], occupancy: [:], now: Date())
              == "rich")
    check("A12 the badge skips a clearance account with two live sessions",
          pick([rich, clearing], occupancy: [clearing.id: 2]) == "rich")
    check("A12 …while one live session still takes it",
          pick([rich, clearing], occupancy: [clearing.id: 1]) == "clearing")
    check("A12 …and before the first count has been read", pick([rich, clearing], occupancy: nil) == "rich")
    // The count the panel reads (`ProbeCadence.liveAccountCounts`): one readable session on the
    // clearance account would let it take this launch, but a second live supervisor's file cannot
    // be read, so the count is unknown and the badge does what `tally status` does (B-1374).
    let stateDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-badgecount-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    try? clearing.id.write(to: stateDir.appendingPathComponent("101.account"), atomically: true,
                           encoding: .utf8)
    let blind = stateDir.appendingPathComponent("102.account")
    try? "rich".write(to: blind, atomically: true, encoding: .utf8)
    chmod(blind.path, 0)
    check("A12 an unreadable live session file leaves the clearance account to the CLI's answer",
          pick([rich, clearing], occupancy: ProbeCadence.liveAccountCounts(
              dir: stateDir, isAlive: { [101, 102].contains($0) })) == "rich")
    chmod(blind.path, 0o644)
    try? FileManager.default.removeItem(at: stateDir)
    check("A12 a dry 5h window is never cleared",
          pick([rich, account("clearing", session: 2, weekly: 50, weeklyResetDays: 18.4 / 24)])
              == "rich")

    // AND A PINNED CARD NEVER ASKS. Both surfaces draw the pinned badge from the pin itself and
    // only consult the reserve-aware pick in auto mode, which is the app end of "naming an account
    // is the answer" (the CLI end is asserted on values in tests/smartpick/reservechecks.swift).
    // Source text because these are SwiftUI bodies this suite does not compile: crude, and still
    // the difference between the rule going quietly and a failing check.
    for view in ["Tally/Views/AccountCardView.swift", "Tally/Views/AccountListRowView.swift"] {
        let source = (try? String(contentsOfFile: view, encoding: .utf8)) ?? ""
        check("\(view) draws the pinned badge from the pin, not from the pick",
              source.contains("facts.launchMode == .manual, facts.isPinnedActive")
                  && source.contains("facts.launchMode == .auto, facts.isAutoPick"))
    }
}
