import Foundation

// The pure contract this feature stands on: `TallyCLI/SessionWaitEvent.swift` (the wire shape,
// the id/idempotency hashes) and `TallyCLI/SessionWaitLogic.swift` (what a tick believes is
// standing, what changed since the last one, how a resolved request is explained), plus the spool
// (`TallyCLI/SessionWaitSpool.swift`) that turns a decided event into a line on disk. Nothing here
// drives a real `syncSessionState` tick or a real supervisor: that wiring is a later package
// (plan §6.8/§6.11), and the regression floor for the board state it must never disturb is
// `tests/run-supervisor-tests.sh`, asserted separately.
//
// T3 IS A NARROWED VERSION OF WHAT THE PLAN ASKS FOR. The literal ask is to call
// `supervisedSessionState` (SessionStateSync.swift:44) and show both a hard and a quiet-soft wait
// reach `.blocked` on the board before showing `openWaitRequest` still tells them apart. Pulling
// that function in means pulling in its whole file, which pulls in `PickProject`
// (Tally/Core/PickContract.swift), `TranscriptWatcher.swift` (434 lines, its own transcript-parsing
// dependency chain) and `SessionQuiet.swift` for a single four-line pure function this suite does
// not otherwise need. The plan's own escape hatch (§ "P2 要做的事" item 4) allows falling back to a
// judgement expressed through `SessionState.swift`'s functions instead, cited rather than executed,
// and that is what T3 does below.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let now = Date(timeIntervalSince1970: 1_800_000_000)

let identity = SessionWaitIdentity(key: "claude:41287:1758575401", supervisorPid: 41287,
                                   supervisorStartedAt: 1_758_575_401, childPid: 41301,
                                   transcriptSessionId: "0f2c-uuid", launchNonce: nil,
                                   account: "personal", directory: "/Users/albertliu/workspace/tally",
                                   project: "tally", worktree: nil)

// MARK: - T1: permission_prompt is confirmed permission

let t1Notice = UserNotice(message: "Claude needs your permission to use Bash", at: now,
                          type: "permission_prompt", sessionID: nil)
let t1 = openWaitRequest(provider: "claude", sessionKey: identity.key, notice: t1Notice, waiting: true,
                         question: nil, questionSince: nil, quiet: false,
                         wait: userWait(notificationType: "permission_prompt"), permissionTool: "Bash")
expect(t1?.kind == SessionWaitKind.permission.rawValue, "T1: permission_prompt opens kind=permission")
expect(t1?.confidence == SessionWaitConfidence.confirmed.rawValue,
       "T1: permission_prompt opens confidence=confirmed")

// MARK: - T2: idle_prompt while quiet is suspected

let t2Notice = UserNotice(message: "", at: now, type: "idle_prompt", sessionID: nil)
let t2 = openWaitRequest(provider: "claude", sessionKey: identity.key, notice: t2Notice, waiting: true,
                         question: nil, questionSince: nil, quiet: true,
                         wait: userWait(notificationType: "idle_prompt"), permissionTool: nil)
expect(t2?.kind == SessionWaitKind.unknown.rawValue, "T2: idle_prompt (quiet) opens kind=unknown")
expect(t2?.confidence == SessionWaitConfidence.suspected.rawValue,
       "T2: idle_prompt (quiet) opens confidence=suspected, never confirmed")

// MARK: - T3 (mutation target): same board state, hard vs soft, different confidence

let t3PermissionNotice = UserNotice(message: "Claude needs your permission to use Bash", at: now,
                                    type: "permission_prompt", sessionID: nil)
let t3IdleNotice = UserNotice(message: "", at: now, type: "idle_prompt", sessionID: nil)
let t3Permission = openWaitRequest(provider: "claude", sessionKey: identity.key,
                                   notice: t3PermissionNotice, waiting: true, question: nil,
                                   questionSince: nil, quiet: true,
                                   wait: userWait(notificationType: "permission_prompt"),
                                   permissionTool: nil)
let t3Idle = openWaitRequest(provider: "claude", sessionKey: identity.key, notice: t3IdleNotice,
                             waiting: true, question: nil, questionSince: nil, quiet: true,
                             wait: userWait(notificationType: "idle_prompt"), permissionTool: nil)
