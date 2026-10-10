import Foundation

// The launch-side load gate (jettoai/tally#4): a THIN account (binding window at or under the
// runway line, `quotaKnockPercent`) that already carries `clearanceMaxSessions` live conversations
// takes no new launch while a sibling can. Fixture: the 2026-10-10T12:32Z `tally status` in #4.
func runLoadChecks() {
    let saved = clearanceSessionCounter
    defer { clearanceSessionCounter = saved }
    let am = account("AM", session: (100, nil), weekly: (100, inHours(152.47)))
    let fp = account("FP", session: (100, nil), weekly: (7, inHours(16.45)))
    let fs = account("FS", session: (100, nil), weekly: (7, inHours(3.47)))
    let gm = account("GM", session: (100, nil), weekly: (100, inHours(152.47)))
    let fleet = [am, fp, fs, gm]
    let issueLoad: [String: Int] = ["FS": 9, "FP": 6]
    func launch(_ accounts: [Snapshot.Account], _ load: [String: Int]?,
                empty: Bool = false) -> String? {
        clearanceSessionCounter = load.map { counts in { counts[$0] ?? 0 } }
        return launchPick(providerID: "claude",
                          in: Snapshot(version: 2, generatedAt: now, accounts: accounts),
                          primaryModel: nil, quarantined: [], emptyConversation: empty,
                          now: now)?.id
    }
    check("L0 premise: with no live sessions the ranking still spends FS's dying 7%",
          launch(fleet, [:]) == "FS")
    check("L1 #4: FS carrying 9 sessions on 7% takes no new launch", launch(fleet, issueLoad) == "AM")
    check("L1 …nor does a new conversation", launch(fleet, issueLoad, empty: true) == "AM")
    check("L2 a thin account with one live session still takes the launch",
          launch(fleet, ["FS": 1]) == "FS")
    check("L3 …two is the cap", launch(fleet, ["FS": 2]) == "AM")
    check("L4 an unknown count is full", launch(fleet, nil) == "AM")
    clearanceSessionCounter = { _ in clearanceMaxSessions }
    check("L4 …and so is the wiring's unknown (nil read as clearanceMaxSessions)",
          launchPick(providerID: "claude",
                     in: Snapshot(version: 2, generatedAt: now, accounts: fleet),
                     primaryModel: nil, quarantined: [], now: now)?.id == "AM")
    check("L5 every account thin and crowded: the field is kept whole and ranked",
          launch([fp, fs], issueLoad) == "FS")
    check("L6 one account only: it is launched on however crowded", launch([fs], issueLoad) == "FS")
    let dying = account("X", session: (100, nil), weekly: (40, inHours(24)))
    check("L7 a crowded account above the runway line is never avoided",
          launch([am, dying, gm], ["X": 5, "AM": 9]) == "X")
    let refilling = account("FS", session: (100, nil), weekly: (7, inHours(0.08)))
    check("L8 a window refilling inside the grace is not thin",
          launch([am, refilling, gm], issueLoad) == "FS")
    let shortSession = account("S", session: (10, inHours(2)), weekly: (80, inHours(100)))
    let steady = account("T", session: (100, nil), weekly: (60, inHours(100)))
    check("L9 premise: the 5h-thin account outranks its sibling", launch([shortSession, steady], [:]) == "S")
    check("L9 three sessions on 10% of a 5h window send the launch to the sibling",
          launch([shortSession, steady], ["S": 3]) == "T")
    let clear = account("C", session: (100, nil), weekly: (3, inHours(18)))
    check("L10 the clearance lane still comes first for a new conversation",
          launch(fleet + [clear], issueLoad, empty: true) == "C")
    clearanceSessionCounter = { issueLoad[$0] ?? 0 }
    let snapshot = Snapshot(version: 2, generatedAt: now, accounts: fleet)
    check("L11 the follow re-pick keeps a session on its incumbent FS (not an evacuation)",
          incumbentSeededBest(providerID: "claude", in: snapshot, incumbentID: "FS",
                              primaryModel: nil, now: now)?.id == "FS")
    check("L11 …but its fallback to best (incumbent gone) avoids the pile",
          incumbentSeededBest(providerID: "claude", in: snapshot, incumbentID: "gone",
                              primaryModel: nil, now: now)?.id == "AM")
}

// The movers (coordinator follow-up): a LIVE conversation moved onto the pile is the worst form of
// it, a long context walling with eight others. Same fleet as above.
func runLoadMoveChecks() {
    let saved = clearanceSessionCounter
    defer { clearanceSessionCounter = saved }
    let am = account("AM", session: (100, nil), weekly: (100, inHours(152.47)))
    let fs = account("FS", session: (100, nil), weekly: (7, inHours(3.47)))
    let gm = account("GM", session: (100, nil), weekly: (100, inHours(152.47)))
    let snapshot = Snapshot(version: 2, generatedAt: now, accounts: [am, fs, gm])
    func follow() -> String? {
        incumbentSeededBest(providerID: "claude", in: snapshot, incumbentID: "AM",
                            primaryModel: nil, now: now)?.id
    }
    clearanceSessionCounter = { _ in 0 }
    check("M1 premise: an empty FS still draws the follow re-pick off AM", follow() == "FS")
    check("M2 premise: an empty FS is the cap handoff's target",
          capHandoffTarget([am, fs, gm], primaryModel: nil, now: now)?.id == "FS")
    clearanceSessionCounter = { $0 == "FS" ? 9 : 0 }
    check("M1 the follow re-pick does not move a session onto FS carrying 9", follow() == "AM")
    check("M2 the cap handoff does not move a session onto FS carrying 9",
          capHandoffTarget([am, fs, gm], primaryModel: nil, now: now)?.id == "AM")
    check("M3 FS as the only comfortable target is still a target (no move turned into a wait)",
          capHandoffTarget([fs], primaryModel: nil, now: now)?.id == "FS")
}
