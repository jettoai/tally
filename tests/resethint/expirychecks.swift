import Foundation

// Expiry stages per credit (design matrix, 2026-09-23), called from main.swift, whose helpers
// (`account`, `credit`, `hint`, `hintAt`, `refused`, `expect`) and clock these use.

func runExpiryChecks() {
    let h40 = now.addingTimeInterval(40 * 3_600)

    // M1. 72 hours out is not news yet, however full or empty the account.
    do {
        let (_, note) = hint([account("a", remaining: 60, expiry: now.addingTimeInterval(72 * 3_600))])
        expect(note == nil, "M1 a credit 72h from expiry does not hint")
    }

    // M2/M3. Inside 48h the hint fires at any remaining; the value line is what changes.
    do {
        let (_, low) = hint([account("a", remaining: 20, expiry: h40)])
        expect(low?.reason == .expiryEarly, "M2 40h out on a 20% account hints early")
        expect(ResetHintLogic.value(remaining: 20, expiresAt: h40, bindingResetsAt: cycle1) == .recovers,
               "M2 at 20% left the body says redeeming recovers")
        let (_, full) = hint([account("a", remaining: 60, expiry: h40)])
        expect(full?.reason == .expiryEarly, "M3 40h out on a 60% account still hints")
        expect(ResetHintLogic.value(remaining: 60, expiresAt: h40, bindingResetsAt: cycle1) == .lostUnused,
               "M3 with no refill before expiry the body says it is lost unused")
    }

    // M4/M5. A refill 3h away, before the expiry: early now, pre-refill at refill minus 2h, nothing
    // after the refill, final inside 6h.
    do {
        let refill = now.addingTimeInterval(3 * 3_600)
        let accounts = [account("a", remaining: 60, expiry: h40, resetsAt: refill)]
        let (s1, first) = hint(accounts)
        expect(first?.reason == .expiryEarly, "M4 early fires first")
        let (s2, second) = hintAt(now.addingTimeInterval(1 * 3_600 + 60), accounts, state: s1)
        expect(second?.reason == .expiryPreReset, "M4 pre-refill fires 2h before the refill")
        expect(ResetHintLogic.value(remaining: 60, expiresAt: h40, bindingResetsAt: refill)
               == .refillsFirst(refill), "M4 its body names the refill")
        let (s3, again) = hintAt(now.addingTimeInterval(1 * 3_600 + 120), accounts, state: s2)
        expect(again == nil, "M4 pre-refill fires once")
        let refilled = [account("a", remaining: 100, expiry: h40, resetsAt: cycle2)]
        let (s4, afterRefill) = hintAt(now.addingTimeInterval(10 * 3_600), refilled, state: s3)
        expect(afterRefill == nil, "M5 a refill does not re-arm early")
        let (_, final) = hintAt(h40.addingTimeInterval(-5 * 3_600), refilled, state: s4)
        expect(final?.reason == .expiryFinal, "M5 inside 6h the final stage fires")
    }

    // M6/M7. The final stage: 5h left, and past the stated expiry while still listed.
    do {
        let (_, five) = hint([account("a", remaining: 90, expiry: now.addingTimeInterval(5 * 3_600))])
        expect(five?.reason == .expiryFinal, "M6 5h left hints final")
        let (state, late) = hint([account("a", remaining: 50, expiry: now.addingTimeInterval(-3_600))])
        expect(late?.reason == .expiryFinal, "M7 past its expiry is final")
        let (_, early) = hint([account("a", remaining: 50, expiry: now.addingTimeInterval(-3_600))],
                              state: state)
        expect(early == nil, "M7 an earlier stage never follows a later one")
    }

    // M8/M9. An undated credit never hints on expiry, and the account says its expiry is unknown.
    do {
        let undated = account("a", remaining: 20, credits: 1, list: [credit("u", nil)])
        let (_, note) = hint([undated])
        expect(note == nil, "M8 an undated credit does not hint")
        expect(undated.resetCreditsExpiryUnknown, "M8 the account reports expiry unknown")
        expect(undated.resetCreditsNextExpiry == nil, "M8 and no date is invented")
        let mixed = account("a", remaining: 60, credits: 2, list: [credit("d", h40), credit("u", nil)])
        let (_, dated) = hint([mixed])
        expect(dated?.reason == .expiryEarly && dated?.creditKey == "d", "M9 the dated credit still hints")
        expect(mixed.resetCreditsExpiryUnknown && mixed.resetCreditsNextExpiry == h40,
               "M9 the account keeps both the date and the unknown")
        let short = account("a", remaining: 60, credits: 2, list: [credit("d", h40)])
        expect(short.resetCreditsExpiryUnknown, "M9 a count larger than the dated list is unknown too")
    }

    // M10. Nothing banked: no drained, no expiry.
    do {
        let (_, note) = hint([account("a", remaining: 3, credits: 0, list: [])])
        expect(note == nil, "M10 zero banked never hints")
    }

    // M14/M15. Dedup per credit, across rounds and across a restart (encode, decode).
    do {
        let (s1, first) = hint([account("a", remaining: 60, expiry: h40)])
        let (_, second) = hintAt(now.addingTimeInterval(3_600), [account("a", remaining: 60, expiry: h40)],
                                 state: s1)
        expect(first?.reason == .expiryEarly && second == nil, "M14 one early hint per credit")
        let data = try? JSONEncoder().encode(s1)
        let restored = data.flatMap { try? JSONDecoder().decode(ResetHintState.self, from: $0) }
        let (_, afterRestart) = hintAt(now.addingTimeInterval(3_600),
                                       [account("a", remaining: 60, expiry: h40)],
                                       state: restored ?? ResetHintState())
        expect(restored != nil && afterRestart == nil, "M15 a restart does not repeat it")
    }

    // M16. An older payload that still carries the dropped keys decodes.
    do {
        let legacy = Data("""
        {"accounts":{"x":{"firedDrained":true,"firedExpiring":true,"rearmedExpiring":true,"cycleKey":"1"}}}
        """.utf8)
        let entry = (try? JSONDecoder().decode(ResetHintState.self, from: legacy))?.accounts["x"]
        expect(entry?.firedDrained == true, "M16 legacy payload with firedExpiring decodes")
    }

    // M17/M18. A failed read keeps the credit memory; a successful read without the credit prunes it.
    do {
        let (s1, _) = hint([account("a", remaining: 60, expiry: h40)])
        let (s2, _) = hint([account("a", remaining: 60, expiry: h40, error: "read failed")], state: s1)
        expect(s2.accounts["a"]?.expiryStages["c1"] == ["expiryEarly"], "M17 a failed read keeps it")
        let (s3, _) = hint([account("a", remaining: 100, credits: 0, list: [])], state: s2)
        expect(s3.accounts["a"]?.expiryStages["c1"] == nil, "M18 a redeemed credit's memory is pruned")
    }

    // M19. A credit with no id is keyed by its expiry.
    do {
        let (state, note) = hint([account("a", remaining: 60, credits: 1, list: [credit(nil, h40)])])
        let key = "exp:\(Int(h40.timeIntervalSince1970))"
        expect(note?.creditKey == key && state.accounts["a"]?.expiryStages[key] != nil,
               "M19 an id-less credit dedups on its expiry")
    }

    // M20. A refused expiry hint is retried once per credit and stage, then stays told.
    do {
        let accounts = [account("a", remaining: 60, expiry: h40)]
        let (told, first) = hint(accounts)
        let (toldAgain, second) = hint(accounts, state: refused(told, first))
        expect(second?.reason == .expiryEarly, "M20 a refused early hint is retried")
        let (_, third) = hint(accounts, state: refused(toldAgain, second))
        expect(third == nil, "M20 only once")
    }

    // M21. Several accounts in one round: one hint, the emptiest first; on a tie the later stage.
    do {
        let pair = [account("a", remaining: 5, expiry: far), account("b", remaining: 60, expiry: h40)]
        let (s1, first) = hint(pair)
        let (_, second) = hint(pair, state: s1)
        expect(first?.accountID == "a" && second?.accountID == "b", "M21 emptiest first, other next")
        let tie = [account("a", remaining: 20, expiry: h40),
                   account("b", remaining: 20, expiry: now.addingTimeInterval(5 * 3_600))]
        let (_, pick) = hint(tie)
        expect(pick?.accountID == "b" && pick?.reason == .expiryFinal, "M21 a tie goes to the later stage")
    }

    // M22. Iron rule 2: a window's reset is never a credit's expiry.
    do {
        let (_, note) = hint([account("a", remaining: 60, credits: 1,
                                      resetsAt: now.addingTimeInterval(10 * 3_600),
                                      list: [credit("u", nil)])])
        expect(note == nil, "M22 an undated credit never hints final off the window's reset")
    }

    // M23. What the redeem confirmation advises (the dialog's branches, decided here).
    do {
        let refill = now.addingTimeInterval(3 * 86_400)
        let far10 = now.addingTimeInterval(10 * 86_400)
        expect(ResetHintLogic.redeemTiming(account("a", remaining: 20, expiry: far10), now: now) == .worthIt,
               "M23 little left: worth it")
        expect(ResetHintLogic.redeemTiming(account("a", remaining: 60, expiry: far10, resetsAt: refill),
                                           now: now) == .waitForRefill(refill),
               "M23 plenty left and a refill first: wait")
        expect(ResetHintLogic.redeemTiming(account("a", remaining: 60, expiry: h40, resetsAt: refill),
                                           now: now) == .useOrLose(h40),
               "M23 plenty left, no refill before expiry: use or lose")
        expect(ResetHintLogic.redeemTiming(account("a", remaining: 60, credits: 1,
                                                   list: [credit("u", nil)]), now: now) == .expiryUnknown,
               "M23 plenty left, undated: expiry unknown")
    }
}
