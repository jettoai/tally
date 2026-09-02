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

// 5c. THE FLAGSHIP WINDOW BORROWS THE ACCOUNT'S WEEKLY RESET when it reports none of its own. Both
//     turn over on the same fixed weekly moment (measured across the live fleet 2026-08-12: every
//     opened account reports the two resets EQUAL), so rating a reset-less flagship window against
//     the 168h fallback understated its rate by up to a week and made the account read as the
//     scarce one. The scenario is the owner's: a full flagship window, no reset of its own, and a
//     weekly reset three days out.
let anchorBorrowed = account("A", weekly: (100, inHours(72)), model: (100, nil), modelName: "Fable")
check("a reset-less flagship window is scored off the weekly anchor, 3d out",
      abs(score(anchorBorrowed) - 100.0 / 72) < 1e-9)
let anchorless = account("A", weekly: (100, nil), model: (100, nil), modelName: "Fable")
// With no weekly reset to borrow, both windows fall through to the rule below them. Here that is
// the untouched-window rule (7d) rather than the full window, because both still read 100%: the
// premise being guarded is that 72h was borrowed above and nothing was borrowed here.
check("and with no weekly reset to borrow, the borrowing stops (guard the premise)",
      abs(score(anchorless) - 100.0 / 84) < 1e-9)

// THE BORROWED VALUE IS NOT THE REPORTED ONE, and the two are carried in separate fields for it:
// the pick and the gate may rank on an inferred anchor, and nothing may print one.
let borrowedWindows = ratedWindows(anchorBorrowed, primaryModel: nil, now: now)
let flagship = borrowedWindows.first { $0.name == "Fable" }
check("the flagship window was found at all (guard the premise)", flagship != nil)
check("the inferred anchor rides in `anchor`, and `resetsAt` stays as reported",
      flagship?.anchor == inHours(72) && flagship?.resetsAt == nil)
// The human sentence quotes the REPORTED field, so a countdown nobody published is never printed.
// The flagship window binds here (30% against the weekly's 100%), which is what makes it the window
// the reason names.
let anchorBinding = account("A", weekly: (100, inHours(72)), model: (30, nil), modelName: "Fable")
check("the reason names the borrowing window (guard the premise)",
      pickReason(anchorBinding, primaryModel: nil, now: now).hasPrefix("Fable 30%"))
check("…and quotes no countdown for it, borrowed or otherwise",
      pickReason(anchorBinding, primaryModel: nil, now: now) == "Fable 30%")

// The nearly-dry gate reads the anchor too, and must: its question is when the wall comes down, and
// this window's wall is the account's weekly one. A flagship window at 3% whose weekly resets in
// five minutes is quota that is already back.
let dryFlagshipSoonWeekly = account("A", session: (80, inHours(3)), weekly: (50, inHours(0.083)),
                                    model: (3, nil), modelName: "Fable")
check("a reset-less flagship window is exempted by the weekly reset it hits",
      accountIsComfortable(dryFlagshipSoonWeekly, primaryModel: nil, now: now))
let dryFlagshipNoAnchor = account("A", session: (80, inHours(3)), weekly: (50, nil),
                                  model: (3, nil), modelName: "Fable")
check("…and with nothing to borrow the same window still drops the account (guard the premise)",
      !accountIsComfortable(dryFlagshipNoAnchor, primaryModel: nil, now: now))

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

// 7b. A MISSING WEEKLY RESET BUYS NOTHING. It briefly bought a tie-breaker of its own (06c8fbc,
//     "prefer starting an unopened weekly clock"), on the premise that the seven days start at the
//     account's first request - so an untouched account could be launched for free and would then
//     be scheduling a refill. The premise is false: the provider assigns each account a FIXED
//     weekly reset moment that does not move with use (support.claude.com, "What is the Max plan";
//     confirmed against the live fleet 2026-08-12, where an account at 100% of its week already
//     carried a reset 3d11h out rather than 7d). A weekly window with no reset time is therefore
//     never "not started yet" - it is only ever "nobody has read one": a v1 snapshot, or an account
//     the app has not polled. So the near-tie band leaves the pick where it was.
//
//     SCOPE, since 7d: this covers a window that was SPENT and whose reset nobody has read, which
//     is what the rivals below are (95% left). A window still at 100% has not been opened at all
//     and is read against the half-window expectation instead - a different rule for a state this
//     one cannot be in.
//
//     These are the live 2026-08-12 numbers the tie-breaker was written from: Claude 4 at 55% with
//     97.5h to run (0.564 %/h) against a reset-less account reading 95/168 = 0.565 %/h.
func score(_ account: Snapshot.Account) -> Double {
    smartScore(account, primaryModel: nil, now: now)
}
let openedLeader = account("A", weekly: (55, inHours(97.5)))
let resetlessRival = account("B", weekly: (95, nil))
check("a missing weekly reset does not take the lead inside the noise band",
      pick([openedLeader, resetlessRival]) == "A")
