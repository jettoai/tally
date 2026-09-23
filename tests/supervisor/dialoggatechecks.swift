import Foundation

// Issue #2: a line NOBODY ASKED FOR (host-health knock, quota knock, limit reset) must never land
// in an open dialog, where its first bytes close it or pick an option and the rest become a prompt.
// A soft idle prompt folds into the same `blocked` word and must still be typed into, and a line
// somebody DID ask for (`tally session send`) must still be able to answer the dialog.
//
// Every writer is driven with the same two readings of one `blocked` board: a hard wait
// (`waitingOnPerson: true`, what the supervisor now hands them as `SessionTick.dialogPossible`)
// and a soft one. Only API the pre-fix tree already had is used here, so this file run against
// that tree shows the defect; the rows that need the new readings are in dialoggatereadingchecks.

func runDialogGateChecks() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-dialoggate-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let log = dir.appendingPathComponent("input.log")
    let now = Date()
    let fixturePid = "dg-test-\(UInt64.random(in: 60_466_176 ..< 2_176_782_336))"

    // MARK: - The host-health knock

    func hostKnock(_ session: SupervisedState, dialog: Bool) -> Int {
        var state = HostHealthKnockState()
        var typed = 0
        let alarm = HostHealthAlarm(at: now.addingTimeInterval(-30), load1: 5.65,
                                    freeBytes: 127_000_000_000, top: [])
        let report = HostHealthReport(sampledAt: now.addingTimeInterval(-10), load1: 5.65, cores: 8,
                                      freeBytes: 127_000_000_000, state: .alarmed,
                                      since: now.addingTimeInterval(-30), lastAlarm: alarm)
        applyHostHealthKnock(&state, pid: fixturePid, typedAlready: false, session: session,
                             quiet: .quiet, turnEnded: { false }, keyboardIdle: true,
                             relaunchPlanned: false, draftSuspected: false, waitingOnPerson: dialog,
                             modified: { _ in now.addingTimeInterval(-10) }, read: { _ in report },
                             now: now, log: log, dir: dir,
                             inject: { _, _ in typed += 1; return .done })
        return typed
    }
    check("host-health knock holds behind a hard dialog on a blocked board",
          hostKnock(.blocked, dialog: true) == 0)
    check("host-health knock holds behind a dialog only the registry sees",
          hostKnock(.idle, dialog: true) == 0)
    check("host-health knock still types into a blocked board that is only an idle prompt",
          hostKnock(.blocked, dialog: false) == 1)

    // MARK: - The quota knock

    func acct(_ id: String, label: String, session: Double) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: label, launchHome: "/tmp/\(id)",
                         sessionRemaining: session, weeklyRemaining: 88, modelRemaining: 88,
                         sessionResetsAt: now.addingTimeInterval(3 * 3600),
                         weeklyResetsAt: now.addingTimeInterval(90 * 3600),
                         modelResetsAt: now.addingTimeInterval(90 * 3600), modelWindowName: "fable",
                         resetCreditsAvailable: nil, isStale: false, error: nil)
    }
    let dying = acct("A", label: "Claude", session: 10)
    let healthy = acct("B", label: "Claude 2", session: 95)
    let fleet = Snapshot(version: 2, generatedAt: now, accounts: [dying, healthy])

    func quotaKnock(_ session: SupervisedState, dialog: Bool) -> Int {
        var state = QuotaKnockState(forced: false)
        var typed = 0
        applyQuotaKnock(&state, pid: fixturePid, provider: "claude", account: dying,
                        primaryModel: "fable", typedAlready: false, session: session,
                        quiet: .quiet, turnEnded: { false }, keyboardIdle: true,
                        relaunchPlanned: false, draftSuspected: false, waitingOnPerson: dialog,
                        counting: { _ in 2 }, loaded: (fleet, nil), now: now, log: log, dir: dir,
                        inject: { _, _ in typed += 1; return .done })
        return typed
    }
    check("quota knock holds behind a hard dialog on a blocked board",
          quotaKnock(.blocked, dialog: true) == 0)
    check("quota knock holds behind a dialog only the registry sees",
          quotaKnock(.idle, dialog: true) == 0)
    check("quota knock still types into a blocked board that is only an idle prompt",
          quotaKnock(.blocked, dialog: false) == 1)

    // MARK: - The limit reset

    // Already held on `waitingOnPerson` before issue #2, so these rows are a lock on the shared gate
    // rather than a parent-red row; its real gap was the registry, which the wiring lock covers.
    func limitReset(_ session: SupervisedState, dialog: Bool) -> Int {
        var state = CapLimitResetState()
        var typed = 0
        let pending = PendingCapRecovery(cappedAccountID: "A", cappedAt: now.addingTimeInterval(-60),
                                         primaryModel: "fable", recoveryResetsAt: nil,
                                         nextRetry: .distantPast, reason: "", capScope: .session)
        applyCapLimitReset(&state, pendingCap: pending, pid: fixturePid, accountLabel: "Claude 2",
                           holding: true, typedAlready: false, session: session, quiet: .quiet,
                           turnEnded: { false }, keyboardIdle: true, relaunchPlanned: false,
                           draftSuspected: false, waitingOnPerson: dialog,
                           settings: { LimitResetSettings(autoReset: true, noticeShown: true) },
                           now: now, log: log,
                           settingsURL: dir.appendingPathComponent("limit-reset.json"),
                           announce: { _ in }, inject: { _, _ in typed += 1; return .done })
        return typed
    }
    check("limit-reset holds behind a hard dialog on a blocked board",
          limitReset(.blocked, dialog: true) == 0)
    check("limit-reset holds behind a dialog only the registry sees",
          limitReset(.idle, dialog: true) == 0)
    check("limit-reset still types into a blocked board that is only an idle prompt",
          limitReset(.blocked, dialog: false) == 1)

    // MARK: - The requested line

    // THE ONE WRITER THAT MUST STILL REACH A DIALOG: answering another session's prompt is part of
    // what `tally session send` is for. Typed key by key under it, nothing stashed.
    func requested(_ session: SupervisedState, dialog: Bool)
        -> (typed: Int, touching: Bool?, outcome: String?) {
        let key = "dg-\(UUID().uuidString.prefix(8))"
        var input = SessionInputState(sessionKey: key, servedEpoch: 0)
        try? writeSessionInputRequest(
            SessionInputRequest(epoch: Int(now.timeIntervalSince1970 * 1000), text: "1"),
            sessionKey: key, dir: dir)
        var guards: [SessionInputDraftGuard] = []
        applySessionInput(&input, session: session, quiet: .quiet, turnEnded: { false },
                          keyboardIdle: true, relaunchPlanned: false, draftSuspected: false,
                          waitingOnPerson: dialog, dir: dir, log: log, now: now) { _, guarded in
            guards.append(guarded)
            return .done
        }
        return (guards.count, guards.first?.touching,
                readSessionInputResult(sessionKey: key, dir: dir)?.outcome)
    }
    let intoHard = requested(.blocked, dialog: true)
    check("a requested line is still typed into a hard dialog",
          intoHard.typed == 1 && intoHard.outcome == "submitted")
    check("…key by key, with nothing stashed out of a composer behind that dialog",
          intoHard.touching == false)
    let intoRegistry = requested(.idle, dialog: true)
    check("…and into a dialog only the registry sees, key by key",
          intoRegistry.typed == 1 && intoRegistry.touching == false)
}
