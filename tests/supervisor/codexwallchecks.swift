import Darwin
import Foundation

// B-2096 package 2: a Codex window on an account that has run out moves itself. The rollout half
// (reading a wall out of a real rollout) is tests/codex-supervisor/wallchecks.swift; this is the
// half that needs the rest of the CLI: choosing the target, the quarantine, the fuse, the redeem
// hold, the two signals, and the locks that keep the move on the one gate, kill and exec path.

func runCodexWallChecks() {
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tally-codexwall-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let homeA = base.appendingPathComponent("home-a"), homeB = base.appendingPathComponent("home-b")
    let homeC = base.appendingPathComponent("home-c"), work = base.appendingPathComponent("work")
    let dir = base.appendingPathComponent("state"), day = homeA.appendingPathComponent("sessions/2026/10/17")
    let thread = UUID().uuidString, pid = String(getpid())
    let transcript = day.appendingPathComponent("rollout-2026-10-17T00-00-00-\(thread).jsonl")
    func writeIdentity(home: URL) throws {
        let identity = SessionMonitoring(provider: "codex", supervisorPID: getpid(),
            supervisorStart: SessionMonitoring.generation(getpid())!, nonce: "n", home: home.path)
        try identity.write(dir: dir)
        try (SessionMonitoring.presencePrefix + String(identity.supervisorStart)).write(
            to: dir.appendingPathComponent(pid), atomically: true, encoding: .utf8)
    }
    do {
        for url in [day, work, dir, homeB, homeC.appendingPathComponent("sessions")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: homeB.appendingPathComponent("sessions"),
                                                   withDestinationURL: homeA.appendingPathComponent("sessions"))
        var first = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": [
            "id": thread, "session_id": thread, "source": "cli"]])
        first.append(10)
        try first.write(to: transcript)
        try writeIdentity(home: homeA)
        try JSONEncoder().encode(CodexSessionBinding(nonce: "n", sessionID: thread, transcriptPath: transcript.path,
            model: nil, directory: work.path)).write(to: dir.appendingPathComponent(pid + ".codex-binding"))
    } catch {
        check("codex wall fixture builds", false)
        return
    }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func account(_ id: String, _ label: String, home: URL, left: Double = 80, refreshed: Date? = nil) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "codex", label: label, launchHome: home.path,
                         sessionRemaining: 80, weeklyRemaining: left, modelRemaining: nil,
                         sessionResetsAt: now.addingTimeInterval(4 * 3600), weeklyResetsAt: now.addingTimeInterval(100 * 3600),
                         modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil, isStale: false, error: nil,
                         refreshedAt: refreshed ?? now.addingTimeInterval(-120))
    }
    let cur = account("codex:.codex1", "Codex Pro", home: homeA), roomy = account("codex:.codex2", "Codex Team", home: homeB)
    let unshared = account("codex:.codex3", "Codex Solo", home: homeC)
    func snap(_ accounts: [Snapshot.Account]) -> Snapshot { Snapshot(version: 2, generatedAt: now, accounts: accounts) }
    func wallReading(at: Date? = nil) -> CodexRateReading? {
        CodexRateReading(limits: ["primary": ["used_percent": 100.0, "resets_at": now.timeIntervalSince1970 + 86400]], at: at ?? now)
    }
    var qn = 0
    func quarantineDirectory() -> URL { qn += 1; return base.appendingPathComponent("quarantine-\(qn)") }
    func tick(_ watch: inout CodexWallWatch, _ reading: CodexRateReading?, _ accounts: [Snapshot.Account], at: Date = now,
              account id: String = "codex:.codex1", fuse: inout RecoveryFuse, quarantine: URL,
              reserves: AccountReserves = .none, snapshot: Bool = true) -> CodexWallVerdict {
        codexWallPlan(watch: &watch, reading: reading, accountID: id, pid: pid, fuse: &fuse, reserves: reserves, now: at,
                      fallbackDirectory: work.path, readSnapshot: { snapshot ? snap(accounts) : nil }, dir: dir, quarantineDir: quarantine)
    }
    func newFuse() -> RecoveryFuse { RecoveryFuse(max: codexWallMaxMoves, window: capResumeBudgetWindow, now: now) }

    // T1: a wall read from the rollout, a healthy sibling that shares the history
    let q1 = quarantineDirectory()
    var watch = CodexWallWatch(), fuse = newFuse()
    let t1 = tick(&watch, wallReading(), [cur, roomy], fuse: &fuse, quarantine: q1)
    check("T1 rollout wall + healthy sibling on the same history: a plan to that sibling",
          t1.wall && t1.held == nil && t1.plan?.targetHome == homeB.path && t1.plan?.threadID == thread
              && t1.plan?.directory == work.path)
    check("T1 …marked as the supervisor's own move, from the rollout, naming both accounts, never crossing a reserve",
          t1.plan?.wall == CodexWallMove(source: "rollout", fromID: cur.id, toID: roomy.id,
                                         fromName: "Codex Pro", toName: "Codex Team",
                                         resumeLine: capResumeMessage(from: cur, to: roomy)) && t1.plan?.spendReserve == false)
    check("T1 …and the wall quarantines the capped account for a launch right now",
          quarantinedAccounts(forPrimary: nil, now: now, dir: q1).contains(cur.id))

    // T2: no candidate on the same history
    var w2 = CodexWallWatch(), f2 = newFuse()
    let t2 = tick(&w2, wallReading(), [cur, unshared], fuse: &f2, quarantine: quarantineDirectory())
    check("T2 a sibling that does not share the sessions directory is not a target: held no-target, no plan",
          t2.wall && t2.plan == nil && t2.held == "no-target")

    // T3: the only candidate is under its reserve
    let reserved = AccountReserves(settings: [homeB.path: AccountRoleSetting(role: AccountRoles.personal, reserve: 10)])
    var w3 = CodexWallWatch(), f3 = newFuse()
    let t3 = tick(&w3, wallReading(), [cur, account("codex:.codex2", "Codex Team", home: homeB, left: 8)],
                  fuse: &f3, quarantine: quarantineDirectory(), reserves: reserved)
    check("T3 a target under its reserve is never spent into: held reserve, no plan", t3.plan == nil && t3.held == "reserve")

    // T4: the account just left is quarantined (T1 wrote it), so the way back is closed
    try? writeIdentity(home: homeB)
    var w4 = CodexWallWatch(), f4 = newFuse()
    let t4 = tick(&w4, wallReading(), [cur, roomy], account: roomy.id, fuse: &f4, quarantine: q1)
    check("T4 from the second account, the quarantined first one is not picked back (it is healthy in the snapshot)",
          t4.wall && t4.plan == nil && t4.held == "no-target")
    var w4b = CodexWallWatch(), f4b = newFuse()
    let t4b = tick(&w4b, wallReading(), [cur, roomy], account: roomy.id, fuse: &f4b, quarantine: quarantineDirectory())
    check("T4 …and with no quarantine on record the same fleet does move back (the control for the line above)",
          t4b.plan?.targetHome == homeA.path)
    try? writeIdentity(home: homeA)

    // T5: the fuse
    var w5 = CodexWallWatch(), f5 = newFuse()
    f5.record(now: now.addingTimeInterval(-60)); f5.record(now: now.addingTimeInterval(-30))
    let t5 = tick(&w5, wallReading(), [cur, roomy], fuse: &f5, quarantine: quarantineDirectory())
    check("T5 a third automatic move inside the window is refused: held fuse", t5.plan == nil && t5.held == "fuse")
    let carried = f5.carried(now: now)
    check("T5 the fuse crosses the exec as epoch seconds and comes back equal",
          decodeRecoveryFuse(encodeRecoveryFuse(carried)) == carried && carried.count == 2)
    var old = RecoveryFuse(max: codexWallMaxMoves, window: capResumeBudgetWindow,
                           recovered: [now.addingTimeInterval(-3 * 3600), now.addingTimeInterval(-3 * 3600 - 1)], now: now)
    check("T5 entries older than the window are dropped on the way in", old.allows(now: now) && old.carried(now: now).isEmpty)

    // T6: a banked reset gets three minutes before anyone moves
    var credited = cur
    credited.resetCreditsAvailable = 1
    credited.resetState = "available"
    var w6 = CodexWallWatch(), f6 = newFuse()
    let held6 = tick(&w6, wallReading(), [credited, roomy], fuse: &f6, quarantine: quarantineDirectory())
    check("T6 a wall with a redeemable reset waits: held redeem, no plan", held6.plan == nil && held6.held == "redeem")
    let later = now.addingTimeInterval(codexWallRedeemHold + 1)
    let after6 = tick(&w6, wallReading(), [credited, roomy], at: later, fuse: &f6, quarantine: quarantineDirectory())
    check("T6 …and moves once the hold has run out", after6.plan?.targetHome == homeB.path)
    var w6b = CodexWallWatch(), f6b = newFuse()
    _ = tick(&w6b, wallReading(), [credited, roomy], fuse: &f6b, quarantine: quarantineDirectory())
    let redeemed = CodexRateReading(limits: ["primary": ["used_percent": 0.0, "resets_at": now.timeIntervalSince1970 + 7 * 86400]],
                                    at: now.addingTimeInterval(70))
    let cleared = tick(&w6b, redeemed, [credited, roomy], at: now.addingTimeInterval(70), fuse: &f6b, quarantine: quarantineDirectory())
    check("T6 a 0% reading during the hold lifts the wall: nothing planned, nothing held",
          !cleared.wall && cleared.plan == nil && cleared.held == nil && w6b.wallAt == nil)
    var w6c = CodexWallWatch(), f6c = newFuse()
    _ = tick(&w6c, wallReading(), [credited, roomy], fuse: &f6c, quarantine: quarantineDirectory())
    var roomyNow = cur
    roomyNow.refreshedAt = now.addingTimeInterval(30)
    let overruled = tick(&w6c, wallReading(), [roomyNow, roomy], at: now.addingTimeInterval(40), fuse: &f6c, quarantine: quarantineDirectory())
    let still = tick(&w6c, wallReading(), [roomyNow, roomy], at: now.addingTimeInterval(80), fuse: &f6c, quarantine: quarantineDirectory())
    check("T6 a fresh, roomy snapshot taken after the reading overrules it, and stays overruled until a newer reading",
          !overruled.wall && !still.wall && w6c.settledReading == now)

    // T7: the snapshot signal, one disqualifier at a time
    var drained = cur
    drained.weeklyRemaining = 0
    check("T7 a fresh, error-free, stamped account with no headroom is a wall", codexSnapshotWall(drained))
    var d1 = drained; d1.isStale = true
    var d2 = drained; d2.lastRefreshFailed = true
    var d3 = drained; d3.error = "x"
    var d4 = drained; d4.refreshedAt = nil
    var d5 = drained; d5.weeklyRemaining = nil; d5.sessionRemaining = nil
    check("T7 stale, a failed last poll, an error, no stamp, or no windows each alone: not a wall",
          [d1, d2, d3, d4, d5].allSatisfy { !codexSnapshotWall($0) } && !codexSnapshotWall(nil) && !codexSnapshotWall(cur))
    var w7 = CodexWallWatch(), f7 = newFuse()
    let t7 = tick(&w7, nil, [drained, roomy], fuse: &f7, quarantine: quarantineDirectory())
    check("T7 a drained snapshot alone (a window another window emptied) plans a move, from the snapshot",
          t7.plan?.wall?.source == "snapshot" && t7.plan?.targetHome == homeB.path)
    var w7b = CodexWallWatch(), f7b = newFuse()
    let t7b = tick(&w7b, nil, [d1, roomy], fuse: &f7b, quarantine: quarantineDirectory())
    var w7c = CodexWallWatch(), f7c = newFuse()
    let t7c = tick(&w7c, wallReading(), [cur, roomy], fuse: &f7c, quarantine: quarantineDirectory(), snapshot: false)
    check("T7 a stale snapshot moves nothing, and no readable snapshot holds a rollout wall: no-snapshot",
          !t7b.wall && t7b.plan == nil && t7c.wall && t7c.plan == nil && t7c.held == "no-snapshot")

    // T11: the destination of a move must not inherit the source's last rollout reading as its own wall
    // (the live rehearsal's finding 1, reproduced end to end up to the tick wiring). The old window's
    // records, 100% included, predate the new supervisor's launch, which is what keeps them out.
    let launched = now.addingTimeInterval(60)
    let rolloutURL = work.appendingPathComponent("rollout-after-move.jsonl")
    func row(_ type: String, _ payload: [String: Any], at: Date) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["type": type, "payload": payload,
            "timestamp": ISO8601DateFormatter().string(from: at)])
        return String(decoding: data, as: UTF8.self) + "\n"
    }
    let sourceSession = UUID().uuidString, oldTurn = UUID().uuidString
    let staleLimits: [String: Any] = ["primary": ["used_percent": 100.0, "window_minutes": 10080,
                                                   "resets_at": launched.timeIntervalSince1970 + 86400]]
    try? (row("session_meta", ["id": sourceSession, "session_id": sourceSession, "source": "cli"], at: now)
        + row("event_msg", ["type": "task_started", "turn_id": oldTurn], at: now.addingTimeInterval(1))
        + row("event_msg", ["type": "token_count", "rate_limits": staleLimits], at: now.addingTimeInterval(2))
        + row("event_msg", ["type": "task_complete", "turn_id": oldTurn], at: now.addingTimeInterval(3)))
        .write(to: rolloutURL, atomically: true, encoding: .utf8)
    let rolloutHome = base.appendingPathComponent("rollout-home")
    let rolloutDay = rolloutHome.appendingPathComponent("sessions")
    try? FileManager.default.createDirectory(at: rolloutDay, withIntermediateDirectories: true)
    let placed = rolloutDay.appendingPathComponent("rollout-after-move.jsonl")
    try? FileManager.default.copyItem(at: rolloutURL, to: placed)
    var fresh = CodexSessionObserver(binding: CodexSessionBinding(nonce: "m", sessionID: sourceSession,
        transcriptPath: placed.path, model: nil), launchedAt: launched)
    fresh.poll(home: rolloutHome.path)
    let q11 = quarantineDirectory()
    var w11 = CodexWallWatch(), f11 = newFuse()
    // the destination is roomy in the snapshot, but its row is OLDER than the stale reading, so the
    // overrule cannot be what saves it
    var olderRoomy = roomy
    olderRoomy.refreshedAt = now.addingTimeInterval(-300)
    let t11 = tick(&w11, fresh.rateReading, [cur, olderRoomy], at: launched.addingTimeInterval(5), account: roomy.id,
                   fuse: &f11, quarantine: q11)
    check("T11 a window started after a move reads none of the source account's rollout, so the destination is no wall "
          + "and is not quarantined",
          !fresh.invalidated && fresh.rateReading == nil && !t11.wall && t11.plan == nil && t11.held == nil
              && !quarantinedAccounts(forPrimary: nil, now: launched.addingTimeInterval(5), dir: q11).contains(roomy.id))

    // T8/T10: one path out of the supervisor, behind the one gate
    let supervisor = (try? String(contentsOfFile: "TallyCLI/CodexSupervisor.swift", encoding: .utf8)) ?? ""
    func count(_ needle: String) -> Int { supervisor.components(separatedBy: needle).count - 1 }
    check("T10 the wall plan is assigned to `handoff` and nothing else; kill and `handoffTo =` appear once for hand-offs",
          supervisor.contains("if handoff == nil, let plan = verdict.plan {\n                        handoff = plan")
              && count("handoffTo = ") == 1 && count("execCodexHandoff(handoffTo") == 1
              && supervisor.contains("kill(child, SIGTERM)\n                        handoffTo = plan"))
    check("T10 …and a wall move waits on the same gate as a manual one, turn boundary included",
          supervisor.contains("turnEnded: observer?.canAcceptInput == true,") && count("codexHandoffGate(") == 1)
    check("T8 a manual request meets a queued wall plan as busy, and a wall never overwrites a queued manual one",
          supervisor.contains("handoff != nil ? \"a hand-off is already queued for this window\"")
              && supervisor.contains("handoff == nil || handoff?.wall != nil"))
    check("T10 the fuse is read from the environment once and removed before the child's environment is built",
          (supervisor.range(of: "unsetenv(codexWallFuseEnv)")?.lowerBound ?? supervisor.endIndex)
              < (supervisor.range(of: "supervisedChildEnvironment(")?.lowerBound ?? supervisor.startIndex)
              && supervisor.contains("if var move = plan.wall {\n                            autoFuse.record()"))

    // T9: what the person sees
    let move = CodexWallMove(source: "rollout", fromID: cur.id, toID: roomy.id, fromName: "Codex Pro", toName: "Codex Team")
    let notice = codexWallNotice(move)
    check("T9 the terminal line names both accounts and the limit, with no em dash",
          notice.contains("Codex Pro") && notice.contains("Codex Team") && notice.contains("usage limit") && !notice.contains("\u{2014}"))
    var resuming = move
    resuming.resumeLine = capResumeMessage(from: cur, to: roomy)
    check("T9 the resume line is typed only when the wall cut a turn short, and is the cap resume's own wording",
          codexWallResumeLine(resuming, turnFailed: true) == capResumeMessage(from: cur, to: roomy)
              && codexWallResumeLine(resuming, turnFailed: false) == nil
              && t1.plan?.wall?.resumeLine == capResumeMessage(from: cur, to: roomy))
    check("T9 …decided at the kill from the observer's failed-turn flag, carried across the exec in the environment "
          + "and queued by the new supervisor after its input state is seeded",
          supervisor.contains("codexWallResumeLine(move, turnFailed: observer?.lastTurnFailed == true)")
              && supervisor.contains("setenv(codexWallResumeEnv, line, 1)")
              && (supervisor.range(of: "var input = SessionInputState(sessionKey: pid)")?.lowerBound ?? supervisor.endIndex)
                  < (supervisor.range(of: "writeSessionInputRequest(SessionInputRequest(")?.lowerBound ?? supervisor.startIndex)
              && (supervisor.range(of: "unsetenv(codexWallResumeEnv)")?.lowerBound ?? supervisor.endIndex)
                  < (supervisor.range(of: "supervisedChildEnvironment(")?.lowerBound ?? supervisor.startIndex))
    check("T9 …and only a line in the cap resume's own shape is accepted back from the environment",
          codexWallCarriedResume(capResumeMessage(from: cur, to: roomy)) == capResumeMessage(from: cur, to: roomy)
              && codexWallCarriedResume("rm -rf /") == nil && codexWallCarriedResume(nil) == nil
              && codexWallCarriedResume(capResumeMarker + String(repeating: "x", count: sessionInputMaxBytes)) == nil)
    let audit = codexWallAuditLine(pid: pid, result: "moved", move: move, now: now)
    check("T9 the audit line carries origin=wall, the signal and both ids",
          audit.contains("input=codex-handoff result=moved origin=wall source=rollout from=codex:.codex1 to=codex:.codex2"))
}
