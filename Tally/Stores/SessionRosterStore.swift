import Foundation
import Observation

/// The one vendor that stamps its own name onto every id it ships.
private let modelVendorPrefix = "claude-"

/// A model id AS A CARD PRINTS IT: the vendor's name off the front, everything else kept.
/// `claude-opus-5` -> `opus-5`, `claude-fable-5` -> `fable-5`, `gpt-5.6-sol` unchanged.
///
/// WHY THE VENDOR GOES AND NOTHING ELSE DOES. The card already names the vendor one field to the
/// left - the account serving the session is called "Claude 5" - so an identity line reading
/// "Claude 5 · claude-opus-5 · high" said Claude twice and spent a truncating line's width doing it.
/// Every segment after that prefix is kept because every one of them tells two models apart.
///
/// NOT `shortModelName`, and the split is by what the answer is FOR rather than by taste.
/// That one normalises for a JUDGEMENT - "is what is serving this session the model I asked for" -
/// so it keeps the family and drops the rest (`claude-opus-4-8` -> `opus`), which is exactly the
/// right coarseness for a comparison and the wrong one here: run a Codex id through it and
/// `gpt-5.6-sol` reads `gpt`, erasing the only segment that separates it from `gpt-5.6-terra`.
/// This one is read by a person, so it drops the one segment that is already on screen and nothing
/// else. Neither may be applied on the writing side: what the supervisor publishes is read by the
/// drift check and the status line too (`syncSessionState`).
func displayModelName(_ id: String) -> String {
    // A bare prefix and nothing after it is left whole: dropping it would trade an odd-looking id
    // for an empty field, and a blank is the one answer that says less than the raw string.
    guard id.lowercased().hasPrefix(modelVendorPrefix), id.count > modelVendorPrefix.count
    else { return id }
    return String(id.dropFirst(modelVendorPrefix.count))
}

/// WHICH SESSIONS ARE RUNNING AND WHAT THEY ARE DOING, as the panel draws them.
///
/// A READER AND NOTHING ELSE. Every state on this board was decided by the supervisor that owns the
/// session (SessionState.swift says why nothing else can), so this store reads files and seats
/// rows; it never infers a state, and a session that has published none is drawn as one that has
/// published none.
///
/// AND THE SEATS ARE TAKEN ONCE PER LAUNCH. The state sort decides them at the first scan that finds
/// a board, and from then on a card keeps the seat it was given: a session that goes from working to
/// blocked lights its own dot where it already sits rather than jumping to the top. A board that
/// re-sorted itself twice a second is a board nobody can learn. `sorted` says what the order IS;
/// `seat` says how long it lasts.
///
/// WHEN IT SCANS, which is the whole of its cost story:
///
///   - While a surface is on screen, every 2 seconds. A directory listing plus a handful of small
///     files per session is what a scan costs (the state reading, and the three sidecars beside it
///     - see `SessionSidecar`). NOT what makes the durations column tick: a scan that finds
///     the board unchanged assigns nothing on purpose (see `refresh`), so the age text is driven by
///     a timeline in the view instead (`SessionBoardView`).
///   - On the supervisors' knock, always, panel or no panel. That is what keeps the menu bar's
///     blocked dot honest while every window is closed: a state change posts
///     `sessionStateChangedNotification`, and the dot is the one reader that cannot wait for
///     somebody to open something.
///
/// There is no third mode, deliberately. A background timer would poll a directory nobody is
/// looking at for the life of the app, and the two triggers above already cover both readers.
@MainActor
@Observable
final class SessionRosterStore {
    static let shared = SessionRosterStore()

    /// The board, in the seats it took (see `seat`). EVERY LIVE SESSION IS ON IT, including the
    /// ones whose supervisor has published no state - a build older than this feature, or one in
    /// the two seconds between registering and its first tick. They are drawn as their own quiet
    /// card rather than summarized as a number, for the reason `reloadLegacyNotice` exists one
    /// question over: the sessions are running, and a board that reduced them to a count would be
    /// naming a number the user cannot act on. What they still know about themselves comes from the
    /// sidecars beside the state file (`SessionSidecar`).
    private(set) var rows: [SessionRow] = []

