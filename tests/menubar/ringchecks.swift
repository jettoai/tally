import Foundation

// The menu bar ring's state table (B-2045): one assertion per row, through the real segment
// builders so the figure the ring reads is the one the strip derives, in both layouts.
func poolRingChecks() {
    func one(_ weeklyUsed: Double, mode: DisplayMode = .remaining, stale: Bool = false,
             resetIn: TimeInterval = 3 * 86_400) -> MenuBarSegment {
        perAccount([account("r", metrics: [metric(.weeklyAll, used: weeklyUsed, resetIn: resetIn)],
                            error: stale ? "boom" : nil, stale: stale)], mode: mode, focus: weeklyFocus)[0]
    }
    func ring(_ used: Double, mode: DisplayMode = .remaining, stale: Bool = false) -> PoolRing {
        PoolRing(one(used, mode: mode, stale: stale))
    }

    // Normal, red below 20 only, 20 itself ink, 0 red with an empty arc.
    expect(ring(40) == PoolRing(fraction: 0.6, isLow: false, isFaded: false), "plenty left: ink, arc = remaining")
    expect(ring(81).isLow && ring(81).fraction == 0.19, "19% left is red")
    expect(!ring(80).isLow && ring(80).fraction == 0.2, "exactly 20% left stays ink (red is below 20)")
    expect(ring(100).isLow && ring(100).fraction == 0, "0% left is red with nothing but the track")
    expect(ring(120).fraction == 0, "a pool reported over 100% used clamps to an empty arc")

    // Used mode: the ring is still drawn as what is LEFT, and so is the red test.
    expect(one(40, mode: .used).lines == ["40%"] && one(40, mode: .used).remaining == 60
           && ring(40, mode: .used) == ring(40), "Used mode: the line prints 40% used, the ring is still 60% long")
    expect(ring(85, mode: .used).isLow && !ring(70, mode: .used).isLow, "Used mode: red follows what is left")

    // Stale: last known length, faded; low stays red.
    expect(ring(40, stale: true) == PoolRing(fraction: 0.6, isLow: false, isFaded: true),
           "stale: last-known arc at 40% opacity")
    expect(ring(90, stale: true).isLow && ring(90, stale: true).isFaded, "stale and low: red and faded")

    // Offline / unreadable: dashed empty ring, no length, never red.
    let offline = PoolRing(fraction: nil, isLow: false, isFaded: true)
    let failed = account("e", metrics: [], error: "boom")
    expect(perAccount([failed])[0].remaining == nil && PoolRing(perAccount([failed])[0]) == offline,
           "per-account error: dashed ring")
    expect(PoolRing(pooled([failed])[0]) == offline, "pooled, every member failed: dashed ring")
    expect(PoolRing(pooled([account("n", metrics: [])])[0]) == offline, "pooled, nothing to pool: dashed ring")
    var heldPassed = AccountUsage(id: "claude:held", providerID: "claude", accountLabel: "held",
                                  metrics: [metric(.weeklyAll, used: 60, resetIn: -70 * 60)],
                                  refreshedAt: now.addingTimeInterval(-84 * 60), isStale: true)
    heldPassed.lastRefreshFailed = true
    expect(PoolRing(MenuBarSegments.perAccount([heldPassed], mode: .remaining, focusedModel: weeklyFocus,
                                               now: now)[0]) == offline,
           "a held-over window past its reset is unknown, not the old arc")

    // Pooled layout: the ring reads the pool's average, in either mode.
    let pair = [account("a", metrics: [metric(.weeklyAll, used: 70)]),
                account("b", metrics: [metric(.weeklyAll, used: 90)])]
    expect(pooled(pair)[0].remaining == 20 && pooled(pair, mode: .used)[0].remaining == 20
           && !PoolRing(pooled(pair)[0]).isLow, "pooled: average of 30 and 10 left is 20, ink")
    let low = [account("a", metrics: [metric(.weeklyAll, used: 80)]),
               account("b", metrics: [metric(.weeklyAll, used: 90)])]
    expect(PoolRing(pooled(low)[0]).isLow && PoolRing(pooled(low, mode: .used)[0]).isLow,
           "pooled: 15% left is red in both modes")
    expect(PoolRing(pooled(pair + [account("s", metrics: [metric(.weeklyAll, used: 10)],
                                           error: "boom", stale: true)])[0]).isFaded,
           "pooled: a stale member fades the pool")

    // The waiting dot is not a ring state: it rides on the face, which already reapplies when the
    // count changes (statusFaceChecks), so it disappears with the session. No segments, no rings.
    expect(pooled([]).isEmpty && perAccount([]).isEmpty, "no pool to show: no segments, the fallback glyph")
}
