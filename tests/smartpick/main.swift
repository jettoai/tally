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

// MARK: - Start mode: `--continue` is only injected where claude could resolve it
//
// `claude --continue` in a directory the launch home has never held a session for prints "No
// conversation found to continue" and exits, so a first launch in a new project directory used to
// die on tally's own injected flag.
let startModeRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("tally-startmode-\(UUID().uuidString)")
let withSession = startModeRoot.appendingPathComponent("home-used")
let withoutSession = startModeRoot.appendingPathComponent("home-fresh")
let workingDir = startModeRoot.appendingPathComponent("project")
try? FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: withoutSession, withIntermediateDirectories: true)
let sessionDir = withSession
    .appendingPathComponent("projects/\(projectSlug(forCwd: workingDir.path))")
try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
try? "{}".write(to: sessionDir.appendingPathComponent("abc.jsonl"), atomically: true, encoding: .utf8)

var continuePolicy = LaunchPolicy()
continuePolicy.startMode = "continue"
func startMode(_ args: [String], home: URL, policy: LaunchPolicy = continuePolicy,
               wantsNew: Bool = false) -> (args: [String], note: String?) {
    applyStartMode(args, policy: policy, wantsNew: wantsNew, home: home.path, cwd: workingDir.path)
}

check("this home has a transcript for the directory", hasConversation(home: withSession.path,
                                                                     cwd: workingDir.path))
check("a home that has never run here has none", !hasConversation(home: withoutSession.path,
                                                                  cwd: workingDir.path))
let used = startMode([], home: withSession)
check("a directory with a session keeps the injected continue", used.args == ["--continue"])
check("and says nothing about it", used.note == nil)
let fresh = startMode([], home: withoutSession)
check("a directory with no session suppresses the injection", fresh.args.isEmpty)
check("and says so once", fresh.note == "no conversation in this directory yet - starting fresh")
// A missing home is the same situation as an empty one, not a crash.
check("a home that does not exist suppresses it too",
      startMode([], home: startModeRoot.appendingPathComponent("absent")).args.isEmpty)
// The transcript check is per launch home: another account having the conversation does not let
// claude find it, so the prediction stays exact.
check("a sibling home's transcript does not count",
      !hasConversation(home: withoutSession.path, cwd: workingDir.path))

// A hand-typed flag is the user's own choice: never removed, never doubled, and never explained
// away with our note (they get the CLI's own error if it cannot be resolved).
let typed = startMode(["--continue"], home: withoutSession)
check("a hand-typed --continue survives in a fresh directory", typed.args == ["--continue"])
check("and is not commented on", typed.note == nil)
check("a hand-typed --resume is left alone",
      startMode(["--resume", "abc"], home: withoutSession).args == ["--resume", "abc"])
check("a hand-typed -c is not doubled",
      startMode(["-c"], home: withSession).args == ["-c"])
check("--print is not a session to continue",
      startMode(["-p", "hi"], home: withSession).args == ["-p", "hi"])
// The other two ways to say no, unchanged by the transcript check.
check("--new (wantsNew) still suppresses the injection",
      startMode([], home: withSession, wantsNew: true).args.isEmpty)
check("a policy that does not continue injects nothing",
      startMode([], home: withSession, policy: LaunchPolicy()).args.isEmpty)

// Injection lands where the flag will be READ: before the first `--`, never appended after the
// prompt. Appended, claude would never parse it (past the marker it is prompt text) and Tally could
// not see it either, so the launch would run without the default it believed it had applied.
check("an injected --continue goes in front of the prompt",
      startMode(["--", "summarise this"], home: withSession).args
      == ["--continue", "--", "summarise this"])
check("and the prompt itself is untouched",
      startMode(["--", "--continue"], home: withSession).args
      == ["--continue", "--", "--continue"])
// Which is also why the suppression check reads only the options: a prompt that mentions the flag
// is not the user choosing it.
check("a session flag inside the prompt does not suppress the injection",
      startMode(["--", "-p", "hi"], home: withSession).args == ["--continue", "--", "-p", "hi"])
check("with no marker the injection still simply appends",
      startMode(["--verbose"], home: withSession).args == ["--verbose", "--continue"])

