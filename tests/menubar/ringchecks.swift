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

    // Colour: the panel bar's own ramp, green from 50% left, amber from 20%, red below. 50 and 20
    // themselves sit on the calmer side; 0% is red with an empty arc.
    func ringOf(_ left: Double) -> PoolRing { ring(100 - left) }
    expect(ring(40) == PoolRing(fraction: 0.6, severity: .normal, isFaded: false),
           "plenty left: green, arc = remaining")
    expect(ringOf(100).severity == .normal && ringOf(100).fraction == 1, "full: green, closed ring")
    expect(ringOf(70).severity == .normal, "70% left: green")
    expect(ringOf(50).severity == .normal && ringOf(49).severity == .warning,
           "exactly 50% left stays green, 49% is amber")
    expect(ringOf(40).severity == .warning && ringOf(40).fraction == 0.4, "40% left: amber")
    expect(ringOf(20).severity == .warning && ringOf(19).severity == .critical,
           "exactly 20% left stays amber, 19% is red")
    expect(ringOf(15).severity == .critical && ringOf(15).fraction == 0.15, "15% left: red")
    expect(ringOf(0).severity == .critical && ringOf(0).fraction == 0, "0% left is red with nothing but the track")
    expect(ring(120).fraction == 0, "a pool reported over 100% used clamps to an empty arc")

    // The ring wears what the bar wears: the metric's own severity, the provider's word over a threshold.
    for left in [100.0, 70, 50, 49, 40, 20, 19, 15, 0] {
        let m = metric(.weeklyAll, used: 100 - left)
        expect(PoolRing(perAccount([account("p", metrics: [m])], focus: weeklyFocus)[0]).severity == m.severity,
               "ring severity is the bar's (metric.severity) at \(Int(left))% left")
    }
    let told = metric(.weeklyAll, used: 30, severity: .critical)
    expect(PoolRing(perAccount([account("t", metrics: [told])], focus: weeklyFocus)[0]).severity == .critical,
           "a severity the provider reported wins over the local threshold, as on the bar")
    expect(PoolRing(perAccount([account("u", metrics: [metric(.weeklyAll, used: 30, severity: .unknown)])],
                               focus: weeklyFocus)[0]).severity == .unknown,
           "no severity to show leaves the ring ink")

    // Used mode: the ring is still drawn as what is LEFT, and so is the colour.
    expect(one(40, mode: .used).lines == ["40%"] && one(40, mode: .used).remaining == 60
           && ring(40, mode: .used) == ring(40), "Used mode: the line prints 40% used, the ring is still 60% long")
    expect(ring(85, mode: .used).severity == .critical && ring(70, mode: .used).severity == .warning
           && ring(30, mode: .used).severity == .normal, "Used mode: colour follows what is left")

    // Stale: last known length and colour, faded.
    expect(ring(40, stale: true) == PoolRing(fraction: 0.6, severity: .normal, isFaded: true),
           "stale: last-known arc and colour at 40% opacity")
    expect(ring(90, stale: true).severity == .critical && ring(90, stale: true).isFaded, "stale and low: red and faded")

    // Offline / unreadable: dashed empty ring, no length, no colour.
    let offline = PoolRing(fraction: nil, severity: .unknown, isFaded: true)
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
           "a held-over window past its reset is unknown, not the old arc or colour")

    // Pooled layout: the ring reads the pool's average, in either mode, coloured as the fleet gauge's bar.
    let pair = [account("a", metrics: [metric(.weeklyAll, used: 70)]),
                account("b", metrics: [metric(.weeklyAll, used: 90)])]
    expect(pooled(pair)[0].remaining == 20 && pooled(pair, mode: .used)[0].remaining == 20
           && PoolRing(pooled(pair)[0]).severity == .warning, "pooled: average of 30 and 10 left is 20, amber")
    let low = [account("a", metrics: [metric(.weeklyAll, used: 80)]),
               account("b", metrics: [metric(.weeklyAll, used: 90)])]
    expect(PoolRing(pooled(low)[0]).severity == .critical && PoolRing(pooled(low, mode: .used)[0]).severity == .critical,
           "pooled: 15% left is red in both modes")
    let rich = [account("a", metrics: [metric(.weeklyAll, used: 20)]),
                account("b", metrics: [metric(.weeklyAll, used: 40)])]
    expect(PoolRing(pooled(rich)[0]).severity == .normal, "pooled: 70% left on average is green")
    expect(PoolRing(pooled(pair + [account("s", metrics: [metric(.weeklyAll, used: 10)],
                                           error: "boom", stale: true)])[0]).isFaded,
           "pooled: a stale member fades the pool")

    // The optional inner ring (5-hour window): same rules as the weekly ring, read from the same builders.
    let both = account("b", metrics: [metric(.session, used: 85), metric(.weeklyAll, used: 40)])
    let innerSeg = perAccount([both], focus: weeklyFocus)[0]
    let innerRing = PoolRing(innerSeg)
    expect(innerSeg.sessionRemaining == 15 && innerRing.innerFraction == 0.15
           && innerRing.innerSeverity == .critical && innerRing.fraction == 0.6 && innerRing.severity == .normal,
           "per account: the inner ring is the session window (15% left, red) beside the weekly (60%, green)")
    let weeklyOnly = PoolRing(one(40))
    expect(weeklyOnly.innerFraction == nil && weeklyOnly.innerSeverity == .unknown && weeklyOnly.fraction == 0.6,
           "no session window: no inner figure (dashed inner track), weekly untouched")
    let heldSession = AccountUsage(id: "claude:held2", providerID: "claude", accountLabel: "held2",
                                   metrics: [metric(.session, used: 60, resetIn: -70 * 60),
                                             metric(.weeklyAll, used: 10)],
                                   refreshedAt: now.addingTimeInterval(-84 * 60), isStale: true)
    let heldRing = PoolRing(MenuBarSegments.perAccount([heldSession], mode: .remaining, focusedModel: weeklyFocus,
                                                       now: now)[0])
    expect(heldRing.innerFraction == nil && heldRing.fraction == 0.9,
           "a session window past its reset is unreadable (no inner arc) while the weekly still reads")
    let sessionPair = [account("a", metrics: [metric(.session, used: 70), metric(.weeklyAll, used: 10)]),
                       account("b", metrics: [metric(.session, used: 90), metric(.weeklyAll, used: 10)])]
    let pooledRing = PoolRing(pooled(sessionPair)[0])
    expect(pooledRing.innerFraction == 0.2 && pooledRing.innerSeverity == .warning && pooledRing.fraction == 0.9,
           "pooled: the inner ring is the session pool's average (20% left, amber)")
    expect(PoolRing(pooled([failed])[0]).innerFraction == nil && PoolRing(perAccount([failed])[0]).innerFraction == nil,
           "an error or an empty pool has no inner figure either")
    expect(PoolRing(fraction: 0.6, severity: .warning, isFaded: false, innerFraction: 0.1, innerSeverity: .critical)
           != PoolRing(fraction: 0.6, severity: .warning, isFaded: false),
           "the inner figure takes part in the ring's equality")

    // The waiting dot is not a ring state: it rides on the face, which already reapplies when the
    // count changes (statusFaceChecks), so it disappears with the session. No segments, no rings.
    expect(pooled([]).isEmpty && perAccount([]).isEmpty, "no pool to show: no segments, the fallback glyph")
}
