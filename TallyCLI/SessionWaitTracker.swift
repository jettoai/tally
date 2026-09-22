import Foundation

// The Claude side's per-tick wait memory, split off SessionStateSync.swift on size: the tick
// (`syncSessionState`) computes the readings, this turns the change between ticks into events.

/// Remembers, across ticks, whether a wait request is standing and turns the change from the last
/// tick's belief into `SessionWaitEvent`s (plan §4.1a/§4.1b/§6.8). Seeded from disk for the same
/// reason `SessionStateWriter` (SessionStateSync.swift) is: a self-update replaces
/// this process with `execv`, keeping the pid, so the new image must recover a request the image it
/// replaced already believed was standing rather than start blind. `CodexWaitTracker`
/// (CodexWaitEvents.swift) is this struct's sibling on the Codex side; the two diverge only in this
/// one's file seed, which Codex does not need (plan §9 blind spot 11).
struct SessionWaitTracker {
    private var identity: SessionWaitIdentity
    /// What the last tick published as standing, or nil. The `previous` side of every reconcile.
    private var open: SessionWaitRequest?
    /// What `open` was the LAST TIME this tracker actually wrote the seed file, so `reconcile` can
    /// skip the write on every tick where nothing about the standing request changed (it ticks every
    /// 2s, for the life of every supervised session, and most ticks change nothing). `SessionWaitRequest`
    /// is already `Equatable`, so this compares the whole value rather than just `id`: a confidence
    /// upgrade or a tool/summary filled in (the same changes that earn a `wait.updated` event) also
    /// have to reach the seed, or a restart mid-wait would recover the stale reading.
    private var seeded: SessionWaitRequest?
    /// Which request Claude Code's registry has been seen holding a dialog open for, and which child
    /// said so (`claudeDialogOpen`'s handshake). Keyed by request id rather than instant so a seed
    /// round trip cannot un-match it; bound to the child because a replaced child has a registry of
    /// its own that knows nothing about the old dialog (Supervisor.swift `.childReplaced` clears
    /// neither the notice nor this tracker).
    struct DialogWitness: Codable, Equatable {
        var requestID: String
        var childPid: Int
    }
    private var witness: DialogWitness?
    /// `witness` as of the last seed write, for the same skip `seeded` buys.
    private var seededWitness: DialogWitness?
    /// A seed read at construction whose `session.key` did not match this generation's own (plan
    /// §4.3): resolved `session-ended` under ITS OWN identity on the first `reconcile` call, rather
    /// than folded into an ordinary resolve/open pair under the new one.
    private var staleSeed: SessionWaitSeed?
    private let pid: String?
    private let dir: URL

    private struct SessionWaitSeed: Codable {
        var identity: SessionWaitIdentity
        var request: SessionWaitRequest
        /// Absent from seeds written before the registry became a closer: decodes nil, so a wait
        /// recovered from such a seed is judged by the older rules until the registry says `waiting`
        /// once more (which, for a dialog still open, is the very next tick).
        var witness: DialogWitness?
    }

    /// Whether the registry has said `waiting` for the standing request under THIS child.
    func dialogWitnessed(childPid: Int?) -> Bool {
        guard let witness, let open, let childPid else { return false }
        return witness.requestID == open.id && witness.childPid == childPid
    }

    /// `pid` optional only so a test can build a tracker with nothing to seed or reseed, mirroring
    /// `SessionStateWriter`'s own escape hatch. `supervisorPid`/`supervisorStartedAt` are this
    /// generation's own, folded into `identity.key` once here and never rebuilt.
    init(pid: String? = nil, supervisorPid: Int = 0, supervisorStartedAt: Int = 0,
        dir: URL = supervisorStateDir) {
        self.pid = pid
        self.dir = dir
        identity = SessionWaitIdentity(key: "claude:\(supervisorPid):\(supervisorStartedAt)",
                                       supervisorPid: supervisorPid, supervisorStartedAt: supervisorStartedAt,
                                       childPid: nil, transcriptSessionId: nil, launchNonce: nil,
                                       account: nil, directory: nil, project: nil, worktree: nil)
        guard let pid, let seed = SessionWaitTracker.readSeed(pid: pid, dir: dir) else { return }
        if seed.identity.key == identity.key {
            open = seed.request
            // The file we just read IS this value, so the in-memory "last written" copy starts in
            // step with it rather than nil, which would otherwise force one redundant write on the
            // very first `reconcile` even though nothing changed.
            seeded = seed.request
            witness = seed.witness
            seededWitness = seed.witness
        } else {
            staleSeed = seed
        }
    }

    private static func seedFile(pid: String, dir: URL) -> URL {
        dir.appendingPathComponent("\(pid).waitopen")
    }

    private static func readSeed(pid: String, dir: URL) -> SessionWaitSeed? {
        guard let data = try? Data(contentsOf: seedFile(pid: pid, dir: dir)) else { return nil }
        return try? sessionWaitEventDecoder().decode(SessionWaitSeed.self, from: data)
    }