// The two helpers on their own, including the no-marker case that must stay a plain append.
check("injecting with no marker appends",
      injectingOptions(["--verbose"], ["--model", "fable"]) == ["--verbose", "--model", "fable"])
check("injecting with a marker goes before it",
      injectingOptions(["--verbose", "--", "hi"], ["--model", "fable"])
      == ["--verbose", "--model", "fable", "--", "hi"])
check("injecting into a bare prompt still precedes it",
      injectingOptions(["--", "hi"], ["--model", "fable"]) == ["--model", "fable", "--", "hi"])
check("removing an own flag leaves the prompt alone",
      removingOption(["--new", "--", "--new"], "--new") == ["--", "--new"])
check("and removes every copy before the marker",
      removingOption(["--new", "-x", "--new"], "--new") == ["-x"])
try? FileManager.default.removeItem(at: startModeRoot)

// MARK: - Resolving a manual pin (AccountPick.swift)

// A pin carries two things: the account id, and the launch home denormalized beside it so the pin
// still works while its account is briefly missing from the snapshot. That fallback asks nothing
// about the account, which is how a pin left behind on an account that later SIGNED OUT kept
// exec'ing a logged-out config dir (2026-08-03): the app publishes a dormant account without a
// launch home, and every other surface skipped it - only this one did not look.
func manualPin(id: String?, home: String?) -> LaunchPolicy {
    LaunchPolicy(mode: "manual", pinnedAccountID: id, pinnedHome: home)
}
func snap(_ accounts: [Snapshot.Account]) -> Snapshot {
    Snapshot(version: 2, generatedAt: now, accounts: accounts)
}
let livePin = account("A", session: (50, inHours(2)), weekly: (60, inHours(48)))
var dormantPin = livePin
dormantPin.launchHome = nil   // exactly what the app publishes for a signed-out account
let pinSibling = account("B", session: (90, inHours(2)), weekly: (95, inHours(48)))

check("a live pin launches its account's own home",
      pinnedLaunchHome(snap([livePin, pinSibling]), policy: manualPin(id: "A", home: "/stale"))
          == "/tmp/A")
// THE FIX. The snapshot listing the account WITHOUT a launch home is Tally saying the login is
// gone; the saved home must not be exec'd behind that statement.
check("a pin whose account signed out launches nothing",
      pinnedLaunchHome(snap([dormantPin, pinSibling]), policy: manualPin(id: "A", home: "/tmp/A"))
          == nil)
check("…and that is recognised as signed out rather than as a missing account",
      pinnedAccountIsSignedOut(snap([dormantPin]), policy: manualPin(id: "A", home: "/tmp/A")))
// The case the fallback was ADDED for stays: absent from the snapshot says only that Tally has not
// seen the account this round (a refresh mid-flight, an app that has not run yet).
check("a pin whose account is simply absent still launches by saved home",
      pinnedLaunchHome(snap([pinSibling]), policy: manualPin(id: "A", home: "/tmp/A")) == "/tmp/A")
check("…and absence is not read as a sign-out",
      !pinnedAccountIsSignedOut(snap([pinSibling]), policy: manualPin(id: "A", home: "/tmp/A")))
check("no snapshot at all keeps the saved home too",
      pinnedLaunchHome(nil, policy: manualPin(id: "A", home: "/tmp/A")) == "/tmp/A"
          && !pinnedAccountIsSignedOut(nil, policy: manualPin(id: "A", home: "/tmp/A")))
// Only manual mode has a pin to resolve, and a policy with neither half resolves to nothing.
check("smart mode resolves no pin",
      pinnedLaunchHome(snap([livePin]), policy: LaunchPolicy(pinnedAccountID: "A",
                                                             pinnedHome: "/tmp/A")) == nil)
check("a manual policy with nothing pinned resolves to nothing",
      pinnedLaunchHome(snap([livePin]), policy: manualPin(id: nil, home: nil)) == nil
          && !pinnedAccountIsSignedOut(snap([livePin]), policy: manualPin(id: nil, home: nil)))

exit(failures == 0 ? 0 : 1)
