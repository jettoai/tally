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
        /// The registry's `statusUpdatedAt` on the FIRST tick that witnessed this request, which is
        /// when the unbroken `waiting` stretch its dialog stood in began. Kept, not refreshed, while
        /// the same request stays witnessed under the same child, so a later reading carrying the
        /// same stamp shows the registry never visibly left `waiting` in between (`fastAnswer`). nil
        /// from a seed written before this field or a registry that wrote no stamp, which only ever
        /// turns the re-notice answer off.
        var stretchBegan: Date? = nil
    }
    private var witness: DialogWitness?
    /// `witness` as of the last seed write, for the same skip `seeded` buys.
    private var seededWitness: DialogWitness?
    /// What the registry said on the LAST tick, whatever the notice slot held: the half of the
    /// fast-answer proof (`fastAnswer`) only a tick before the notice can supply. In memory only, so
    /// a self-update loses it and a dialog answered across one falls back to the older rules, exactly
    /// as before this change (they can close early or late; see `isRegistryMeasured`).
    private struct RegistryObservation {
        var childPid: Int
        var isWaiting: Bool
        var waitingFor: String?
        var statusUpdatedAt: Date?
        var observedAt: Date
    }
    private var lastReading: RegistryObservation?
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

    /// Whether the registry has said `waiting` for the standing request under THIS child, AND that
    /// request is still the one `notice` describes. `witness` is rebound only at the end of a tick
    /// (`reconcile`), after this has been asked, so a notice that took the slot since the last tick
    /// (hard over hard replaces, UserNotice.swift) would otherwise be judged on the handshake of the
    /// request it replaced, and cleared as answered without ever opening.
    func dialogWitnessed(childPid: Int?, notice: UserNotice?) -> Bool {
        guard let witness, let open, let childPid, let notice,
              SessionWaitTracker.isRegistryMeasured(notice.type) else { return false }
        return witness.requestID == open.id && witness.childPid == childPid
            && open.since == notice.at && open.noticeType == notice.type
    }

    /// The notice types whose dialog Claude Code's registry has been MEASURED to hold at `waiting`
    /// while it stands (2.1.280, H1f: `permission_prompt` only). The registry's status is per
    /// session, not per dialog, so a `waiting` seen while any other kind stands may belong to a
    /// different dialog behind it; such a kind never earns a witness and stays with the older rules.
    /// Those rules err both ways: a main-chain record or a keyboard burst after the notice closes it
    /// whether or not its dialog is still up (early: H1e O6, H1f B5t), and nothing else closes it
    /// until one arrives (late: H1f B1x). What this set guarantees is narrower: a kind outside it is
    /// never closed as `answered` on the registry's word. Checked where a witness is recorded AND
    /// where one is read, so a witness an older build seeded for such a kind is void. Measure on a
    /// real CLI before widening this.
    private static let registryMeasuredNoticeTypes: Set<String> = ["permission_prompt"]

    /// False for a nil type: a request with no notice behind it has no registry dialog to measure.
    private static func isRegistryMeasured(_ noticeType: String?) -> Bool {
        noticeType.map(registryMeasuredNoticeTypes.contains) ?? false
    }

    /// The shortest time Claude Code 2.1.280 was measured to take between a permission dialog
    /// appearing (its registry turning `waiting`) and the `permission_prompt` notification firing:
    /// 6.010 to 6.026 s on every dialog measured (H1f, and O15 L1, L2, C1, R1, R2), first notice and
    /// re-notice alike. 5 s keeps a second of margin under it. `fastAnswer` leans on it twice: the
    /// stretch it trusts began at least this long before the notice (the notice's dialog stood in
    /// it), and the tick that saw that stretch ran less than this long before the notice (no dialog
    /// could have appeared after that tick and already been announced).
    static let claudeNoticeDelayFloor: TimeInterval = 5

    /// How a notice no tick could witness was nonetheless answered (`fastAnswer`).
    enum FastAnswer: Equatable {
        /// The notice re-announces the stretch the standing, witnessed request stood in: same child,
        /// same measured type, same unbroken `waiting` stretch. That request is the one answered.
        case standing
        /// Nothing standing covers it: the notice's own request opens and is answered in the same
        /// tick, so a consumer still sees the dialog appear and go.
        case unseen
    }

    /// THE FAST ANSWER (O15): a dialog answered after its notice fired but before the next tick read
    /// the registry. No tick ever sees `waiting` together with that notice, so the handshake
    /// (`dialogWitnessed`) cannot close it, and the older rules kept it standing until something
    /// else wrote the main chain (measured: 154 to 170 s, O15 L1, L2, R2).
    ///
    /// Proved from two sources that fail independently, and both are required:
    ///   - THIS SUPERVISOR SAW `waiting`: the previous tick's reading, for this same child, said
    ///     `waiting`, and that tick ran less than `claudeNoticeDelayFloor` before the notice fired.
    ///     A registry that never writes `waiting` (vocabulary drift) never gets here, exactly as it
    ///     never earns a witness.
    ///   - CLAUDE CODE STAMPED THE STRETCH AROUND THE NOTICE: that `waiting` stretch began at least
    ///     `claudeNoticeDelayFloor` before the notice, and the reading now, no longer `waiting`, was
    ///     stamped strictly after it. The status is per session, so "not waiting" means no dialog is
    ///     up at all, and it changed after the notice's dialog was announced.
    ///
    /// Only for a measured kind, and never while the registry says `waiting`: a dialog still up is
    /// never closed by this. A notice already witnessed is the handshake's to close.
    func fastAnswer(childPid: Int?, notice: UserNotice?, registry: ClaudeRegistryReading?) -> FastAnswer? {
        guard let childPid, let notice, let registry, !registry.isWaiting,
              SessionWaitTracker.isRegistryMeasured(notice.type),
              !dialogWitnessed(childPid: childPid, notice: notice),
              let left = registry.statusUpdatedAt, left > notice.at,
              let seen = lastReading, seen.childPid == childPid, seen.isWaiting,
              let began = seen.statusUpdatedAt,
              notice.at.timeIntervalSince(began) >= SessionWaitTracker.claudeNoticeDelayFloor,
              notice.at.timeIntervalSince(seen.observedAt) < SessionWaitTracker.claudeNoticeDelayFloor
        else { return nil }
        // THE RE-NOTICE (O15 R2): the standing request was witnessed in the very stretch that just
        // ended, so whichever dialog this notice names, the standing request's dialog is closed too,
        // and a person pressing Esc on a re-announced dialog answered that request rather than
        // superseding it. The stamps compare to the millisecond: the witness's copy may have made a
        // round trip through the seed's fractional ISO 8601 text.
        if let open, let witness, witness.requestID == open.id, witness.childPid == childPid,
           open.noticeType == notice.type, open.since < notice.at,
           let stretch = witness.stretchBegan, abs(stretch.timeIntervalSince(began)) < 0.001 {
            return .standing
        }
        return .unseen
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
    /// `fastAnswer` is this tick's own `fastAnswer(...)` verdict (the caller asks it before judging,
    /// because it decides `dialogOpen`); `registryReading` is the registry read on EVERY tick, notice
    /// or not, remembered as the next tick's `lastReading`.
    /// `permissionTool` is always nil here: revision 1 cuts the sidecar that would have supplied it.
    mutating func reconcile(childPid: Int?, transcriptSessionId: String?, accountID: String?,
                            directory: String?, project: String?, worktree: String?, notice: UserNotice?,
                            waiting: Bool, question: String?, questionSince: Date?, quiet: Bool,
                            wait: UserWait?, answeredAt: Date?, dialogWaitingFor: String? = nil,
                            dialogOpen: Bool? = nil, fastAnswer: FastAnswer? = nil,
                            registryReading: ClaudeRegistryReading? = nil, registryVersion: String? = nil,
                            driftLog: URL? = nil, now: Date) -> [SessionWaitEvent] {
        identity.childPid = childPid
        identity.transcriptSessionId = transcriptSessionId
        identity.account = accountID
        identity.directory = directory
        identity.project = project
        identity.worktree = worktree

        var events = takeStaleSeedEvents(now: now)

        // THE FAST ANSWER'S EVENTS (`fastAnswer`), ahead of the ordinary reconcile so that one finds
        // nothing standing. `.standing` answers the witnessed request; `.unseen` opens the notice's
        // own request (superseding whatever else stood) and answers it in the same tick.
        if let fastAnswer, let notice {
            let answered: SessionWaitRequest?
            switch fastAnswer {
            case .standing:
                answered = open
            case .unseen:
                answered = openWaitRequest(provider: "claude", sessionKey: identity.key, notice: notice,
                                           waiting: true, question: nil, questionSince: nil, quiet: quiet,
                                           wait: .hard, permissionTool: nil,
                                           dialogWaitingFor: lastReading?.waitingFor)
            }
            if let answered {
                events += reconcileWaitRequests(previous: open, current: answered, resolution: nil,
                                                identity: identity, provider: "claude", now: now)
                events += reconcileWaitRequests(previous: answered, current: nil, resolution: .answered,
                                                identity: identity, provider: "claude", now: now)
                open = nil
                witness = nil
            }
        }

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
            // older rules just closed is either a dialog answered inside the notice delay that the
            // fast answer could not prove, or a Claude Code whose registry vocabulary moved. Either
            // way the handshake fell back, and this line is the only place that shows it. Once per
            // wait, by construction. Only for a measured kind: an unmeasured one never earns a
            // witness, so its fallback is not drift. Asked of the STANDING request's own witness,
            // not of the notice now in the slot: a witnessed request whose notice was replaced
            // before the older rules closed it did hear `waiting` (O16).
            if dialogOpen == nil, let registryVersion, let driftLog,
               SessionWaitTracker.isRegistryMeasured(standing.noticeType),
               !(witness?.requestID == standing.id && witness?.childPid == childPid) {
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
        if let current, dialogOpen == true, let childPid, SessionWaitTracker.isRegistryMeasured(current.noticeType) {
            // The stretch is the one the FIRST witnessing tick saw (`DialogWitness.stretchBegan`).
            let kept = witness?.requestID == current.id && witness?.childPid == childPid
            witness = DialogWitness(requestID: current.id, childPid: childPid,
                                    stretchBegan: kept ? witness?.stretchBegan : registryReading?.statusUpdatedAt)
        } else if current == nil || witness?.requestID != current?.id {
            witness = nil
        }
        // What the registry said on THIS tick, for the next tick's `fastAnswer`. Overwritten on every
        // tick, an unreadable one included, so "the previous tick said `waiting`" means exactly that.
        lastReading = childPid.flatMap { child in
            registryReading.map {
                RegistryObservation(childPid: child, isWaiting: $0.isWaiting, waitingFor: $0.waitingFor,
                                    statusUpdatedAt: $0.statusUpdatedAt, observedAt: now)
            }
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
        lastReading = nil
        events.append(makeSessionWaitEvent(.ended, request: nil, resolution: nil, identity: identity,
                                           provider: "claude", now: now))
        if let pid { try? FileManager.default.removeItem(at: SessionWaitTracker.seedFile(pid: pid, dir: dir)) }
        return events
    }
}
