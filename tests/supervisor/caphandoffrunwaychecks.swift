import Foundation

// WHERE A CAP HANDOFF LANDS (TallyCLI/CapDetection.swift `capHandoffPick`).
//
// THE INCIDENT (2026-09-26 10:27:53Z). A capped session was moved to Claude 5, weekly 7% left and
// the best burn-rate score, while Claude 3 sat at 100%; three seconds later the knock told the
// same session Claude 5 was running low. The readings below are that fleet's.

func runCapHandoffRunwayChecks() {
    let iso = ISO8601DateFormatter()
    func at(_ text: String) -> Date { iso.date(from: text)! }
    let now = at("2026-09-26T10:27:53Z")
    func acct(_ label: String, session: Double?, sessionResets: String?, weekly: Double,
              weeklyResets: String) -> Snapshot.Account {
        Snapshot.Account(id: label, provider: "claude", label: label,
                         launchHome: "/tmp/runway-\(label)", sessionRemaining: session,
                         weeklyRemaining: weekly, modelRemaining: nil,
                         sessionResetsAt: sessionResets.map(at), weeklyResetsAt: at(weeklyResets),
                         modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil,
                         isStale: false, error: nil)
    }
    let c5 = acct("Claude 5", session: 100, sessionResets: "2026-09-26T13:30:00Z", weekly: 7,
                  weeklyResets: "2026-09-26T21:00:00Z")
    let c3 = acct("Claude 3", session: 100, sessionResets: "2026-09-26T13:19:00Z", weekly: 100,
                  weeklyResets: "2026-10-03T10:00:00Z")
    let c0 = acct("Claude 0", session: nil, sessionResets: nil, weekly: 82,
                  weeklyResets: "2026-10-01T17:00:00Z")
    let reserves = AccountReserves(settings: [
        "/tmp/runway-Claude 0": AccountRoleSetting(role: AccountRoles.personal, reserve: 10),
    ])
    let fleet = [c5, c3, c0]

    // C0. The fixture reproduces the event, so C1 is about the change and not about the fixture.
    check("runway: the shared chooser still picks the 7% account the event picked",
          capHandoffTarget(fleet, primaryModel: "opus", reserves: reserves, now: now)?.label
              == "Claude 5")
    // C1.
    check("runway: a cap handoff takes the full sibling instead",
          capHandoffPick(fleet, primaryModel: "opus", reserves: reserves, now: now)?.label
              == "Claude 3")
    // C2. Nobody above the knock's line: the old nearly-dry rule still finds somebody.
    let thin = [acct("A", session: 100, sessionResets: nil, weekly: 8,
                     weeklyResets: "2026-09-27T10:00:00Z"),
                acct("B", session: 100, sessionResets: nil, weekly: 12,
                     weeklyResets: "2026-09-30T10:00:00Z")]
    let thinPick = capHandoffPick(thin, primaryModel: "opus", reserves: .none, now: now)
    check("runway: with nobody above the line, the handoff falls back rather than waits",
          thinPick != nil
              && thinPick?.id == capHandoffTarget(thin, primaryModel: "opus", now: now)?.id)
    // C3.
    let dry = [acct("A", session: 100, sessionResets: nil, weekly: 4,
                    weeklyResets: "2026-09-27T10:00:00Z"),
               acct("B", session: 100, sessionResets: nil, weekly: 3,
                    weeklyResets: "2026-09-30T10:00:00Z")]
    // Rewritten for B-5634: a thin field is spent down rather than waited on, earliest weekly
    // reset first (A resets three days before B).
    check("runway: nobody above nearly dry spends the earliest weekly reset first",
          capHandoffPick(dry, primaryModel: "opus", reserves: .none, now: now)?.id == "A")
    // C4. The reserve counts: 22 with 10 held back is 12, under the line.
    let reserved = acct("R", session: 100, sessionResets: nil, weekly: 22,
                        weeklyResets: "2026-09-26T12:00:00Z")
    let roomy = acct("S", session: 100, sessionResets: nil, weekly: 60,
                     weeklyResets: "2026-10-03T10:00:00Z")
    let heldBack = AccountReserves(settings: [
        "/tmp/runway-R": AccountRoleSetting(role: AccountRoles.personal, reserve: 10),
    ])
    check("runway: the reserve comes off before the line is measured",
          capHandoffPick([reserved, roomy], primaryModel: "opus", reserves: heldBack, now: now)?
              .id == "S")
    // The edge: exactly at the line is what the knock already calls running low.
    check("runway: exactly 15 is not a runway, the knock's own at-or-under",
          !hasRunway([ComfortWindow(remaining: quotaKnockPercent, resetsAt: nil)],
                     floor: quotaKnockPercent, now: now)
              && quotaKnockStep(quotaKnockPercent) == quotaKnockPercent)
    runCapLastResortChecks()
    // C5. Wired at the cap, and only at the cap.
    let detection = (try? String(contentsOfFile: "TallyCLI/CapDetection.swift",
                                 encoding: .utf8)) ?? ""
    check("runway: the cap path chooses through capHandoffPick",
          detection.contains("?? capHandoffPick(candidates"))
    let pick = (try? String(contentsOfFile: "TallyCLI/AccountPick.swift", encoding: .utf8)) ?? ""
    let shared = pick.range(of: "func capHandoffTarget(").map {
        String(pick[$0.lowerBound...].prefix(600))
    } ?? ""
    check("runway: the chooser the other three moves share is untouched",
          shared.contains("requiringComfortable") && !shared.contains("quotaKnockPercent"))
}

