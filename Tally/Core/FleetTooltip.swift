import Foundation

/// What the fleet gauge's hover says, decided here and worded by the view.
///
/// The gauge answers "how much does the whole fleet have and does it last". The hover used to try to
/// answer everything else at once: every pooled window with its weakest account, the whole refill
/// schedule, and then a line per account repeating the numbers already on the cards below it. As a
/// system tooltip that arrived as a wall of text, and the half of it that mattered was buried in the
/// half that was already on screen.
///
/// So the hover keeps the three things the gauge itself cannot show, and nothing else:
///
///  - the capacity unit ("1.4/4 accounts' worth left"), which the value column gives up so the whole
///    panel can speak in percent;
///  - the TIGHTEST window in the fleet, named with the account that owns it, which is the one thing
///    a pooled average structurally hides: four healthy accounts and one at 3% average out fine;
///  - the next refill, which the gauge shows only for the pool it is currently displaying.
///
/// Pure and semantic: the numbers and the choices are decided here, the words and the clock
/// formatting stay with the view that owns the localization. That split is what lets the selection
/// rules be tested without a running app.
enum FleetTooltip {
    /// The fleet's weak spot: the pool whose worst member is closest to the wall, and that member.
    struct Tightest: Equatable {
        /// The pool this member belongs to, in the parts its display name is built from.
        let poolKind: MetricKind
        let poolLabel: String
        let modelName: String?
        let accountLabel: String
        let remaining: Double
        var severity: MetricSeverity { MetricSeverity.fromUsedPercent(100 - remaining) }
    }

    /// One provider's hover content.
    struct Model: Equatable {
        let accountCount: Int
        /// The pool the capacity line is about: the one the gauge is currently leading with, so the
        /// hover explains the bar the pointer is on rather than some other pool.
        let poolKind: MetricKind
        let poolLabel: String
        let poolModelName: String?
        /// Units left in that pool, where one account's full window is 100.
        let unitsRemaining: Double
        /// How many accounts that pool spans (the denominator of "1.4/4").
        let poolAccountCount: Int
        let tightest: Tightest?
        let nextRefill: FleetPool.Refill?
    }

    /// The hover for one provider, or nil when the gauge is showing nothing for it (no displayed
    /// pool means no bar to explain).
    ///
    /// `displayed` is what the strip actually renders for this summary, leading pool first; it is
    /// passed in rather than recomputed because the display order depends on the user's gauge focus,
    /// which lives in Settings.
    static func model(_ summary: FleetSummary, displayed: [FleetPool]) -> Model? {
        guard let leading = displayed.first else { return nil }
        return Model(
            accountCount: summary.accountCount,
            poolKind: leading.kind,
            poolLabel: leading.label,
            poolModelName: leading.modelName,
            unitsRemaining: leading.totalRemaining,
            poolAccountCount: leading.members.count,
            tightest: tightest(summary.pools),
            // The leading pool's own next refill, not the fleet's soonest: this line sits under a
            // capacity figure for THAT pool, and a refill belonging to a different window would read
            // as the moment this number goes up.
            nextRefill: leading.refills.first)
    }

    /// Which reading the refill line gives: a countdown to the instant, or the instant itself.
    /// The view formats whichever this picks, so the CHOICE can be tested without a window.
    enum RefillValue: Equatable {
        /// Seconds from now, already floored (a refill inside the next minute still reads "1m"
        /// rather than counting seconds down to zero).
        case countdown(TimeInterval)
        case clock(Date)
    }

    /// Countdown or clock, from the user's global reset-display preference (`DisplaySettings.swift`)
    /// - the same preference every reset label on the panel follows, toggled by clicking any of
    /// them. The hover used to answer with a countdown unconditionally, so a user who had switched
    /// the whole app to exact times got one line still counting down (codex review, 2026-08-04).
    static func refillValue(_ refill: FleetPool.Refill, style: ResetDisplay,
                            now: Date) -> RefillValue {
        style == .absolute
            ? .clock(refill.at)
            : .countdown(max(60, refill.at.timeIntervalSince(now)))
    }

    /// The worst member across the fleet's weekly-cycle pools. Ties break toward the pool listed
    /// first, which is `FleetMath`'s own order rather than anything this decides.
    ///
    /// Deliberately the worst MEMBER rather than the worst pool average: an average is exactly what
    /// the gauge already draws, and it is also what hides the account about to hit a wall.
    ///
    /// Session windows are left out for the same reason the gauge leaves them out: a five-hour
    /// window is the one that is nearly always lowest and the one that always comes back on its own,
    /// so a "tightest" line reading it would name a session almost every time and never say anything
    /// about the week (measured on live data, 2026-08-04: a 11% session outranked every weekly pool
    /// in the fleet). A session-only fleet still gets an answer, matching `displayPools`' own
    /// fallback: that is then the only budget it has.
    static func tightest(_ pools: [FleetPool]) -> Tightest? {
        let weeklyCycle = pools.filter { $0.kind != .session }
        return worst(in: weeklyCycle.isEmpty ? pools : weeklyCycle)
    }

    /// The lowest member of these pools, or nil when there are none. Pools with no members cannot
    /// occur (`FleetMath` only pools a window two or more accounts share), but an empty list still
    /// answers nil rather than trapping.
    private static func worst(in pools: [FleetPool]) -> Tightest? {
        var worst: Tightest?
        for pool in pools where !pool.members.isEmpty {
            let member = pool.minMember
            guard member.remaining < (worst?.remaining ?? .infinity) else { continue }
            worst = Tightest(poolKind: pool.kind, poolLabel: pool.label,
                             modelName: pool.modelName, accountLabel: member.accountLabel,
                             remaining: member.remaining)
        }
        return worst
    }
}
