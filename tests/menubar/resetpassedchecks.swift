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
