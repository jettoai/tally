import Foundation

/// Usage advisor: turns the raw burn-rate history (`~/.tally/history.jsonl`) into a plain
/// "do I need another account?" verdict. Pure math over decoded samples, no I/O and no
/// `MetricKind` dependency, so ONE copy of this file compiles into both the app (Tally target,
/// wired in via project.yml) and the `tally` CLI (this folder), and the test harness builds it
/// standalone. Presentation is layered on top: the panel localizes its own headline from the
/// verdict, the CLI/JSON layer formats English. This layer only produces numbers and a verdict.
enum UsageAdvisor {
    // Window identifiers matched as raw strings so this file needs no MetricKind (which lives in
    // the app-only Providers layer). Kept in step with MetricKind.rawValue.
    static let weeklyAllWindow = "weeklyAll"
    static let weeklyModelWindow = "weeklyModel"

    /// How far back the reading looks - four weeks, matching the history's retention, so the
    /// weekly-demand trend has room to average out day-to-day swings.
    static let lookbackDays: Double = 28
    /// Below this much history the pace is noise, not a trend: show "collecting data", never a
    /// recommendation.
    static let minimumDays: Double = 7
    /// A window at or above this percent used has no usable quota left - it is starved.
    static let starvedThreshold: Double = 99
    /// Two samples farther apart than this aren't one continuous stretch of work; cap the gap so an
    /// overnight idle span counts as neither active nor starved time. It is also how long one
    /// sample vouches for the app having been awake (`observedSpans`).
    static let maxGap: TimeInterval = 30 * 60
    /// How far a reported reset time may move and still name the SAME weekly cycle.
    ///
    /// RESET TIMES WOBBLE. Claude's are parsed out of `/usage`'s human text, whose finest unit is
    /// the minute, so one unbroken window is reported a minute earlier or later as the underlying
    /// instant rounds; Codex's walk forward almost every poll while a window sits idle, because the
    /// weekly period starts at the first request rather than on a calendar. Matched by EQUALITY,
    /// 31,618 of this machine's 34,281 Claude weekly samples looked like a fresh cycle and their
    /// real deltas were thrown away (Sol's audit, 2026-09-02). The same 5 minutes the rebalance
    /// claim uses for the same reason (`rebalanceCycleTolerance`, TallyCLI/Rebalance.swift); they
    /// are one tolerance over one wobble and should move together.
    static let resetTolerance: TimeInterval = 5 * 60
    /// Recommend another account once weekly demand reaches this fraction of pooled capacity...
    static let demandTriggerRatio: Double = 0.9
    /// ...or once the fleet sits starved more than this many hours in a week.
    static let starvedTriggerHours: Double = 2
    /// The spans the panel can read the weekly demand over, shortest first. The VERDICT is always
    /// the full `lookbackDays` one - a recommendation that changed with the reader's zoom level
    /// would be a different piece of advice per click - so these only ever move the figure on
    /// screen. Last entry is the default and has to be `lookbackDays`, because that is the window
    /// every other surface publishes (`Reading.demandPerWeek`, the CLI's JSON).
    static let displayWindows: [Double] = [1, 3, 7, 28]

    /// One history row, decoded straight from the JSONL file. Field-for-field the same as
    /// `UsageHistory.Sample`; kept separate so this pure file carries no app dependency.
    struct Sample: Codable, Sendable {
        var ts: Date
        var account: String
        var provider: String
        var window: String
        var model: String?
        var used: Double
        var resetAt: Date?
    }

    enum Verdict: String, Sendable, Equatable {
        case collecting   // not enough history yet
        case addAccount   // demand or starvation crossed the trigger
        case sufficient   // current accounts cover the demand
    }

    /// One plan tier's slice of the weekly demand. Accounts are interchangeable only INSIDE a tier:
    /// a Codex Pro seat and a Codex Team seat both read "1.0 account-week" at full spend while
    /// buying very different amounts of work, so a pooled total across them is a number no
    /// subscription can be bought against. `plan` is nil for the accounts whose plan this machine
    /// cannot name (the history carries no plan; it is joined from the live accounts).
    struct TierDemand: Sendable, Equatable {
        var plan: String?
        var demandPerWeek: Double
        var accountCount: Int
    }

    /// The same weekly demand measured over ONE of the display windows, so the panel can offer the
    /// reader a shorter lens than the 28 days the verdict is fixed to: a fleet whose habits changed
    /// last Tuesday reads its old month as one number and its new week as another, and only the
    /// reader knows which one they are asking about.
    ///
    /// EVERY WINDOW HAS ITS OWN COLLECTING GATE, in `minimumDays` below. A day's window is a real
    /// reading after a day; the month's still waits the week the trend gate has always waited, and
    /// no window waits longer than that. A window that has not reached its own gate carries a nil
    /// demand rather than a small number computed over a sliver of history, because the sliver
    /// would look exactly like a fact.
    struct WindowDemand: Sendable, Equatable {
        /// The span in days: one of `displayWindows`.
        var days: Double
        /// Pooled weekly burn over that span, or nil while the history is shorter than the gate.
        var demandPerWeek: Double?
        /// The same figure split by plan, on the same terms as `Reading.tierDemands`. Empty while
        /// the window is still collecting.
        var tierDemands: [TierDemand] = []
        /// How much history this window needs before it reads at all.
        var minimumDays: Double
    }

