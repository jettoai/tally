import Foundation

/// Fixture accounts for marketing and README screenshots:
/// `open Tally.app --args -TallyDemoData YES`.
///
/// The flag lives in the volatile argument domain, so a normal launch always shows real data. Demo
/// mode never runs a provider CLI and never writes the launch snapshot, so a demo instance on
/// screen can't steer the `tally` CLI's account picking.
enum DemoUsage {
    static var isActive: Bool { UserDefaults.standard.bool(forKey: "TallyDemoData") }

    /// The fixture whose identity callout `-TallyTooltipPreview identity` holds open: the Team
    /// account that shares its address with the Pro one, which is the whole point that callout's
    /// second line exists to make.
    static let tooltipPreviewAccountID = "codex:demo-Codex 4"

    /// The one fixture whose home is NOT under the user's own directory: a `CODEX_HOME` pointed
    /// somewhere else, which the env var allows today. It is the fixture the callout preview holds
    /// open, so the capture that checks this feature checks the shortened form the rule produces
    /// for such a path (`…/codex-team`, AccountIdentity.homeName) rather than only `~/.codexN`.
    private static let customHomes = [tooltipPreviewAccountID: "/Volumes/work/codex-team"]

    /// The config home a fixture stands for (`~/.codex4`), for that second line.
    ///
    /// Derived from the label the same way `tally add` numbers real homes, rather than stored: the
    /// fixtures ARE their labels, and a parallel table would be one more thing to keep in step -
    /// bar the one above, which is deliberately not derivable. Asked only by the identity line - a
    /// fixture still has no `launchHome` anywhere discovery can see, so every action that would
    /// touch a folder stays greyed out on a demo card.
    static func launchHome(accountID: String) -> String? {
        guard isActive else { return nil }
        if let custom = customHomes[accountID] { return custom }
        guard let separator = accountID.range(of: ":demo-") else { return nil }
        let base = accountID.hasPrefix("claude:") ? ".claude" : ".codex"
        let number = accountID[separator.upperBound...].filter(\.isNumber)
        return NSHomeDirectory() + "/\(base)\(number)"
    }

    static func accounts(now: Date = Date()) -> [AccountUsage] {
        [
            // Every remaining percentage stays double-digit (10-99): a mixed column of "8%" and
            // "100%" reads ragged in the right-aligned figures, and this grid IS the README shot.
            claude("Claude", plan: "Max 20x", model: 3, session: 2, weekly: 8,
                   modelResetDays: 6.4, sessionResetHours: 4.6, weeklyResetDays: 6.4, now: now),
            claude("Claude 2", plan: "Max 20x", model: 52, session: 25, weekly: 39,
                   modelResetDays: 1.2, sessionResetHours: 3.1, weeklyResetDays: 1.2, now: now),
            claude("Claude 3", plan: "Max 20x", model: 88, session: 66, weekly: 82,
                   modelResetDays: 0.8, sessionResetHours: 1.4, weeklyResetDays: 0.8, now: now),
            claude("Claude 4", plan: "Max 20x", model: 27, session: 12, weekly: 20,
                   modelResetDays: 4.2, sessionResetHours: 2.3, weeklyResetDays: 4.2, now: now),
            // The one card whose login has run out (LoginStatusStore.demoExpiredAccountID puts the
            // red "Login expired" chip on it). It keeps its numbers: the last-good figures are
            // exactly what a real expired account still shows, and a blank card would make the
            // screenshot about an error rather than about the chip.
            claude("Claude 5", plan: "Max 20x", model: 45, session: 89, weekly: 59,
                   modelResetDays: 2.6, sessionResetHours: 0.6, weeklyResetDays: 2.6, now: now),
            codex("Codex", plan: "Pro", email: "sam@example.com", session: 42, weekly: 69,
                  sessionResetHours: 2.4, weeklyResetDays: 5.9, resets: 3, now: now),
            codex("Codex 2", plan: "Pro", email: "sam2@example.com", session: 71, weekly: 14,
                  sessionResetHours: 0.9, weeklyResetDays: 3.3, resets: 1, now: now),
            codex("Codex 3", plan: "Pro", email: "sam3@example.com", session: 18, weekly: 83,
                  sessionResetHours: 3.8, weeklyResetDays: 1.7, resets: 0, now: now),
            // Nine accounts total (a 3-column demo screenshot lands as a full 3x3 grid); the
            // one non-premium plan sits last, not mid-pack.
            //
            // Deliberately the SAME address as "Codex" above, on a different plan: one ChatGPT
            // login in a personal workspace and in a team's is two accounts that answer with one
            // email, and the identity callout's second line is what tells them apart. A fixture
            // set where every address is unique could never show that.
            codex("Codex 4", plan: "Team", email: "sam@example.com", session: 47, weekly: 62,
                  sessionResetHours: 1.6, weeklyResetDays: 4.8, resets: 2, now: now),
        ]
    }