check("and it really was inside the band, not simply losing on score (guard the premise)",
      score(resetlessRival) >= score(openedLeader)
          && !(score(resetlessRival) > score(openedLeader) * smartPickMargin
               && score(resetlessRival) > score(openedLeader) + smartPickMinGain))
// The same account listed FIRST still leads, which is the other half of "the band decides nothing":
// order alone carries it, and no property of the reset-less account is consulted either way.
check("and it leads when it is listed first, on list order alone",
      pick([resetlessRival, openedLeader]) == "B")

// A spent weekly with no reset reads as a full 168h window (`ratedWindows`), which is the
// conservative degradation and not a claim about the account: it must not out-score a real
// advantage either.
let strongLeader = account("A", weekly: (30, inHours(24)))
check("a missing weekly reset does not outvote a real score advantage",
      pick([strongLeader, resetlessRival]) == "A")

// A running weekly clock at the same numbers is treated identically: with the tie-breaker gone,
// "reset known" and "reset unknown" are the same thing to the pick at equal score.
let openedRival = account("B", weekly: (95, inHours(168)))
check("a known reset and a missing one at the same score both keep the leader",
      pick([openedLeader, openedRival]) == "A" && pick([openedLeader, resetlessRival]) == "A")
check("…and those two rivals really do score the same (guard the premise)",
      score(openedRival) == score(resetlessRival))

// v1 snapshots carry no reset times at all, so every spent account looks the same way to this rule.
// The coarse-percentage case that made removal a fix as well as a correction: one point apart is
// one noise-level point, and it used to hand the launch to whichever account reported the rounder
// number rather than to the leader. (Both are below 100 on purpose: 7d reads a 100 deliberately.)
let v1First = account("A", weekly: (98, nil))
let v1Second = account("B", weekly: (99, nil))
check("a one-point difference between two reset-less accounts keeps the list order",
      pick([v1First, v1Second]) == "A")
check("and the pair swapped keeps it too (the rounder number buys nothing)",
      pick([v1Second, v1First]) == "B")

// 7c. The banked-reset tie-breaker is the one that stayed, and it still decides the same band the
//     removed one used to take first - including when the challenger is the reset-less account,
//     which is where the two rules used to disagree.
let bankedResetless = account("B", weekly: (95, nil), resets: 2)
check("banked resets still break a near-tie, reset time or no reset time",
      pick([openedLeader, bankedResetless]) == "B")

// 7d. AN UNTOUCHED FIXED-CYCLE WINDOW IS RATED AGAINST HALF ITS LENGTH, not all of it (the session
//     window is the exception, 7e). The provider publishes a reset only once usage opens the
//     window, so an account that has never run a request reports
//     100% and a null reset on every window - a state whose PHASE is unknown, not one that is
//     certainly a full window away. Rating it at the full window is the worst case, and it
//     deadlocks: the account is never picked, so it never runs, so it never earns a reset to be
//     rated by.
//
//     The deadlock, live at 2026-08-19T16:53Z: a brand new Claude 4 (three windows at 100%, every
//     reset null) against the working main account (weekly 16% with 24h to run, session 88% with
//     1.15h, flagship 20% with 24h). The main account binds at 16/24 = 0.667 %/h; the new account
//     read 100/168 = 0.595 %/h and could not even reach the 1.15x challenge, so the user had to
//     open its week by hand with `tally account`.
let virginAccount = account("virgin", session: (100, nil), weekly: (100, nil), model: (100, nil),
                            modelName: "Fable")
let workingMain = account("main", session: (88, inHours(1.15)), weekly: (16, inHours(24)),
                          model: (20, inHours(24)), modelName: "Fable")
check("the never-launched account takes the launch from the account with 16% of its week",
      pick([workingMain, virginAccount]) == "virgin")
check("its weekly is rated against 84h, the midpoint of the window",
      abs(score(virginAccount) - 100.0 / 84) < 1e-9)
