import Foundation

/// The usage advisor's arithmetic: the burn walk over the recorded history, the pool ratios and the
/// starvation spans. Split out of UsageAdvisor.swift purely for file size (the repo's 500-line
/// rule); it is the same enum, and `UsageAdvisor.reading` is the only caller of everything here.
///
/// COMPILED WHEREVER UsageAdvisor.swift IS - the app target (project.yml), the `tally` CLI, and
/// every test runner that lists the advisor. The two files are one unit and travel together.
extension UsageAdvisor {
    /// The demand over each display window, shortest first, each behind its own collecting gate.
    ///
    /// THE DENOMINATOR IS THE SPAN ACTUALLY COVERED, `min(window, history)`, so a fortnight-old
    /// fleet reading its 28-day window gets the same figure it always did rather than one halved by
    /// a month that has not happened yet. The burn walk sees the WHOLE history and only credits
    /// what falls inside the window (`consumption(_:since:)`), so the sample just before the window
    /// opens is a baseline rather than a loss - a shorter lens must not invent burn or drop it.
    static func windowDemands(_ samples: [Sample], days: Double, now: Date,
                              live: Set<String>?,
                              planOf: (String) -> String?) -> [WindowDemand] {
        displayWindows.map { window in
            // No window waits longer than the trend gate: 28 days of history is not a precondition
            // for reading a month, it is only a precondition for reading a month IN FULL, and the
            // partial month is exactly what this reading has always published.
            let gate = min(window, minimumDays)
            guard days >= gate else { return WindowDemand(days: window, minimumDays: gate) }
            let weeks = max(min(window, days) / 7, 1e-6)
            let since = now.addingTimeInterval(-window * 86_400)
            return WindowDemand(days: window,
                                demandPerWeek: consumption(samples, since: since).total / weeks / 100,
                                tierDemands: tierDemands(samples, weeks: weeks, since: since,
                                                         live: live, planOf: planOf),
                                minimumDays: gate)
        }
    }

    /// The weekly demand split by plan, largest first. Splitting by account keeps every series
    /// (account | window | model) whole, which is why the tiers add back up to the pooled figure.
    ///
    /// The DEMAND is every account's, live or departed, for the reason `readings` states; only the
    /// account COUNT is the live fleet's, because that number is a claim about what is on this
    /// machine right now.
    static func tierDemands(_ samples: [Sample], weeks: Double, since: Date = .distantPast,
                            live: Set<String>?,
                            planOf: (String) -> String?) -> [TierDemand] {
        Dictionary(grouping: samples) { planOf($0.account) }
            .map { plan, rows in
                TierDemand(plan: plan, demandPerWeek: consumption(rows, since: since).total / weeks / 100,
                           accountCount: Set(rows.map(\.account))
                               .filter { isLive($0, in: live) }.count)
            }
            .sorted { a, b in
                if a.demandPerWeek != b.demandPerWeek { return a.demandPerWeek > b.demandPerWeek }
                // Ties break by name so a refresh cannot reshuffle the row under the reader; the
                // unnamed tier goes last, which is where an unknown belongs.
                switch (a.plan, b.plan) {
                case let (left?, right?): return left < right
                case (_?, nil): return true
                default: return false
                }
            }
    }

    /// A pool's weekly demand as a fraction of its own account capacity (accounts contributing the
    /// window). Zero when the pool has no accounts.
    ///
    /// CAPACITY IS THE PART TALLY MAY SPEND, so an account contributes `(100 - reserve) / 100` of
    /// an account-week rather than a whole one. Two accounts with 30 points reserved on one of them
    /// are 1.7 accounts of capacity, and the verdict this feeds - "do I need another account?" - is
    /// about exactly that number: a fleet whose spendable half is saturated needs another seat no
    /// matter how much quota is sitting behind somebody's browser reserve. A pool whose accounts are
    /// entirely reserved has no capacity at all, which is saturation by any demand above zero.
    ///
    /// CAPACITY IS THE LIVE FLEET'S. An account that was removed last week left its burn in the
    /// numerator and took its seat with it, and counting the seat anyway is the one direction that
    /// matters: it makes a fleet that just lost a quarter of itself read as comfortable.
    static func poolRatio(_ samples: [Sample], weeks: Double, live: Set<String>?,
                          reserveOf: (String) -> Double) -> Double {
        let capacity = Set(samples.map(\.account))
            .filter { isLive($0, in: live) }
            .reduce(0.0) { $0 + (100 - min(max(reserveOf($1), 0), 100)) / 100 }
        let demand = consumption(samples).total / weeks / 100
        // Nothing spendable: saturated by any demand at all, and no signal without one. Both halves
        // matter - a fleet reserved down to nothing and not being used is a preference, not a
        // shortage, and telling that person to buy a seat would be advice about their own setting.
        guard capacity > 0 else { return demand > 0 ? .infinity : 0 }
        return demand / capacity
    }

