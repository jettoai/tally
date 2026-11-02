import Foundation

// B-3570: INSIDE THE TIE BAND THE EARLIEST PUBLISHED WEEKLY RESET WINS. The smart pick used to walk
// the list with its first account as the leader, so which of several near-equal accounts won was the
// order of the config folders. The failing sample is the 2026-11-02T04:18:35Z snapshot: albert (top
// score, earliest reset) went unmarked and doro, 0.736 to its 0.780, took the badge.

func runTieBreakChecks() {
    func weekly(_ id: String, _ remaining: Double, hours: Double, resets: Int? = nil) -> Snapshot.Account {
        account(id, weekly: (remaining, inHours(hours)), resets: resets)
    }
    let sample = [
        weekly("doro", 94, hours: 127.7), weekly("albert", 98, hours: 125.7),
        weekly("albert5", 100, hours: 132.7), weekly("666", 100, hours: 136.7),
        weekly("hyde", 71, hours: 84.7), weekly("albert2", 21, hours: 60.7),
        weekly("albert4", 10, hours: 35.7), weekly("albert3", 12, hours: 61.7),
    ]
    let hydeReserve = AccountReserves(settings: ["/tmp/hyde": AccountRoleSetting(role: "personal", reserve: 20)])
    func sampleSnapshot(_ accounts: [Snapshot.Account]) -> Snapshot {
        Snapshot(version: 2, generatedAt: now, accounts: accounts)
    }
    func sampleScore(_ a: Snapshot.Account) -> Double {
        smartScore(a, primaryModel: "opus", reserves: hydeReserve, now: now)
    }
    func samplePick(_ accounts: [Snapshot.Account]) -> String? {
        best(providerID: "claude", in: sampleSnapshot(accounts), primaryModel: "opus",
             reserves: hydeReserve, now: now)?.id
    }
    func decision(_ accounts: [Snapshot.Account]) -> SmartPickResult<Snapshot.Account>? {
        smartPickLeader(accounts, score: sampleScore, weeklyResetsAt: { $0.weeklyResetsAt },
                        resetCredits: { $0.resetCreditsAvailable ?? 0 })
    }
    let byID = Dictionary(uniqueKeysWithValues: sample.map { ($0.id, $0) })
    let top = sampleScore(byID["albert"]!)

    check("the failing sample: the top-score, earliest-reset account takes the pick",
          samplePick(sample) == "albert")
    check("…and the premise holds: doro is tied with albert but scores lower",
          smartPickTied(sampleScore(byID["doro"]!), top: top) && sampleScore(byID["doro"]!) < top
              && sampleScore(byID["albert"]!) == sample.map(sampleScore).max())
    check("…and hyde, albert2/3/4 are outside the band (their score is too far below)",
          ["hyde", "albert2", "albert3", "albert4"].allSatisfy { !smartPickTied(sampleScore(byID[$0]!), top: top) })
    check("the same sample listed in reverse picks the same account",
          samplePick(sample.reversed()) == "albert")
    let result = decision(sample)
    check("the decision names three tied accounts and the earliest reset as the reason",
          result?.leader.id == "albert" && result?.othersTied == 3 && result?.decidedBy == .earliestReset)

    let codex = [weekly("codex1", 26, hours: 50.4, resets: 3), weekly("codex2", 51, hours: 87.1, resets: 3)]
    check("Codex: the earlier reset wins the tie (codex1), in either list order",
          [codex, codex.reversed()].allSatisfy {
              best(providerID: "claude", in: sampleSnapshot($0), now: now)?.id == "codex1"
          })

    // Stability: the leader keeps the pick while it stays in the band and gives it up once it is out.
    func albert(_ remaining: Double) -> [Snapshot.Account] {
        sample.map { $0.id == "albert" ? weekly("albert", remaining, hours: 125.7) : $0 }
    }
    check("albert at 83% is still tied with the top and keeps the pick", samplePick(albert(83)) == "albert")
    check("albert at 82% falls out of the band and doro (earliest left in it) takes over",
          samplePick(albert(82)) == "doro")

    // The band is measured from the TOP score only, so two accounts tied with each other but not
    // with the top cannot pull the pick away: E ties X, but 1.00 beats 0.80 by both gates.
    let cycle = smartPickLeader(["A", "X", "E"],
        score: { ["A": 1.00, "X": 0.88, "E": 0.80][$0]! },
        weeklyResetsAt: { inHours(["A": 130, "X": 100, "E": 60][$0]!) },
        resetCredits: { _ in 0 })
    check("a non-transitive tie cannot reach past the top score", cycle?.leader == "X")

    // An estimated anchor never decides: an untouched window (100%) carries no published reset.
    let untouched = account("A", weekly: (100, nil))
    let published = account("B", weekly: (97, inHours(90)))
    check("the untouched window and the published one are tied (guard the premise)",
          smartPickTied(score(published), top: score(untouched)) && score(untouched) > score(published))
    check("a published reset outranks an estimated anchor, in either order",
          pick([untouched, published]) == "B" && pick([published, untouched]) == "B")

    // Source locks: the badge and the launcher must keep ending in the one shared function.
    let autoPick = (try? String(contentsOfFile: "Tally/Stores/LaunchPolicyStore+AutoPick.swift", encoding: .utf8)) ?? ""
    let cliPick = (try? String(contentsOfFile: "TallyCLI/AccountPick.swift", encoding: .utf8)) ?? ""
    let policyStore = (try? String(contentsOfFile: "Tally/Stores/LaunchPolicyStore.swift", encoding: .utf8)) ?? ""
    check("the panel pick ends in the shared leader function, reading the weekly window's published reset",
          autoPick.contains("smartPickLeader(candidates,") && autoPick.contains(".kind == .weeklyAll }?.resetsAt"))
    check("the launcher ends in it too",
          cliPick.contains("smartPickLeader(candidates,"))
    check("neither side carries the hand-rolled leader loop any more",
          !autoPick.contains("leaderScore * Self.smartPickMargin") && !cliPick.contains("leaderScore * smartPickMargin"))
    check("and the panel store holds no second copy of the margin constants",
          !policyStore.contains("static let smartPickMargin") && !policyStore.contains("static let smartPickMinGain"))
}
