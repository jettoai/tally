import Foundation

// The line that wakes a session whose background work a Tally relaunch killed (RestartWake.swift),
// replayed against the two sessions of 2026-09-27 that slept 59 and 54 minutes after a self-update.
// The fixtures keep every structural field of the real transcript lines; paths and prose that were
// not English are replaced.

private let wakeIso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private func wakeAt(_ s: String) -> Date { wakeIso.date(from: s)! }

private let wakeNote = #"<note>No completion record was found for it in the previous session. It may have been stopped (via the UI, Monitor timeout, or agent teardown \#u{2014} these leave no transcript marker), or it may have been running when the previous Claude Code process exited. Check the output file for partial results before assuming it completed.</note>"#

private let sample1Conversation = "99de728d-ded6-4fa1-8b8f-de6a9b9e96d0"
private let sample1Launch = wakeAt("2026-09-27T09:05:14.000Z")
private let sample1Notice = #"<task-notification>\n<task-id>bzsyqpoyk</task-id>\n<tool-use-id>toolu_01WdvWAVCkwSxJz5NYU22GZG</tool-use-id>\n<status>stopped</status>\n<summary>Background shell command didn't finish before the previous session ended</summary>\n"#
    + wakeNote + #"\n</task-notification>"#
private let sample1: [String] = [
    #"{"parentUuid":"1f60cf64-3ebd-4892-a1d7-035d2c40d3f6","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_011CfTg2bm5VNc6VZHPVzgiE","type":"message","role":"assistant","content":[{"type":"text","text":"Two decisions are waiting on Telegram."}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":375,"cache_read_input_tokens":259450,"output_tokens":155}},"requestId":"req_011CfTg2bHJw6vkbGUzxVMG8","type":"assistant","uuid":"ef53ba32-50cc-4ffa-ba51-02259e012cda","timestamp":"2026-09-27T09:02:42.220Z","userType":"external","entrypoint":"cli","cwd":"/work/project","sessionId":"99de728d-ded6-4fa1-8b8f-de6a9b9e96d0","version":"2.1.283","gitBranch":"main"}"#,
    #"{"parentUuid":"44e6ba48-356c-413e-9bd6-cb6301db200f","isSidechain":false,"type":"system","subtype":"turn_duration","durationMs":18623,"messageCount":300,"timestamp":"2026-09-27T09:02:43.081Z","uuid":"b96f370a-de22-4de7-b54f-fd730fa3f659","isMeta":false,"userType":"external","entrypoint":"cli","cwd":"/work/project","sessionId":"99de728d-ded6-4fa1-8b8f-de6a9b9e96d0","version":"2.1.283","gitBranch":"main"}"#,
    #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-27T09:05:22.048Z","sessionId":"99de728d-ded6-4fa1-8b8f-de6a9b9e96d0","content":""# + sample1Notice + #""}"#,
    #"{"type":"queue-operation","operation":"dequeue","timestamp":"2026-09-27T09:05:22.314Z","sessionId":"99de728d-ded6-4fa1-8b8f-de6a9b9e96d0"}"#,
    #"{"parentUuid":"b96f370a-de22-4de7-b54f-fd730fa3f659","isSidechain":false,"promptId":"b92989bf-8b3e-4773-8d61-333d0dacb776","type":"user","message":{"role":"user","content":""# + sample1Notice + #""},"uuid":"ad459c90-9c94-41cd-abb1-444ec12bb96b","timestamp":"2026-09-27T09:05:22.317Z","permissionMode":"bypassPermissions","origin":{"kind":"task-notification"},"promptSource":"system","queueSkipAttachments":true,"queueTranscriptOnly":true,"userType":"external","entrypoint":"cli","cwd":"/work/project","sessionId":"99de728d-ded6-4fa1-8b8f-de6a9b9e96d0","version":"2.1.283","gitBranch":"main"}"#,
    #"{"parentUuid":"6c276fdf-93cd-4a02-ba7b-2c46063bfd63","isSidechain":false,"attachment":{"type":"hook_success","hookName":"SessionStart:resume","toolUseID":"fe8d4601-ba5f-4eaf-adce-50730c9a2a49","hookEvent":"SessionStart","content":"","stdout":"","stderr":"","exitCode":0},"type":"attachment","uuid":"00686cfd-06f8-4146-b278-57c0bc3c0fcc","timestamp":"2026-09-27T09:05:23.548Z","userType":"external","entrypoint":"cli","cwd":"/work/project","sessionId":"99de728d-ded6-4fa1-8b8f-de6a9b9e96d0","version":"2.1.283","gitBranch":"main"}"#,
    #"{"parentUuid":"00686cfd-06f8-4146-b278-57c0bc3c0fcc","isSidechain":false,"type":"system","subtype":"informational","content":"agents-md: no CLAUDE.md found; AGENTS.md loaded: /work/AGENTS.md","isMeta":false,"timestamp":"2026-09-27T09:05:23.715Z","uuid":"bb86a6b3-c9a3-46f4-9337-1198f9a76a0e","level":"notice","userType":"external","entrypoint":"cli","cwd":"/work/project","sessionId":"99de728d-ded6-4fa1-8b8f-de6a9b9e96d0","version":"2.1.283","gitBranch":"main"}"#,
]