check("the full-window reading could not have cleared the challenge gates (guard the premise)",
      !(100.0 / 168 > score(workingMain) * smartPickMargin
        && 100.0 / 168 > score(workingMain) + smartPickMinGain))
// Both accounts are in the field on their own merits: neither the eligibility filter nor the
// nearly-dry gate removed the main account, so this is the ordering deciding and not a walkover.
check("and the account it beat was a live candidate, not gated out (guard the premise)",
      eligible(workingMain) && accountIsComfortable(workingMain, primaryModel: nil, now: now))

// 7e. THE SESSION WINDOW IS EXEMPT from that halving, because its phase is not unknown: the 5h
//     session clock starts on the first message rather than on a moment the provider fixes
//     (Tally/Views/MetricRowView.swift tells the user the same thing), so an untouched session
//     window has its whole 5h still ahead of it and the half-window expectation does not apply.
//     Halving it reads 100/2.5 = 40 %/h where the truth is 100/5 = 20 %/h, doubling the rate of
//     the one window every idle account carries.
let virginSessionOnly = account("A", session: (100, nil))
check("an untouched session window is rated against the full 5h, not half of it",
      abs(score(virginSessionOnly) - 100.0 / 5) < 1e-9)
//     What the doubling bought at the pick: an idle account whose session has never started held
//     the launch against a rival sustaining a genuinely faster burn, on the strength of a window
//     nobody had opened. The idle account's weekly reads 25 %/h either way; only its session moves,
//     from 40 %/h (never the binding window) to 20 %/h (binding, and correctly so).
let idleUnstarted = account("idle", session: (100, nil), weekly: (100, inHours(4)))
let busyRival = account("busy", weekly: (48, inHours(2)))
check("an idle account's unstarted session no longer holds the launch",
      pick([idleUnstarted, busyRival]) == "busy")
check("the halved reading would have kept it: 24 %/h clears 20 but not 25 (guard the premise)",
      abs(score(idleUnstarted) - 20) < 1e-9 && abs(score(busyRival) - 24) < 1e-9
          && !(24 > 25 * smartPickMargin && 24 > 25 + smartPickMinGain))
check("and the rival was a live candidate, not a walkover (guard the premise)",
      eligible(busyRival) && accountIsComfortable(busyRival, primaryModel: nil, now: now))

// The regression the rule must not swallow: BELOW 100% the window was spent by someone and the
// missing reset is only an unread one, which stays the conservative full window (7b).
let spentUnread = account("A", weekly: (60, nil))
check("a spent window with no reset keeps the full-window assumption",
      abs(score(spentUnread) - 60.0 / 168) < 1e-9)
// A reported reset always wins over the inference, even at 100%: the rule reads absence, not the
// percentage.
let untouchedButRead = account("A", weekly: (100, inHours(168)))
check("a reported reset outranks the half-window inference",
      abs(score(untouchedButRead) - 100.0 / 168) < 1e-9)

// The half window is an inference, so it rides in `anchor` exactly like the borrowed one and never
// reaches a sentence: the reason quotes no countdown the provider never published.
let virginWindows = ratedWindows(virginAccount, primaryModel: nil, now: now)
let virginWeekly = virginWindows.first { $0.name == "weekly" }
check("the untouched weekly window was found at all (guard the premise)", virginWeekly != nil)
check("the half window rides in `anchor` and `resetsAt` stays empty",
      virginWeekly?.anchor == inHours(84) && virginWeekly?.resetsAt == nil)
// The exemption is one window wide, on the one account: its flagship window keeps the midpoint
// (168h fixed cycle, nothing to borrow) while its session window anchors nowhere at all.
check("the same account's untouched flagship window still anchors at 84h",
      virginWindows.first { $0.name == "Fable" }?.anchor == inHours(84))
let virginSession = virginWindows.first { $0.name == "session" }
check("and its untouched session window anchors nowhere, rating at 100/5",
      virginSession?.anchor == nil && abs((virginSession?.rate ?? 0) - 100.0 / 5) < 1e-9)
check("and the pick reason quotes no countdown for it",
      pickReason(virginAccount, primaryModel: nil, now: now) == "weekly 100%")

// The app scores the same snapshot for its smart badge from its own copy of `ratedWindows`
// (LaunchPolicyScoring.swift, "keep both sides in lockstep"), and a rule living in one copy means
// the badge naming one account while the launcher takes another. This suite compiles the CLI only,
// so the mirror is checked as source text: crude, and still the difference between the two halves
// drifting silently and a failing test.
let appPolicySource = (try? String(contentsOfFile: "Tally/Stores/LaunchPolicyScoring.swift",
                                   encoding: .utf8)) ?? ""
