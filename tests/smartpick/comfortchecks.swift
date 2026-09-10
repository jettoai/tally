import Foundation

func runComfortChecks() {
    // 10. The nearly-dry gate. A rate can be highest on an account with almost nothing left, because
    //     an imminent reset divides a tiny remainder by a tiny number of hours. The two accounts below
    //     are the live 2026-07-25T11:10Z measurement, with an opus primary (so the fable window is
    //     excluded by the scoping in group 5): the rates come out 0.294 %/h for Claude against
    //     1.248 %/h for Claude 2, so the rate chose Claude 2, whose weekly window had 1% left, and the
    //     session capped within minutes.
    let healthyMain = account("claude", session: (75, inHours(1.48)), weekly: (37, inHours(125.82)))
    let nearlyDrySibling = account("claude2", session: (100, inHours(5)), weekly: (1, inHours(0.8)))
    check("the measured 2026-07-25 pick skips the account with 1% weekly left",
          pick([healthyMain, nearlyDrySibling], primaryModel: "opus") == "claude")
    check("the rate alone would have picked it (guard the premise)",
          smartScore(nearlyDrySibling, primaryModel: "opus", now: now)
              > smartScore(healthyMain, primaryModel: "opus", now: now))

    // The refuted counterexample: 9% resetting in 3 minutes is not stranded quota, it is a full
    // window three minutes from now, and taking it beats a sibling with 11% that must last 5h.
    let aboutToRefill = account("A", session: (9, inHours(0.05)))
    let slightlyRicher = account("B", session: (11, inHours(5)))
    check("9% resetting in 3 minutes still wins over 11% that has to last five hours",
          pick([aboutToRefill, slightlyRicher]) == "A")

    // Both edges of the grace window, on a window too thin to survive the gate on its own (3%): at
    // exactly 10 minutes it counts as refilled and the account stays selectable; half a minute later
    // it does not, and the healthier sibling takes the launch even though its rate is lower.
    let atGrace = account("A", session: (3, inHours(10.0 / 60)), weekly: (80, inHours(120)))
    let pastGrace = account("A", session: (3, inHours(10.5 / 60)), weekly: (80, inHours(120)))
    let plainSibling = account("B", session: (50, inHours(3)), weekly: (40, inHours(120)))
    check("a 3% window resetting in exactly 10 minutes counts as refilled",
          pick([atGrace, plainSibling]) == "A")
    check("half a minute past the grace the same 3% window drops the account",
          pick([pastGrace, plainSibling]) == "B")

    // The gate reuses the model scoping: a flagship window the declared primary does not spend must
    // not make the account look nearly dry either (it is not one of the account's counted windows).
    let dryFableOnly = account("A", weekly: (60, inHours(120)), model: (1, inHours(120)), modelName: "Fable")
    let plainerB = account("B", weekly: (40, inHours(120)))
    check("a drained fable window does not strand an account whose primary is sonnet",
          pick([dryFableOnly, plainerB], primaryModel: "sonnet") == "A")

    // Nothing comfortable: launching beats stranding the user, so the field is kept whole and the
    // existing ordering (hysteresis included) still decides.
    let dryLeader = account("A", session: (1, inHours(3)), weekly: (4, inHours(100)))
    let dryChallenger = account("B", session: (2, inHours(3)), weekly: (5, inHours(100)))
    let drainedPick = pick([dryLeader, dryChallenger])
    check("an all-drained field still returns a pick", drainedPick != nil)
    check("and the drained field keeps its hysteresis", drainedPick == "A")

    // The cap handoff runs the STRICTER half of the gate. The launch keeps its fallback because no
    // session is worse than a thin session; the handoff has a live session already, so moving it to a
    // spent account buys minutes and costs a visible restart that reloads the conversation. That was
    // the bounce the user reported: capped on A, handed to an already spent B, capped again, back to A.
    let comfortableRefuge = account("refuge", session: (50, inHours(3)), weekly: (40, inHours(120)))
    func handoff(_ accounts: [Snapshot.Account], primaryModel: String? = nil) -> String? {
        capHandoffTarget(accounts, primaryModel: primaryModel, now: now)?.id
    }
    check("the handoff takes the one comfortable account",
          handoff([dryLeader, dryChallenger, comfortableRefuge]) == "refuge")
    check("with everything dry the handoff has no target, so the supervisor waits",
          handoff([dryLeader, dryChallenger]) == nil)
    check("the launch path in that same state still returns an account",
          pick([dryLeader, dryChallenger]) != nil)
    // The imminent-reset grace counts here too: a thin window minutes from refilling is a real target,
    // so a session waiting on a cap is not held back by a percentage that is about to stop being true.
    let refillingSoon = account("B", session: (2, inHours(0.05)), weekly: (60, inHours(120)))
    check("an account whose window resets within the grace is a valid handoff target",
          handoff([dryLeader, refillingSoon]) == "B")

    // The follow re-pick runs the gate on its CHALLENGERS. This is the 2026-08-02T06:47Z incident,
    // replayed from the snapshot recorded a hundred seconds before it (history.jsonl): two sessions
    // adopted a new launch default and both landed on the account with 4% of its week left and 1.2h
    // until it refilled, while a sibling sat at 98% of a week that had six days to run. The rate is why
    // - 4/1.2 = 3.33 %/h beats 98/147 = 0.67 %/h - and the gate is what the other picks use to refuse
    // exactly that trade. This was the last pick in the repo deciding on a bare rate.
    let incidentIncumbent = account("claude2", session: (100, nil), weekly: (82, inHours(149.2)),
                                    model: (71, inHours(149.2)), modelName: "Fable")
    let incidentDry = account("claude4", session: (100, nil), weekly: (4, inHours(1.2)),
                              model: (4, inHours(1.2)), modelName: "Fable")
    let incidentHealthy = account("claude3", session: (91, inHours(2.7)), weekly: (98, inHours(147.2)),
                                  model: (98, inHours(147.2)), modelName: "Fable")
    let incidentField = [incidentIncumbent, incidentDry, incidentHealthy]
    check("the follow re-pick refuses the account with 4% of its week left",
          seeded(incidentField, incumbent: "claude2", primaryModel: "fable") == "claude3")
    check("the bare rate is what chose it (guard the premise)",
          smartScore(incidentDry, primaryModel: "fable", now: now)
              > smartScore(incidentHealthy, primaryModel: "fable", now: now) * smartPickMargin)
    check("and that account really was outside the imminent-reset grace",
          !accountIsComfortable(incidentDry, primaryModel: "fable", now: now))
    // The grace still applies here, so a thin window minutes from refilling is a real challenger: the
    // gate this borrows is the same one, not a stricter copy of it.
    let challengerRefilling = account("B", session: (100, inHours(5)), weekly: (2, inHours(0.05)))
    let plainIncumbent = account("A", session: (60, inHours(4)), weekly: (30, inHours(120)))
    check("a challenger whose window resets within the grace can still take the session",
          seeded([plainIncumbent, challengerRefilling], incumbent: "A") == "B")
    // The incumbent is deliberately NOT gated: a dying account is the idle rebalance's problem, where
    // one claim per drought stops five sessions evacuating onto one sibling at once. A Settings change
    // must not become that evacuation, so a dry incumbent with no comfortable challenger stays put.
    let dryIncumbent = account("A", session: (100, inHours(5)), weekly: (3, inHours(50)))
    check("a dry incumbent is not evicted by the gate when nothing comfortable is offered",
          seeded([dryIncumbent, dryChallenger], incumbent: "A") == "A")
    check("but a comfortable challenger that clears both gates still takes it",
          seeded([dryIncumbent, comfortableRefuge], incumbent: "A") == "refuge")

    // Two comfortable accounts near a tie must not start flapping because the gate ran first.
    let comfyA = account("A", session: (100, inHours(3)), weekly: (60, inHours(120)))
    let comfyB = account("B", session: (100, inHours(3)), weekly: (58, inHours(120)))
    check("a near-tie between two comfortable accounts stays with the leader",
          pick([comfyA, comfyB]) == "A")

}
