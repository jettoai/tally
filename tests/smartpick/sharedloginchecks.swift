import Foundation

// Two config homes signed into ONE Claude account (jettoai/tally#6), CLI side. Fixture: the issue's
// AM and GM. The app publishes the duplicate (AM, re-signed into GM's account) with an error, no
// launch home, no numbers and `sameAccountAs` = GM; the twin cells for the panel are in
// tests/integrations/sharedloginbadgechecks.swift.
func sharedLoginDuplicate(_ id: String, of kept: String) -> Snapshot.Account {
    var row = account(id)
    row.launchHome = nil
    row.error = "\(id) and \(kept) are signed into the same Claude account"
    row.sameAccountAs = kept
    return row
}

func runSharedLoginChecks() {
    let saved = clearanceSessionCounter
    defer { clearanceSessionCounter = saved }
    clearanceSessionCounter = { _ in 0 }
    let gm = account("GM", session: (100, nil), weekly: (98, inHours(150)))
    let amBefore = account("AM", session: (100, nil), weekly: (99, inHours(150)))
    let am = sharedLoginDuplicate("AM", of: "GM")
    func snap(_ accounts: [Snapshot.Account]) -> Snapshot {
        Snapshot(version: 2, generatedAt: now, accounts: accounts)
    }
    func launch(_ accounts: [Snapshot.Account]) -> String? {
        launchPick(providerID: "claude", in: snap(accounts), primaryModel: nil, quarantined: [],
                   now: now)?.id
    }
    check("P0 premise (the issue): published as its own account, AM is a fresh launch target",
          launch([amBefore, gm]) == "AM")
    check("P1 published as GM's duplicate, AM is never picked", launch([am, gm]) == "GM")
    check("P1 …nor for a new conversation",
          launchPick(providerID: "claude", in: snap([am, gm]), primaryModel: nil, quarantined: [],
                     emptyConversation: true, now: now)?.id == "GM")
    check("P2 `tally account AM` finds no account to move to",
          accountMatching("AM", provider: "claude", in: snap([am, gm])) == .none)
    check("P3 a pin on AM stops steering (falls back to the pick)",
          pinnedLaunchHome(snap([am, gm]), policy: LaunchPolicy(mode: "manual", pinnedAccountID: "AM"))
              == nil)

    // The load gate (#4) counts a login's sessions, not a home's: AM's two run on GM's quota.
    let thinGM = account("GM", session: (100, nil), weekly: (7, inHours(3.47)))
    let healthy = account("X", session: (100, nil), weekly: (100, inHours(150)))
    let fleet = [am, thinGM, healthy]
    func counted(_ count: @escaping (String) -> Int?) -> (String) -> Int {
        { id in sessionsOnLogin(id, in: fleet, count: count) }
    }
    clearanceSessionCounter = { _ in 0 }
    check("P4 premise: an empty thin GM takes the launch", launch(fleet) == "GM")
    clearanceSessionCounter = { ["AM": 2][$0] ?? 0 }
    check("P4 premise: counted per home, GM reads 0 and still takes it (the #6 gap)", launch(fleet) == "GM")
    clearanceSessionCounter = counted { ["AM": 2][$0] ?? 0 }
    check("P4 two sessions in AM's home count on GM: the launch goes to X", launch(fleet) == "X")
    check("P4 …the count itself", sessionsOnLogin("GM", in: fleet) { ["AM": 2, "GM": 1][$0] } == 3)
    clearanceSessionCounter = counted { $0 == "AM" ? nil : 0 }
    check("P4b AM's count unknown: GM reads full", launch(fleet) == "X")
    check("P4b …the count itself",
          sessionsOnLogin("GM", in: fleet) { $0 == "AM" ? nil : 0 } == clearanceMaxSessions)
    let three = [account("A"), sharedLoginDuplicate("B", of: "A"), sharedLoginDuplicate("C", of: "A")]
    check("P5 three homes on A's login: A counts all three",
          sessionsOnLogin("A", in: three) { ["A": 1, "B": 2, "C": 3][$0] } == 6)
    check("P5 …and a duplicate counts only itself (never asked: it is not a candidate)",
          sessionsOnLogin("B", in: three) { ["A": 1, "B": 2, "C": 3][$0] } == 2)
    check("P6 no duplicates: the count is the account's own",
          sessionsOnLogin("X", in: fleet) { ["X": 1][$0] } == 1)

    check("A1 the advisor's live set leaves the duplicate out",
          advisorLiveAccounts(snap([am, gm, healthy])) == ["GM", "X"])
    check("A1 …and keeps every account when there is none",
          advisorLiveAccounts(snap([amBefore, gm])) == ["AM", "GM"])
}
