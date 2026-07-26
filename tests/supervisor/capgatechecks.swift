import Foundation

// The cap handoff's account gate, split out of main.swift for file size. Top-level statements can
// only live in main.swift, so these run as one function it calls; the harness (`check`, `failures`)
// and the fixed `launch` date are shared from there.
//
// The policy under test: unlike a launch, a handoff has a live session to lose, so it moves ONLY to
// an account with room. An all-dry field is a wait, and that wait has to explain itself in terms of
// quota, because the siblings the user can see in the panel do exist. They are just as spent as the
// account that capped. Handing the session to one of them was the bounce the user reported: capped
// on A, handed to an already spent B, capped again, back to A.

func runCapGateChecks() {
    func cliAccount(_ id: String, session: (Double, Double),
                    weekly: (Double, Double)) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: id, launchHome: "/tmp/\(id)",
                         sessionRemaining: session.0, weeklyRemaining: weekly.0,
                         modelRemaining: nil,
                         sessionResetsAt: launch.addingTimeInterval(session.1 * 3600),
                         weeklyResetsAt: launch.addingTimeInterval(weekly.1 * 3600),
                         modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil,
                         isStale: false, error: nil)
    }

    let dryField = [
        cliAccount("A", session: (2, 3), weekly: (4, 100)),
        cliAccount("B", session: (3, 3), weekly: (5, 100)),
    ]
    let noTarget = capHandoffTarget(dryField, primaryModel: nil, now: launch)
    check("an all-dry field gives the handoff no target", noTarget == nil)
    let dryWait = capRecoveryAction(mode: "auto", fuseAllows: true, snapshotStale: false,
                                    hasTarget: noTarget != nil)
    check("which is the waiting state, not the end of supervision", dryWait == .waitNoTarget)
    check("and the note names quota rather than claiming there is no other account",
          dryWait.waitingNote == "no account with quota to spare, waiting for one to free up")

    let comfortableField = dryField + [cliAccount("C", session: (60, 3), weekly: (50, 120))]
    check("one comfortable sibling is still handed off to",
          capHandoffTarget(comfortableField, primaryModel: nil, now: launch)?.id == "C")

    // The imminent-reset grace counts for the handoff too: a 2% window three minutes from refilling
    // is a full window three minutes from now, so waiting for it while sitting on a capped account
    // would be waiting for something already true.
    let refilling = dryField + [cliAccount("D", session: (2, 0.05), weekly: (60, 120))]
    check("a window resetting inside the grace makes a valid handoff target",
          capHandoffTarget(refilling, primaryModel: nil, now: launch)?.id == "D")
}