    /// How much a set of samples spent, walked series by series (one series = one account, window
    /// and model). ONE walk answers both questions this file asks of the history - the total, and
    /// the part of it that happened over an observed span - because they have to agree about what
    /// counted as spending, and two loops applying the same rules twice is how they stop agreeing.
    ///
    /// THE RULES, and why each is not the obvious thing:
    ///
    /// - A CYCLE IS MATCHED BY NEARNESS, not by equality (`resetTolerance`). The reported reset
    ///   wobbles by a minute on Claude and walks forward on Codex while nothing is spent, and an
    ///   equality test reads every wobble as a fresh week and throws that pair's real delta away.
    /// - A NIL RESET DOES NOT CUT THE CYCLE. It is a provider that did not say this time, not a
    ///   window that rolled over; the anchor is kept until a reported time actually disagrees.
    /// - INSIDE A CYCLE ONLY A NEW HIGH COUNTS, never a pairwise delta. A percentage that dips and
    ///   recovers (rounding, a provider recomputing) is one purchase, and pairwise rectification
    ///   bills the recovery again - on this machine's real history, 5.98 account-weeks against the
    ///   high-water 3.44. The running maximum is what was actually spent this cycle.
    /// - THE FIRST SAMPLE OF A CONFIRMED NEW CYCLE IS ALL BURN. The window restarted at zero, so
    ///   whatever it already reads was spent inside it - the case where the app was closed and came
    ///   back to a fresh week at 40%, which the old pair-skipping rule dropped entirely.
    /// - THE FIRST SAMPLE THIS HISTORY EVER SAW IS A BASELINE, not burn: it was spent before the
    ///   record begins, and the tail between the previous week's last observation and its reset
    ///   cannot be reconstructed from a change-only log. Undercounting there is the honest answer;
    ///   assuming it ran to 100% is not.
    ///
    /// `since` is the display window: the walk always sees the whole history (so the sample just
    /// before the window is a baseline rather than a loss) and credits only what lands at or after
    /// it. `.distantPast` is the whole thing.
    static func consumption(_ samples: [Sample], since: Date = .distantPast)
        -> (total: Double, activeBurn: Double, activeSeconds: Double) {
        var total = 0.0, activeBurn = 0.0, activeSeconds = 0.0
        for (_, rows) in Dictionary(grouping: samples, by: seriesKey) {
            let sorted = rows.sorted { $0.ts < $1.ts }
            var cycle: Date?          // the reset instant anchoring the cycle being watched
            var watermark = 0.0       // the highest `used` seen inside it
            var previous: Sample?
            for sample in sorted {
                defer { previous = sample }
                guard let prior = previous else {
                    cycle = sample.resetAt
                    watermark = sample.used
                    continue
                }
                if let reported = sample.resetAt, let anchor = cycle,
                   abs(reported.timeIntervalSince(anchor)) > resetTolerance {
                    cycle = reported
                    watermark = sample.used
                    // Spent inside the new cycle, but over a span this history did not watch (the
                    // rollover happened between two samples), so it is burn without active time.
                    if sample.ts >= since { total += sample.used }
                    continue
                }
                // Same cycle: follow the reported time so a minute-per-poll drift never accumulates
                // into a false rollover.
                if sample.resetAt != nil { cycle = sample.resetAt }
                guard sample.used > watermark else { continue }
                let step = sample.used - watermark
                watermark = sample.used
                guard sample.ts >= since else { continue }
                total += step
                activeBurn += step
                // Gap-capped so an idle stretch between two spending samples doesn't dilute the
                // "while working" pace.
                activeSeconds += min(maxGap, sample.ts.timeIntervalSince(prior.ts))
            }
        }
        return (total, activeBurn, activeSeconds)
    }

    /// Whether an account is still on this machine. A nil live set means nobody told us, which is
    /// every account the history holds - the reading every caller got before the fleet was joined
    /// in, and the one the tests mean. One place answers this because four call sites ask it and a
    /// fifth that answered differently is how a departed account keeps half its privileges.
    static func isLive(_ account: String, in live: Set<String>?) -> Bool {
        live?.contains(account) ?? true
    }