check("the app's copy of the scoring is readable from here (guard the premise)",
      appPolicySource.contains("static func ratedWindows"))
check("and it carries the untouched-window anchor too, behind the same fixed-cycle gate",
      appPolicySource.contains("fixedCycle && metric.remainingPercent >= 100")
          && appPolicySource.contains("fullWindowHours / 2 * 3600")
          && appPolicySource.contains("?? inferredAnchor ?? untouchedAnchor"))
// And that it exempts the same window: the weekly and flagship call sites opt in, the 5h session
// one does not. A mirror that halved only on one side would have the badge naming an idle account
// the launcher passes over.
check("and it opts its weekly window in",
      appPolicySource.contains("window(AccountRoles.weeklyWindowName, weekly, "
                                   + "fullWindowHours: 168, fixedCycle: true,"))
check("and leaves its 5h session window out",
      !appPolicySource.contains("fullWindowHours: 5, fixedCycle: true"))
// AND IT TAKES THE RESERVE OFF THE RATE, the same subtraction in the same place as `ratedWindows`
// above. Ranking is where "spend somewhere else if you can" bites, so a copy that ranked on the raw
// percentage would put the badge on the personal account while `tally` spent a sibling - the badge
// naming one account and the launcher taking another, which is the drift this block guards.
// (The behaviour itself is asserted on values in tests/integrations/smartbadgechecks.swift, the one
// suite that compiles the app's store.)
check("and its rate is what Tally may spend, the reserve taken off",
      appPolicySource.contains("(metric.remainingPercent - held) / hours"))
// AND OFF THE SAME WINDOWS. The reserve covers the weekly all-models window and the 5h session one
// and nothing else (Albert's ruling, 2026-09-02; Tally/Core/AccountReserve.swift owns it, and each
// mirror marks those windows where it builds them), so a copy that subtracted on every window would
// have the badge stepping off an account whose FLAGSHIP window dipped while the launcher stayed on
// it - and a copy that subtracted on one of them would have it staying while the launcher stepped.
check("…and only from the windows the reserve is held back from",
      appPolicySource.contains(
          "let held = reserved && AccountRoles.reservedWindowNames.contains(name) ? reserve : 0"))
check("…which are the weekly one and the 5h one, named from the file that owns the ruling",
      appPolicySource.contains("window(AccountRoles.weeklyWindowName, weekly, "
                                   + "fullWindowHours: 168, fixedCycle: true,")
          && appPolicySource.contains("window(AccountRoles.sessionWindowName, "
                                          + "usage.metrics.first { $0.kind == .session },")
          && appPolicySource.components(separatedBy: "reserved: true").count == 3)
// AND THE FLAGSHIP CALL SITE OPTS INTO NEITHER, which is the half a count cannot show: the model
// window is built from a name the PROVIDER chose, and the two conditions above are what keep it out
// of the feature however that name is spelled.
check("…while the flagship window is built without the opt-in",
      appPolicySource.contains("inferredAnchor: weekly?.resetsAt, fullWindowHours: 168,\n"
                                   + "                          fixedCycle: true)"))
// THE REST OF THAT SUBTRACTION'S JOURNEY, because taking it off the rate is only the first of three
// places it has to land. The rules the two targets share are compiled from one file
// (Tally/Core/AccountReserve.swift, listed under both targets); the SCORING is mirrored, so these
// are the mirror's remaining halves.
check("and it hands the reserve across into the gate's window rather than re-deriving it",
      appPolicySource.contains("reserve: $0.reserve"))
check("and it has the launch fallback's other half, so the badge does not blank a dipping fleet",
      appPolicySource.contains("static func aboveReserve"))
// THE HALF THAT MUST NOT MIRROR: the sentence under the badge quotes the provider's own percentage,
// on both sides. A reserve can shift which window BINDS a pick; it may never change a number a
// person reads (`windowReason` states the rule for the CLI).
check("…while the badge's own sentence is scored reserve-blind, as `pickReason` is",
      appPolicySource.contains("ratedWindows(usage, primaryModel: primaryModel, now: now)"))