// The board-state premise, cited rather than exercised (see header): `supervisedSessionState`
// reads `wait == .hard` as `.blocked` unconditionally and `wait == .soft && quiet` as `.blocked`
// too (SessionStateSync.swift:44-52). Both notices below are quiet == true, and these two reads
// are exactly the `.hard`/`.soft` split that function's own doc comment names as its two paths to
// the same word.
expect(userWait(notificationType: "permission_prompt") == .hard,
       "T3: permission_prompt is a hard wait (blocks the board unconditionally)")
expect(userWait(notificationType: "idle_prompt") == .soft,
       "T3: idle_prompt is a soft wait (blocks the board only while quiet, same as here)")
expect(t3Permission?.confidence == SessionWaitConfidence.confirmed.rawValue,
       "T3: the hard-wait request is confirmed")
expect(t3Idle?.confidence == SessionWaitConfidence.suspected.rawValue,
       "T3: the soft-wait request is suspected")
expect(t3Permission?.confidence != t3Idle?.confidence,
       "T3: same .blocked board state, different confidence between the two")

// MARK: - T4: idle_prompt while NOT quiet (fan-out background) opens nothing

let t4Notice = UserNotice(message: "", at: now, type: "idle_prompt", sessionID: nil)
let t4 = openWaitRequest(provider: "claude", sessionKey: identity.key, notice: t4Notice, waiting: true,
                         question: nil, questionSince: nil, quiet: false,
                         wait: userWait(notificationType: "idle_prompt"), permissionTool: nil)
expect(t4 == nil, "T4: idle_prompt while a subagent is still writing opens no wait")

// MARK: - T5: sessionWaitRequestID is stable for the same input, and a 1ms `since` delta changes it

let t5SinceA = Date(timeIntervalSince1970: 1_800_000_000.100)
let t5SinceB = t5SinceA.addingTimeInterval(0.001)
let t5IdA1 = sessionWaitRequestID(sessionKey: identity.key, kind: "permission",
                                  noticeType: "permission_prompt", since: t5SinceA)
let t5IdA2 = sessionWaitRequestID(sessionKey: identity.key, kind: "permission",
                                  noticeType: "permission_prompt", since: t5SinceA)
let t5IdB = sessionWaitRequestID(sessionKey: identity.key, kind: "permission",
                                 noticeType: "permission_prompt", since: t5SinceB)
expect(t5IdA1 == t5IdA2, "T5: the same input always produces the same request id")
expect(t5IdA1 != t5IdB, "T5: a 1ms difference in `since` produces a different request id")

// MARK: - T6: reconciling identical previous/current produces nothing

let t6Request = SessionWaitRequest(id: "abc123", kind: "permission", confidence: "confirmed",
                                   since: now, noticeType: "permission_prompt", tool: "Bash",
                                   summary: "Claude needs your permission to use Bash")
let t6 = reconcileWaitRequests(previous: t6Request, current: t6Request, resolution: nil,
                               identity: identity, provider: "claude", now: now)
expect(t6.isEmpty, "T6: identical previous and current reconcile to no events (the no-flood guarantee)")

// MARK: - T7: a confidence upgrade on the same request id is exactly one wait.updated

var t7Suspected = t6Request
t7Suspected.confidence = SessionWaitConfidence.suspected.rawValue
let t7 = reconcileWaitRequests(previous: t7Suspected, current: t6Request, resolution: nil,
                               identity: identity, provider: "claude", now: now)
expect(t7.count == 1, "T7: a confidence upgrade produces exactly one event")
expect(t7.first?.kind == SessionWaitEventKind.updated.rawValue,
       "T7: a confidence upgrade is wait.updated, not a second wait.opened")

// MARK: - T8 (mutation target): the same notification type reopening with a different `since` is
// two independent requests

let t8SinceX = now
let t8SinceY = now.addingTimeInterval(120)
let t8ReqX = openWaitRequest(provider: "claude", sessionKey: identity.key,
                             notice: UserNotice(message: "", at: t8SinceX, type: "idle_prompt",
                                                sessionID: nil),
                             waiting: true, question: nil, questionSince: nil, quiet: true,
                             wait: .soft, permissionTool: nil)
