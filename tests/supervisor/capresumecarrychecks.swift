import Foundation

// CAP RESUME ACROSS A SELF-UPDATE EXEC (TallyCLI/CapResume.swift, ResuperviseContract.swift).
//
// THE INCIDENT (2026-09-26). A cap handoff folded a waiting self-update into the same tick
// (`selfUpdateFold`), the exec replaced the supervisor, and the arm raised a moment earlier lived
// only in the old image's memory: the session sat 22 minutes with an empty composer. The arm now
// rides the exec argv like the pending cap does, and raising one leaves a line in the input log.

func runCapResumeCarryChecks() {
    let wall = Date(timeIntervalSince1970: 1_800_000_000)
    func acct(_ id: String, label: String) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: label, launchHome: "/tmp/\(id)",
                         sessionRemaining: 40, weeklyRemaining: 40, modelRemaining: nil,
                         sessionResetsAt: nil, weeklyResetsAt: nil, modelResetsAt: nil,
                         modelWindowName: nil, resetCreditsAvailable: nil, isStale: false,
                         error: nil)
    }
    let capped = acct("A", label: "Claude 5")
    let sibling = acct("B", label: "Claude 3")
    let conversation = "abc-123"

    var armed = CapResumeState()
    armed.arm(reason: "cap", fresh: false, cappedAt: wall, answeredAt: wall.addingTimeInterval(-10),
              conversation: conversation, from: capped, to: sibling, userTurnAt: nil,
              caughtUp: true)
    var nudged = CapResumeState()
    nudged.arm(reason: "cap", fresh: false, cappedAt: wall.addingTimeInterval(-600),
               answeredAt: nil, conversation: conversation, from: capped, to: sibling,
               userTurnAt: nil, caughtUp: true)
    nudged.spend()
    nudged.noteTyped(at: wall.addingTimeInterval(-590))
    check("the fixtures are what they claim: one standing offer, one spent with a stamp",
          armed.isArmed && !nudged.isArmed && nudged.nudgedAt != nil && nudged.lastCapAt != nil)

    // MARK: A1. The argv round trip

    func trip(_ state: CapResumeState?) -> ResuperviseArgs {
        parseResuperviseArgs(Array(selfUpdateArgv(
            binary: "/usr/local/bin/tally", id: "acct-1", label: "Claude 3", home: "/h",
            follow: true, recoveries: [wall], lastConversation: conversation, capResume: state,
            args: ["--resume", conversation]).dropFirst(2)))
    }
    check("a standing offer survives the exec", trip(armed).capResume == armed)
    check("…and so does a spent one's latch and stamp", trip(nudged).capResume == nudged)
    check("…without disturbing what rides beside it",
          trip(armed).recoveries == [wall] && trip(armed).lastConversation == conversation
              && trip(armed).childArgs == ["--resume", conversation])
    check("an empty state writes no flag at all",
          !selfUpdateArgv(binary: "x", id: "a", label: "A", home: "/h", follow: true,
                          capResume: CapResumeState(), args: []).contains(resuperviseCapResumeFlag))
    check("an argv from a build predating the flag parses as no resume",
          parseResuperviseArgs(["--id", "a", "--home", "/h", "--", "--resume", "x"])
              .capResume == nil)
    check("a truncated value is no resume", decodeCapResume("{") == nil)
    check("half an offer is no resume", decodeCapResume(#"{"at":1}"#) == nil)
    check("an offer about something that is not a transcript id is no resume",
          decodeCapResume(#"{"at":1,"conversation":"../../etc/passwd","line":"x"}"#) == nil)
    check("an offer with no line is no resume",
          decodeCapResume(#"{"at":1,"conversation":"abc","line":""}"#) == nil)
    check("a latch that is present and unreadable is no resume",
          decodeCapResume(#"{"lastCapAt":"soon"}"#) == nil)
    check("a line carrying a comma, a newline and a non-ASCII label survives",
          decodeCapResume(encodeCapResume(CapResumeState(offer: .init(
              at: wall, conversation: "abc", line: "a, b\n帳號 (x)")))!)?.offer?.line
              == "a, b\n帳號 (x)")

    // MARK: A2. Both ends of the exec are wired (source string: the loop needs a live child)

    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    let call = loop.range(of: "execPlannedSelfUpdate(upgrade").flatMap { start in
        loop.range(of: "args:", range: start.upperBound..<loop.endIndex).map {
            String(loop[start.lowerBound..<$0.upperBound])
        }
    } ?? ""
    check("the exec call in the supervisor loop is readable", call.hasSuffix("args:"))
    check("an upgrading supervisor hands its cap resume on",
          call.contains("capResume: capResume"))
    check("…and the image it hands to starts holding it",
          loop.contains("var capResume = carriedResume ?? CapResumeState()"))
    let entry = (try? String(contentsOfFile: "TallyCLI/SelfUpdate.swift", encoding: .utf8)) ?? ""
    check("…which the resupervise entry point takes off the argv",
          entry.contains("capResume: parsed.capResume"))

    // MARK: A3. The restored state behaves as the one it replaced

    let restored = decodeCapResume(encodeCapResume(armed)!)!
    func decide(_ state: CapResumeState, session: SupervisedState = .idle,
                conversation: String? = conversation) -> CapResumeDecision {
        state.decide(state: session, quiet: .quiet, turnEnded: false, keyboardIdle: true,
                     relaunchPlanned: false, dialogPossible: false, draftSuspected: false,
                     caughtUp: true, userTurnAt: nil, conversation: conversation,
                     now: wall.addingTimeInterval(30))
    }
    check("a restored offer waits out a turn of the new child's own",
          decide(restored, session: .working) == .hold(.input(.turn)))
    check("…and is typed once the session is quiet",
          decide(restored) == .type(armed.offer!.line))
    check("…but never into a different conversation",
          decide(restored, conversation: "other") == .drop(.otherConversation))
    var spent = restored
    spent.spend()
    spent.arm(reason: "cap", fresh: false, cappedAt: wall, answeredAt: nil,
              conversation: conversation, from: capped, to: sibling, userTurnAt: nil,
              caughtUp: true)
    check("the restored latch keeps one wall worth one line", !spent.isArmed)

    // MARK: A5. Raising an arm leaves a line

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-capresume-carry-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = dir.appendingPathComponent("input.log")
    func logged() -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    let stampNow = wall.addingTimeInterval(4)
    var fresh = CapResumeState()
    func raise(_ state: inout CapResumeState, caughtUp: Bool) {
        armCapResume(&state, pid: "42", log: log, now: stampNow, reason: "cap", fresh: false,
                     cappedAt: wall, answeredAt: nil, conversation: "0123456789abcdef",
                     from: capped, to: sibling, userTurnAt: nil, caughtUp: caughtUp)
    }
    var halfRead = CapResumeState()
    raise(&halfRead, caughtUp: false)
    check("a guard that refuses writes nothing", !halfRead.isArmed && logged().isEmpty)
    raise(&fresh, caughtUp: true)
    let iso = ISO8601DateFormatter()
    check("a raised arm leaves exactly its line",
          logged() == ["\(iso.string(from: stampNow)) pid=42 input=cap-resume-armed "
                       + "conversation=01234567 cappedAt=\(iso.string(from: wall))"])
    raise(&fresh, caughtUp: true)
    check("…and the same wall a second time leaves no second one", logged().count == 1)

    runCapResumeFinanceReplay()
}

// MARK: A4. The 2026-09-26 finance transcript, redacted (regression lock)

/// Lines 426-455 of the session that sat unresumed: the last real answer, three background task
/// notifications, the weekly wall. Every field the watcher does not read is gone, the text is
/// redacted, and the ids are invented; the wall's own sentence is kept because the detector reads
/// it.
private let financeWallLines: [String] = [
        #"{"type":"assistant","timestamp":"2026-09-26T10:27:38.689Z","parentUuid":"00000000-0000-4000-8000-000000000001","uuid":"00000000-0000-4000-8000-000000000002","sessionId":"f1a2b3c4-0000-4000-8000-000000000426","isSidechain":false,"message":{"role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"[redacted]"}]}}"#,
        #"{"type":"last-prompt"}"#,
        #"{"type":"ai-title"}"#,
        #"{"type":"mode"}"#,
        #"{"type":"atis-latch"}"#,
        #"{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-09-26T10:27:40.228Z"}"#,
        #"{"type":"system","subtype":"turn_duration","timestamp":"2026-09-26T10:27:40.231Z"}"#,
        #"{"type":"queue-operation","timestamp":"2026-09-26T10:27:49.118Z"}"#,
        #"{"type":"queue-operation","timestamp":"2026-09-26T10:27:49.121Z"}"#,
        #"{"type":"user","timestamp":"2026-09-26T10:27:49.128Z","parentUuid":"00000000-0000-4000-8000-000000000003","uuid":"00000000-0000-4000-8000-000000000004","sessionId":"f1a2b3c4-0000-4000-8000-000000000426","isSidechain":false,"promptSource":"system","message":{"role":"user","content":"<task-notification>\n<task-id>task-435</task-id>\n<status>failed</status>\n<summary>[redacted]</summary>\n</task-notification>"}}"#,
        #"{"type":"attachment","timestamp":"2026-09-26T10:27:49.211Z"}"#,
        #"{"type":"assistant","timestamp":"2026-09-26T10:27:49.600Z","parentUuid":"00000000-0000-4000-8000-000000000005","uuid":"00000000-0000-4000-8000-000000000006","sessionId":"f1a2b3c4-0000-4000-8000-000000000426","isSidechain":false,"isApiErrorMessage":true,"error":"rate_limit","message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"You've hit your weekly limit · resets 8pm (Asia/Taipei)"}]}}"#,
        #"{"type":"system","subtype":"informational","timestamp":"2026-09-26T10:27:49.602Z"}"#,
        #"{"type":"system","subtype":"turn_duration","timestamp":"2026-09-26T10:27:49.605Z"}"#,
        #"{"type":"cost-state"}"#,
        #"{"type":"last-prompt"}"#,
        #"{"type":"cost-state"}"#,
        #"{"type":"queue-operation","timestamp":"2026-09-26T10:27:50.845Z"}"#,
        #"{"type":"queue-operation","timestamp":"2026-09-26T10:27:50.845Z"}"#,
        #"{"type":"queue-operation","timestamp":"2026-09-26T10:27:50.845Z"}"#,
        #"{"type":"queue-operation","timestamp":"2026-09-26T10:27:55.031Z"}"#,
        #"{"type":"queue-operation","timestamp":"2026-09-26T10:27:55.044Z"}"#,
        #"{"type":"queue-operation","timestamp":"2026-09-26T10:27:55.057Z"}"#,
        #"{"type":"queue-operation","timestamp":"2026-09-26T10:27:55.057Z"}"#,
        #"{"type":"user","timestamp":"2026-09-26T10:27:55.059Z","parentUuid":"00000000-0000-4000-8000-000000000007","uuid":"00000000-0000-4000-8000-000000000008","sessionId":"f1a2b3c4-0000-4000-8000-000000000426","isSidechain":false,"promptSource":"system","message":{"role":"user","content":"<task-notification>\n<task-id>task-450</task-id>\n<status>stopped</status>\n<summary>[redacted]</summary>\n</task-notification>"}}"#,
        #"{"type":"user","timestamp":"2026-09-26T10:27:55.060Z","parentUuid":"00000000-0000-4000-8000-000000000008","uuid":"00000000-0000-4000-8000-000000000009","sessionId":"f1a2b3c4-0000-4000-8000-000000000426","isSidechain":false,"promptSource":"system","message":{"role":"user","content":"<task-notification>\n<task-id>task-451</task-id>\n<status>stopped</status>\n<summary>[redacted]</summary>\n</task-notification>"}}"#,
        #"{"type":"attachment","timestamp":"2026-09-26T10:27:55.278Z"}"#,
        #"{"type":"attachment","timestamp":"2026-09-26T10:27:55.326Z"}"#,
        #"{"type":"attachment","timestamp":"2026-09-26T10:27:55.629Z"}"#,
        #"{"type":"attachment","timestamp":"2026-09-26T10:27:55.630Z"}"#,
]

private func runCapResumeFinanceReplay() {
    let conversation = "f1a2b3c4-0000-4000-8000-000000000426"
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-capresume-finance-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try! (financeWallLines.joined(separator: "\n") + "\n")
        .write(to: dir.appendingPathComponent("\(conversation).jsonl"), atomically: true,
               encoding: .utf8)
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func at(_ text: String) -> Date { iso.date(from: text)! }
    func drained(since: Date) -> TranscriptWatcher {
        var w = TranscriptWatcher(projectDir: dir, since: since, resumeID: conversation)
        for _ in 0..<20 where !w.caughtUp || w.transcriptSessionID == nil { _ = w.sawCapHit() }
        _ = w.sawCapHit()
        return w
    }
    // The child that hit the wall, launched well before it.
    let old = drained(since: at("2026-09-26T10:00:00.000Z"))
    check("finance: the old child read the whole sample", old.caughtUp)
    check("finance: its task notifications are not a person", old.lastUserTurnAt == nil)
    check("finance: the last real answer is the one before the wall",
          old.lastMainChainEventAt == at("2026-09-26T10:27:38.689Z"))
    let cappedAt = at("2026-09-26T10:27:49.600Z")
    func acct(_ id: String, _ label: String) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: label, launchHome: "/tmp/\(id)",
                         sessionRemaining: nil, weeklyRemaining: nil, modelRemaining: nil,
                         sessionResetsAt: nil, weeklyResetsAt: nil, modelResetsAt: nil,
                         modelWindowName: nil, resetCreditsAvailable: nil, isStale: false,
                         error: nil)
    }
    var state = CapResumeState()
    state.arm(reason: "cap", fresh: false, cappedAt: cappedAt,
              answeredAt: old.lastMainChainEventAt, conversation: old.transcriptSessionID,
              from: acct("A", "Claude 0"), to: acct("B", "Claude 5"),
              userTurnAt: old.lastUserTurnAt, caughtUp: old.caughtUp)
    check("finance: the handoff raises an offer", state.isArmed)
    // Across the exec, then the child that relaunch started (10:27:53), which sees the two
    // notifications that landed after it.
    let carried = decodeCapResume(encodeCapResume(state)!)!
    let new = drained(since: at("2026-09-26T10:27:53.000Z"))
    check("finance: the new child's notifications are not a person either",
          new.lastUserTurnAt == nil)
    let decision = carried.decide(state: .idle, quiet: .quiet, turnEnded: true, keyboardIdle: true,
                                  relaunchPlanned: false, dialogPossible: false,
                                  draftSuspected: false, caughtUp: new.caughtUp,
                                  userTurnAt: new.lastUserTurnAt,
                                  conversation: new.transcriptSessionID,
                                  now: at("2026-09-26T10:28:30.000Z"))
    check("finance: the carried offer is typed rather than dropped", decision == state.offer.map {
        CapResumeDecision.type($0.line)
    })
}
