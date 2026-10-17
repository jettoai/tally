import Foundation

// A held-over figure its reset has overtaken reads as "?" on the strip, never as the old
// percentage (HeldOverReset.swift); the same account read fresh keeps its numbers.
func resetPassedStripChecks() {
    var held = AccountUsage(id: "claude:held", providerID: "claude", accountLabel: "held",
                            metrics: [metric(.session, used: 100, resetIn: -70 * 60),
                                      metric(.weeklyAll, used: 60, resetIn: 3 * 86_400)],
                            refreshedAt: now.addingTimeInterval(-84 * 60), isStale: true)
    held.lastRefreshFailed = true
    let segment = MenuBarSegments.perAccount([held], mode: .remaining, focusedModel: weeklyFocus,
                                             now: now).first
    expect(segment?.lines == ["?", "40%"] && segment?.dimmed == true,
           "a held-over window past its reset reads as ? on the strip")
    var fresh = held
    fresh.isStale = false
    fresh.lastRefreshFailed = false
    expect(MenuBarSegments.perAccount([fresh], mode: .remaining, focusedModel: weeklyFocus,
                                      now: now).first?.lines == ["0%", "40%"],
           "the same reading with no failed poll keeps its numbers, even past the reset")
}

// The pooled layout answers the same question per pool: any member whose held-over reading of a
// window its reset has overtaken makes that ring unknown (nil) and its line "?", never an average
// over a figure that is no longer true.
func resetPassedPooledChecks() {
    func heldOver(_ id: String, sessionResetIn: TimeInterval, weeklyResetIn: TimeInterval) -> AccountUsage {
        var a = AccountUsage(id: id, providerID: "claude", accountLabel: id,
                             metrics: [metric(.session, used: 100, resetIn: sessionResetIn),
                                       metric(.weeklyAll, used: 60, resetIn: weeklyResetIn)],
                             refreshedAt: now.addingTimeInterval(-84 * 60), isStale: true)
        a.lastRefreshFailed = true
        return a
    }
    let held = heldOver("held", sessionResetIn: -70 * 60, weeklyResetIn: 3 * 86_400)
    let single = pooled([held], focus: weeklyFocus).first
    expect(single?.sessionRemaining == nil && single?.sessionSeverity == .unknown
           && single?.lines == ["?", "40%"] && single?.remaining == 40,
           "pooled: a single held-over account past its session reset has an unknown inner ring")

    let fresh = account("fresh", metrics: [metric(.session, used: 20, resetIn: 3600),
                                           metric(.weeklyAll, used: 50, resetIn: 3 * 86_400)])
    let mixed = pooled([fresh, held], focus: weeklyFocus).first
    expect(mixed?.sessionRemaining == nil && mixed?.lines.first == "?" && mixed?.remaining != nil,
           "pooled: one held-over member makes the whole inner ring unknown")

    let weeklyHeld = heldOver("weekly", sessionResetIn: 3600, weeklyResetIn: -60 * 60)
    let outer = pooled([weeklyHeld], focus: weeklyFocus).first
    expect(outer?.remaining == nil && outer?.severity == .unknown && outer?.lines.last == "?"
           && outer?.sessionRemaining != nil,
           "pooled: a held-over weekly window past its reset has an unknown outer ring")

    var landed = held
    landed.isStale = false
    landed.lastRefreshFailed = false
    expect(pooled([landed], focus: weeklyFocus).first?.sessionRemaining == 0
           && perAccount([landed], focus: weeklyFocus).first?.sessionRemaining == 0,
           "pooled: the same reading with no failed poll keeps its value, as per-account does")
}