    /// Which fixture each supervised session gets during a capture, by pid in ASCENDING STRING
    /// ORDER.
    ///
    /// WHAT THE ORDER BUYS IS STABILITY, NOT AN ARRANGEMENT. It is not the board's own order (that
    /// is the roster's seating, `SessionBoardOrder`) and it is not numeric (these are pid strings,
    /// so "1234" sorts before "987"): which card on screen carries the warned fixture therefore
    /// cannot be predicted before a capture, only that it stays the same card while the capture
    /// runs. That is the property a screenshot needs - a fixture that moved between ticks would
    /// change the picture between two presses of the shutter.
    ///
    /// THE KEYS ARE THE CARDS THAT WILL BE DRAWN, which is the caller's part of the same bargain
    /// (`ProcessFootprintStore.sample`): handed the roster instead, a session the store turns out
    /// to have no reading for takes an index with it, and the fixtures after the hole all shift up
    /// - so the WARNED card, the one state a capture cannot sit and wait for, can be missing from
    /// a shot that otherwise looks entirely normal.
    static func fixtureOrder(of keys: [String]) -> [String: Int] {
        var order: [String: Int] = [:]
        for (index, key) in keys.sorted().enumerated() { order[key] = index }
        return order
    }

    /// One session's readings replaced by a fixture, so a capture can show the states a real board
    /// reaches rarely and never on demand: readings that are WARNED (which takes ten seconds of a
    /// heavy idle session to earn) and a port with a name against it (which takes a dev server
    /// somebody happens to have left running).
    ///
    /// THE CARDS ARE STILL THE MACHINE'S OWN, because the board's rows are: this app has no fixture
    /// sessions, and inventing some would mean a second roster. What is replaced is the READINGS,
    /// and all of them - every branch below states every field it could show, including the ports.
    /// A branch that left a field alone would put this machine's own dev server ports into a
    /// screenshot meant for a README (see the file's own note above about what these are for).
    static func footprint(_ real: ProcessFootprint, at index: Int) -> ProcessFootprint {
        var one = real
        one.agents = 0
        one.cpuLeader = nil
        one.diskWriteBytesPerSecond = nil
        one.diskLeader = nil
        one.listeningPorts = []
        one.portNames = [:]
        switch index % 3 {
        case 0:
            one.processes = 3
            one.cpuPercent = 92
            // BOTH READINGS NAME A PROCESS ON THIS ONE, which is what a warned card looks like on a
            // real machine: 92% of a core is being burned by something, and a card that warns about
            // the CPU without saying whose it is answers half of its own alarm. It is also the only
            // fixture that puts the trend row under its own narrowest rung - two names is the state
            // a 236pt card cannot hold both of (`SessionCardView.sessionFootprintTrends`), so a
            // capture shows what that row does about it rather than leaving it to a live board.
            one.cpuLeader = "node"
            one.memoryBytes = 4_100_000_000
            one.memoryLeader = "bun"
            one.alerts = FootprintAlerts(cpu: true, memory: true)
        case 1:
            one.processes = 2
            one.cpuPercent = 4
            one.memoryBytes = 1_260_000_000
            one.memoryLeader = "node"
            one.listeningPorts = [3000, 5173, 9229]
            one.portNames = [3000: "next-server", 5173: "vite", 9229: "node"]
            one.alerts = FootprintAlerts()
        default:
            one.processes = 0
            one.cpuPercent = 1
            one.memoryBytes = 214_000_000
            one.memoryLeader = nil
            one.alerts = FootprintAlerts()
        }
        return one
    }

