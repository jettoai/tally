import Foundation

// The clearance lane (B-1360, TallyCLI/AccountComfort.swift): a LAUNCH may take an account whose
// only dry windows are weekly-cycle ones resetting within a day, because those leftovers are about to
// be lost; every move of a live conversation still refuses it. Every cell goes through the public
// picks only, so the same file replays against a tree that predates the lane.
func runClearanceChecks() {
    // The 2026-10-09T15:33Z snapshot, seven accounts (b1360 findings section 1). albert has 3% of its
    // week left 18.4h before the reset; albert4 is the comfortable leader at 1.006 %/h; hyde is the
    // personal account holding 30 back.
    let hyde = account("hyde", session: (100, inHours(3.4)), weekly: (70, inHours(145.4)))
    let dorothy = account("Dorothy", session: (100, nil), weekly: (0, nil))
    let albert = account("albert", session: (99, inHours(0.4)), weekly: (3, inHours(18.4)))
    let albert2 = account("albert2", session: (100, nil), weekly: (5, inHours(121.4)))
    let six = account("666", session: (100, nil), weekly: (0, nil))
    let albert3 = account("albert3", session: (0, inHours(0.1)), weekly: (12, inHours(122.4)))
    let albert4 = account("albert4", session: (89, inHours(3.9)), weekly: (97, inHours(96.4)))
    let fleet = [hyde, dorothy, albert, albert2, six, albert3, albert4]
    let reserves = AccountReserves(settings: [
        "/tmp/hyde": AccountRoleSetting(role: AccountRoles.personal, reserve: 30)])
    func launch(_ accounts: [Snapshot.Account]) -> String? {
        launchPick(providerID: "claude",
                   in: Snapshot(version: 2, generatedAt: now, accounts: accounts),
                   primaryModel: nil, quarantined: [], reserves: reserves, now: now)?.id
    }

    // A1: the failure sample. Before the lane this was albert4 and albert's 3% vanished at the reset.
    check("A1 the 2026-10-09 launch spends albert's 3% before its weekly reset", launch(fleet) == "albert")
    check("A1 premise: the ranking alone still picks albert4",
          best(providerID: "claude", in: Snapshot(version: 2, generatedAt: now, accounts: fleet),
               reserves: reserves, now: now)?.id == "albert4")
    check("a quarantined clearance account is not launched on",
          launchPick(providerID: "claude",
                     in: Snapshot(version: 2, generatedAt: now, accounts: fleet),
                     primaryModel: nil, quarantined: ["albert"], reserves: reserves, now: now)?.id
              == "albert4")

    // A3: a reset 30h out is not about to be lost; the leftovers will still be there tomorrow.
    let farReset = account("albert", session: (99, inHours(0.4)), weekly: (3, inHours(30)))
    check("A3 3% resetting in 30 hours is not cleared", launch([farReset, albert4]) == "albert4")
    check("the horizon edge: exactly 24 hours still clears",
          launch([account("albert", weekly: (3, inHours(24))), albert4]) == "albert")

    // A4: a dry SESSION window is a wall minutes away, not leftovers.
    let drySession = account("albert", session: (2, inHours(2)), weekly: (50, inHours(18)))
    check("A4 a dry 5h window is never cleared", launch([drySession, albert4]) == "albert4")
    let bothDry = account("albert", session: (2, inHours(2)), weekly: (3, inHours(18)))
    check("a dry weekly window does not excuse a dry 5h one", launch([bothDry, albert4]) == "albert4")

    // A5: nothing left is nothing to clear.
    check("A5 a spent weekly window is not cleared",
          launch([account("albert", weekly: (0, inHours(18))), albert4]) == "albert4")

    // A6: a reserve that eats the remainder leaves nothing that is Tally's to clear.
    let reservedDry = account("hyde", session: (100, nil), weekly: (3, inHours(18)))
    check("A6 3% held back by a 3-point reserve is not cleared",
          launchPick(providerID: "claude",
                     in: Snapshot(version: 2, generatedAt: now, accounts: [reservedDry, albert4]),
                     primaryModel: nil, quarantined: [],
                     reserves: AccountReserves(settings: [
                         "/tmp/hyde": AccountRoleSetting(role: AccountRoles.personal, reserve: 3)]),
                     now: now)?.id == "albert4")

    // A7: several clearance accounts: the most leftovers first, then the earlier reset.
    let three = account("X", weekly: (3, inHours(18)))
    let four = account("Y", weekly: (4, inHours(20)))
    let threeSooner = account("Z", weekly: (3, inHours(10)))
    check("A7 the clearance account with more left goes first", launch([three, four, albert4]) == "Y")
    check("A7 on a tie the earlier reset goes first", launch([three, threeSooner, albert4]) == "Z")

    // A8/A9: every move of a LIVE conversation still refuses the account (the lane is launch-only).
    check("A8 the cap handoff does not move a conversation onto albert",
          capHandoffTarget(fleet.filter { $0.id != "albert4" }, primaryModel: nil,
                           reserves: reserves, now: now)?.id != "albert"
              && capHandoffTarget(fleet, primaryModel: nil, reserves: reserves, now: now)?.id
                  == "albert4")
    let snapshot = Snapshot(version: 2, generatedAt: now, accounts: fleet)
    check("A9 the follow re-pick does not move a conversation onto albert",
          incumbentSeededBest(providerID: "claude", in: snapshot, incumbentID: "hyde",
                              primaryModel: nil, reserves: reserves, now: now)?.id != "albert"
              && incumbentSeededBest(providerID: "claude", in: snapshot, incumbentID: "gone",
                                     primaryModel: nil, reserves: reserves, now: now)?.id
                  == "albert4")
}
