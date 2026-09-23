import Foundation

// Issue #2, the half that needs the readings the fix added: what a tick says about a dialog
// (`SessionTick.dialogOpen`/`dialogPossible`, the registry read with no hook installed), the cap
// resume's own gate, what an input log line records, and the source-string locks that keep the
// automatic gate the only one the automatic writers ask.

func runDialogGateReadingChecks() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-dialogreading-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let now = Date()

    // MARK: - What a tick says about a dialog

    let unknown = SessionTick(state: .blocked, quiet: .quiet,
                              wait: userWait(notificationType: "some_future_prompt"),
                              dialogRegistry: false)
    check("an unknown notification type is a dialog that may be open",
          unknown.dialogOpen && unknown.dialogPossible)
    let idlePrompt = SessionTick(state: .blocked, quiet: .quiet, wait: .soft, dialogRegistry: false)
    check("an idle prompt with a clear registry is no dialog",
          !idlePrompt.dialogOpen && !idlePrompt.dialogPossible)
    let unread = SessionTick(state: .idle, quiet: .quiet, wait: nil, dialogRegistry: nil)
    check("an unreadable registry holds automatic lines but is not a known dialog",
          !unread.dialogOpen && unread.dialogPossible)
    let registryOnly = SessionTick(state: .idle, quiet: .quiet, wait: nil, dialogRegistry: true)
    check("a registry reading waiting is a known dialog with no hook and no wait",
          registryOnly.dialogOpen && registryOnly.dialogPossible)

    // THE ISSUE'S OWN SHAPE through the whole tick: no hook, so no notice; a structured question the
    // transcript will only show once answered; and Claude Code's registry saying `waiting`.
    let rig = dir.appendingPathComponent("rig")
    let projects = rig.appendingPathComponent("cfg/projects/p")
    let sessions = rig.appendingPathComponent("cfg/sessions")
    let stateDir = rig.appendingPathComponent("state")
    for made in [projects, sessions, stateDir] {
        try? FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
    }
    let file = projects.appendingPathComponent("session.jsonl")
    try? Data().write(to: file)
    try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-120)],
                                           ofItemAtPath: file.path)
    let childPid = 70123
    let registry = sessions.appendingPathComponent("\(childPid).json")
    var watcher = TranscriptWatcher(projectDir: projects, file: file, since: now.addingTimeInterval(-600))
    watcher.auditLog = rig.appendingPathComponent("audit.log")
    var writer = SessionStateWriter()
    func tick(status: String?) -> SessionTick {
        if let status {
            try? JSONSerialization.data(withJSONObject: ["pid": childPid, "status": status,
                                                         "waitingFor": "input needed",
                                                         "version": "2.1.280"]).write(to: registry)
        } else {
            try? FileManager.default.removeItem(at: registry)
        }
        _ = watcher.sawCapHit()
        return syncSessionState(&writer, pid: "dg-rig", project: PickProject(name: "p", path: file.path),
                                accountID: "claude:.claude", childPid: childPid, model: nil,
                                supervisorVersion: nil, watcher: &watcher, keyboardBurstAt: nil,
                                dir: stateDir, now: now)
    }
    let waiting = tick(status: "waiting")
    check("with no hook the board reads a session holding a question as idle (the issue's premise)",
          waiting.state == .idle && waiting.wait == nil)
    check("the tick reads the registry with no notice and no hook",
          waiting.dialogRegistry == true && waiting.dialogPossible)
    check("…a readable registry that is not waiting says so", tick(status: "idle").dialogRegistry == false)
    check("…and one that cannot be read is nil, which the automatic writers hold on",
          tick(status: nil).dialogRegistry == nil)

    // MARK: - The cap resume

    func acct(_ id: String, label: String) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: label, launchHome: "/tmp/\(id)",
                         sessionRemaining: 50, weeklyRemaining: 88, modelRemaining: 88,
                         sessionResetsAt: now.addingTimeInterval(3600),
                         weeklyResetsAt: now.addingTimeInterval(90 * 3600),
                         modelResetsAt: now.addingTimeInterval(90 * 3600), modelWindowName: "fable",
                         resetCreditsAvailable: nil, isStale: false, error: nil)
    }
    var armed = CapResumeState()
    armed.arm(reason: "cap", fresh: false, cappedAt: now, answeredAt: now.addingTimeInterval(-10),
              conversation: "dg-conversation", from: acct("A", label: "Claude"),
              to: acct("B", label: "Claude 2"), userTurnAt: nil)
    func resume(_ session: SupervisedState, dialog: Bool) -> CapResumeDecision {
        armed.decide(state: session, quiet: .quiet, turnEnded: false, keyboardIdle: true,
                     relaunchPlanned: false, dialogPossible: dialog, draftSuspected: false,
                     userTurnAt: nil, conversation: "dg-conversation", now: now.addingTimeInterval(30))
    }
    check("cap resume holds behind a dialog only the registry sees",
          resume(.idle, dialog: true) == .hold(.blocked))
    check("cap resume still holds behind a hard dialog on a blocked board",
          resume(.blocked, dialog: true) == .hold(.blocked))
    check("cap resume types into a blocked board that is only an idle prompt",
          resume(.blocked, dialog: false) == .type(armed.offer?.line ?? ""))

    // MARK: - What the input log records

    let log = dir.appendingPathComponent("input.log")
    var host = HostHealthKnockState()
    let alarm = HostHealthAlarm(at: now.addingTimeInterval(-30), load1: 5.65,
                                freeBytes: 127_000_000_000, top: [])
    let report = HostHealthReport(sampledAt: now.addingTimeInterval(-10), load1: 5.65, cores: 8,
                                  freeBytes: 127_000_000_000, state: .alarmed,
                                  since: now.addingTimeInterval(-30), lastAlarm: alarm)
    applyHostHealthKnock(&host, pid: "dg-seen", typedAlready: false, session: .blocked,
                         quiet: .quiet, turnEnded: { false }, keyboardIdle: true,
                         relaunchPlanned: false, draftSuspected: false, waitingOnPerson: false,
                         seen: SessionInputSeen(state: .blocked, wait: .soft, registry: false),
                         modified: { _ in now.addingTimeInterval(-10) }, read: { _ in report },
                         now: now, log: log, dir: dir, inject: { _, _ in .done })
    check("a typed knock records what the tick saw, between its outcome and its bytes",
          ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains(
              " pid=dg-seen input=\(hostHealthKnockOutcome) state=blocked wait=soft registry=clear bytes="))
    check("…and the three words cover a hard wait and an unread registry",
          SessionInputSeen(state: .idle, wait: .hard, registry: nil).fields
              == "state=idle wait=hard registry=unread"
              && SessionInputSeen(state: .idle, wait: nil, registry: true).fields
              == "state=idle wait=none registry=waiting")
    let fixed = Date(timeIntervalSince1970: 1_800_000_000)
    check("a typed line carries no seen fields when none is handed",
          sessionInputLogLine(pid: "9", outcome: "submitted", text: "/help", now: fixed)
              == "\(ISO8601DateFormatter().string(from: fixed)) pid=9 input=submitted bytes=5 text=/help\n")

    // MARK: - Which writers ask which gate

    // THE AUTOMATIC GATE HAS EXACTLY FOUR CALLERS, one per writer nobody asked for, and the shared
    // table exactly two (the requested line's decision and the automatic gate itself). The
    // population is `command grep -rn 'injectSessionInput(' TallyCLI`: a sixth writer has to be
    // added here, which is the point of counting.
    let sources = ((try? FileManager.default.contentsOfDirectory(atPath: "TallyCLI")) ?? [])
        .filter { $0.hasSuffix(".swift") }
    func calls(_ needle: String, definedAs definition: String) -> [String: Int] {
        var found: [String: Int] = [:]
        for name in sources {
            guard let text = try? String(contentsOfFile: "TallyCLI/\(name)", encoding: .utf8) else {
                continue
            }
            let count = text.components(separatedBy: "\n")
                .filter { $0.contains(needle) && !$0.contains(definition) }.count
            if count > 0 { found[name] = count }
        }
        return found
    }
    check("the TallyCLI sources were really read", sources.count > 20)
    check("every writer nobody asked for asks the automatic gate, once each",
          calls("automaticSessionInputHold(", definedAs: "func automaticSessionInputHold(")
              == ["QuotaKnock.swift": 1, "HostHealthKnock.swift": 1, "CapLimitReset.swift": 1,
                  "CapResume.swift": 1])
    check("…and the shared table is asked only by the requested line and by that gate",
          calls("sessionInputHold(", definedAs: "func sessionInputHold(")
              == ["SessionInput.swift": 1, "SessionInputAutomatic.swift": 1])
    let input = (try? String(contentsOfFile: "TallyCLI/SessionInput.swift", encoding: .utf8)) ?? ""
    let decision = input.range(of: "func sessionInputDecision(").map { start -> String in
        let rest = input[start.upperBound...]
        return String(rest[..<(rest.range(of: "\nfunc ")?.lowerBound ?? rest.endIndex)])
    } ?? ""
    check("the requested line's decision never asks the dialog row",
          !decision.isEmpty && !decision.contains("automaticSessionInputHold")
              && !decision.contains("dialogPossible"))
    let sync = (try? String(contentsOfFile: "TallyCLI/SessionStateSync.swift", encoding: .utf8)) ?? ""
    check("the tick hands on the registry it reads every tick, not the hard-notice one",
          sync.contains("dialogRegistry: reading.map") && !sync.contains("dialogRegistry: registry"))
}