    /// Fabricated burn rates so the fleet strip's forecast renders in screenshots: Claude spends
    /// faster than its combined refill budget (a concrete "lasts about …"), Codex within it
    /// (the "sustainable" state). Real instances estimate these from ~/.tally/history.jsonl.
    static var fleetRates: [String: FleetRate] {
        // Keys cover every window the gauge focus can headline, so the forecast renders in demo
        // whichever focus is active (Fable pool by default, weekly when switched).
        ["claude|weeklyModel|fable": FleetRate(perHour: 4.6, sampledHours: 72),
         "claude|weeklyAll": FleetRate(perHour: 4.6, sampledHours: 72),
         "codex|weeklyAll": FleetRate(perHour: 1.4, sampledHours: 72)]
    }

    /// Fabricated advisor readings so the advisor strip renders in screenshots too. Real instances
    /// derive these from ~/.tally/history.jsonl, which a demo launch never has, so without fixtures
    /// the strip is simply absent from the shot. The numbers continue the story the gauges above
    /// already tell: the five Claude accounts spend more per week than they refill (pace asks for a
    /// sixth, one hollow pip), while the four Codex accounts stay inside their budget.
    static var advisorReadings: [UsageAdvisor.Reading] {
        // 5.8 account-weeks over 5 accounts puts the pool past the 0.9 trigger on its own, and the
        // starved hours cross their 2h/wk trigger too, so both paths to "add an account" agree.
        // The active burn is the same working week seen from each provider: ~580 percent-points a
        // week at 11%/h and ~260 at 5%/h are both about 53 hours of hands-on time.
        //
        // The tier splits mirror the fixture accounts above: five Claude seats on one plan (so the
        // strip shows the pooled figure, the uniform-fleet case), and Codex spread over Pro and
        // Team, which is what puts the per-tier reading on screen. Each split sums to its own
        // pooled demand, the same invariant a real reading keeps.
        [UsageAdvisor.Reading(provider: "claude", verdict: .addAccount, demandPerWeek: 5.8,
                              activeBurnPerHour: 11, starvedHoursPerWeek: 3.4,
                              daysOfData: 14, accountCount: 5,
                              tierDemands: [.init(plan: "Max 20x", demandPerWeek: 5.8,
                                                  accountCount: 5)]),
         UsageAdvisor.Reading(provider: "codex", verdict: .sufficient, demandPerWeek: 2.6,
                              activeBurnPerHour: 5, starvedHoursPerWeek: 0,
                              daysOfData: 14, accountCount: 4,
                              tierDemands: [.init(plan: "Pro", demandPerWeek: 1.7, accountCount: 3),
                                            .init(plan: "Team", demandPerWeek: 0.9,
                                                  accountCount: 1)])]
    }

    /// Fixture token history for the Tokens tab, so the screenshot shows a plausible year of work
    /// instead of this machine's real project names. Spread over 366 days so every range button
    /// (today / 7D / 30D / all) has something to show AND a row's expanded activity graph is a full
    /// year rather than a bright corner, and shaped like the real corpus: cache reads dwarf
    /// everything, cache writes are a few times output, fresh input tracks output.
    static func tokenSamples(today: Int = LocalDayStamper.today()) -> [TokenSample] {
        let projects: [(path: String, provider: String, output: Int64)] = [
            ("/Users/you/workspace/atlas", "claude", 96_000),
            ("/Users/you/workspace/atlas-web", "claude", 61_000),
            ("/Users/you/workspace/ledger", "codex", 44_000),
            ("/Users/you/workspace/relay", "claude", 28_000),
            ("/Users/you/.claude", "claude", 12_000),
            (TokenProject.otherKey, "codex", 7_000),
        ]
        return (0 ..< 366).flatMap { offset -> [TokenSample] in
            // A fixed, uneven weekly rhythm (quiet weekends, one heavy day) - a flat series would
            // make every range button show the same shape. Under it, a slow swell over about seven
            // weeks, so the year-long graph reads as busy and quiet stretches instead of one even
            // texture. Both are arithmetic on the day offset and carry no randomness: a fixture
            // that redrew differently on every launch could not be screenshotted twice.
            let season = 0.55 + 0.45 * sin(Double(offset) / 23)
            let weight = [1.0, 1.3, 0.9, 1.6, 1.1, 0.3, 0.2][offset % 7] * season
            return projects.enumerated().map { index, project in
                let output = Int64(Double(project.output) * weight * (index == 0 && offset == 0 ? 0.6 : 1))
                return TokenSample(
                    day: today - offset, project: project.path, providerID: project.provider,
                    totals: TokenTotals(input: output, cacheWrite: output * 8,
                                        cacheRead: output * 330, output: output))
            }
        }
    }

