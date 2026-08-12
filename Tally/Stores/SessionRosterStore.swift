import Foundation
import Observation

/// WHICH SESSIONS ARE RUNNING AND WHAT THEY ARE DOING, as the panel draws them.
///
/// A READER AND NOTHING ELSE. Every state on this board was decided by the supervisor that owns the
/// session (SessionState.swift says why nothing else can), so this store reads files and sorts
/// rows; it never infers a state, and a session that has published none is drawn as one that has
/// published none.
///
/// WHEN IT SCANS, which is the whole of its cost story:
///
///   - While a surface is on screen, every 2 seconds. A directory listing plus one small file per
///     session is what a scan costs. NOT what makes the durations column tick: a scan that finds
///     the board unchanged assigns nothing on purpose (see `refresh`), so the age text is driven by
///     a timeline in the view instead (`SessionSectionView`).
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

    /// The board, sorted (see `sorted`). Empty means nothing is running, which is what the panel
    /// renders as no section at all.
    private(set) var rows: [SessionRow] = []
    /// Live sessions whose supervisor has published no state: one from a build older than this
    /// feature, or one in the two seconds between registering and its first tick. COUNTED RATHER
    /// THAN DROPPED, for the reason `reloadLegacyNotice` exists one question over: the sessions are
    /// running, and a board that silently omitted them would be under-reporting rather than quiet.
    private(set) var notReporting = 0

    /// Called after every change that a reader outside SwiftUI has to act on: the menu bar's
    /// blocked dot, which is drawn imperatively (`StatusItemController.updateButton`).
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var timer: Timer?
    /// How many surfaces are currently showing the board. Three hosts can be open at once (the
    /// popover, the pinned panel, the dashboard window), so this is a count rather than a flag:
    /// one of them closing must not stop the polling the other two are relying on.
    @ObservationIgnored private var viewers = 0

    private init() {}

    /// One session's row: the reading its supervisor published, plus the identity a list needs.
    ///
    /// THE RECORD IS CARRIED WHOLE rather than copied out field by field, which is the difference
    /// between a field added to the contract appearing here for free and a field added to the
    /// contract being silently dropped by a mapping nobody remembered to extend.
    struct SessionRow: Identifiable, Equatable {
        /// The supervisor pid, as a string. Stable for the life of the session, which is what makes
        /// it the row's identity across refreshes.
        let id: String
        let record: SessionStateRecord

        var state: SupervisedState { record.supervised }
        /// When it entered that state.
        var since: Date { record.since }
        /// What it is waiting for, while it is waiting.
        var reason: String? { record.reason }
        /// The checkout, which is what the terminal jump matches a window against.
        var directory: String? { record.directory }
        var accountID: String? { record.accountID }
        var model: String? { record.model }
        var childPid: Int? { record.childPid }

        /// What the row is called: the repository, with its parallel line beside it. A session in a
        /// directory git cannot answer for still has a name (`pickProject` guarantees one), so this
        /// is only ever empty for a supervisor too old to publish any of it.
        var title: String {
            guard let project = record.project, !project.isEmpty else { return record.worktree ?? "" }
            guard let worktree = record.worktree, !worktree.isEmpty else { return project }
            return project + pickEffortSeparator + worktree
        }
    }

    var blockedCount: Int { rows.filter { $0.state == .blocked }.count }

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
        let live = liveSessionStates()
        let rows = Self.sorted(live.compactMap(Self.row))
        let missing = live.count - rows.count
        // Nothing changed is the ordinary tick, and assigning anyway would re-render every surface
        // twice a second for a board that is standing still.
        guard rows != self.rows || missing != notReporting else { return }
        self.rows = rows
        notReporting = missing
        onChange?()
    }

    private static func row(_ live: LiveSessionState) -> SessionRow? {
        live.record.map { SessionRow(id: String(live.supervisorPid), record: $0) }
    }

    /// The board's order: what needs somebody first, then what is moving, then what is not, then
    /// what cannot say. Within a state the OLDEST leads, because the age of the wait is the thing
    /// worth acting on and a list that reordered itself as sessions ticked would be unreadable.
    /// `nonisolated` because it is a pure function of what it is handed and nothing else, which is
    /// also what lets the assertion harness state the order without an app around it.
    nonisolated static func sorted(_ rows: [SessionRow]) -> [SessionRow] {
        rows.sorted {
            rank($0.state) != rank($1.state) ? rank($0.state) < rank($1.state) : $0.since < $1.since
        }
    }

    nonisolated private static func rank(_ state: SupervisedState) -> Int {
        switch state {
        case .blocked: return 0
        case .working: return 1
        case .idle: return 2
        case .unknown: return 3
        }
    }
}
