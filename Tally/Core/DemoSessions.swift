import Foundation

/// THE SESSION BOARD A CAPTURE SHOWS: every card's identity, its state and its figures replaced by
/// a fixture, so a README screenshot of the board is not a photograph of whoever took it.
///
/// WHAT THE OTHER FIXTURES ARE FOR IS STATED ONE FILE OVER (DemoUsage.swift, and this is the same
/// `-TallyDemoData` launch): fixture accounts, a plausible year of token history, and readings for
/// the process footprint. This one is the board of live sessions, which leaks a different KIND of
/// thing - not usage figures but the names of the checkouts somebody is working in, the accounts
/// they are on and how large those conversations have grown.
///
/// A FILE OF ITS OWN RATHER THAN A SECTION OF THAT ONE, for a reason that is about the harness
/// rather than about length: these fixtures are built out of the board's own types (the state
/// record, the sidecars, the roster's row), and three assertion suites compile DemoUsage.swift for
/// the account fixtures alone. Kept together, every one of them would have to compile the session
/// board and the supervisor machinery under it to get at nine fake accounts. Split, the suite that
/// asserts THIS (tests/supervisor/demoboardchecks.swift) is the only one that compiles it.
extension DemoUsage {
    /// THE INSTANT EVERY SESSION FIXTURE'S CLOCK IS MEASURED BACK FROM, taken once for the life of
    /// the process.
    ///
    /// TAKEN ONCE RATHER THAN PER SCAN, and both halves of that matter. A `Date()` read on every
    /// scan would hold each card at the same age for ever - a board of clocks that never move,
    /// which is the one thing on these cards a person watching the screen would notice - and it
    /// would also rewrite every record twice a second, defeating the store's own "nothing changed"
    /// guard (`SessionRosterStore.refresh`) and re-rendering every surface for a board that is
    /// standing still. Anchored, the ages tick up exactly as a live board's do and the rows compare
    /// equal between scans.
    private static let captureStarted = Date()

    /// One session's card as a capture draws it: who it is, what it is doing, and for how long.
    ///
    /// The offsets are measured back from `captureStarted`, so the fixtures below say how OLD a
    /// reading is rather than when it happened.
    private struct SessionFixture {
        /// The repository, and the parallel line beside it on the one card that has one. Both are
        /// what a supervisor publishes (`pickProject`), so the card's title is built the real way.
        let project: String
        var worktree: String?
        /// Where that checkout is. Fictional, like every path in this file: it is the field the
        /// board falls back to for a card whose supervisor published no state at all.
        let directory: String
        /// Which fixture account is serving it (`DemoUsage.accounts`), by id: the card names it
        /// through the same lookup a real one does, so a renamed demo account renames the card too.
        let account: String
        /// The model id as a supervisor writes it - raw, so the card's own normalisation is what
        /// shortens it (`displayModelName`) rather than this table pre-shortening it.
        var model: String?
        /// The effort the child is running at. Absent on one card, which is the state the identity
        /// line drops a segment for.
        var effort: String?
        let context: Int
        /// What it is doing, or nil for the supervisor that publishes no state at all - the board's
        /// fourth group, which is a card drawn from its sidecars alone.
        var state: SupervisedState?
        /// How long that has been true, and how long ago the conversation last moved.
        let since: TimeInterval
        let activity: TimeInterval
        /// What the wait is for, on the one card that is waiting: the hook's own sentence, which is
        /// exactly what a real record carries (`UserNotice.message`).
        var reason: String?
        var noticeType: String?
    }