    /// How many of them cannot say what they are doing. Derived rather than stored: it is a reading
    /// of the same rows, and two places holding it would be two places to disagree.
    var notReporting: Int { rows.filter { !$0.isReporting }.count }

    /// Called after every change that a reader outside SwiftUI has to act on: the menu bar's
    /// blocked dot, which is drawn imperatively (`StatusItemController.updateButton`).
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var timer: Timer?
    /// WHERE EACH SESSION SITS, as supervisor pids in board order, or nil until a scan finds a board
    /// to seat. Everything about the freeze is this one field, and `seat` is all of the rule.
    ///
    /// NOT PERSISTED, deliberately, and the one place the board's two orders differ: an arrangement
    /// is something the user MADE and expects to find again (`SessionBoardOrder` keys it by project
    /// so it outlives the sessions), while a seat belongs to a pid that will not exist tomorrow. So
    /// each launch seats the board afresh from what is running then.
    @ObservationIgnored private var seating: [String]?
    /// How many surfaces are currently showing the board. Three hosts can be open at once (the
    /// popover, the pinned panel, the dashboard window), so this is a count rather than a flag:
    /// one of them closing must not stop the polling the other two are relying on.
    @ObservationIgnored private var viewers = 0

    private init() {}

    /// One session's row: the reading its supervisor published, the sidecars beside it, and the
    /// identity a list needs.
    ///
    /// THE RECORD IS CARRIED WHOLE rather than copied out field by field, which is the difference
    /// between a field added to the contract appearing here for free and a field added to the
    /// contract being silently dropped by a mapping nobody remembered to extend.
    ///
    /// AND IT IS OPTIONAL, because the session is not: a supervisor too old to publish a state is
    /// running all the same, and the sidecars it DOES write still say which account it is on, what
    /// it is running and how big the conversation is. Every accessor below therefore reads "what is
    /// known" rather than "what the state file said", and falls back rather than going blank.
    struct SessionRow: Identifiable, Equatable {
        /// The supervisor pid, as a string. Stable for the life of the session, which is what makes
        /// it the row's identity across refreshes.
        let id: String
        /// What this session published about what it is DOING, or nil when it has published none.
        let record: SessionStateRecord?
        /// The context reading beside it (`<pid>.session`), which older supervisors write too.
        var session: SessionSidecar?
        /// The directory this supervisor was started in (`<pid>.cwd`), written once at startup by
        /// every build that has ever had the file.
        var cwd: String?
        /// The Claude Code this supervisor spawned (`<pid>.child`), used only as the fallback the
        /// state record's own `childPid` normally provides.
        var child: Int?

        /// Whether this session can say what it is doing. The board's fourth group and its quietest
        /// kind of card.
        var isReporting: Bool { record != nil }
        var state: SupervisedState { record?.supervised ?? .unknown }
        /// When it entered that state, for a session that has published one.
        var since: Date? { record?.since }
        /// What it is waiting for, while it is waiting.
        var reason: String? { record?.reason }
        /// The checkout, which is what the terminal jump matches a window against.
        var directory: String? { record?.directory ?? cwd }
        var accountID: String? { record?.accountID ?? session?.accountID }

        /// Which PROVIDER is serving this session, taken off the account id's own head
        /// (`claude:.claude5` -> `claude`). Read for the mark the identity line leads with, which is
        /// the one thing on that line the user cannot rename away: the account beside it is called
        /// whatever they have called it ("Work" says nothing about whose Work), and the model id is
        /// an open axis - a dated snapshot or a Bedrock arn names no vendor either.
        ///
        /// nil rather than a guess when the id has no head to read: no colon at all, or a colon in
        /// front (`:.claude5`). Both are addresses this build does not understand, and naming a
        /// provider off one would put a wrong mark on the card rather than no mark.
        var providerID: String? {
            guard let accountID, let colon = accountID.firstIndex(of: ":"),
                  colon != accountID.startIndex else { return nil }
            return String(accountID[..<colon])
        }

