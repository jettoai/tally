import Foundation

// jettoai/tally#10: `tally account GM` said "the conversation continues", then the relaunch found
// another head holding that conversation and opened an empty window. Three layers are asserted here:
// the request is refused while the person can still act (S3-S7), a holder that appears later holds
// the move at plan time instead of costing the conversation (S8-S9), and a fresh start that still
// happens says so on both surfaces (S11-S12).
//
// The holder is this test process, registered as an unmanaged head: certainly alive, and nothing
// here signals it.

func runSecondHeadSwitchChecks() {
    let tmp = FileManager.default.temporaryDirectory
    let stateDir = tmp.appendingPathComponent("tally-shs-state-\(UUID().uuidString)")
    let unmanagedDir = tmp.appendingPathComponent("tally-shs-unmanaged-\(UUID().uuidString)")
    let projectCwd = tmp.appendingPathComponent("tally-shs-cwd-\(UUID().uuidString)")
    for dir in [stateDir, unmanagedDir, projectCwd] {
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    let held = "530014d3-aaaa-bbbb-cccc-111111111111"
    let me = ConversationHolder(pid: String(getpid()), supervised: false)
    let myStamp = processStamp(getpid())!
    writeUnmanagedLaunch(UnmanagedLaunch(claudeCode: myStamp, cwd: realpathString(projectCwd.path),
                                         id: held), dir: unmanagedDir)
    func holders(excluding: String? = nil) -> [String: ConversationHolder] {
        conversationHolders(in: projectCwd.path, excluding: excluding, dir: stateDir,
                            unmanagedDir: unmanagedDir)
    }
    func live(excluding: String? = nil) -> Set<String> {
        liveConversations(in: projectCwd.path, excluding: excluding, dir: stateDir,
                          unmanagedDir: unmanagedDir)
    }

    // MARK: - S1, S2. The holder map, and the set that is exactly its keys

    check("S1 an unmanaged head holds its conversation under its own pid", holders()[held] == me)
    check("S2 the live set is the holders' keys (unmanaged only)", live() == Set(holders().keys)
          && live() == [held])
    let sibling = legacySupervisorFixture()
    defer { sibling.terminate(); sibling.waitUntilExit() }
    let siblingKey = String(sibling.processIdentifier)
    let siblingConversation = "66666666-7777-8888-9999-aaaaaaaaaaaa"
    markSupervisorLive(pid: siblingKey, dir: stateDir)
    writeSupervisorCwd(projectCwd.path, pid: siblingKey, dir: stateDir)
    if let stamp = processStamp(sibling.processIdentifier) {
        writeTranscriptIdentity(TranscriptIdentity(id: siblingConversation, claudeCode: stamp),
                                pid: siblingKey, dir: stateDir)
    }
    check("S2 a supervised sibling is held under its supervisor pid",
          holders()[siblingConversation] == ConversationHolder(pid: siblingKey, supervised: true))
    check("S2 both witnesses together", live() == [held, siblingConversation]
          && live() == Set(holders().keys))
    check("S2 excluding the sibling's own key drops only its conversation",
          live(excluding: siblingKey) == [held]
              && holders(excluding: siblingKey)[siblingConversation] == nil)

    // MARK: - S3 to S7. The request-time refusal

    let heldHolders = [held: me]
    let refusal = switchSecondHeadRefusal(conversation: held, holders: heldHolders, target: "GM")
    check("S3 a held conversation refuses the switch", refusal != nil)
    let text = refusal ?? ""
    check("S3 and names the conversation (cut), the holder pid, that Tally does not supervise it, "
          + "the target and that nothing was queued",
          text.contains(held.prefix(8)) && text.contains("pid \(getpid())")
              && text.contains("not supervised") && text.contains("GM")
              && text.contains("nothing was queued"))
    check("S3 without the full id, a promise of continuation or an em dash",
          !text.contains(held) && !text.contains("continues") && !text.contains("\u{2014}"))
    check("S4 nobody holding anything refuses nothing",
          switchSecondHeadRefusal(conversation: held, holders: [:], target: "GM") == nil)
    check("S4 a holder of a DIFFERENT conversation refuses nothing",
          switchSecondHeadRefusal(conversation: held, holders: [siblingConversation: me],
                                  target: "GM") == nil)
    check("S5 an unknown conversation is never refused",
          switchSecondHeadRefusal(conversation: nil, holders: heldHolders, target: "GM") == nil)

    let promptId = "11111111-1111-1111-1111-111111111111"
    let reportId = "22222222-2222-2222-2222-222222222222"
    let publishedId = "33333333-3333-3333-3333-333333333333"
    let good = TranscriptIdentity(id: reportId, claudeCode: myStamp)
    let stale = TranscriptIdentity(id: reportId, claudeCode: ProcessStamp(pid: myStamp.pid,
                                                                          startedAt: myStamp.startedAt + 1))
    check("S6 the prompt's own id outranks the report and the publish",
          sessionConversation(promptID: promptId, identity: good, published: publishedId) == promptId)
    check("S6 then a live process's report outranks the publish",
          sessionConversation(promptID: nil, identity: good, published: publishedId) == reportId)
    check("S6 a report from a process that is no longer the one running is ignored",
          sessionConversation(promptID: nil, identity: stale, published: publishedId) == publishedId)
    check("S6 nothing known is nil",
          sessionConversation(promptID: nil, identity: nil, published: nil) == nil)

    let command = (try? String(contentsOfFile: "TallyCLI/SwitchCommand.swift", encoding: .utf8)) ?? ""
    let checkAt = command.range(of: "switchSecondHeadRefusal(")?.lowerBound
    let writeAt = command.range(of: "try writeSwitchRequest(")?.lowerBound
    check("S7 the refusal is asked before the request is written",
          checkAt != nil && writeAt != nil && checkAt! < writeAt!)
    check("S7 and only for a real move (a target that is not already the session's account)",
          command.contains("if let target, !alreadyThere,"))
    check("S4 the queued message for an unheld conversation is unchanged",
          command.contains("there when the current turn ends and the conversation continues"))

    // MARK: - S8, S9. The plan-time hold, and the move once the holder is gone

    let watcherDir = tmp.appendingPathComponent("tally-shs-watch-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: watcherDir, withIntermediateDirectories: true)
    let transcript = watcherDir.appendingPathComponent("\(held).jsonl")
    try! #"{"type":"user","timestamp":"2026-01-01T00:00:00Z"}"#
        .write(to: transcript, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)],
                                           ofItemAtPath: transcript.path)
    var watcher = TranscriptWatcher(projectDir: watcherDir, file: transcript,
                                    since: Date().addingTimeInterval(-600))
    let onA = switchAccount("A")
    let toGM = switchAccount("GM", label: "GM")
    let tickDir = tmp.appendingPathComponent("tally-shs-tick-\(UUID().uuidString)")
    var state = ManualMoveState(sessionKey: "4242", servedEpoch: 100)
    let request = SwitchRequest(epoch: 200, accountID: "GM")
    func tick(_ heldElsewhere: @escaping (String) -> ConversationHolder?)
        -> (plan: RelaunchPlan?, record: PendingSwitchConsumption?) {
        var plan: RelaunchPlan?
        var record: PendingSwitchConsumption?
        var policy = LaunchPolicy()
        policy.mode = "auto"
        applyManualMoves(plan: &plan, state: &state, record: &record, policy: &policy,
                         account: onA, providerID: "claude", watcher: &watcher, childAge: 9999,
                         keyboardIdle: { _ in true }, dir: tickDir, request: { _ in request },
                         accounts: { [onA, toGM] }, homeOnDisk: { _, _ in false },
                         quarantineIn: switchQuarantineDir, heldElsewhere: heldElsewhere)
        return (plan, record)
    }
    let holding = tick { $0 == held ? me : nil }
    check("S8 a holder present at plan time plans no move", holding.plan == nil)
    check("S8 and consumes nothing", holding.record == nil && state.servedEpoch == 100)
    check("S8 the status line says the move is held",
          state.waiting?.badge == "switch: held, conversation open elsewhere"
              && state.waiting?.detail?.contains("pid \(getpid())") == true
              && state.waiting?.detail?.contains("staying on A") == true)
    let released = tick { _ in nil }
    check("S9 once the holder has exited the same request moves the session",
          released.plan?.reason == "switch" && released.plan?.target.id == "GM")
    check("S9 resuming the conversation, not starting fresh", released.plan?.fresh == false)
    check("S9 and the hold badge is gone", state.waiting?.badge != "switch: held, conversation open elsewhere")

    // MARK: - S10. The supervisor is wired to both

    let supervisor = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("S10 the tick hands the plan-time hold the live holders",
          supervisor.contains(
              "heldElsewhere: { conversationHolders(in: cwd, excluding: supervisorPID)[$0] }"))
    check("S10 a fresh start after the kill is noted on the status line too",
          supervisor.contains("manualMoves.noteFreshStart("))
    check("S10 the resume decision still asks the holders",
          supervisor.contains("secondHead = resumeForksConversation("))
    let carryingAt = supervisor.range(
        of: "let carrying = fresh || secondHead ? nil : sessionFile")?.lowerBound
    let resumedAt = supervisor.range(of: "switchResumedNotice(")?.lowerBound
    check("S10 a typed switch that continues the conversation says so after the decision",
          carryingAt != nil && resumedAt != nil && carryingAt! < resumedAt!
              && supervisor.contains("if reason == \"switch\", let id = carrying"))

    // MARK: - S11, S12. What a fresh start says, and how long the badge lives

    let notice = secondHeadNotice(conversation: held, target: "GM", holder: me)
    check("S11 the fresh-start notice says so, names the holder and what ended with the window",
          notice.contains("started fresh") && notice.contains("pid \(getpid())")
              && notice.contains("Subagents") && notice.contains(held.prefix(8))
              && !notice.contains(held))
    let line = secondHeadHoldLine(conversation: held, pid: "4242", cwd: "/work", holder: "999")
    check("S11 the audit line names the holder before cwd and stays one line",
          line.contains("holder=999 cwd=/work") && line.hasSuffix("\n")
              && !line.dropLast().contains("\n"))
    let freshBadge = secondHeadFreshBadge(conversation: held, holder: me, target: "GM")
    check("S11 the badge starts 'started fresh:' and no surface has an em dash",
          freshBadge.badge.hasPrefix("started fresh:") && freshBadge.kind == secondHeadFreshNoticeKind
              && !notice.contains("\u{2014}") && !line.contains("\u{2014}")
              && !(freshBadge.detail ?? "").contains("\u{2014}"))

    var news = ManualMoveState(sessionKey: "1", servedEpoch: 0)
    let raised = Date(timeIntervalSince1970: 1_000)
    news.noteFreshStart(freshBadge, at: raised)
    check("S12 the fresh start shows on the status line", news.badge == freshBadge)
    news.expireCancellation(lastUserTurnAt: raised.addingTimeInterval(-5))
    check("S12 a prompt from before it does not clear it", news.badge == freshBadge)
    news.waiting = PendingBadge("switch: session busy")
    check("S12 a live wait outranks it", news.badge?.badge == "switch: session busy")
    news.waiting = nil
    news.expireCancellation(lastUserTurnAt: raised.addingTimeInterval(5))
    check("S12 the user's next prompt clears it", news.badge == nil)
}