let t8ReqY = openWaitRequest(provider: "claude", sessionKey: identity.key,
                             notice: UserNotice(message: "", at: t8SinceY, type: "idle_prompt",
                                                sessionID: nil),
                             waiting: true, question: nil, questionSince: nil, quiet: true,
                             wait: .soft, permissionTool: nil)
expect(t8ReqX?.id != t8ReqY?.id, "T8: a different `since` yields a different request id")
let t8Open1 = reconcileWaitRequests(previous: nil, current: t8ReqX, resolution: nil, identity: identity,
                                    provider: "claude", now: t8SinceX)
let t8Resolve1 = reconcileWaitRequests(previous: t8ReqX, current: nil, resolution: .unknown,
                                       identity: identity, provider: "claude",
                                       now: t8SinceX.addingTimeInterval(60))
let t8Open2 = reconcileWaitRequests(previous: nil, current: t8ReqY, resolution: nil, identity: identity,
                                    provider: "claude", now: t8SinceY)
expect(t8Open1.count == 1 && t8Open1.first?.kind == SessionWaitEventKind.opened.rawValue,
       "T8: the first idle_prompt opens")
expect(t8Resolve1.count == 1 && t8Resolve1.first?.kind == SessionWaitEventKind.resolved.rawValue,
       "T8: the first idle_prompt resolves before the second one arrives")
expect(t8Open2.count == 1 && t8Open2.first?.kind == SessionWaitEventKind.opened.rawValue,
       "T8: the second idle_prompt (different since) opens as its own request")
expect(t8Open1.first?.idempotencyKey != t8Open2.first?.idempotencyKey,
       "T8: the two independent opens carry different idempotency keys")

// MARK: - T9 (mutation target): a stale seed after a restart resolves session-ended, never updated

let t9Stale = SessionWaitRequest(id: "stale-request-id", kind: "permission", confidence: "suspected",
                                 since: now.addingTimeInterval(-600), noticeType: "permission_prompt",
                                 tool: nil, summary: "stale, from before the restart")
let t9 = reconcileWaitRequests(previous: t9Stale, current: nil, resolution: .sessionEnded,
                               identity: identity, provider: "claude", now: now)
expect(t9.count == 1, "T9: a session-key mismatch after restart produces exactly one event")
expect(t9.first?.kind == SessionWaitEventKind.resolved.rawValue,
       "T9: ...and it is wait.resolved, never a wait.updated on the stale request")
expect(t9.first?.resolution == SessionWaitResolution.sessionEnded.rawValue,
       "T9: ...with resolution session-ended")
expect(!t9.contains { $0.kind == SessionWaitEventKind.updated.rawValue },
       "T9: no wait.updated is ever produced for a stale seed")

// MARK: - T10: spool append/read round trip, seq strictly increasing