private let sample2Conversation = "87ede923-882e-44be-95f6-277e80c014c2"
private let sample2Launch = wakeAt("2026-09-27T09:10:45.500Z")
private let sample2Notice = #"<task-notification>\n<task-id>bps74l7j4</task-id>\n<task-id>bf7jvkkbk</task-id>\n<task-id>__orphan_summary__:shell</task-id>\n<status>stopped</status>\n<summary>2 background shell command tasks didn't finish before the previous session ended. Task ids: bps74l7j4, bf7jvkkbk.</summary>\n<note>No completion record was found for them in the previous session. They may have been stopped (via the UI, Monitor timeout, or agent teardown \#u{2014} these leave no transcript marker), or they may have been running when the previous Claude Code process exited. They have been marked stopped. Task ids in this notification beginning with \"__orphan_summary\" are internal scan markers, not tasks.</note>\n</task-notification>"#
private let sample2: [String] = [
    #"{"parentUuid":"7f1dd6c3-3768-4439-a4cb-8fa2f48b6658","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_011CfTg7CxmTM4DKPJXWRZLy","type":"message","role":"assistant","content":[{"type":"text","text":"Pushing staging and main in the background."}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":770,"cache_read_input_tokens":271960,"output_tokens":196}},"requestId":"req_011CfTg7CUkSnc9tK5thWGnb","type":"assistant","uuid":"c812c923-b511-4689-8e8b-405389bcb069","timestamp":"2026-09-27T09:03:45.327Z","userType":"external","entrypoint":"cli","cwd":"/work/project","sessionId":"87ede923-882e-44be-95f6-277e80c014c2","version":"2.1.283","gitBranch":"staging"}"#,
    #"{"parentUuid":"5f995006-0b59-444d-af1e-7bd831b4a58a","isSidechain":false,"type":"system","subtype":"away_summary","content":"The fix is committed and being pushed to staging and production in the background.","timestamp":"2026-09-27T09:06:49.188Z","uuid":"3811b5a0-bae6-4487-a3bd-b629221e04df","isMeta":false,"userType":"external","entrypoint":"cli","cwd":"/work/project","sessionId":"87ede923-882e-44be-95f6-277e80c014c2","version":"2.1.283","gitBranch":"staging"}"#,
    #"{"type":"cost-state","sessionId":"87ede923-882e-44be-95f6-277e80c014c2","totalCostUSD":17.8315448,"totalLinesAdded":138,"totalLinesRemoved":0}"#,
    #"{"type":"last-prompt","leafUuid":"3811b5a0-bae6-4487-a3bd-b629221e04df","sessionId":"87ede923-882e-44be-95f6-277e80c014c2"}"#,
    #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-27T09:10:45.223Z","sessionId":"87ede923-882e-44be-95f6-277e80c014c2","content":"<task-notification>\n<task-id>bf7jvkkbk</task-id>\n<tool-use-id>toolu_01VtmpexMVqbEoSdcwZV6daX</tool-use-id>\n<output-file>/tmp/tasks/bf7jvkkbk.output</output-file>\n<status>killed</status>\n<summary>Monitor \"push log stall watch\" stopped</summary>\n</task-notification>"}"#,
    #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-27T09:10:45.232Z","sessionId":"87ede923-882e-44be-95f6-277e80c014c2","content":"<task-notification>\n<task-id>bps74l7j4</task-id>\n<tool-use-id>toolu_01WivzWZEt4F7PVFhyvFcwiX</tool-use-id>\n<output-file>/tmp/tasks/bps74l7j4.output</output-file>\n<status>killed</status>\n<summary>Background command \"Push staging then merge into main and push\" was stopped</summary>\n</task-notification>"}"#,
    #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-27T09:10:47.419Z","sessionId":"87ede923-882e-44be-95f6-277e80c014c2","content":""# + sample2Notice + #""}"#,
    #"{"type":"queue-operation","operation":"dequeue","timestamp":"2026-09-27T09:10:47.458Z","sessionId":"87ede923-882e-44be-95f6-277e80c014c2"}"#,
    #"{"parentUuid":"3811b5a0-bae6-4487-a3bd-b629221e04df","isSidechain":false,"promptId":"62d5f45e-c4e5-4226-81cf-1b63e84a3ce7","type":"user","message":{"role":"user","content":""# + sample2Notice + #""},"uuid":"80bb862c-4db0-44da-b4bb-67587160cdd7","timestamp":"2026-09-27T09:10:47.461Z","permissionMode":"bypassPermissions","origin":{"kind":"task-notification"},"promptSource":"system","queueSkipAttachments":true,"queueTranscriptOnly":true,"userType":"external","entrypoint":"cli","cwd":"/work/project","sessionId":"87ede923-882e-44be-95f6-277e80c014c2","version":"2.1.283","gitBranch":"staging"}"#,
    #"{"parentUuid":"80bb862c-4db0-44da-b4bb-67587160cdd7","isSidechain":false,"attachment":{"type":"hook_success","hookName":"SessionStart:resume","toolUseID":"a1f0c2de-0000-4000-8000-000000000001","hookEvent":"SessionStart","content":"","stdout":"","stderr":"","exitCode":0},"type":"attachment","uuid":"a1f0c2de-0000-4000-8000-000000000002","timestamp":"2026-09-27T09:10:48.900Z","userType":"external","entrypoint":"cli","cwd":"/work/project","sessionId":"87ede923-882e-44be-95f6-277e80c014c2","version":"2.1.283","gitBranch":"staging"}"#,
]

