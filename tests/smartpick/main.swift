import Foundation

// Assertion harness for the CLI's burn-rate account pick (TallyCLI/Snapshot.swift), compiled
// against the real source. Every scenario uses a FIXED `now` so the math is deterministic.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

let now = Date(timeIntervalSince1970: 1_800_000_000)
func inHours(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

func account(_ id: String,
             session: (Double, Date?)? = nil,
             weekly: (Double, Date?)? = nil,
             model: (Double, Date?)? = nil,
             modelName: String? = nil,
             resets: Int? = nil) -> Snapshot.Account {
    Snapshot.Account(id: id, provider: "claude", label: id, launchHome: "/tmp/\(id)",
                     sessionRemaining: session?.0, weeklyRemaining: weekly?.0,
                     modelRemaining: model?.0,
                     sessionResetsAt: session?.1, weeklyResetsAt: weekly?.1,
                     modelResetsAt: model?.1, modelWindowName: modelName,
                     resetCreditsAvailable: resets,
                     isStale: false, error: nil)
}

func pick(_ accounts: [Snapshot.Account], primaryModel: String? = nil) -> String? {
    let snapshot = Snapshot(version: 2, generatedAt: now, accounts: accounts)
    return best(providerID: "claude", in: snapshot, primaryModel: primaryModel, now: now)?.id
}

// 1. Dying session quota: A has little left but it resets in 5 minutes (the leftover would
//    evaporate unused), and its weekly refreshes sooner too. Plain headroom would pick B.
let dyingA = account("A", session: (15, inHours(0.083)), weekly: (60, inHours(72)))
let dyingB = account("B", session: (80, inHours(4)), weekly: (70, inHours(100)))
check("session about to reset wins over bigger raw headroom", pick([dyingA, dyingB]) == "A")
check("plain headroom would have picked B (guard the premise)", headroom(dyingA) < headroom(dyingB))

// 2. Weekly perishability: 30% expiring tomorrow sustains a faster spend than 50% that must
//    last six more days.
let weekA = account("A", weekly: (30, inHours(24)))
let weekB = account("B", weekly: (50, inHours(144)))
check("sooner weekly reset wins over bigger slow-refreshing weekly", pick([weekA, weekB]) == "A")

// 3. No reset data (old snapshot): full-window assumption makes the weekly window bind (the
//    scarce budget - a session refills within 5h either way), so more weekly left wins.
let oldA = account("A", session: (80, nil), weekly: (75, nil))
let oldB = account("B", session: (40, nil), weekly: (90, nil))
check("without reset times the bigger weekly budget wins", pick([oldA, oldB]) == "B")

// 4. A capped window (0%) excludes the account outright, whatever its other windows say.
let capped = account("A", session: (0, inHours(0.083)), weekly: (90, inHours(24)))
let modest = account("B", session: (30, inHours(3)), weekly: (40, inHours(100)))
check("capped account is ineligible even with a near reset", pick([capped, modest]) == "B")

// 5. Primary-model anchoring: a drained fable window must not veto the account when the
//    declared primary is sonnet - but with no declared primary it stays flagship-first.
let drained = account("A", weekly: (80, inHours(100)), model: (5, inHours(100)), modelName: "Fable")
let steady = account("B", weekly: (50, inHours(100)), model: (60, inHours(100)), modelName: "Fable")
check("sonnet primary ignores the drained fable window", pick([drained, steady], primaryModel: "sonnet") == "A")
check("no declared primary keeps the flagship window binding", pick([drained, steady]) == "B")
check("fable primary keeps the flagship window binding", pick([drained, steady], primaryModel: "fable") == "B")

// 5b. Model-aware eligibility (R7): a flagship window at 0 must not exclude an account whose
//     declared primary is a different tier - that window is not the one it spends. With no
//     declared primary the account stays flagship-first (the drained window still caps it).
let fableZero = account("A", weekly: (60, inHours(100)), model: (0, inHours(100)), modelName: "Fable")
check("sonnet primary keeps a fable-zero account eligible", eligible(fableZero, primaryModel: "sonnet"))
check("fable primary drops a fable-zero account", !eligible(fableZero, primaryModel: "fable"))
check("no declared primary drops a fable-zero account (flagship-first)", !eligible(fableZero))
let sessionZero = account("A", session: (0, inHours(1)), weekly: (60, inHours(100)),
                          model: (80, inHours(100)), modelName: "Fable")
check("a zero non-model window still excludes regardless of primary",
      !eligible(sessionZero, primaryModel: "sonnet"))

// 6. Hysteresis: a tie stays with the first account (stable, not random), and using the leader
//    down a point must NOT bounce the pick to the idle sibling - only a meaningful advantage
//    (beyond smartPickMargin) flips it.
let evenA = account("A", session: (100, inHours(3)), weekly: (100, inHours(120)))
let evenB = account("B", session: (100, inHours(3)), weekly: (100, inHours(120)))
check("exact tie stays with the first account", pick([evenA, evenB]) == "A")
let dippedA = account("A", session: (99, inHours(3)), weekly: (99, inHours(120)))
check("a one-point dip after use does not flip the pick", pick([dippedA, evenB]) == "A")
let drainedA = account("A", session: (90, inHours(3)), weekly: (30, inHours(120)))
let freshB = account("B", session: (100, inHours(3)), weekly: (60, inHours(120)))
check("a real advantage beyond the margin still flips", pick([drainedA, freshB]) == "B")

// At the low end the ratio alone lies (2% vs 3% reads as +50%): the absolute gate must keep two
// nearly-drained siblings from ping-ponging, while a genuinely healthier one still rescues.
let dying2 = account("A", weekly: (2, inHours(100)))
let dying3 = account("B", weekly: (3, inHours(100)))
check("two nearly-drained accounts do not ping-pong", pick([dying2, dying3]) == "A")
let dying5 = account("A", weekly: (5, inHours(120)))
let healthy20 = account("B", weekly: (20, inHours(120)))
check("a genuinely healthier sibling still rescues a dying leader", pick([dying5, healthy20]) == "B")

// 7. Banked resets break near-ties only: a wall with an escape hatch behind it is softer, so
//    the reset-rich account burns first - but banked resets never outvote a real score gap.
let noHatch = account("A", weekly: (50, inHours(120)))
let hatch = account("B", weekly: (50, inHours(120)), resets: 3)
check("exact tie prefers the account with banked resets", pick([noHatch, hatch]) == "B")
let betterNoHatch = account("A", weekly: (80, inHours(120)))
check("banked resets never outvote a real score gap", pick([betterNoHatch, hatch]) == "A")

// 8. The pick reason names the binding window with its reset ETA.
let reason = pickReason(dyingA, primaryModel: nil, now: now)
check("reason names the binding window (weekly, 3d)", reason.contains("weekly 60%") && reason.contains("3d"))
let reasonOld = pickReason(oldB, primaryModel: nil, now: now)
check("reason omits ETA without reset data", reasonOld == "weekly 90%")

exit(failures == 0 ? 0 : 1)