    /// One provider's verdict plus the numbers behind it. Language-free on purpose: the panel
    /// builds a localized headline from `verdict`, the CLI/JSON layer an English one.
    struct Reading: Sendable, Equatable {
        var provider: String
        var verdict: Verdict
        /// Pooled weekly burn in account-weeks: 1.0 means one full account's weekly quota per week.
        var demandPerWeek: Double
        /// Percent of a window spent per hour of active work.
        var activeBurnPerHour: Double
        var starvedHoursPerWeek: Double
        var daysOfData: Double
        var accountCount: Int
        /// The same weekly demand split by plan tier, largest first. The parts always sum to
        /// `demandPerWeek` (the split partitions the very same samples), so a surface can show
        /// either without the two disagreeing. With no plan supplied for any account this is ONE
        /// tier whose `plan` is nil and whose demand IS the pooled figure, not an empty list: the
        /// split is always complete, it just has nothing to name its single tier.
        var tierDemands: [TierDemand] = []
        /// The same demand measured over each of `displayWindows`, shortest first - what the panel's
        /// clickable figure cycles through. The `lookbackDays` entry is `demandPerWeek` itself, by
        /// construction rather than by coincidence: same samples, same denominator.
        var windowDemands: [WindowDemand] = []
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Tolerant line-by-line decode (fail-open: one malformed line costs only itself, never the
    /// whole file), keeping samples at or after `since`.
    static func decodeSamples(_ data: Data, since: Date) -> [Sample] {
        var out: [Sample] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let s = try? decoder.decode(Sample.self, from: Data(line)), s.ts >= since
            else { continue }
            out.append(s)
        }
        return out
    }

    /// One reading per provider present in the samples, providers in stable alphabetical order.
    ///
    /// `planOf` names the plan an account is on today (nil = unknown), which is what splits the
    /// demand into tiers. It is a lookup rather than a field on `Sample` because the history has no
    /// plan in it and never will retroactively: a plan change is rare, and the 28-day window heals
    /// one within a month, whereas a stored-per-sample plan would have to be back-filled.
    ///
    /// `reserveOf` names the percentage points of each account's WEEKLY window its owner keeps for
    /// their own use (Tally's per-account reserve), a lookup for the same reason `planOf` is one:
    /// the history has no reserve in it and never will retroactively, and what the question here
    /// means - "do these accounts cover the demand" - is about the part of them Tally may actually
    /// spend. An account with 30 points held back is 0.7 of an account-week to this reading, and it
    /// is starved 30 points earlier than its siblings - in the ACCOUNT-WIDE pool, which is the only
    /// pool a week's capacity is counted in (the model pools below read it as zero, for the reason
    /// stated where they are summed). Defaults to no reserve
    /// anywhere, which is every fleet that has not set one and every caller that has not been taught
    /// to ask.
    ///
    /// `liveAccounts` is the fleet AS IT IS NOW - the accounts still on this machine. The history
    /// outlives a removed account by up to four weeks, and while it does, that account is a whole
    /// account-week of CAPACITY nobody has any more, a reserve nobody holds, a pip nobody owns, and
    /// a member of the starvation intersection that never starves (so the pool never does either).
    /// Its past BURN stays in the demand, which is the honest half: the work happened, and it is
    /// the work the remaining accounts would have to absorb. Nil means "every account in the
    /// history is live", which is what every caller that has not been taught to ask means, and what
    /// the tests mean.
    static func readings(samples: [Sample], now: Date = Date(),
                         planOf: (String) -> String? = { _ in nil },
                         reserveOf: @escaping (String) -> Double = { _ in 0 },
                         liveAccounts: Set<String>? = nil) -> [Reading] {
        Dictionary(grouping: samples, by: \.provider).keys.sorted().compactMap { provider in
            reading(provider: provider, samples: samples.filter { $0.provider == provider },
                    now: now, planOf: planOf, reserveOf: reserveOf, liveAccounts: liveAccounts)
        }
    }