/// The session's own answer after the notice: it is awake.
private let sample1Answer = #"{"parentUuid":"ad459c90-9c94-41cd-abb1-444ec12bb96b","isSidechain":false,"message":{"model":"claude-opus-5-5","role":"assistant","content":[{"type":"text","text":"Checking the stopped task."}],"stop_reason":"end_turn"},"type":"assistant","uuid":"b0a1c2d3-0000-4000-8000-00000000a001","timestamp":"2026-09-27T09:05:30.000Z","cwd":"/work/project","sessionId":"99de728d-ded6-4fa1-8b8f-de6a9b9e96d0"}"#

private func wakeReplay(_ lines: [String], conversation: String, since: Date) -> TranscriptWatcher {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-restartwake-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! (lines.joined(separator: "\n") + "\n")
        .write(to: dir.appendingPathComponent("\(conversation).jsonl"), atomically: true, encoding: .utf8)
    var w = TranscriptWatcher(projectDir: dir, since: since, resumeID: conversation)
    for _ in 0..<20 where !w.caughtUp { _ = w.sawCapHit() }
    try? FileManager.default.removeItem(at: dir)
    return w
}

private func wakeOffer(_ w: TranscriptWatcher, launch: Date, state: RestartWakeState = RestartWakeState(),
                       spawnedByTally: Bool = true, resumes: Bool = true, note: RestartNote? = nil,
                       capOwns: Bool = false,
                       after seconds: TimeInterval = 40) -> CapResumeState.Offer? {
    restartWakeOffer(state: state, spawnedByTally: spawnedByTally, resumesConversation: resumes,
                     note: note, launchedAt: launch, notice: w.lastStoppedTasks,
                     answeredAt: w.lastMainChainEventAt, userTurnAt: w.lastUserTurnAt,
                     conversation: w.transcriptSessionID, caughtUp: w.caughtUp,
                     capOwnsChild: capOwns, now: launch.addingTimeInterval(seconds))
}