    private func writeSeed(pid: String) {
        let file = SessionWaitTracker.seedFile(pid: pid, dir: dir)
        guard let open else { try? FileManager.default.removeItem(at: file); return }
        let seed = SessionWaitSeed(identity: identity, request: open, witness: witness)
        guard let data = try? sessionWaitEventEncoder().encode(seed) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// The stale seed's `session-ended` (plan §4.3), under ITS OWN identity, handed out once.
    private mutating func takeStaleSeedEvents(now: Date) -> [SessionWaitEvent] {
        guard let stale = staleSeed else { return [] }
        staleSeed = nil
        return reconcileWaitRequests(previous: stale.request, current: nil, resolution: .sessionEnded,
                                     identity: stale.identity, provider: "claude", now: now)
    }

    /// One tick (plan §4.1b), driven by `syncSessionState`. `notice`/`waiting`/`question`/
    /// `questionSince`/`quiet`/`wait` are that tick's own readings; `answeredAt` (the watcher's
    /// `lastPersonInputAt`, never the file's mtime) is what explains a standing request going away
    /// as answered (`resolvedWaitOutcome`, §4.1c/§14 revision 1); `dialogWaitingFor` is Claude
    /// Code's own name for its top dialog (`readClaudeRegistry`); `dialogOpen` is Claude Code's own
    /// word on whether the dialog behind a hard notice is open (`claudeDialogOpen`).
    /// `registryVersion` is non-nil whenever that tick's registry read was readable, and with
    /// `driftLog` it feeds the one line that says the handshake never happened (below).
    /// `permissionTool` is always nil here: revision 1 cuts the sidecar that would have supplied it.
    mutating func reconcile(childPid: Int?, transcriptSessionId: String?, accountID: String?,
                            directory: String?, project: String?, worktree: String?, notice: UserNotice?,
                            waiting: Bool, question: String?, questionSince: Date?, quiet: Bool,
                            wait: UserWait?, answeredAt: Date?, dialogWaitingFor: String? = nil,
                            dialogOpen: Bool? = nil, registryVersion: String? = nil,
                            driftLog: URL? = nil, now: Date) -> [SessionWaitEvent] {
        identity.childPid = childPid
        identity.transcriptSessionId = transcriptSessionId
        identity.account = accountID
        identity.directory = directory
        identity.project = project
        identity.worktree = worktree

        var events = takeStaleSeedEvents(now: now)

        let current = stabilizedWaitRequest(
            previous: open,
            current: openWaitRequest(provider: "claude", sessionKey: identity.key, notice: notice,
                                     waiting: waiting, question: question, questionSince: questionSince,
                                     quiet: quiet, wait: wait, permissionTool: nil,
                                     dialogWaitingFor: dialogWaitingFor),
            notice: notice, noticeOpen: waiting)
        var resolution: SessionWaitResolution?
        if current == nil, let standing = open {
            // `questionClosed` is the TRANSCRIPT's question closing (no notice behind it): a
            // question recognised from the registry never had a transcript call open to close.
            resolution = resolvedWaitOutcome(request: standing, answeredAt: answeredAt,
                                             questionClosed: standing.kind == SessionWaitKind.question.rawValue
                                                && standing.noticeType == nil && question == nil,
                                             dialogClosed: dialogOpen == false)
            // THE DRIFT TRIPWIRE: a readable registry that never said `waiting` for a wait the
            // older rules just closed is either a dialog answered inside the notice delay or a
            // Claude Code whose registry vocabulary moved. Either way the handshake fell back, and
            // this line is the only place that shows it. Once per wait, by construction.
            if dialogOpen == nil, let registryVersion, let driftLog, !dialogWitnessed(childPid: childPid) {
                appendHandoffLine("\(ISO8601DateFormatter().string(from: now)) pid=\(pid ?? "-") "
                    + "wait \(standing.id) closed by legacy rules; registry v\(registryVersion) "
                    + "never said waiting\n", to: driftLog)
            }
        }
        events += reconcileWaitRequests(previous: open, current: current, resolution: resolution,
                                        identity: identity, provider: "claude", now: now)
        open = current
        // THE HANDSHAKE'S MEMORY: remembered while the registry says the standing request's dialog is
        // open, forgotten with the request (a new request starts unwitnessed, and the registry says
        // `waiting` for it on the very next tick if its dialog is really up).
        if let current, dialogOpen == true, let childPid {
            witness = DialogWitness(requestID: current.id, childPid: childPid)
        } else if current == nil || witness?.requestID != current?.id {
            witness = nil
        }
        if let pid, open != seeded || witness != seededWitness {
            writeSeed(pid: pid)
            seeded = open
            seededWitness = witness
        }
        return events
    }

    /// Supervisor shutdown (plan §4.1b's fifth rule, §6.11): a standing request resolves
    /// `session-ended` first, then `session.ended` closes the session itself.
    mutating func finish(now: Date) -> [SessionWaitEvent] {
        var events = takeStaleSeedEvents(now: now)
        events += reconcileWaitRequests(previous: open, current: nil, resolution: .sessionEnded,
                                        identity: identity, provider: "claude", now: now)
        open = nil
        witness = nil
        events.append(makeSessionWaitEvent(.ended, request: nil, resolution: nil, identity: identity,
                                           provider: "claude", now: now))
        if let pid { try? FileManager.default.removeItem(at: SessionWaitTracker.seedFile(pid: pid, dir: dir)) }
        return events
    }
}