    /// THE BOARD A CAPTURE SHOWS, one fixture per card, in `fixtureOrder`'s own order.
    ///
    /// EIGHT OF THEM, AND THE STATES ARE THE POINT: four working, one blocked, two idle and one
    /// that cannot report itself. That is the distribution a README shot needs and the one a real
    /// board reaches only by luck - `blocked` in particular cannot be waited for, since it means
    /// Claude Code has stopped and asked somebody something in one of these terminals. The waiting
    /// card is FIRST, so a capture of a single session still has it: the count is what the index is
    /// taken modulo, exactly as the footprint fixtures are, so a board of three shows the first
    /// three and the rest are simply not on that shot.
    ///
    /// THE NAMES ARE THE TOKEN TAB'S NAMES (`DemoUsage.tokenSamples`), for the reason its own
    /// note gives: a screenshot must carry a plausible year of work rather than real checkouts,
    /// and the two tabs of one shot naming different projects would read as two machines.
    private static let sessionFixtures: [SessionFixture] = [
        // THE CARD THE BOARD EXISTS FOR: red edge, the word, a waiting timer, and the hook's
        // sentence under a hover of that word (`SessionCardView`). It is also the menu bar's dot,
        // which is the one mark on the strip that is not a number (`StatusItemButton`).
        SessionFixture(project: "atlas", directory: "/Users/you/workspace/atlas",
                       account: "claude:demo-Claude", model: "claude-fable-5", effort: "high",
                       context: 142_000, state: .blocked, since: 4 * 60, activity: 70,
                       reason: "Claude needs your permission to use Bash",
                       noticeType: "permission_prompt"),
        // The one with a parallel line beside it, which is the only way that field is ever drawn.
        SessionFixture(project: "atlas", worktree: "feat-search",
                       directory: "/Users/you/workspace/atlas-feat-search",
                       account: "claude:demo-Claude 2", model: "claude-opus-5", effort: "high",
                       context: 61_000, state: .working, since: 12 * 60, activity: 20),
        // The one on the other provider, and the one with no effort to report: the identity line
        // drops the segment rather than drawing a placeholder (`sessionIdentityLine`), and this is
        // the card that shows it doing so.
        SessionFixture(project: "ledger", directory: "/Users/you/workspace/ledger",
                       account: "codex:demo-Codex", model: "gpt-5.6-sol",
                       context: 24_000, state: .working, since: 3 * 60, activity: 5),
        SessionFixture(project: "relay", directory: "/Users/you/workspace/relay",
                       account: "claude:demo-Claude 3", model: "claude-sonnet-5", effort: "medium",
                       context: 45_000, state: .idle, since: 26 * 60, activity: 26 * 60),
        SessionFixture(project: "beacon", directory: "/Users/you/workspace/beacon",
                       account: "claude:demo-Claude 2", model: "claude-opus-5", effort: "xhigh",
                       context: 208_000, state: .working, since: 65, activity: 10),
        // THE QUIET CARD: a supervisor too old to publish a state, drawn dimmed from the sidecars
        // it does write and counted under "not reporting" rather than as any of the three states
        // (`SessionRosterStore.count`). Its title comes from the directory, which is why this is
        // the fixture that proves that fallback carries a fictional name too.
        SessionFixture(project: "cinder", directory: "/Users/you/workspace/cinder",
                       account: "claude:demo-Claude 4", model: "claude-opus-5",
                       context: 12_000, state: nil, since: 0, activity: 3 * 3_600),
        SessionFixture(project: ".claude", directory: "/Users/you/.claude",
                       account: "claude:demo-Claude", model: "claude-fable-5", effort: "high",
                       context: 96_000, state: .idle, since: 72 * 60, activity: 60 * 60),
        SessionFixture(project: "dune", directory: "/Users/you/workspace/dune",
                       account: "codex:demo-Codex 2", model: "gpt-5.6-sol", effort: "high",
                       context: 187_000, state: .working, since: 8 * 60, activity: 45),
    ]

    /// THE WHOLE BOARD, FIXTURED, and empty of fixtures on every ordinary launch.
    ///
    /// KEYED BY THE CARDS THAT WILL BE DRAWN, the bargain `fixtureOrder` states: these ARE the rows
    /// the board is about to seat, so no card can take an index and then fail to appear, and the
    /// waiting fixture - the one state a capture cannot sit and wait for - is on every shot that
    /// has a card at all.
    ///
    /// A CARD THE ORDER SOMEHOW DOES NOT NAME STILL GETS A FIXTURE (index 0) rather than being left
    /// alone. Handed distinct pids that cannot happen; what decides the fallback is which way it is
    /// allowed to fail. Two cards sharing a fixture is a duplicated card in a screenshot; a card
    /// left alone is this machine's own checkout, account and conversation size in a picture bound
    /// for a public README, which is the whole reason this exists (see the file's note above).
    ///
    /// THE ROWS ARE STILL THE MACHINE'S OWN, exactly as the footprint fixtures leave them: this app
    /// invents no sessions, and every card on a demo board is a supervisor really running here. The
    /// pid and the Claude Code it spawned are kept for that reason too - a demo card is still the
    /// way to its own terminal - and they are the two fields nothing on a card ever prints.
    static func sessions(_ rows: [SessionRosterStore.SessionRow])
        -> [SessionRosterStore.SessionRow] {
        guard isActive else { return rows }
        let order = fixtureOrder(of: rows.map(\.id))
        return rows.map { session($0, at: order[$0.id] ?? 0) }
    }

    /// One card's identity, state and figures replaced by the fixture at this index.
    ///
    /// EVERY FIELD A CARD DRAWS IS STATED HERE, which is the same rule `DemoUsage.footprint`
    /// keeps and for the same reason: a field left alone keeps whatever the real session held, and
    /// board that is a checkout path, an account, a model and a conversation size belonging to
    /// whoever is running the capture. The record and the sidecar are therefore BUILT rather than
    /// edited - a copy with some fields overwritten would carry every field this table forgot.
    private static func session(_ real: SessionRosterStore.SessionRow,
                                at index: Int) -> SessionRosterStore.SessionRow {
        let fixture = sessionFixtures[index % sessionFixtures.count]
        let moved = captureStarted.addingTimeInterval(-fixture.activity)
        var sidecar = SessionSidecar()
        sidecar.accountID = fixture.account
        sidecar.contextTokens = fixture.context
        sidecar.updatedAt = moved
        sidecar.observedModel = fixture.model
        sidecar.runningEffort = fixture.effort
        let record = fixture.state.map { state in
            SessionStateRecord(state: state.rawValue,
                               since: captureStarted.addingTimeInterval(-fixture.since),
                               updatedAt: moved, reason: fixture.reason,
                               noticeType: fixture.noticeType, quiet: state != .working,
                               accountID: fixture.account, directory: fixture.directory,
                               project: fixture.project, worktree: fixture.worktree,
                               // Short form, because that is what a supervisor publishes here: the
                               // record's own writer trims the id before it writes it, and the
                               // sidecar's is the raw one (`SessionRow.model`).
                               model: fixture.model.map(displayModelName),
                               childPid: real.childPid)
        }
        return SessionRosterStore.SessionRow(id: real.id, record: record, session: sidecar,
                                             cwd: fixture.directory, child: real.child)
    }
}