let t10Dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("tally-waitevents-t10-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: t10Dir, withIntermediateDirectories: true)
let t10Base = SessionWaitEvent(at: now, kind: SessionWaitEventKind.opened.rawValue, provider: "claude",
                               session: identity, request: t6Request, resolution: nil)
appendSessionWaitEvent(t10Base, dir: t10Dir)
appendSessionWaitEvent(t10Base, dir: t10Dir)
appendSessionWaitEvent(t10Base, dir: t10Dir)
let t10Since1 = readSessionWaitEvents(since: 1, dir: t10Dir)
expect(t10Since1.count == 2, "T10: since:1 returns the two events written after seq 1")
let t10Seqs = t10Since1.map { $0.seq }
expect(t10Seqs == t10Seqs.sorted(), "T10: returned events are in strictly increasing seq order")
expect(Set(t10Seqs).count == t10Seqs.count, "T10: every seq value is distinct")
try? FileManager.default.removeItem(at: t10Dir)

// MARK: - T11: HMAC signature matches a fixed vector

// Vector computed once with Python's own `hmac` module (plan §12 T11), not re-derived here:
//   python3 -c "
//   import hmac, hashlib
//   secret = 'example-secret'
//   ts = '1758575401'
//   body = '{\"kind\":\"wait.opened\",\"seq\":1}'
//   print(hmac.new(secret.encode(), (ts + '.' + body).encode(), hashlib.sha256).hexdigest())
//   "
// -> ebf647d745691fc8899edecf27f99406c25e69391e86fc97a1d2024ea1e8c217
let t11Secret = "example-secret"
let t11Timestamp = "1758575401"
let t11Body = "{\"kind\":\"wait.opened\",\"seq\":1}"
let t11Expected = "ebf647d745691fc8899edecf27f99406c25e69391e86fc97a1d2024ea1e8c217"
let t11Signature = hmacSignatureHex(secret: t11Secret, timestamp: t11Timestamp, body: t11Body)
expect(t11Signature == t11Expected, "T11: HMAC-SHA256 of \"<ts>.<body>\" matches the fixed vector")

// MARK: - T12 (mutation target): exhausted retries dead-letter the event, cursor advances anyway

let t12Dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("tally-waitevents-t12-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: t12Dir, withIntermediateDirectories: true)
_ = writeEventSinkConfig(EventSinkConfig(url: "http://127.0.0.1:1/sink", secret: "t12-secret",
                                         createdAt: now), dir: t12Dir)
let t12Event = SessionWaitEvent(at: now, kind: SessionWaitEventKind.opened.rawValue, provider: "claude",
                                session: identity, request: t6Request, resolution: nil)
appendSessionWaitEvent(t12Event, dir: t12Dir)

var t12Attempts = 0
let t12AlwaysFail: EventSender = { _, _, _ in
    t12Attempts += 1
    return (status: 500, error: nil)
}
// No real sleeping: the backoff schedule is 0+2+8+30+120 = 160s of wall clock a unit test may never
// spend (work order's own instruction). The sleeper is exercised for its CALL COUNT, not its delay.
var t12SleepCalls = 0
let t12NoSleep: (TimeInterval) -> Void = { _ in t12SleepCalls += 1 }

let t12ExitCode = deliverPendingEvents(replayDeadLetter: false, dir: t12Dir, sender: t12AlwaysFail,
                                       sleeper: t12NoSleep)
expect(t12ExitCode == 0, "T12: deliverPendingEvents returns 0 even when every attempt fails")
expect(t12Attempts == 5, "T12: a permanently-500ing sink is retried exactly 5 times")
expect(t12SleepCalls == 4, "T12: 4 backoff sleeps between 5 attempts (none before the first)")
let t12DeadLetters = readDeadLetterEntries(dir: t12Dir)
expect(t12DeadLetters.count == 1, "T12: the exhausted event lands in dead-letter exactly once")
expect(t12DeadLetters.first?.attempts == 5, "T12: the dead-letter entry records all 5 attempts")
expect(t12DeadLetters.first?.event.idempotencyKey == t12Event.idempotencyKey,
       "T12: the dead-lettered event is the same event, not a copy missing its identity")
// THE MUTATION TARGET: cursor must equal the event's own seq (it advanced) even though delivery
// never succeeded - a dead-lettered event must never leave the cursor stuck behind it (§5.5).
expect(readEventDeliveryCursor(dir: t12Dir) == t12DeadLetters.first?.event.seq,
       "T12: cursor advances past a dead-lettered event, never stalls on it")
try? FileManager.default.removeItem(at: t12Dir)

// MARK: - T13: `sink show` never prints the secret's literal value

let t13Dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("tally-waitevents-t13-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: t13Dir, withIntermediateDirectories: true)
let t13Secret = "correct-horse-battery-staple-example"
_ = writeEventSinkConfig(EventSinkConfig(url: "https://example.invalid/hook", secret: t13Secret,
                                         createdAt: now), dir: t13Dir)
let t13Lines = eventsSinkShowLines(dir: t13Dir)
let t13Joined = t13Lines.joined(separator: "\n")
expect(!t13Joined.contains(t13Secret), "T13: sink show output never contains the secret's literal value")
expect(t13Joined.contains("secret: set"), "T13: sink show reports secret presence without the value")
expect(t13Joined.contains("example.invalid"), "T13: sink show still reports the url (that part is not a secret)")
let t13UnsetLines = eventsSinkShowLines(dir: FileManager.default.temporaryDirectory
    .appendingPathComponent("tally-waitevents-t13-unset-\(UUID().uuidString)"))
expect(t13UnsetLines.joined(separator: "\n").contains("secret: unset"),
       "T13: an unconfigured sink reports secret: unset, not an error")
try? FileManager.default.removeItem(at: t13Dir)

// MARK: - Verdict

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("all assertions passed")
