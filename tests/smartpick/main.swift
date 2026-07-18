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
             modelName: String? = nil) -> Snapshot.Account {
    Snapshot.Account(id: id, provider: "claude", label: id, launchHome: "/tmp/\(id)",
                     sessionRemaining: session?.0, weeklyRemaining: weekly?.0,
                     modelRemaining: model?.0,
                     sessionResetsAt: session?.1, weeklyResetsAt: weekly?.1,
                     modelResetsAt: model?.1, modelWindowName: modelName,
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

// 6. The pick reason names the binding window with its reset ETA.
let reason = pickReason(dyingA, primaryModel: nil, now: now)
check("reason names the binding window (weekly, 3d)", reason.contains("weekly 60%") && reason.contains("3d"))
let reasonOld = pickReason(oldB, primaryModel: nil, now: now)
check("reason omits ETA without reset data", reasonOld == "weekly 90%")

exit(failures == 0 ? 0 : 1)
