import Foundation

// THE PERSONAL ACCOUNT'S RESERVE, AT THE FOUR STATIONS THAT MOVE A RUNNING SESSION: the cap handoff,
// the idle rebalance, the turn-boundary move and the `/clear` window repick. What the reserve IS is
// asserted next door in the smartpick suite (the state file, the subtraction, the picks); what is
// asserted here is that each mover's own gate table reads it, and that the tick hands it to all of
// them.
//
// TWO CHECKS PER STATION, and they are opposite instructions rather than a pair of examples: a
// session ON a reserved account that has dipped under its line MOVES (that is the whole feature),
// and no session is ever moved ONTO one. Beside them the ruling this package took: under its own
// line an account reads as spent, so its idle sessions are released without waiting for the one
// move per drought - with the three trust guards still in front of it, because a reserve is a
// preference and not evidence about quota.

func runReserveMoverChecks() {
    // MARK: - R9. The fixtures

    /// Session and weekly healthy, so the WEEKLY window alone decides - and with a config home
    /// named, because that is the key a reserve is written under.
    func acct(_ id: String, weekly: Double, stale: Bool = false, error: String? = nil,
              refreshFailed: Bool? = false) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: id, launchHome: "/tmp/reserve-\(id)",
                         sessionRemaining: 90, weeklyRemaining: weekly, modelRemaining: nil,
                         sessionResetsAt: launch.addingTimeInterval(4 * 3600),
                         weeklyResetsAt: launch.addingTimeInterval(100 * 3600),
                         modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil,
                         isStale: stale, error: error, lastRefreshFailed: refreshFailed)
    }
    let held = AccountReserves(settings: [
        "/tmp/reserve-A": AccountRoleSetting(role: AccountRoles.personal, reserve: 30),
    ])
    /// Under its line (25 against 30) and nowhere near the raw 5% one: every refusal below is the
    /// reserve's doing and nothing else's, which is what makes the `.none` twin of each check the
    /// control rather than a second example.
    let personal = acct("A", weekly: 25)
    let sibling = acct("B", weekly: 60)

    // MARK: - R10. The idle rebalance

    func rebalance(current: Snapshot.Account = personal,
                   candidates: [Snapshot.Account] = [sibling],
                   reserves: AccountReserves = held,
                   claim: @escaping () -> Bool = { true }) -> Snapshot.Account? {
        rebalanceTarget(steering: true, mode: "auto", blocked: false, agentsWorking: false,
                        isQuiet: true, carryable: true, fuseAllows: true,
                        current: current, candidates: candidates, primaryModel: nil,
                        reserves: reserves, now: launch, claim: claim)
    }
    check("the rebalance moves a session off an account under its reserve",
          rebalance()?.id == "B")
    check("…and leaves it alone when nobody reserved anything (guard the premise)",
          rebalance(reserves: .none) == nil)
    check("the rebalance never moves a session ONTO an account under its reserve",
          rebalance(current: acct("C", weekly: 3), candidates: [personal]) == nil)
    check("…and would have moved it there without the reserve (guard the premise)",
          rebalance(current: acct("C", weekly: 3), candidates: [personal],
                    reserves: .none)?.id == "A")

    // MARK: - R11. The turn-boundary move

    func boundary(current: Snapshot.Account = personal,
                  candidates: [Snapshot.Account] = [sibling],
                  reserves: AccountReserves = held,
                  claim: @escaping () -> Bool = { true }) -> Snapshot.Account? {
        turnBoundaryTarget(steering: true, mode: "auto", blocked: false, keyboardIdle: true,
                           draftSuspected: false, carryable: true, fuseAllows: true,
                           agentsIdle: true, turnEnded: true, toolCallOpen: false,
                           current: current, candidates: candidates, primaryModel: nil,
                           reserves: reserves, now: launch, claim: claim)
    }
    check("a turn ending on an account under its reserve moves the session",
          boundary()?.id == "B")
    check("…and ends nowhere without the reserve (guard the premise)",
          boundary(reserves: .none) == nil)
    check("a turn boundary never lands a session on an account under its reserve",
          boundary(current: acct("C", weekly: 3), candidates: [personal]) == nil)

    // MARK: - R12. The `/clear` window repick

    func repick(on: Snapshot.Account = personal, accounts: [Snapshot.Account]? = nil,
                reserves: AccountReserves = held) -> Snapshot.Account? {
        windowRepickMove(provider: "claude", account: on, primaryModel: nil, mode: "auto",
                         steering: true, carryable: true, fuseAllows: true,
                         reserves: reserves,
                         loaded: (Snapshot(version: 2, generatedAt: launch,
                                           accounts: accounts ?? [on, sibling]), nil),
                         now: launch)
    }
    check("a window cleared on an account under its reserve reopens on the sibling",
          repick()?.id == "B")
    check("…and reopens where it stood without the reserve (guard the premise)",
          repick(reserves: .none) == nil)
    check("a cleared window never reopens on an account under its reserve",
          repick(on: acct("C", weekly: 3), accounts: [acct("C", weekly: 3), personal]) == nil)

    // MARK: - R13. The cap handoff's stay-put branch

    // A pinned session that just capped is offered the fallback pairing ON THE ACCOUNT IT IS ON,
    // and an account under its owner's line cannot serve one: what it has left is not Tally's to
    // spend, so the session belongs in the move below instead.
    var fleet = LaunchPolicy()
    fleet.fallbackModel = "sonnet"
    check("a capped session on a reserved account is not offered a fallback in place",
          capFallbackInPlace(policy: fleet, account: personal, primaryModel: "fable",
                             reserves: held, now: launch) == nil)
    check("…and is offered one when the account was pinned by hand (guard the premise)",
          capFallbackInPlace(policy: fleet, account: personal, primaryModel: "fable",
                             now: launch)?.model == "sonnet")

    // MARK: - R14. The ruling, at the gate that consumes it

    // Under its own line the account is SPENT, so the claim is not asked for at all - which is what
    // releases the idle sessions the reserve exists to get off it. `claim: { false }` stands in for
    // "another supervisor already holds this drought's one move".
    check("a session on an account under its reserve moves without the drought's claim",
          rebalance(claim: { false })?.id == "B")
    check("…and the turn boundary waives it on the same reading",
          boundary(claim: { false })?.id == "B")
    check("…while the same account with no reserve waits for the claim (guard the premise)",
          rebalance(current: acct("A", weekly: 3), reserves: .none, claim: { false }) == nil)
    // AND THE THREE TRUST GUARDS STAY IN FRONT OF IT. A reserve is read off a file; it is not
    // evidence about quota, and it must not be what makes numbers held over from a failed poll
    // actionable - every idle supervisor on the account would waive the claim on the same tick and
    // land on one sibling together, which is the stampede the claim was written to stop.
    check("a failed poll is not waived into a claim-free move by a reserve",
          rebalance(current: acct("A", weekly: 25, refreshFailed: true), claim: { false }) == nil)
    check("…nor is a stale row",
          rebalance(current: acct("A", weekly: 25, stale: true), claim: { false }) == nil)
    check("…nor is an errored one",
          rebalance(current: acct("A", weekly: 25, error: "boom"), claim: { false }) == nil)
    // The move itself is not refused by those rows, only the WAIVER: with the claim in hand the
    // session still leaves, which is what separates "cannot be trusted to skip the queue" from
    // "cannot be moved".
    check("…and each of them still moves once the claim is actually held",
          rebalance(current: acct("A", weekly: 25, refreshFailed: true))?.id == "B")

    // MARK: - R15. The wiring, which no value assertion can reach

    // The tick lives in a `while true` inside a process that spawns children, so the source carries
    // these - the technique the steering gate and the rebalance stand-down both use. Read off the
    // CALL rather than the file, because `reserves` is a word that now appears at eight stations.
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the reserve checks", !loop.isEmpty)
    check("the tick reads the reserves once, beside the policy from the same file",
          loop.contains("let reserves = accountReserves()"))
    check("…exactly once", loop.components(separatedBy: "accountReserves()").count == 2)
    func call(_ opening: String, until closing: String) -> String {
        guard let start = loop.range(of: opening),
              let end = loop.range(of: closing, range: start.upperBound ..< loop.endIndex)
        else { return "" }
        return String(loop[start.upperBound ..< end.upperBound])
    }
    check("the cap station is handed the reserves",
          call("applyCapHandoff(plan: &plan,", until: "reserves: reserves)")
              .contains("reserves: reserves"))
    check("the degradation rescue is handed them",
          call("applyDegradationRescue(plan: &plan,", until: "reserves: reserves)")
              .contains("reserves: reserves"))
    check("the preventive station is handed them",
          call("applyProactiveMoves(plan: &plan,", until: "reserves: reserves)")
              .contains("reserves: reserves"))
    check("the turn-boundary station is handed them",
          call("applyTurnBoundaryMove(plan: &plan,", until: "reserves: reserves)")
              .contains("reserves: reserves"))
    check("the directives station is handed them, for the follow and the model re-picks",
          call("applySessionDirectives(plan: &plan,", until: "keyboardIdle: { keyboard.idle($0) })")
              .contains("reserves: reserves"))
    check("the reload's ride on the rebalance is handed them",
          call("repick: {", until: "reserves: reserves)").contains("reserves: reserves"))
    check("the clear-boundary landing is handed them",
          call("clearBoundary: {", until: "reserves: reserves)").contains("reserves: reserves"))
    check("the advisory knock is handed them",
          call("applyQuotaKnock(&quotaKnock,", until: "filing: { quotaKnockFiling })")
              .contains("reserves: reserves"))
    // AND THE FIELD EVERY MOVER PLAYS ON IS NOT. Narrowing there would hide a reserved account from
    // the SENTENCE the knock writes about the fleet, and the gate one step later is where the
    // question "may Tally spend this" belongs.
    let field = (try? String(contentsOfFile: "TallyCLI/MoveField.swift", encoding: .utf8)) ?? ""
    check("the move field source is readable from the reserve checks", !field.isEmpty)
    check("…and the field itself asks nothing about reserves", !field.contains("reserves"))
    // THE PATHS A PERSON NAMED AN ACCOUNT ON PASS NOTHING, which is the whole of their exemption.
    // The manual-pin branch of the launcher is the one that would be silently wrong.
    let launcher = (try? String(contentsOfFile: "TallyCLI/main.swift", encoding: .utf8)) ?? ""
    check("the launcher source is readable from the reserve checks", !launcher.isEmpty)
    check("the reserves are read below every branch that launches a named account",
          launcher.range(of: "let reserves = accountReserves()").map { read in
              launcher.range(of: "(pinned)").map { $0.upperBound < read.lowerBound } ?? false
          } ?? false)
    check("…and the launch that spends one says so before it names the account",
          launcher.range(of: "reserveDipNotice(account,").map { notice in
              launcher.range(of: "pickReason(account, primaryModel: primaryModel)").map {
                  notice.upperBound < $0.lowerBound
              } ?? false
          } ?? false)
}