func runRestartWakeChecks() {
    let line1 = "[tally] Tally restarted Claude Code (self-update) and 1 background task(s) were stopped. Check which ones stopped and restart or resume them."
    let line2 = "[tally] Tally restarted Claude Code (self-update) and 2 background task(s) were stopped. Check which ones stopped and restart or resume them."

    // R1, R2: the notice as the resumed Claude Code wrote it.
    let w1 = wakeReplay(sample1, conversation: sample1Conversation, since: sample1Launch)
    check("R1 sample 1: the stopped notice is read with its one task id",
          w1.caughtUp && w1.lastStoppedTasks?.ids == ["bzsyqpoyk"]
              && w1.lastStoppedTasks?.uuid == "ad459c90-9c94-41cd-abb1-444ec12bb96b")
    check("R1 …and it is neither a person's turn nor an answer (the pre-launch reply is ignored)",
          w1.lastUserTurnAt == nil && w1.lastMainChainEventAt == nil)
    let w2 = wakeReplay(sample2, conversation: sample2Conversation, since: sample2Launch)
    check("R2 sample 2: two real ids, the orphan marker and the queued killed lines left out",
          w2.lastStoppedTasks?.ids == ["bps74l7j4", "bf7jvkkbk"]
              && w2.lastStoppedTasks?.uuid == "80bb862c-4db0-44da-b4bb-67587160cdd7")

    // R3: the line, word for word, off an exec from a build that carried no note.
    check("R3 sample 1 owes the one-task line", wakeOffer(w1, launch: sample1Launch)?.line == line1)
    check("R3 sample 2 owes the two-task line", wakeOffer(w2, launch: sample2Launch)?.line == line2)

    // R4, R5: the station types it once.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-restartwake-log-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    var typed: [String] = []
    func station(_ state: inout RestartWakeState, _ w: TranscriptWatcher, launch: Date,
                 candidate: CapResumeState.Offer?, log: URL, typedAlready: Bool = false,
                 waitingOnPerson: Bool = false, userTurnAt: Date?? = .none,
                 after seconds: TimeInterval = 40) -> String? {
        applyRestartWake(&state, pid: "rw-test", candidate: candidate,
                         source: w.lastStoppedTasks == nil ? "roster" : "notice", launchedAt: launch,
                         noticeUUID: w.lastStoppedTasks?.uuid, answeredAt: w.lastMainChainEventAt,
                         typedAlready: typedAlready, session: .idle, quiet: .quiet,
                         turnEnded: { true }, keyboardIdle: true, relaunchPlanned: false,
                         draftSuspected: false, waitingOnPerson: waitingOnPerson,
                         caughtUp: w.caughtUp, userTurnAt: userTurnAt ?? w.lastUserTurnAt,
                         conversation: w.transcriptSessionID,
                         now: launch.addingTimeInterval(seconds), log: log,
                         stamped: { launch.addingTimeInterval(seconds + 5) },
                         inject: { text, _ in typed.append(text); return .done })
    }
    func audit(_ log: URL) -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
    func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: "\n").filter { $0.contains(needle) }.count
    }

    let log4 = dir.appendingPathComponent("r4.log")
    var s4 = RestartWakeState()
    let typed4 = station(&s4, w1, launch: sample1Launch, candidate: wakeOffer(w1, launch: sample1Launch, state: s4),
                         log: log4)
    check("R4 all gates open: the line is typed once", typed4 == line1 && typed == [line1])
    check("R4 …the arm and the typing are both on the record",
          audit(log4).contains("input=restart-wake-armed source=notice conversation=99de728d")
              && count("input=restart-wake ", in: audit(log4)) == 1)
    let again = wakeOffer(w1, launch: sample1Launch, state: s4, after: 42)
    _ = station(&s4, w1, launch: sample1Launch, candidate: again, log: log4, after: 42)
    check("R5 the next tick raises nothing and types nothing",
          again == nil && typed.count == 1 && count("input=restart-wake ", in: audit(log4)) == 1)

    // R6: a session that answered on its own.
    let w6 = wakeReplay(sample1 + [sample1Answer], conversation: sample1Conversation, since: sample1Launch)
    check("R6 an answer after the notice: no offer", wakeOffer(w6, launch: sample1Launch) == nil)
    let log6 = dir.appendingPathComponent("r6.log")
    var s6 = RestartWakeState()
    typed = []
    _ = station(&s6, w1, launch: sample1Launch, candidate: wakeOffer(w1, launch: sample1Launch),
                log: log6, typedAlready: true)
    let armed6 = s6.isArmed
    _ = station(&s6, w6, launch: sample1Launch, candidate: wakeOffer(w6, launch: sample1Launch, state: s6),
                log: log6, after: 42)
    check("R6 armed first, answered next tick: dropped as answered, nothing typed",
          armed6 && !s6.isArmed && typed.isEmpty
              && audit(log6).contains("input=restart-wake-dropped reason=answered"))

    // R7, R8: not Tally's restart, or nothing resumed.
    check("R7 a first spawn (a person's own --resume) is not armed",
          wakeOffer(w1, launch: sample1Launch, spawnedByTally: false) == nil)
    check("R8 a fresh child is not armed", wakeOffer(w1, launch: sample1Launch, resumes: false) == nil)
    let busy = SessionAgentsRecord(live: ["a"], trusted: true, updatedAt: Date(), background: 2)
    check("R8 a fresh handoff leaves no note",
          restartNoteForHandoff(reason: "clear-boundary", fresh: true, roster: busy) == nil
              && restartNoteForHandoff(reason: "reload", fresh: false, roster: busy)
                  == RestartNote(reason: "reload", background: 3))

    // R9: the roster alone, after the settle.
    let reload = RestartNote(reason: "reload", background: 2)
    let quiet = wakeReplay([sample1[0], sample1[1]], conversation: sample1Conversation, since: sample1Launch)
    check("R9 roster only, before the settle: nothing yet",
          wakeOffer(quiet, launch: sample1Launch, note: reload, after: 5) == nil)
    let roster9 = wakeOffer(quiet, launch: sample1Launch, note: reload, after: 16)
    check("R9 …after it, the roster's count and the handoff's reason",
          roster9?.line == "[tally] Tally restarted Claude Code (reload) and 2 background task(s) were stopped. Check which ones stopped and restart or resume them.")
    let log9 = dir.appendingPathComponent("r9.log")
    var s9 = RestartWakeState()
    _ = station(&s9, quiet, launch: sample1Launch, candidate: roster9, log: log9, typedAlready: true,
                after: 16)
    check("R9 …recorded as a roster arm", audit(log9).contains("input=restart-wake-armed source=roster"))
    check("R9 a roster of zero raises nothing",
          wakeOffer(quiet, launch: sample1Launch, note: RestartNote(reason: "reload", background: 0),
                    after: 16) == nil)
    check("R9 notice and roster together: the larger count",
          wakeOffer(w1, launch: sample1Launch, note: RestartNote(reason: "reload", background: 3))?.line
              .contains("and 3 background task(s)") == true)

    // R10: the shared door's holds and drops.
    let log10 = dir.appendingPathComponent("r10.log")
    var s10 = RestartWakeState()
    typed = []
    _ = station(&s10, w1, launch: sample1Launch, candidate: wakeOffer(w1, launch: sample1Launch),
                log: log10, waitingOnPerson: true)
    check("R10 a dialog holds the line and keeps the offer", s10.isArmed && typed.isEmpty)
    _ = station(&s10, w1, launch: sample1Launch, candidate: nil, log: log10,
                userTurnAt: .some(sample1Launch.addingTimeInterval(30)), after: 42)
    check("R10 a person's own turn drops it",
          !s10.isArmed && typed.isEmpty
              && audit(log10).contains("input=restart-wake-dropped reason=user-turn"))

    // R11: a child the cap resume owns.
    check("R11 the cap resume's child is left to it", wakeOffer(w1, launch: sample1Launch, capOwns: true) == nil)

    // R12: the roster count and the hold's record.
    check("R12 roster count: subagents plus background, zero when unbelievable or absent",
          rosterBackgroundCount(busy) == 3
              && rosterBackgroundCount(SessionAgentsRecord(live: ["a"], trusted: false,
                                                           updatedAt: Date(), background: 2)) == 0
              && rosterBackgroundCount(nil) == 0)
    let t = wakeAt("2026-09-27T08:00:00.000Z")
    let hold = selfUpdateHoldLine(pid: "42", event: "expired", background: 3, heldSince: t,
                                  roster: "ok", rosterAt: wakeAt("2026-09-27T08:59:58.000Z"),
                                  now: wakeAt("2026-09-27T09:00:00.000Z"))
    check("R12 the hold line reads as its grep expects",
          hold == "2026-09-27T09:00:00Z pid=42 self-update-hold=expired background=3 heldSince=2026-09-27T08:00:00Z roster=ok rosterAt=2026-09-27T08:59:58Z\n")
    let released = selfUpdateHoldLine(pid: "42", event: "released", background: 0, heldSince: nil,
                                      roster: "none", rosterAt: nil,
                                      now: wakeAt("2026-09-27T09:00:00.000Z"))
    check("R12 a release with no roster file says so",
          released == "2026-09-27T09:00:00Z pid=42 self-update-hold=released background=0 heldSince=none roster=none rosterAt=none\n")
    check("R12 roster state tells the gate's four readings apart",
          selfUpdateRosterState(nil, childStartedAt: t) == "none"
              && selfUpdateRosterState(SessionAgentsRecord(live: [], trusted: false, updatedAt: t,
                                                           background: 1), childStartedAt: t) == "untrusted"
              && selfUpdateRosterState(SessionAgentsRecord(live: [], trusted: true,
                                                           updatedAt: t.addingTimeInterval(-1),
                                                           background: 1), childStartedAt: t) == "stale"
              && selfUpdateRosterState(SessionAgentsRecord(live: [], trusted: true, updatedAt: t,
                                                           background: 1), childStartedAt: t) == "ok")
}