        /// What the card CALLS the account this session is on, given a way to name one.
        ///
        /// THE NAMING IS THE CALLER'S because only the surface holds it: the account list and the
        /// user's own names for its members live in two app stores, and this row is compiled into
        /// an assertion harness that has neither. What is fixed HERE is the answer when the naming
        /// comes back empty-handed - an id naming an account this build cannot see, which is an
        /// ordinary state rather than an error (a session outlives the account it was started on:
        /// the config home goes to the Trash and the supervisor keeps running).
        ///
        /// AND THAT ANSWER IS NOTHING AT ALL, never the id. `claude:.claude5` is an address, not a
        /// name; a card printing one would read as a bug on a board whose other cards read as
        /// sentences, and the segment it would occupy is on a line that truncates. A missing
        /// segment is what the rest of this row already does with everything it cannot say.
        func accountName(_ name: (String) -> String?) -> String? {
            accountID.flatMap(name)
        }

        /// What is SERVING this session, most trustworthy answer first: the model seen answering
        /// the last turn, then the one the child was launched with, then whatever the state record
        /// carried. The order is `SupervisedSession`'s own reasoning - an observation beats a
        /// request, because a fallback or a `/model` moves the answer without moving the argv.
        ///
        /// AND ALL THREE ARE SPELLED THE ONE WAY HERE, which is why the normalisation is on the row
        /// rather than in the view that draws it: only the first two are raw ids (the state record's
        /// was already trimmed by its writer), so a board reading them straight printed
        /// `claude-opus-5` on the cards that had been observed and `opus` on the ones that had
        /// fallen back - two spellings of one answer, side by side, on the same page.
        var model: String? {
            Self.firstAnswer(session?.observedModel, session?.runningModel, record?.model)
                .map(displayModelName)
        }
        /// The effort it is running at: a pin if one was set for this session, otherwise what the
        /// child is actually running. Absent on a document written before the axis existed, which
        /// reads as "cannot say" and is simply not drawn.
        var effort: String? { Self.firstAnswer(session?.sessionEffort, session?.runningEffort) }

        /// The first of these that actually says something. An empty string is not an answer: a
        /// field written blank by a build that had nothing to put in it must not outrank the one
        /// behind it that does.
        private static func firstAnswer(_ candidates: String?...) -> String? {
            candidates.compactMap { $0 }.first { !$0.isEmpty }
        }
        /// How big the conversation is, when a turn has been read. ZERO IS NOT A READING: the
        /// figure is published from an assistant turn's own usage, so nothing but "no turn yet"
        /// produces one, and drawing "0" would state a measurement nobody took.
        var contextTokens: Int? {
            guard let tokens = session?.contextTokens, tokens > 0 else { return nil }
            return tokens
        }
        /// When that reading was taken, which is the age of the last turn rather than of the poll.
        var lastActivity: Date? { session?.updatedAt }
        /// The Claude Code to jump to. The record's is the vetted one (the supervisor publishes it
        /// only while it can prove it); the sidecar is the fallback that reaches a session too old
        /// to publish a state at all, checked for liveness and nothing more (see `readChildPid`).
        var childPid: Int? { record?.childPid ?? child }

        /// What the row is called: the repository, with its parallel line beside it. A session in a
        /// directory git cannot answer for still has a name (`pickProject` guarantees one), so the
        /// published pair is used whenever there is one; a supervisor that published neither is
        /// named after the directory it runs in, which is the same name by another route.
        var title: String {
            let published = [record?.project, record?.worktree]
                .compactMap { $0 }.filter { !$0.isEmpty }
            guard published.isEmpty else {
                return published.joined(separator: pickEffortSeparator)
            }
            return cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        }
    }

    /// How many sessions are in each state, over the WHOLE board: what the page's summary says, and
    /// deliberately not filtered by what the page is currently listing (a count that moved with the
    /// filter would be answering a different question than the one it is read for).
    var blockedCount: Int { count(.blocked) }
    var workingCount: Int { count(.working) }
    var idleCount: Int { count(.idle) }