// 8. The pick reason names the binding window with its reset ETA.
let reason = pickReason(dyingA, primaryModel: nil, now: now)
check("reason names the binding window (weekly, 3d)", reason.contains("weekly 60%") && reason.contains("3d"))
let reasonOld = pickReason(oldB, primaryModel: nil, now: now)
check("reason omits ETA without reset data", reasonOld == "weekly 90%")

// 9. R1 incumbent-seeded pick: a running session adopting a new model stays on its account
//    whenever it can still serve the model, and switches only when it can't or a sibling wins
//    decisively - no churn on noise, unlike the plain list-order best().
func seeded(_ accounts: [Snapshot.Account], incumbent: String, primaryModel: String? = nil) -> String? {
    let snapshot = Snapshot(version: 2, generatedAt: now, accounts: accounts)
    return incumbentSeededBest(providerID: "claude", in: snapshot, incumbentID: incumbent,
                               primaryModel: primaryModel, now: now)?.id
}
let incA = account("A", weekly: (50, inHours(120)))
let incB = account("B", weekly: (52, inHours(120)))
check("incumbent stays put on a noise-level difference", seeded([incA, incB], incumbent: "A") == "A")
check("incumbent stays even when it is listed second", seeded([incB, incA], incumbent: "A") == "A")
let weakInc = account("A", weekly: (10, inHours(120)))
let strongSib = account("B", weekly: (80, inHours(120)))
check("a decisively healthier sibling still wins", seeded([weakInc, strongSib], incumbent: "A") == "B")
let incFableDry = account("A", weekly: (60, inHours(120)), model: (0, inHours(120)), modelName: "Fable")
let sibFableOk = account("B", weekly: (40, inHours(120)), model: (50, inHours(120)), modelName: "Fable")
check("incumbent ineligible for the new model yields to an eligible sibling",
      seeded([incFableDry, sibFableOk], incumbent: "A", primaryModel: "fable") == "B")
check("with a sonnet primary the same incumbent stays (fable window irrelevant)",
      seeded([incFableDry, sibFableOk], incumbent: "A", primaryModel: "sonnet") == "A")
let allDry = account("A", weekly: (0, inHours(120)))
check("nothing eligible returns nil (a dead end)", seeded([allDry], incumbent: "A") == nil)

// F1: a single-account user who caps the flagship window and then switches Settings to a model
// that window doesn't gate must be able to adopt it - the follow repick targets the very account
// that capped (this is the follow path that the cap-wait branch must no longer starve).
let cappedFable = account("A", weekly: (55, inHours(120)), model: (0, inHours(120)), modelName: "Fable")
check("the capped account is a valid follow target for a model it can still serve",
      seeded([cappedFable], incumbent: "A", primaryModel: "sonnet") == "A")
check("but not for the model whose window it just capped",
      seeded([cappedFable], incumbent: "A", primaryModel: "fable") == nil)

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

// MARK: - launchPick: the pick every PREVIEW has to agree with (quarantine included)
//
// The badge and `tally status` predict the launch, so they run this rather than `best`. Ignoring
// the quarantine made the panel name an account the launcher was skipping (2026-07-25).
func preview(_ accounts: [Snapshot.Account], quarantined: Set<String>) -> String? {
    let snapshot = Snapshot(version: 2, generatedAt: now, accounts: accounts)
    return launchPick(providerID: "claude", in: snapshot, primaryModel: nil,
                      quarantined: quarantined, now: now)?.id
}

let healthy = account("A", session: (90, inHours(3)), weekly: (80, inHours(120)))
let sibling = account("B", session: (70, inHours(3)), weekly: (50, inHours(120)))
check("with nothing quarantined the preview is the plain best",
      preview([healthy, sibling], quarantined: []) == "A")
check("a quarantined account is not previewed",
      preview([healthy, sibling], quarantined: ["A"]) == "B")
check("and the account that WOULD launch is named instead",
      preview([healthy, sibling], quarantined: ["A"])
          == best(providerID: "claude",
                  in: Snapshot(version: 2, generatedAt: now, accounts: [healthy, sibling]),
                  excluding: ["A"], now: now)?.id)
// Quarantine emptying the field: the launcher launches anyway, so the preview must name that
// account rather than go blank (a blank badge would read as "no account can be used").
check("an all-quarantined field falls back to the unfiltered pick",
      preview([healthy, sibling], quarantined: ["A", "B"]) == "A")
check("a quarantine on an ineligible account changes nothing",
      preview([healthy, sibling], quarantined: ["C"]) == "A")

runLaunchChecks()
runReserveChecks()

exit(failures == 0 ? 0 : 1)