    /// The spans this provider's history is evidence the app was awake for: `maxGap` from each
    /// sample it wrote, on ANY account and in ANY window, coalesced.
    ///
    /// WHY STARVATION NEEDS THIS. The recorder writes only when a value moves, so a sample's
    /// reading persists until the next one - which is right while the app is running and wrong the
    /// moment it is not. A laptop closed at 100% for ten hours produced, by that rule alone, ten
    /// starved hours nobody observed, and 2.5 of them per week is enough to trip the 2h/wk trigger
    /// on its own. Truncating at the reset only catches the droughts that happen to span one.
    ///
    /// WHAT IT COSTS, said plainly: a fleet so completely stuck that not one window of one account
    /// moves for half an hour stops accruing starved time even though the app is running. That is
    /// the conservative direction, and it is narrow in practice - the 5-hour windows keep moving
    /// under a pinned weekly one, and every account contributes. The complete answer is a low
    /// frequency poll-liveness marker in the history itself; this is the honest approximation
    /// available from the rows that already exist.
    static func observedSpans(_ samples: [Sample]) -> [Interval] {
        merge(samples.map { Interval(start: $0.ts, end: $0.ts.addingTimeInterval(maxGap)) })
    }

    /// Seconds a whole pool sat starved: the time ALL of its accounts were simultaneously at or
    /// above the starved threshold. One account keeping quota means the pool can still absorb a
    /// handoff, so it is not starved. Zero for an empty pool or any account that never starved.
    ///
    /// LIVE ACCOUNTS ONLY, and the reason is the opposite of the capacity one: a departed account
    /// stopped writing samples, so it never starves, so the intersection with it is empty and the
    /// pool reports no starvation at all for as long as the history remembers it.
    static func poolStarvedSeconds(_ samples: [Sample], now: Date, live: Set<String>?,
                                   observed: [Interval],
                                   reserveOf: (String) -> Double) -> Double {
        let byAccount = Dictionary(grouping: samples, by: \.account)
            .filter { isLive($0.key, in: live) }
        guard !byAccount.isEmpty else { return 0 }
        var intersection: [Interval]?
        for (account, rows) in byAccount {
            let starved = intersect(
                merge(starvedIntervals(rows, now: now, reserve: reserveOf(account))), observed)
            if starved.isEmpty { return 0 }
            intersection = intersection.map { intersect($0, starved) } ?? starved
            if intersection?.isEmpty == true { return 0 }
        }
        return (intersection ?? []).reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    /// Half-open `[start, end)` span. Internal rather than private only because `reading` builds
    /// one list of these (the observed spans) in the file next door; nothing outside the advisor
    /// has a use for it.
    struct Interval { var start: Date; var end: Date }

    /// The spans one account's series sat starved. Per the recorder's change-only contract each
    /// sample's value persists until the next; the last sample extends to `now`.
    ///
    /// AND NEVER PAST ITS OWN RESET. A window that was full at 09:00 and refills at 11:00 is not
    /// starved at noon, whatever the next sample says or whether one was ever written: the quota
    /// came back on a schedule the sample itself carries. The caller crops the rest of the span
    /// down to the time the app was awake for (`observedSpans`).
    ///
    /// AN ACCOUNT WITH A RESERVE STARVES EARLIER, by exactly the size of the reserve: what starved
    /// means here is "this account can absorb no more work", and the points its owner kept were
    /// never work this fleet could absorb. Without it, a personal account at 30 points reserved
    /// would read as healthy through the whole drought Tally spends refusing to touch it, and the
    /// pool - starved only while EVERY account is - would report no starvation at all.
    private static func starvedIntervals(_ samples: [Sample], now: Date,
                                         reserve: Double) -> [Interval] {
        let threshold = starvedThreshold - min(max(reserve, 0), 100)
        let sorted = samples.sorted { $0.ts < $1.ts }
        var out: [Interval] = []
        for (i, s) in sorted.enumerated() {
            let next = i + 1 < sorted.count ? sorted[i + 1].ts : now
            let end = min(min(next, now), s.resetAt ?? .distantFuture)
            guard s.used >= threshold, end > s.ts else { continue }
            out.append(Interval(start: s.ts, end: end))
        }
        return out
    }

    /// Coalesce overlapping or touching spans so intersection can sweep them linearly.
    private static func merge(_ intervals: [Interval]) -> [Interval] {
        var out: [Interval] = []
        for iv in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, iv.start <= last.end {
                out[out.count - 1].end = max(last.end, iv.end)
            } else {
                out.append(iv)
            }
        }
        return out
    }

    /// The overlap of two coalesced span lists (time covered by both).
    private static func intersect(_ a: [Interval], _ b: [Interval]) -> [Interval] {
        var out: [Interval] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            let start = max(a[i].start, b[j].start)
            let end = min(a[i].end, b[j].end)
            if start < end { out.append(Interval(start: start, end: end)) }
            if a[i].end < b[j].end { i += 1 } else { j += 1 }
        }
        return out
    }

    private static func seriesKey(_ s: Sample) -> String {
        "\(s.account)|\(s.window)|\(s.model ?? "")"
    }
}
