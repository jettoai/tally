import Foundation

// THE SESSION BOARD A CAPTURE SHOWS (Tally/Core/DemoUsage.swift, `sessions`), which exists for one
// reason: the cards on a real board are named after the checkouts, accounts and conversations of
// whoever is running the app, and a README screenshot of that board would publish all three. The
// fixtures replace what a card SAYS while the rows stay the machine's own, which is the same
// bargain the footprint fixtures keep one question over (`DemoUsage.footprint`).
//
// AND THE STATE THAT CANNOT BE POSED FOR. `blocked` means Claude Code has stopped and asked
// somebody something in one of these terminals; a capture cannot sit and wait for it, and it is
// the state the board, the red card edge and the menu bar's dot all exist for. So the waiting
// fixture is first, and the checks below state that a board of ONE card still has it.
//
// COMPILED RATHER THAN READ, unlike the footprint fixtures' own checks: the session fixtures are
// pure functions over rows this harness can build, so what a card would be handed is asserted
// directly. The two rules that are not pure - the store laying the fixtures over its scan, and the
// menu bar counting the result - are read off the source, which is what this family does with a
// rule that only exists inside a live store or a SwiftUI body.
//
// LAST IN THE SUITE, ON PURPOSE. Turning the fixtures on means registering the launch flag in this
// process's defaults, and from that line on `DemoUsage.isActive` is true for everything that runs
// after it. Nothing else in this suite reads it today; running last is what keeps that true
// tomorrow without anybody having to remember it.