    /// A Claude account shaped exactly like ClaudeUsageCLI's mapping: a model-scoped weekly window
    /// (the headline), the 5h session, and the all-model weekly. A nil session reset mirrors the
    /// untouched-account case ("5h starts on first use").
    private static func claude(_ label: String, plan: String, model: Double, session: Double,
                               weekly: Double, modelResetDays: Double?, sessionResetHours: Double?,
                               weeklyResetDays: Double?, now: Date) -> AccountUsage {
        // Fixture identity for the header's hover tooltip ("Claude 2" → alex2@example.com), derived
        // from the label so no screenshot can ever carry this machine's real address.
        AccountUsage(
            id: "claude:demo-\(label)", providerID: "claude", accountLabel: label, planName: plan,
            accountEmail: "alex\(label.filter(\.isNumber))@example.com",
            metrics: [
                UsageMetric(id: "weekly_model:Fable", kind: .weeklyModel, label: "Fable",
                            modelName: "Fable", usedPercent: model,
                            severity: .fromUsedPercent(model),
                            resetsAt: modelResetDays.map { now.addingTimeInterval($0 * 86_400) },
                            isActive: false),
                UsageMetric(id: "session", kind: .session, label: "Session", modelName: nil,
                            usedPercent: session, severity: .fromUsedPercent(session),
                            resetsAt: sessionResetHours.map { now.addingTimeInterval($0 * 3_600) },
                            isActive: false),
                UsageMetric(id: "weekly_all", kind: .weeklyAll, label: "Weekly", modelName: nil,
                            usedPercent: weekly, severity: .fromUsedPercent(weekly),
                            resetsAt: weeklyResetDays.map { now.addingTimeInterval($0 * 86_400) },
                            isActive: false),
            ],
            refreshedAt: now)
    }

    /// A Codex account shaped like CodexAppServerClient's mapping: the 5h primary window plus
    /// the weekly secondary, both with resets (some real plans report only the weekly; the demo
    /// shows the full shape).
    private static func codex(_ label: String, plan: String, email: String, session: Double,
                              weekly: Double, sessionResetHours: Double, weeklyResetDays: Double,
                              resets: Int, now: Date) -> AccountUsage {
        AccountUsage(
            id: "codex:demo-\(label)", providerID: "codex", accountLabel: label, planName: plan,
            // Spelled out per fixture rather than derived from the label (which is what the Claude
            // ones do): two of these deliberately share one address, and a derivation cannot say so.
            accountEmail: email,
            metrics: [
                UsageMetric(id: "session", kind: .session, label: "Session", modelName: nil,
                            usedPercent: session, severity: .fromUsedPercent(session),
                            resetsAt: now.addingTimeInterval(sessionResetHours * 3_600),
                            isActive: false),
                UsageMetric(id: "weekly_all", kind: .weeklyAll, label: "Weekly", modelName: nil,
                            usedPercent: weekly, severity: .fromUsedPercent(weekly),
                            resetsAt: now.addingTimeInterval(weeklyResetDays * 86_400),
                            isActive: false),
            ],
            refreshedAt: now,
            resetCreditsAvailable: resets > 0 ? resets : nil)
    }
}
