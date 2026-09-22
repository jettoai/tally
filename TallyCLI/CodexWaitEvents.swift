import Foundation

// THE CODEX HALF OF THE WAIT-EVENT ADAPTER (plan §4.2): turns `CodexSessionObserver.pendingPermission`
// into the same `SessionWaitEvent` stream the Claude side publishes, through the shared
// `openWaitRequest` / `reconcileWaitRequests` pair (SessionWaitLogic.swift), so the two providers
// cannot drift in what an open or a resolved request looks like on the wire.
//
// IN-MEMORY ONLY. There is no `<pid>.waitopen` seed on this side (plan §9 blind spot 11): a
// supervisor killed while a permission is standing does not replay a `session-ended` after it comes
// back, and cannot replay a stale one either, because `session.key` folds in `supervisorStartedAt`
// and a restarted supervisor never computes the old key.
//
// Pure apart from the observer it reads: the supervisor appends whatever this returns
// (`appendSessionWaitEvent`), so a test can drive it with a fixture observer and never touch
// `~/.tally/events`.

/// The one sentence a Codex permission event carries. Neutral by rule (plan §14 revision 5): the
/// hook proves a `PermissionRequest` fired, never that a person is looking at it, so the summary
/// names the signal and nothing more.
let codexPermissionSummary = "Codex PermissionRequest hook fired"

struct CodexWaitTracker {
    private(set) var identity: SessionWaitIdentity
    /// What the last tick published as standing, or nil. The `previous` side of every reconcile.
    private(set) var open: SessionWaitRequest?
    /// The Codex turn `open` belongs to, kept beside it so a clearing outcome the observer reports
    /// can be matched to THIS request rather than to whichever permission cleared last.
    private var openTurnID: String?

    init(identity: SessionWaitIdentity) {
        self.identity = identity
    }

    /// One tick. `directory`/`project`/`worktree` are re-read every call because the supervisor
    /// only learns them once the Codex binding lands (CodexSupervisor.swift, the `observer == nil`
    /// branch), which can be several ticks after this tracker was built.
    ///
    /// Resolution when a standing request goes away (plan §4.2, §14 revision 6): the observer
    /// clearing it with reason `invalidated` (transcript replaced or truncated) is `session-ended`;
    /// every other clearing (`turn-ended`, `turn-moved`) is `unknown`, because Codex never says what
    /// the person did, only that the turn moved on.
    mutating func reconcile(observer: CodexSessionObserver?, directory: String?, project: String?,
                            worktree: String?, now: Date) -> [SessionWaitEvent] {
        identity.directory = directory
        identity.project = project
        identity.worktree = worktree
        identity.transcriptSessionId = observer?.binding.sessionID
        let pending = observer?.pendingPermission
        let current = pending.flatMap { pending in
            openWaitRequest(provider: "codex", sessionKey: identity.key,
                            notice: UserNotice(message: codexPermissionSummary, at: pending.at,
                                               type: nil, sessionID: nil),
                            waiting: true, question: nil, questionSince: nil, quiet: false,
                            wait: nil, permissionTool: pending.tool)
        }
        var resolution: SessionWaitResolution?
        if open != nil, current == nil {
            let outcome = observer?.lastPermissionOutcome
            let invalidated = outcome?.turnID == openTurnID && outcome?.reason == "invalidated"
            resolution = invalidated ? .sessionEnded : .unknown
        }
        let events = reconcileWaitRequests(previous: open, current: current, resolution: resolution,
                                           identity: identity, provider: "codex", now: now)
        open = current
        openTurnID = pending?.turnID
        return events
    }

    /// The supervisor is shutting down (§4.1b's last rule, same shape for Codex): a standing request
    /// resolves as `session-ended` first, then `session.ended` closes the session itself.
    mutating func finish(now: Date) -> [SessionWaitEvent] {
        var events = reconcileWaitRequests(previous: open, current: nil, resolution: .sessionEnded,
                                           identity: identity, provider: "codex", now: now)
        open = nil
        openTurnID = nil
        events.append(makeSessionWaitEvent(.ended, request: nil, resolution: nil, identity: identity,
                                           provider: "codex", now: now))
        return events
    }
}