// SPEND THE THIN FIELD DOWN (B-5634). 2026-10-05 22:3x Taipei: Claude 5 hit its weekly wall and the
// badge sat on "no account with quota to spare" while `tally claude` launched fine. Readings as the
// owner reported them; weekly resets as `~/.tally/snapshot.json` held them at 14:38:53Z.
func runCapLastResortChecks() {
    let iso = ISO8601DateFormatter()
    func at(_ text: String) -> Date { iso.date(from: text)! }
    let now = at("2026-10-05T14:36:00Z")
    func acct(_ label: String, session: Double, sessionResets: String?, weekly: Double,
              weeklyResets: String) -> Snapshot.Account {
        Snapshot.Account(id: label, provider: "claude", label: label,
                         launchHome: "/tmp/lastresort-\(label)", sessionRemaining: session,
                         weeklyRemaining: weekly, modelRemaining: nil,
                         sessionResetsAt: sessionResets.map(at), weeklyResetsAt: at(weeklyResets),
                         modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil,
                         isStale: false, error: nil)
    }
    let c0 = acct("Claude 0", session: 4, sessionResets: "2026-10-05T15:00:00Z", weekly: 6,
                  weeklyResets: "2026-10-08T17:00:00Z")
    let c2 = acct("Claude 2", session: 100, sessionResets: nil, weekly: 3,
                  weeklyResets: "2026-10-10T12:00:00Z")
    let c3 = acct("Claude 3", session: 2, sessionResets: "2026-10-05T17:20:00Z", weekly: 3,
                  weeklyResets: "2026-10-10T10:00:00Z")
    let c4 = acct("Claude 4", session: 100, sessionResets: "2026-10-05T17:59:00Z", weekly: 0,
                  weeklyResets: "2026-10-07T16:59:00Z")
    let c5 = acct("Claude 5", session: 47, sessionResets: "2026-10-05T16:19:00Z", weekly: 0,
                  weeklyResets: "2026-10-10T20:59:00Z")

    func capTick(_ accounts: [Snapshot.Account]) -> (RelaunchPlan?, PendingCapRecovery?) {
        var plan: RelaunchPlan?
        var pending: PendingCapRecovery? = PendingCapRecovery(
            cappedAccountID: c5.id, cappedAt: now, primaryModel: "opus",
            recoveryResetsAt: nil, nextRetry: .distantPast, reason: "")
        applyCapHandoff(plan: &plan, pendingCap: &pending, account: c5, providerID: "claude",
                        fleet: LaunchPolicy(), steering: true, sessionPin: nil, quarantine: [:],
                        fuseAllows: true, now: now,
                        loaded: (Snapshot(version: 2, generatedAt: now, accounts: accounts), nil))
        return (plan, pending)
    }
    let replay = capTick([c0, c2, c3, c4, c5])
    check("last resort: the 22:3x fleet hands off instead of waiting",
          replay.0?.reason == "cap" && replay.1?.reason != CapAction.waitNoTarget.waitingNote)
    check("last resort: to Claude 2, the one whose 5h window still has room",
          replay.0?.target.label == "Claude 2")

    // Rule (2): among thin accounts with a usable 5h window, the earliest weekly reset wins,
    // whatever the rate or the remaining percentage says (B resets two days earlier on less).
    let early = acct("B", session: 100, sessionResets: nil, weekly: 2,
                     weeklyResets: "2026-10-08T10:00:00Z")
    let late = acct("L", session: 100, sessionResets: nil, weekly: 5,
                    weeklyResets: "2026-10-10T10:00:00Z")
    check("last resort: same thin field, the earlier weekly reset is spent first",
          capHandoffPick([late, early], primaryModel: "opus", reserves: .none, now: now)?.id == "B")
    // A 5h window at or under the nearly-dry line is skipped even when its weekly resets first.
    check("last resort: a spent 5h window is skipped and waited back",
          capHandoffPick([c0, late], primaryModel: "opus", reserves: .none, now: now)?.id == "L")
    // ...unless it refills inside the grace, which counts as already full.
    let refilling = acct("R", session: 1, sessionResets: "2026-10-05T14:40:00Z", weekly: 3,
                         weeklyResets: "2026-10-07T10:00:00Z")
    check("last resort: a 5h window resetting inside the grace is usable",
          capHandoffPick([refilling, late], primaryModel: "opus", reserves: .none, now: now)?
              .id == "R")
    // Boundary: a weekly window 30 minutes from resetting is quota about to be thrown away, so it
    // is spent first (outside the 10-minute grace, so still a thin account, not a refilled one).
    let expiring = acct("E", session: 100, sessionResets: nil, weekly: 2,
                        weeklyResets: "2026-10-05T15:06:00Z")
    check("last resort: a weekly reset 30 minutes out is burned before it expires",
          capHandoffPick([late, early, expiring], primaryModel: "opus", reserves: .none,
                         now: now)?.id == "E")
    // Rule (3): every sibling has a window at 0, so the wait stands.
    let empty = capTick([c4, c5, acct("Z", session: 0, sessionResets: "2026-10-05T16:00:00Z",
                                      weekly: 40, weeklyResets: "2026-10-09T10:00:00Z")])
    check("last resort: nothing but 0% windows left still waits",
          empty.0 == nil && empty.1?.reason == CapAction.waitNoTarget.waitingNote)
    // Only 5h-spent siblings left (above 0, under the line): wait for the 5h reset too.
    check("last resort: only nearly-spent 5h windows left still waits",
          capHandoffPick([c0, c3], primaryModel: "opus", reserves: .none, now: now) == nil)

    // B-1213, 2026-10-07T13:10:53Z: a capped session moved Dorothy -> hyde with hyde, the personal
    // account, at 6% of its week and 10 held back. A move never crosses a reserve, the last tier
    // included: hyde alone under its line means wait.
    let hyde = acct("hyde", session: 90, sessionResets: "2026-10-05T17:00:00Z", weekly: 6,
                    weeklyResets: "2026-10-08T17:00:00Z")
    let hydeReserve = AccountReserves(settings: [
        "/tmp/lastresort-hyde": AccountRoleSetting(role: AccountRoles.personal, reserve: 10),
    ])
    check("last resort: a personal account under its line is waited on, not moved onto",
          capHandoffPick([hyde], primaryModel: "opus", reserves: hydeReserve, now: now) == nil)
    check("…and is moved onto with no reserve (guard the premise)",
          capHandoffPick([hyde], primaryModel: "opus", reserves: .none, now: now)?.id == "hyde")
    check("…and a thin sibling above its line is still spent first",
          capHandoffPick([hyde, c2], primaryModel: "opus", reserves: hydeReserve, now: now)?
              .id == "Claude 2")
}
