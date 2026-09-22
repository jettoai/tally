import Foundation

// SessionWaitTracker's §4.3 restart path (SessionStateSync.swift): a seed file whose
// `identity.key` does not match this generation's own is a STALE leftover from a previous
// supervisor generation for the same pid, and the tracker's first `reconcile` must resolve it
// `session-ended` under its OWN (stale) identity - never silently adopted as this generation's
// `open`. Regression for the mutation this file's own header used to prove (§4.3, flipping
// `seed.identity.key == identity.key` to `!=`): the flipped comparison wrongly adopts the stale
// seed as `open`, so the first tick resolves it through the ORDINARY path (`resolvedWaitOutcome`
// -> `.unknown`, stamped under the NEW identity) instead of the forced stale-restart path. This was
// P3's own scratch probe (`p3-findings.md`'s "Variant self-proof"); this file is that probe made
// permanent, per the follow-up brief's own instruction.
//
// The second half (seed file's key MATCHES this generation's own) is the ordinary seed-recovery
// path: a self-update `execv` keeps the pid, so the new process image has to recover a standing
// wait from disk rather than start blind (`SessionWaitTracker`'s own header states why).

func runWaitTrackerChecks() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-waittracker-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 1_800_000_500)

    /// The private `SessionWaitTracker.SessionWaitSeed` shape, reproduced field-for-field (that
    /// type is private to `SessionStateSync.swift`): `{identity: SessionWaitIdentity, request:
    /// SessionWaitRequest}`, encoded with the same `sessionWaitEventEncoder()` every writer on this
    /// track uses.
    struct SeedProbe: Codable {
        var identity: SessionWaitIdentity
        var request: SessionWaitRequest
    }

    func writeSeed(pid: String, identity: SessionWaitIdentity, request: SessionWaitRequest) {
        let file = dir.appendingPathComponent("\(pid).waitopen")
        let data = try! sessionWaitEventEncoder().encode(SeedProbe(identity: identity, request: request))
        try! data.write(to: file, options: .atomic)
    }

    /// A tick with nothing standing at all: no notice, no open question, quiet. The one shape every
    /// assertion below drives `reconcile` with, because what is under test is what a tracker DOES
    /// with a seed it read at construction, not any particular live signal.
    func reconcileNoWait(_ tracker: inout SessionWaitTracker) -> [SessionWaitEvent] {
        tracker.reconcile(childPid: nil, transcriptSessionId: nil, accountID: nil, directory: nil,
                          project: nil, worktree: nil, notice: nil, waiting: false, question: nil,
                          questionSince: nil, quiet: true, wait: nil, transcriptModified: nil, now: now)
    }

    // MARK: - A seed for a DIFFERENT generation of the same pid (the stale-restart path)

    let stalePid = "88881"
    let staleIdentity = SessionWaitIdentity(key: "claude:1:111", supervisorPid: 1, supervisorStartedAt: 111,
                                            childPid: nil, transcriptSessionId: nil, launchNonce: nil,
                                            account: nil, directory: nil, project: nil, worktree: nil)
    let staleRequest = SessionWaitRequest(id: sessionWaitRequestID(sessionKey: staleIdentity.key,
                                                                    kind: "permission", noticeType: "permission_prompt",
                                                                    since: now.addingTimeInterval(-30)),
                                          kind: "permission", confidence: "suspected",
                                          since: now.addingTimeInterval(-30), noticeType: "permission_prompt",
                                          tool: "Bash", summary: "test permission")
    writeSeed(pid: stalePid, identity: staleIdentity, request: staleRequest)

    // A fresh generation (pid 88881, but a NEW supervisorPid/supervisorStartedAt) constructing over
    // that file: its own identity.key ("claude:2:222") does not match the seed's ("claude:1:111"),
    // so the seed is read as `staleSeed`, not adopted as `open`.
    var staleTracker = SessionWaitTracker(pid: stalePid, supervisorPid: 2, supervisorStartedAt: 222, dir: dir)
    let firstTick = reconcileNoWait(&staleTracker)
    check("a stale seed resolves as exactly one session-ended event on the first tick",
          firstTick.count == 1 && firstTick[0].kind == "wait.resolved" && firstTick[0].resolution == "session-ended")
    check("...stamped under the STALE seed's own key, not the new generation's",
          firstTick[0].session.key == "claude:1:111")
    check("...and carries no wait.updated alongside it",
          !firstTick.contains { $0.kind == "wait.updated" })

    let secondTick = reconcileNoWait(&staleTracker)
    check("the same tracker's next tick, with nothing standing, emits nothing",
          secondTick.isEmpty)

    // MARK: - A seed for THIS generation of a different pid (the ordinary seed-recovery path)

    let recoverPid = "88882"
    let recoverIdentity = SessionWaitIdentity(key: "claude:2:222", supervisorPid: 2, supervisorStartedAt: 222,
                                              childPid: nil, transcriptSessionId: nil, launchNonce: nil,
                                              account: nil, directory: nil, project: nil, worktree: nil)
    let recoverRequest = SessionWaitRequest(id: sessionWaitRequestID(sessionKey: recoverIdentity.key,
                                                                      kind: "permission", noticeType: "permission_prompt",
                                                                      since: now.addingTimeInterval(-10)),
                                            kind: "permission", confidence: "suspected",
                                            since: now.addingTimeInterval(-10), noticeType: "permission_prompt",
                                            tool: "Read", summary: "another permission")
    writeSeed(pid: recoverPid, identity: recoverIdentity, request: recoverRequest)

    // Constructed with the SAME supervisorPid/supervisorStartedAt the seed itself carries, so
    // `identity.key` matches and the seed is adopted as `open` rather than treated as stale.
    var recoverTracker = SessionWaitTracker(pid: recoverPid, supervisorPid: 2, supervisorStartedAt: 222, dir: dir)
    let recoverTick = reconcileNoWait(&recoverTracker)
    check("a same-generation seed with nothing standing now resolves as exactly one event",
          recoverTick.count == 1 && recoverTick[0].kind == "wait.resolved")
    check("...under this generation's own key, not a stale one",
          recoverTick[0].session.key == "claude:2:222")
    check("...with the resolution `resolvedWaitOutcome` gives a nil transcript and no closed question",
          recoverTick[0].resolution == resolvedWaitOutcome(request: recoverRequest, transcriptModified: nil,
                                                            questionClosed: false).rawValue)

    try? FileManager.default.removeItem(at: dir)
}