    /// Reporting only: a session that cannot say what it is doing is not idle, and counting it as
    /// any of the three would be inventing the reading its absence IS.
    private func count(_ state: SupervisedState) -> Int {
        rows.filter { $0.isReporting && $0.state == state }.count
    }

    // MARK: Lifecycle

    /// Start listening for the supervisors' knock, for the life of the process. Registered once
    /// exactly as the pick panel's observer and the update check's are, and for the same reason: a
    /// missed registration is a feature that silently never fires.
    func install() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(stateChanged),
            name: Notification.Name(sessionStateChangedNotification), object: nil)
        refresh()
    }

    @objc nonisolated private func stateChanged(_ note: Notification) {
        Task { @MainActor in self.refresh() }
    }

    /// A surface showing the board has appeared. Refreshes immediately, because what somebody just
    /// opened has to be current before the first tick rather than after it.
    func beginViewing() {
        viewers += 1
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            Task { @MainActor in SessionRosterStore.shared.refresh() }
        }
        // `.common`, so the board keeps ticking while a menu or a scroll is tracking: a default-mode
        // timer stops for the whole of either, and a duration frozen mid-read is the one thing on
        // this row a person would notice.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func endViewing() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    // MARK: The scan

    func refresh() {
        let (rows, seating) = Self.seat(liveSessionStates().map(Self.row), seating: self.seating)
        self.seating = seating
        // Nothing changed is the ordinary tick, and assigning anyway would re-render every surface
        // twice a second for a board that is standing still.
        guard rows != self.rows else { return }
        self.rows = rows
        onChange?()
    }

    /// TAKE THE SEATS AGAIN, from what every session is doing now: the board's own "Sort by status"
    /// (`sessionsSortByStateButton`), which sorts once exactly as a launch does and then holds that
    /// order again. Clearing the ARRANGEMENT is the caller's half of that button
    /// (`SettingsStore.sortSessionBoardByState`) because it is the caller's to hold: this store
    /// knows nothing about what was dragged.
    func resortByState() {
        seating = nil
        refresh()
    }

    /// One live session, joined with everything beside it on disk. Nothing here is required: a
    /// session with no state, no context reading and no directory is still a session, and reads as
    /// a card that knows only that it is running.
    private static func row(_ live: LiveSessionState) -> SessionRow {
        let pid = String(live.supervisorPid)
        return SessionRow(id: pid, record: live.record,
                          session: SessionSidecar.read(pid: pid),
                          cwd: SessionSidecar.readCwd(pid: pid),
                          child: SessionSidecar.readChildPid(pid: pid))
    }

    /// The board's order: what needs somebody first, then what is moving, then what is not, then
    /// what cannot say, and last of all what cannot say ANYTHING. Within a group the OLDEST leads,
    /// because the age of the wait is the thing worth acting on.
    ///
    /// ASKED TWICE IN THE LIFE OF THE APP, not twice a second: once at the first scan of a launch
    /// and once more whenever somebody presses "Sort by status" (`refresh`, `resortByState`). It is
    /// the only thing that ever DECIDES an order here; what holds that decision still is `seat`.
    /// `nonisolated` because it is a pure function of what it is handed and nothing else, which is
    /// also what lets the assertion harness state the order without an app around it.
    nonisolated static func sorted(_ rows: [SessionRow]) -> [SessionRow] {
        rows.sorted {
            rank($0) != rank($1) ? rank($0) < rank($1) : ordinal($0) < ordinal($1)
        }
    }

    /// ONE SCAN'S BOARD, AND THE SEATING IT LEAVES BEHIND: the whole of the freeze, pure, so the
    /// harness can state every case of it without an app around it (`refresh` is then the two lines
    /// that carry the seating between scans).
    ///
    ///   - Handed no seating, a scan that FOUND something takes its seats from the state sort and no
    ///     scan after it may: the "first sort of the launch" the board then holds.
    ///   - Every scan after that keeps each card where it is. A state change rewrites what a card
    ///     SAYS and never where it sits, because the one thing here that reads a state is `sorted`,
    ///     and the seating is what it wrote once rather than what it would write now.
    ///   - A session the seating never heard of goes to the END, in the order the scan handed it
    ///     over, which is ascending supervisor pid (`liveSessionStates`): one that started later has
    ///     the higher pid, so "new cards join at the bottom" needs no clock of its own.
    ///   - A session that ended leaves its seat and nothing else moves - the seating that comes back
    ///     is read off the board rather than maintained beside it - and an empty board comes back
    ///     unseated, so whatever appears after one is sorted again. Nothing is at risk there: an
    ///     empty board has no cards to move.
    nonisolated static func seat(_ scanned: [SessionRow],
                                 seating: [String]?) -> (rows: [SessionRow], seating: [String]?) {
        let rows = ordered(scanned, by: seating ?? sorted(scanned).map(\.id)) { $0.id }
        return (rows, rows.isEmpty ? nil : rows.map(\.id))
    }

    /// The board in the order somebody DRAGGED it into, given what they have arranged so far
    /// (`SessionBoardOrder`, which says why the arrangement is written in project directories).
    ///
    /// Handed the seated board and nothing else, so the two orders compose in one direction only:
    /// an empty arrangement is the seating untouched, and inside one seat - two sessions of the
    /// same project - the seating is what still separates them. The stable tie-break is what
    /// carries that, so it is not an implementation detail: rewrite it as an unstable sort and two
    /// sessions of one project start swapping places twice a second.
    ///
    /// A PROJECT NOBODY HAS ARRANGED SITS LAST, in the order it arrived in. A session started in a
    /// new checkout has to appear somewhere, and anywhere else means the board rearranging itself
    /// around a card the user never touched.
    ///
    /// `nonisolated` for the reason `sorted` is: it is a pure function of what it is handed, which
    /// is also what lets the assertion harness state the order without an app around it.
    nonisolated static func arranged(_ rows: [SessionRow], manualKeys: [String]) -> [SessionRow] {
        guard SessionBoardOrder.isManual(manualKeys) else { return rows }
        return ordered(rows, by: manualKeys, key: orderKey)
    }

    /// Rows in the order a list of keys names, stably: what the list does not name keeps the order
    /// it was handed in, at the end. Spelled once because the board's two orders are the same
    /// ordering asked about two different keys - a card's session (the seating) and a card's project
    /// (the arrangement) - and two copies of it would be two places for the tie-break to rot.
    nonisolated private static func ordered(_ rows: [SessionRow], by keys: [String],
                                            key: (SessionRow) -> String?) -> [SessionRow] {
        // The arrangement's own index, which is plain string algebra: first mention wins, blanks are
        // not keys (`SessionBoardOrder.ranking`). Both true of pids as well as of directories.
        let ranking = SessionBoardOrder.ranking(keys)
        return rows.enumerated().sorted { lhs, rhs in
            let left = key(lhs.element).flatMap { ranking[$0] } ?? Int.max
            let right = key(rhs.element).flatMap { ranking[$0] } ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// What a card is ARRANGED by: the directory its session runs in, which outlives the session
    /// (`SessionBoardOrder`). Nil for a session that has published no directory at all - it cannot
    /// be dragged and cannot be dropped onto, because there is nothing about it to remember.
    nonisolated static func orderKey(_ row: SessionRow) -> String? {
        guard let directory = row.directory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else { return nil }
        return directory
    }

    /// A session that has published nothing sits below all four states rather than among the
    /// unknowns: "running, with nothing to say about it yet" is a reading, and this is the absence
    /// of one.
    nonisolated private static func rank(_ row: SessionRow) -> Int {
        guard row.isReporting else { return 4 }
        switch row.state {
        case .blocked: return 0
        case .working: return 1
        case .idle: return 2
        case .unknown: return 3
        }
    }

    /// What a row is aged by inside its group: when it entered its state, or - for one that has
    /// published no state - when it last had a turn. Neither is known for a session that has
    /// published nothing at all, and those sort as the oldest, which is what they are: a supervisor
    /// with no files beside it has been there since before this feature existed.
    nonisolated private static func ordinal(_ row: SessionRow) -> Date {
        row.since ?? row.lastActivity ?? .distantPast
    }
}

/// THE FILES THE SUPERVISOR WRITES BESIDE ITS STATE, as the panel reads them.
///
/// `<pid>.session` is the context reading (`SupervisedSession`, TallyCLI/SessionContext.swift),
/// `<pid>.cwd` the directory the session runs in and `<pid>.child` the Claude Code it spawned. All
/// three predate the status board, which is exactly why the board reads them: a supervisor too old
/// to publish a state still writes these, so a session that cannot say what it is DOING can still
/// say what it is, where, and how big it has grown.
///
/// A SEPARATE DECLARATION FROM THE WRITER'S, deliberately. The app compiles the state record itself
/// (project.yml says why), but the context reading lives in a file full of supervisor machinery -
/// transcript scanning, the writer's own change gate - that the app has no business carrying. So
/// this is a reader's view of that document: every field optional, unknown fields ignored, and the
/// suffixes asserted against the writer's own constants in `tests/supervisor/sessionstatechecks.swift`
/// so the two spellings cannot drift apart in silence.
struct SessionSidecar: Equatable, Decodable {
    var accountID: String?
    var contextTokens: Int?
    var updatedAt: Date?
    var sessionPin: String?
    var sessionModel: String?
    var sessionEffort: String?
    var observedModel: String?
    var runningModel: String?
    var runningEffort: String?

    /// The app's spelling of the three suffixes. Held here rather than typed at each call site, and
    /// locked to the writer's in the assertions above.
    static let contextSuffix = ".session"
    static let cwdSuffix = ".cwd"
    static let childSuffix = ".child"

    /// A document that cannot be read, or cannot be understood, reads as no document: the board
    /// simply draws the parts it knows. Same best-effort rule the state reading beside it follows.
    static func read(pid: String, dir: URL = supervisorStateDir) -> SessionSidecar? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(pid + contextSuffix))
        else { return nil }
        let decoder = JSONDecoder()
        // THE WRITER'S FORM AND ANYTHING NEWER. `.iso8601` alone rejects a stamp carrying fractional
        // seconds outright, and rejecting is losing the whole reading - the same failure the state
        // record's string-typed state word exists to avoid, one field over (and the fractional form
        // is not hypothetical: the user-notice file gained one on 2026-08-13).
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let forms: [ISO8601DateFormatter.Options] = [
                [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds],
            ]
            for options in forms {
                let parser = ISO8601DateFormatter()
                parser.formatOptions = options
                if let date = parser.date(from: text) { return date }
            }
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "not an instant: \(text)")
        }
        return try? decoder.decode(SessionSidecar.self, from: data)
    }

    /// The directory this supervisor was started in, or nil when the file is absent or empty (an
    /// empty one is a write that got as far as the file and no further, which says nothing).
    static func readCwd(pid: String, dir: URL = supervisorStateDir) -> String? {
        guard let raw = try? String(contentsOf: dir.appendingPathComponent(pid + cwdSuffix),
                                    encoding: .utf8) else { return nil }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    /// The Claude Code pid this supervisor spawned, IF IT IS STILL RUNNING. A publish that failed
    /// leaves the previous child's number behind, and a dead pid handed to the terminal jump is a
    /// click that matches nothing; liveness is what this can check cheaply and it checks exactly
    /// that. The CLI's own reader (`readSupervisorChild`) additionally proves the process is this
    /// supervisor's child, which needs the process table - the app settles for less here because
    /// the cost of being wrong is one fallback, not a wrong decision: the jump falls back to the
    /// directory match and then to a bare activate.
    static func readChildPid(pid: String, dir: URL = supervisorStateDir) -> Int? {
        guard let raw = try? String(contentsOf: dir.appendingPathComponent(pid + childSuffix),
                                    encoding: .utf8),
              let child = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let running = pid_t(exactly: child), supervisorAlive(running) else { return nil }
        return child
    }
}
