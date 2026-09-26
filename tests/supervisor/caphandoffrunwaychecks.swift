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
    check("runway: nobody above nearly dry still means wait",
          capHandoffPick(dry, primaryModel: "opus", reserves: .none, now: now) == nil)
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