func runDemoSessionBoardChecks() {
    let t0 = Date(timeIntervalSince1970: 1_786_571_200)
    // The one string this suite looks for afterwards: every field of every REAL row carries it, so
    // any field a fixture forgets shows up as this marker on a card. Named like the things it
    // stands in for - a checkout, an account, a model - because that is what would be leaking.
    let sentinel = "thismachine"

    /// A row as the scan really hands one over, with something identifiable in every field a card
    /// can draw.
    func realRow(_ id: String) -> SessionRosterStore.SessionRow {
        var sidecar = SessionSidecar()
        sidecar.accountID = "claude:.claude5-\(sentinel)"
        sidecar.contextTokens = 999_111
        sidecar.updatedAt = t0
        sidecar.observedModel = "claude-\(sentinel)-observed"
        sidecar.runningModel = "claude-\(sentinel)-running"
        sidecar.sessionModel = "claude-\(sentinel)-pinned"
        sidecar.sessionEffort = "\(sentinel)-pin"
        sidecar.runningEffort = "\(sentinel)-effort"
        sidecar.sessionPin = "\(sentinel)-account"
        let record = SessionStateRecord(
            state: SupervisedState.working.rawValue, since: t0, updatedAt: t0,
            reason: "\(sentinel) is waiting", noticeType: "permission_prompt", quiet: false,
            accountID: "claude:.claude5-\(sentinel)",
            directory: "/Users/\(sentinel)/workspace/\(sentinel)-repo",
            project: "\(sentinel)-repo", worktree: "\(sentinel)-line",
            model: "\(sentinel)-model", childPid: 4_242)
        return SessionRosterStore.SessionRow(
            id: id, record: record, session: sidecar,
            cwd: "/Users/\(sentinel)/workspace/\(sentinel)-repo", child: 4_242)
    }

    /// Everything a card draws off one row, as strings: the whole population the leak check is run
    /// over. Taken from what the card files actually ask the row for, which the last check in this
    /// file pins, so a field added to a card cannot quietly stay outside this list.
    func drawn(_ row: SessionRosterStore.SessionRow) -> [String] {
        [row.title, row.directory ?? "", row.accountID ?? "", row.providerID ?? "",
         row.model ?? "", row.effort ?? "", row.reason ?? "", row.state.rawValue,
         String(row.contextTokens ?? 0), String(describing: row.since),
         String(describing: row.lastActivity), String(row.isReporting),
         // The badge the card actually draws is a function of this one and the installed version
         // (`outdatedSupervisorBuild`), so the raw field is the whole leak surface.
         row.supervisorVersion ?? ""]
    }

    let scan = (1 ... 8).map { realRow(String($0)) }

    // MARK: an ordinary launch is untouched

    check("without the flag the board is the scan itself, field for field",
          !DemoUsage.isActive && DemoUsage.sessions(scan) == scan)

    // The volatile registration domain rather than a write: this suite must leave nothing behind in
    // anybody's preferences, and the flag it stands in for is itself volatile (`-TallyDemoData`
    // lives in the argument domain, which is why an ordinary launch can never have it).
    UserDefaults.standard.register(defaults: ["TallyDemoData": true])
    check("the capture flag is what turns the fixtures on", DemoUsage.isActive)

    let board = DemoUsage.sessions(scan)
    check("every card is still a real session of this machine's, by pid",
          board.map(\.id) == scan.map(\.id) && board.count == scan.count)

    // MARK: nothing of this machine's reaches a card

    let leaked = board.flatMap { drawn($0) }.filter { $0.contains(sentinel) }
    check("no field any card draws still carries what the session really said", leaked.isEmpty)
    check("…the conversation sizes included, which are the figures on the stats line",
          board.allSatisfy { ($0.contextTokens ?? 0) != 999_111 })
    check("…and the checkout every card would otherwise be named after",
          board.allSatisfy { ($0.directory ?? "").hasPrefix("/Users/you/") })

    // THE TWO FIELDS THAT STAY REAL, and they are the two nothing on a card ever prints: the pid
    // the row is identified by, and the Claude Code the click jumps to. A demo card is still the
    // way to its own terminal.
    check("the way to the terminal is kept, being the one thing no card prints",
          board.allSatisfy { $0.childPid == 4_242 })

    // MARK: the account, the model and the effort a card names

    // A card names its account by asking the account list, so a fixture id naming nothing in it
    // would draw no account segment at all - a blank where the whole identity line starts
    // (`SessionRow.accountName`).
    let known = Set(DemoUsage.accounts().map(\.id))
    check("every fixture session runs on a fixture account the card can name",
          board.allSatisfy { $0.accountID.map(known.contains) == true })
    check("…and the provider mark is read off that id on every card",
          Set(board.compactMap(\.providerID)) == ["claude", "codex"])
    // The model ids are stored raw, so the card's own normalisation is the thing being exercised
    // rather than a pre-shortened string (`displayModelName`).
    check("the model each card prints is the short form the board spells everywhere",
          board.compactMap(\.model).allSatisfy { !$0.hasPrefix("claude-") }
              && board.compactMap(\.model).contains("fable-5")
              && board.compactMap(\.model).contains("gpt-5.6-sol"))
    check("one reporting card names no effort, which is the segment the identity line drops",
          board.filter { $0.isReporting && $0.effort == nil }.count == 1)
    // Two different absences, which is why the one above counts only the reporting cards: that one
    // is a session whose supervisor publishes no effort for it, this one is a supervisor old enough
    // to publish neither an effort nor a state.
    check("…and the quiet card names no effort either, being older than the axis",
          board.filter { !$0.isReporting }.allSatisfy { $0.effort == nil })
    check("one card carries a parallel line beside its project, which is how that field is drawn",
          board.filter { $0.title.contains(" · ") }.count == 1)
    check("no two cards are named the same thing",
          Set(board.map(\.title)).count == board.count)
    // The figure the README quotes about this board.
    check("the waiting card is the one carrying a 142k conversation",
          board.first { $0.state == .blocked }?.contextTokens == 142_000)

    // MARK: the card that is a build behind

    // THE SECOND STATE A CAPTURE CANNOT POSE FOR. A supervisor only reads as outdated in the window
    // between an app update landing and its own next idle moment, so the badge would otherwise
    // never appear on a screenshot - and the fixture cannot carry a literal version either, because
    // one that caught up with the app would draw NOTHING rather than something wrong.
    check("the lagging version is this build's own, one component back",
          DemoUsage.laggingVersion("0.64.2") == "0.64.1")
    check("…taking the last MOVING component, so a fresh minor does not come back unchanged",
          DemoUsage.laggingVersion("0.64.0") == "0.63.0"
              && DemoUsage.laggingVersion("1.0.0") == "0.0.0")
    check("…and nothing at all when there is nothing to take back, which draws no badge",
          DemoUsage.laggingVersion("0.0.0") == nil && DemoUsage.laggingVersion(nil) == nil)

    // Handed an installed version explicitly: `Bundle.main` in this harness is the test binary and
    // carries none, so a board built off the default would have no badge on it and every assertion
    // below would be green about nothing.
    // The badge is asked for the way a card asks, except that the installed side is handed in too:
    // `SessionRow.outdatedSupervisorVersion` reads it off `Bundle.main`, which is this test binary.
    let updating = DemoUsage.sessions(scan, installed: "9.9.9")
    let badges = updating.compactMap { outdatedSupervisorBuild($0.supervisorVersion,
                                                              installed: "9.9.9") }
    check("exactly one fixture card is watched by a build other than the installed one",
          badges.count == 1)
    check("…and it is the one the badge names, by ITS version rather than the app's",
          badges.first == "9.9.8")
    check("…while every other card says nothing at all, which is the ordinary board",
          updating.filter { $0.supervisorVersion == nil }.count == updating.count - 1)
    check("…and no field of the machine's own session reached that board either",
          updating.flatMap { drawn($0) }.allSatisfy { !$0.contains(sentinel) })

    // MARK: the states a capture cannot wait for

    check("the board shows four working, one blocked, two idle and one that cannot report",
          board.filter { $0.isReporting && $0.state == .working }.count == 4
              && board.filter { $0.isReporting && $0.state == .blocked }.count == 1
              && board.filter { $0.isReporting && $0.state == .idle }.count == 2
              && board.filter { !$0.isReporting }.count == 1)
    // What the red card edge, the waiting timer and the hover are all drawn from
    // (`SessionCardView.sessionIsWaiting`, `sessionReason`).
    let waiting = board.first { $0.state == .blocked }
    check("the waiting card says what it is waiting for, in a hook's own words",
          waiting?.reason == "Claude needs your permission to use Bash")
    check("…and has a moment to count the wait from",
          waiting.flatMap(\.since).map { $0 < Date() } == true)
    // A CAPTURE OF ANY SIZE HAS IT. The fixtures are handed out modulo their count, so a board of
    // one shows the first of them - and the first is the state that cannot be waited for.
    check("every board from one card up has the waiting card on it",
          (1 ... 8).allSatisfy { n in
              DemoUsage.sessions(Array(scan.prefix(n))).contains { $0.state == .blocked }
          })
    check("…the single-card board being the waiting one itself",
          DemoUsage.sessions([scan[0]]).first?.state == .blocked)

    // MARK: the same picture between two presses of the shutter

    check("two scans of one board are the same board, ages included",
          DemoUsage.sessions(scan) == DemoUsage.sessions(scan))
    // Keyed by the pid rather than by where the row sat in the scan, which is what `fixtureOrder`
    // buys: the roster's own order can change between scans (a session ends, another starts) and
    // the card under the shutter must not change fixture when it does.
    let shuffled = DemoUsage.sessions(scan.reversed())
    check("a card keeps its fixture however the scan happens to be ordered",
          Dictionary(uniqueKeysWithValues: shuffled.map { ($0.id, $0.title) })
              == Dictionary(uniqueKeysWithValues: board.map { ($0.id, $0.title) }))
    // A key listed twice takes two indices and answers to one of them, which would leave a card
    // with no fixture at all - and a card with no fixture is this machine's own name on a shot.
    check("a repeated pid still leaves every card fixtured",
          DemoUsage.sessions([scan[0], scan[0], scan[1]])
              .allSatisfy { row in drawn(row).allSatisfy { !$0.contains(sentinel) } })

    // MARK: how many fixtures there are, and what a bigger board does

    let wide = DemoUsage.sessions((1 ... 16).map { realRow(String(format: "%02d", $0)) })
    check("there are eight of them, and a wider board cycles rather than running out",
          Set(wide.prefix(8).map(\.title)).count == 8
              && wide.prefix(8).map(\.title) == wide.suffix(8).map(\.title))

    // MARK: what lays them over the board, and what counts the result

    let store = (try? String(contentsOfFile: "Tally/Stores/SessionRosterStore.swift",
                             encoding: .utf8)) ?? ""
    let statusItem = (try? String(contentsOfFile: "Tally/MenuBar/StatusItemButton.swift",
                                  encoding: .utf8)) ?? ""
    let cards = ["Tally/Views/SessionCardView.swift", "Tally/Views/SessionCardState.swift",
                 "Tally/Views/SessionCardFootprint.swift"]
        .map { (try? String(contentsOfFile: $0, encoding: .utf8)) ?? "" }
        .joined(separator: "\n")
    check("the sources this suite reads are readable from it",
          !store.isEmpty && !statusItem.isEmpty && !cards.isEmpty)

    // ONE PLACE LAYS THEM ON, and it is upstream of everything that reads a row: the seats, the
    // arrangement, the summary counts and the menu bar's dot all come off `rows`.
    check("the scan is fixtured before the board is seated",
          store.contains("let scanned = DemoUsage.sessions(liveSessionStates().map(Self.row))")
              && store.contains("Self.seat(scanned, seating: self.seating)"))
    check("…and the counts are readings of those same rows rather than a second scan",
          store.contains("var blockedCount: Int { count(.blocked) }")
              && store.contains("rows.filter { $0.isReporting && $0.state == state }.count"))
    check("…which is what the menu bar's dot is drawn from",
          statusItem.contains("SessionRosterStore.shared.blockedCount"))

    // EVERY FIELD A CARD ASKS THE ROW FOR IS ACCOUNTED FOR HERE. The leak check above can only see
    // the fields it is handed, so the population it is handed is checked against the cards
    // themselves: a card that starts drawing a new field would otherwise draw the real one with
    // nothing going red.
    let code = cards.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
    let asked = Set(code.components(separatedBy: "row.").dropFirst()
        .map { String($0.prefix { $0.isLetter || $0.isNumber }) }.filter { !$0.isEmpty })
    // The two that are deliberately the machine's own, and the reason they can be: neither is ever
    // printed. `id` is the supervisor pid the footprint readings are keyed by (fixtured in their
    // own right, `DemoUsage.footprint`), and `childPid` is the terminal the click jumps to.
    let covered: Set<String> = ["title", "state", "since", "reason", "model", "effort",
                                "contextTokens", "lastActivity", "directory", "accountName",
                                "providerID", "isReporting", "accountID", "id", "childPid",
                                "outdatedSupervisorVersion"]
    check("every field the cards read off a row is one this file replaces or keeps on purpose",
          asked.subtracting(covered).isEmpty)
}