    static func reading(provider: String, samples: [Sample], now: Date = Date(),
                        planOf: (String) -> String? = { _ in nil },
                        reserveOf: (String) -> Double = { _ in 0 },
                        liveAccounts: Set<String>? = nil) -> Reading? {
        guard let earliest = samples.map(\.ts).min() else { return nil }
        let days = now.timeIntervalSince(earliest) / 86_400
        let weeks = max(days / 7, 1e-6)   // div-safety only; the collecting gate handles young data
        let accounts = Set(samples.map(\.account)).filter { isLive($0, in: liveAccounts) }
        // A provider whose every account has gone still has history. It has no fleet, so it has no
        // question: "do I need another account" is not asked of a provider nobody is on any more.
        guard !accounts.isEmpty else { return nil }

        let weeklyAll = samples.filter { $0.window == weeklyAllWindow }
        let weeklyModel = samples.filter { $0.window == weeklyModelWindow }
        // WHAT THE APP ACTUALLY WATCHED, from every sample this provider wrote - any account, any
        // window. Starvation is measured inside it (`poolStarvedSeconds`) so a laptop that was shut
        // for ten hours cannot report ten starved hours it was not there to see.
        let observed = observedSpans(samples)

        // ONE walk of the account-wide series answers both the pooled demand and the active
        // pace; they are the same spending seen two ways, and walking it twice is how they
        // would come to disagree.
        let spent = consumption(weeklyAll)
        let demandPerWeek = spent.total / weeks / 100

        // Binding constraint: the most saturated pool relative to its OWN account capacity - the
        // account-wide weekly, or any single model window. A fable window can be the wall while
        // the account-wide weekly still reads healthy.
        // A RESERVE IS TAKEN OFF THE ACCOUNT-WIDE POOL ONLY, and that is a statement about POOLS
        // rather than a re-run of the window ruling. The question here is "do these accounts cover a
        // week's demand", and the only pool a week's capacity is counted in is the account-wide one:
        // the 5h window and the flagship one that the reserve also covers (Tally/Core/AccountReserve.
        // swift) are respectively a pacing constraint that refills 33 times a week and a slice of
        // the very week already counted here, so subtracting the reserve from either would hold the
        // same points back twice and report a pool as saturated on capacity nothing withholds.
        var bindingRatio = poolRatio(weeklyAll, weeks: weeks, live: liveAccounts,
                                     reserveOf: reserveOf)
        for model in Set(weeklyModel.compactMap(\.model)) {
            bindingRatio = max(bindingRatio, poolRatio(weeklyModel.filter { $0.model == model },
                                                       weeks: weeks, live: liveAccounts,
                                                       reserveOf: { _ in 0 }))
        }

        let activeBurnPerHour = spent.activeSeconds > 0
            ? spent.activeBurn / (spent.activeSeconds / 3_600) : 0

        // Starvation is pool-level and conservative: a pool only counts as starved while EVERY one
        // of its accounts is simultaneously at/above the threshold (any account with quota can
        // absorb a handoff). Provider value = the most-starved pool, mirroring bindingRatio.
        var starvedSeconds = poolStarvedSeconds(weeklyAll, now: now, live: liveAccounts,
                                                observed: observed, reserveOf: reserveOf)
        for model in Set(weeklyModel.compactMap(\.model)) {
            // The account-wide pool only, for the reason the ratio above states: this reading is
            // about a week's CAPACITY, and a model pool is a slice of the week already counted.
            starvedSeconds = max(starvedSeconds,
                                 poolStarvedSeconds(weeklyModel.filter { $0.model == model },
                                                    now: now, live: liveAccounts,
                                                    observed: observed, reserveOf: { _ in 0 }))
        }
        let starvedHoursPerWeek = starvedSeconds / 3_600 / weeks

        let verdict: Verdict
        if days < minimumDays {
            verdict = .collecting
        } else if bindingRatio >= demandTriggerRatio || starvedHoursPerWeek > starvedTriggerHours {
            verdict = .addAccount
        } else {
            verdict = .sufficient
        }
        return Reading(provider: provider, verdict: verdict, demandPerWeek: demandPerWeek,
                       activeBurnPerHour: activeBurnPerHour, starvedHoursPerWeek: starvedHoursPerWeek,
                       daysOfData: days, accountCount: accounts.count,
                       tierDemands: tierDemands(weeklyAll, weeks: weeks, live: liveAccounts,
                                                planOf: planOf),
                       windowDemands: windowDemands(weeklyAll, days: days, now: now,
                                                    live: liveAccounts, planOf: planOf))
    }

    /// English one-liner for the CLI and the --json `headline` field. The panel builds its own
    /// localized version from `verdict`.
    static func englishHeadline(_ r: Reading) -> String {
        switch r.verdict {
        case .collecting:
            // Floor, never round: at 6.6 days the reading is still collecting, so "7 of 7 days"
            // would read as a contradiction.
            return "collecting data (\(Int(r.daysOfData)) of \(Int(minimumDays)) days)"
        case .addAccount:
            return "consider adding an account"
        case .sufficient:
            return "current accounts are sufficient"
        }
    }
}
