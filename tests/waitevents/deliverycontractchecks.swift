import Foundation

// The webhook delivery contract, face by face: authentication (R1-R2), bounded retry (R3-R5),
// deduplication (R6-R8), recovery (R9-R11) and not blocking the supervisor (R12-R14). Every pass
// here passes `handoff: {}` so reaching a pass bound can never spawn this test binary as
// `events --deliver-once`. `expect`, `now`, `identity` and `t6Request` are top-level in `main.swift`.
func runDeliveryContractChecks() {
    func freshDir(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-waitevents-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func receiverLog(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-waitevents-\(name)-receiver-\(UUID().uuidString).log")
    }
    func configureSink(_ dir: URL, url: String = "https://example.invalid/hook", secret: String = "s") {
        _ = writeEventSinkConfig(EventSinkConfig(url: url, secret: secret, createdAt: now), dir: dir)
    }
    func decoded(_ body: Data) -> SessionWaitEvent? {
        try? sessionWaitEventDecoder().decode(SessionWaitEvent.self, from: body)
    }
    func make(_ kind: SessionWaitEventKind, _ request: SessionWaitRequest? = t6Request,
              _ resolution: SessionWaitResolution? = nil) -> SessionWaitEvent {
        makeSessionWaitEvent(kind, request: kind == .ended ? nil : request, resolution: resolution,
                             identity: identity, provider: "claude", now: now)
    }
    /// One pass with an injected sender that answers call n with `statuses[n]` (the last one
    /// repeating) and `error` whenever that status is 0; returns what it was sent and slept.
    func scriptedPass(_ dir: URL, _ statuses: [Int], error: String? = nil, replay: Bool = false)
        -> (sent: [(headers: [String: String], body: Data)], sleeps: [TimeInterval]) {
        var sent: [(headers: [String: String], body: Data)] = []
        var sleeps: [TimeInterval] = []
        _ = deliverPendingEvents(replayDeadLetter: replay, dir: dir,
                                 sender: { _, body, headers in
                                     sent.append((headers, body))
                                     let status = statuses[min(sent.count - 1, statuses.count - 1)]
                                     return (status: status, error: status == 0 ? error : nil)
                                 },
                                 sleeper: { sleeps.append($0) }, handoff: {})
        return (sent, sleeps)
    }

    let opened = make(.opened)
    let resolved = make(.resolved, t6Request, .answered)

    // R1: a 4xx other than 408/429 is permanent: one send, no sleep, dead-letter at attempts 1.
    let r1Dir = freshDir("r1")
    let r1Receiver = LoopbackReceiver(logFile: receiverLog("r1"), status: { _ in 401 })
    configureSink(r1Dir, url: r1Receiver.url)
    appendSessionWaitEvent(opened, dir: r1Dir)
    var r1Sleeps = 0
    _ = deliverPendingEvents(replayDeadLetter: false, dir: r1Dir, sleeper: { _ in r1Sleeps += 1 }, handoff: {})
    let r1Dead = readDeadLetterEntries(dir: r1Dir)
    expect(r1Receiver.received.count == 1 && r1Sleeps == 0,
           "R1: a sink answering 401 over real HTTP is sent to once and never retried "
           + "(\(r1Receiver.received.count) sends, \(r1Sleeps) sleeps)")
    expect(r1Dead.count == 1 && r1Dead.first?.attempts == 1 && r1Dead.first?.lastError == "http 401",
           "R1: ...and the event is dead-lettered with attempts 1, lastError \"http 401\"")
    expect(r1Dead.count == 1 && readEventDeliveryCursor(dir: r1Dir) == r1Dead.first?.event.seq,
           "R1: ...and the cursor moves past it")
    try? FileManager.default.removeItem(at: r1Dir)
    for status in [400, 403, 404] {
        let dir = freshDir("r1-\(status)")
        configureSink(dir)
        appendSessionWaitEvent(opened, dir: dir)
        let pass = scriptedPass(dir, [status])
        let dead = readDeadLetterEntries(dir: dir)
        expect(pass.sent.count == 1 && pass.sleeps.isEmpty && dead.count == 1 && dead.first?.attempts == 1
               && dead.first?.lastError == "http \(status)",
               "R1: \(status) is permanent too: one send, no sleep, dead-letter attempts 1")
        try? FileManager.default.removeItem(at: dir)
    }

    // R2: the signature on the wire verifies against the bytes on the wire, and nothing else does.
    let r2Dir = freshDir("r2")
    let r2Secret = "r2-secret"
    let r2Receiver = LoopbackReceiver(logFile: receiverLog("r2"))
    configureSink(r2Dir, url: r2Receiver.url, secret: r2Secret)
    appendSessionWaitEvent(opened, dir: r2Dir)
    _ = deliverPendingEvents(replayDeadLetter: false, dir: r2Dir, sleeper: { _ in }, handoff: {})
    let r2Request = r2Receiver.requests.first
    let r2Headers = r2Request?.headers ?? [:]
    let r2Timestamp = r2Headers["x-tally-timestamp"] ?? ""
    let r2Signature = r2Headers["x-tally-signature"] ?? ""
    let r2Body = String(decoding: r2Request?.body ?? Data(), as: UTF8.self)
    func r2Signed(_ secret: String, _ timestamp: String, _ body: String) -> String {
        "sha256=" + hmacSignatureHex(secret: secret, timestamp: timestamp, body: body)
    }
    expect(r2Receiver.requests.count == 1 && !r2Signature.isEmpty && !r2Body.isEmpty
           && r2Signature == r2Signed(r2Secret, r2Timestamp, r2Body),
           "R2: the X-Tally-Signature on the wire verifies against the wire's timestamp and body")
    var r2Flipped = Array(r2Request?.body ?? Data())
    if !r2Flipped.isEmpty { r2Flipped[r2Flipped.count / 2] ^= 0x01 }
    expect(r2Signature != r2Signed("wrong-secret", r2Timestamp, r2Body),
           "R2: the same bytes signed with a wrong secret do not verify")
    expect(r2Signature != r2Signed(r2Secret, r2Timestamp, String(decoding: r2Flipped, as: UTF8.self)),
           "R2: a body with one byte flipped does not verify")
    expect(r2Signature != r2Signed(r2Secret, "", r2Body),
           "R2: a missing timestamp header (read as empty) does not verify")
    expect(abs((Int(r2Timestamp) ?? 0) - Int(Date().timeIntervalSince1970)) <= 2,
           "R2: the timestamp is the current second (\(r2Timestamp))")
    expect(!r2Body.isEmpty && r2Headers["x-tally-idempotency-key"] == decoded(Data(r2Body.utf8))?.idempotencyKey,
           "R6: on the wire, the X-Tally-Idempotency-Key header equals the body's idempotencyKey")
    try? FileManager.default.removeItem(at: r2Dir)

    let r2bDir = freshDir("r2b")
    configureSink(r2bDir)
    appendSessionWaitEvent(opened, dir: r2bDir)
    var r2bStamps: [Int] = []
    _ = deliverPendingEvents(replayDeadLetter: false, dir: r2bDir,
                             sender: { _, _, headers in
                                 r2bStamps.append(Int(headers["X-Tally-Timestamp"] ?? "") ?? -1)
                                 return (status: r2bStamps.count == 1 ? 500 : 200, error: nil)
                             },
                             sleeper: { _ in Thread.sleep(forTimeInterval: 1.1) }, handoff: {})
    expect(r2bStamps.count == 2 && r2bStamps[0] > 0 && r2bStamps[1] > r2bStamps[0],
           "R2: every attempt is signed over its own second (\(r2bStamps))")
    try? FileManager.default.removeItem(at: r2bDir)

    // R3: the backoff schedule is the documented one, not just the right number of sleeps.
    let r3Dir = freshDir("r3")
    configureSink(r3Dir)
    appendSessionWaitEvent(opened, dir: r3Dir)
    let r3 = scriptedPass(r3Dir, [500])
    expect(r3.sleeps == [2, 8, 30, 120], "R3: the backoff between five 500s is 2, 8, 30, 120 (\(r3.sleeps))")
    try? FileManager.default.removeItem(at: r3Dir)

    // R4: which statuses retry, and a mid-schedule success stops the schedule.
    let r4Cases: [(name: String, statuses: [Int], sends: Int, lastError: String?)] = [
        ("status 0 (no response)", [0], 5, "connection refused"),
        ("408", [408], 5, "http 408"),
        ("429", [429], 5, "http 429"),
        ("500, 500, then 200", [500, 500, 200], 3, nil),
    ]
    for r4 in r4Cases {
        let dir = freshDir("r4")
        configureSink(dir)
        appendSessionWaitEvent(opened, dir: dir)
        let pass = scriptedPass(dir, r4.statuses, error: "connection refused")
        let dead = readDeadLetterEntries(dir: dir)
        let deadOK = r4.lastError.map { dead.count == 1 && dead.first?.attempts == 5 && dead.first?.lastError == $0 }
            ?? (dead.isEmpty && pass.sleeps == [2, 8])
        expect(pass.sent.count == r4.sends && deadOK,
               "R4: \(r4.name) is sent \(r4.sends) times, then "
               + (r4.lastError.map { "dead-lettered with lastError \"\($0)\"" } ?? "stops with nothing dead-lettered")
               + " (\(pass.sent.count) sends, \(dead.count) dead)")
        try? FileManager.default.removeItem(at: dir)
    }

    // R5: the real sender gives up on a sink that never answers, within its 5s/6s bound.
    let r5Receiver = LoopbackReceiver(logFile: receiverLog("r5"), onRequest: { _ in
        Thread.sleep(forTimeInterval: 7)
    })
    let r5Start = Date()
    let r5 = defaultEventSender(URL(string: r5Receiver.url)!, Data("{}".utf8), [:])
    let r5Elapsed = Date().timeIntervalSince(r5Start)
    expect(r5Receiver.received.count == 1 && r5.status == 0 && r5Elapsed >= 4.5 && r5Elapsed <= 6.5,
           "R5: a sink holding its reply 7s makes the real sender return status 0 after "
           + String(format: "%.2fs", r5Elapsed))

    // R6: every retry of one event carries the same key, and it is the body's key.
    let r6Dir = freshDir("r6")
    configureSink(r6Dir)
    appendSessionWaitEvent(opened, dir: r6Dir)
    let r6 = scriptedPass(r6Dir, [500, 500, 200])
    let r6Keys = r6.sent.map { $0.headers["X-Tally-Idempotency-Key"] ?? "" }
    expect(r6Keys.count == 3 && Set(r6Keys).count == 1 && !opened.idempotencyKey.isEmpty
           && r6Keys.first == opened.idempotencyKey
           && r6.sent.allSatisfy { decoded($0.body)?.idempotencyKey == r6Keys.first },
           "R6: three attempts of one event send one header key, equal to the body's key (\(r6Keys))")
    try? FileManager.default.removeItem(at: r6Dir)

    // R7: two wait.updated for the same request are two events, so they carry two keys; a retry of
    // one of them keeps its own; opened/resolved keep the key they were built with.
    let r7Dir = freshDir("r7")
    configureSink(r7Dir)
    var r7Suspected = t6Request
    r7Suspected.confidence = SessionWaitConfidence.suspected.rawValue
    r7Suspected.tool = nil
    var r7Confirmed = r7Suspected
    r7Confirmed.confidence = SessionWaitConfidence.confirmed.rawValue
    let r7Updates = reconcileWaitRequests(previous: r7Suspected, current: r7Confirmed, resolution: nil,
                                          identity: identity, provider: "claude", now: now)
        + reconcileWaitRequests(previous: r7Confirmed, current: t6Request, resolution: nil,
                                identity: identity, provider: "claude", now: now)
    let r7Opened = make(.opened, r7Suspected)
    let r7Resolved = make(.resolved, t6Request, .answered)
    for event in [r7Opened] + r7Updates + [r7Resolved] { appendSessionWaitEvent(event, dir: r7Dir) }
    let r7Spooled = readSessionWaitEvents(since: 0, dir: r7Dir)
    let r7UpdateKeys = r7Spooled.filter { $0.kind == SessionWaitEventKind.updated.rawValue }.map(\.idempotencyKey)
    expect(r7Updates.count == 2 && r7UpdateKeys.count == 2 && !r7UpdateKeys[0].isEmpty
           && r7UpdateKeys[0] != r7UpdateKeys[1],
           "R7: two wait.updated for the same request carry different idempotency keys (\(r7UpdateKeys))")
    expect(r7Spooled.first?.idempotencyKey == r7Opened.idempotencyKey
           && r7Spooled.last?.idempotencyKey == r7Resolved.idempotencyKey,
           "R7: wait.opened and wait.resolved keep the key they were built with")
    var r7SeenSeqs: Set<Int> = []
    var r7Attempts: [Int: [String]] = [:]
    _ = deliverPendingEvents(replayDeadLetter: false, dir: r7Dir,
                             sender: { _, body, headers in
                                 let seq = decoded(body)?.seq ?? -1
                                 r7Attempts[seq, default: []].append(headers["X-Tally-Idempotency-Key"] ?? "")
                                 return (status: r7SeenSeqs.insert(seq).inserted ? 500 : 200, error: nil)
                             },
                             sleeper: { _ in }, handoff: {})
    expect(r7Spooled.count == 4 && r7Spooled.allSatisfy { r7Attempts[$0.seq] == [$0.idempotencyKey, $0.idempotencyKey] },
           "R7: each event's retry resends its own spooled key (\(r7Attempts.keys.sorted()))")
    try? FileManager.default.removeItem(at: r7Dir)

    // R8: a pass after everything is delivered sends nothing again.
    let r8Dir = freshDir("r8")
    let r8Receiver = LoopbackReceiver(logFile: receiverLog("r8"))
    configureSink(r8Dir, url: r8Receiver.url)
    appendSessionWaitEvent(opened, dir: r8Dir)
    appendSessionWaitEvent(resolved, dir: r8Dir)
    _ = deliverPendingEvents(replayDeadLetter: false, dir: r8Dir, sleeper: { _ in }, handoff: {})
    let r8AfterFirst = r8Receiver.received.count
    _ = deliverPendingEvents(replayDeadLetter: false, dir: r8Dir, sleeper: { _ in }, handoff: {})
    expect(r8AfterFirst == 2 && r8Receiver.received.count == 2,
           "R8: a second pass over a delivered spool sends nothing (\(r8AfterFirst) then \(r8Receiver.received.count))")
    try? FileManager.default.removeItem(at: r8Dir)

    // R9: a fresh pass resumes from the cursor on disk (a restart), not from the start of the spool.
    let r9Dir = freshDir("r9")
    let r9Receiver = LoopbackReceiver(logFile: receiverLog("r9"))
    configureSink(r9Dir, url: r9Receiver.url)
    for _ in 1...4 { appendSessionWaitEvent(opened, dir: r9Dir) }
    try? "2".write(to: r9Dir.appendingPathComponent("cursor"), atomically: true, encoding: .utf8)
    _ = deliverPendingEvents(replayDeadLetter: false, dir: r9Dir, sleeper: { _ in }, handoff: {})
    expect(r9Receiver.received.map(\.seq) == [3, 4] && readEventDeliveryCursor(dir: r9Dir) == 4,
           "R9: with cursor 2 on disk a fresh pass sends seq 3 and 4 only (\(r9Receiver.received.map(\.seq)))")
    try? FileManager.default.removeItem(at: r9Dir)

    // R10: --replay-dead-letter tries each entry once: a success drops it, a failure keeps it.
    let r10Dir = freshDir("r10")
    configureSink(r10Dir)
    appendSessionWaitEvent(opened, dir: r10Dir)
    appendSessionWaitEvent(resolved, dir: r10Dir)
    _ = scriptedPass(r10Dir, [500])
    let r10Before = readDeadLetterEntries(dir: r10Dir)
    let r10Cursor = readEventDeliveryCursor(dir: r10Dir)
    let r10 = scriptedPass(r10Dir, [200, 500], replay: true)
    let r10After = readDeadLetterEntries(dir: r10Dir)
    expect(r10Before.count == 2 && r10.sent.count == 2 && r10After.count == 1
           && r10After.first?.event.seq == r10Before.last?.event.seq
           && r10After.first?.attempts == 6 && r10After.first?.lastError == "http 500",
           "R10: replay drops the entry that succeeded and keeps the other at attempts 6, lastError http 500")
    expect(r10Cursor == 2 && readEventDeliveryCursor(dir: r10Dir) == r10Cursor,
           "R10: replay leaves the cursor where it was")
    expect(r10.sent.map { $0.headers["X-Tally-Idempotency-Key"] ?? "" } == r10Before.map(\.event.idempotencyKey)
           && Set(r10Before.map(\.event.idempotencyKey)).count == 2,
           "R10: replay resends each entry under its original key")
    try? FileManager.default.removeItem(at: r10Dir)

    // R11: once an event is dead-lettered, a later ordinary pass never sends it again by itself; only
    // --replay-dead-letter (or the consumer reading --since) recovers it.
    let r11Dir = freshDir("r11")
    configureSink(r11Dir)
    appendSessionWaitEvent(opened, dir: r11Dir)
    appendSessionWaitEvent(resolved, dir: r11Dir)
    var r11FirstSeqs: [Int] = []
    _ = deliverPendingEvents(replayDeadLetter: false, dir: r11Dir,
                             sender: { _, body, _ in
                                 let seq = decoded(body)?.seq ?? -1
                                 r11FirstSeqs.append(seq)
                                 return seq == 1 ? (status: 0, error: "connection refused") : (status: 200, error: nil)
                             },
                             sleeper: { _ in }, handoff: {})
    expect(r11FirstSeqs == [1, 1, 1, 1, 1, 2] && readDeadLetterEntries(dir: r11Dir).map(\.event.seq) == [1],
           "R11: a sink that is down for event 1's whole schedule dead-letters it, event 2 still goes")
    appendSessionWaitEvent(opened, dir: r11Dir)
    let r11Second = scriptedPass(r11Dir, [200])
    expect(r11Second.sent.compactMap { decoded($0.body)?.seq } == [3]
           && readDeadLetterEntries(dir: r11Dir).map(\.event.seq) == [1],
           "R11: with the sink back, an ordinary pass sends only the new event, never the dead-lettered one")
    try? FileManager.default.removeItem(at: r11Dir)

    // R12: a sink stuck on a reply does not hold up an append to the spool.
    let r12Dir = freshDir("r12")
    let r12Arrived = DispatchSemaphore(value: 0)
    let r12Release = DispatchSemaphore(value: 0)
    let r12Receiver = LoopbackReceiver(logFile: receiverLog("r12"), onRequest: { number in
        guard number == 1 else { return }
        r12Arrived.signal()
        _ = r12Release.wait(timeout: .now() + 3)
    })
    configureSink(r12Dir, url: r12Receiver.url)
    appendSessionWaitEvent(opened, dir: r12Dir)
    let r12Done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        _ = deliverPendingEvents(replayDeadLetter: false, dir: r12Dir, sleeper: { _ in }, handoff: {})
        r12Done.signal()
    }
    let r12Held = r12Arrived.wait(timeout: .now() + 5) == .success
    let r12Start = Date()
    appendSessionWaitEvent(resolved, dir: r12Dir)
    let r12Took = Date().timeIntervalSince(r12Start)
    let r12Visible = readSessionWaitEvents(since: 1, dir: r12Dir).map(\.seq)
    r12Release.signal()
    expect(r12Held && r12Took < 0.5 && r12Visible == [2],
           "R12: while the deliverer is stuck in a send, an append takes "
           + String(format: "%.3fs", r12Took) + " and is readable at once (\(r12Visible))")
    expect(r12Done.wait(timeout: .now() + 10) == .success, "R12: the stuck deliverer finishes once released")
    try? FileManager.default.removeItem(at: r12Dir)

    // R13: neither supervisor sends anything itself; both only spawn the detached deliverer.
    for path in ["TallyCLI/Supervisor.swift", "TallyCLI/CodexSupervisor.swift"] {
        let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        expect(source.contains("maybeSpawnEventDeliverer(") && !source.contains("deliverPendingEvents(")
               && !source.contains("defaultEventSender"),
               "R13: \(path) spawns the deliverer and never calls deliverPendingEvents or defaultEventSender")
    }

    // R14: the spawn returns while the deliverer it started is still running.
    let r14Dir = freshDir("r14")
    let r14Script = r14Dir.appendingPathComponent("slow-deliverer")
    let r14Marker = r14Dir.appendingPathComponent("ran")
    try? "#!/bin/sh\necho \"$@\" > '\(r14Marker.path)'\nsleep 5\n"
        .write(to: r14Script, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: r14Script.path)
    let r14Start = Date()
    spawnDetachedEventDeliverer(executable: r14Script.path)
    let r14Took = Date().timeIntervalSince(r14Start)
    var r14Ran = ""
    for _ in 0..<60 where r14Ran.isEmpty {
        r14Ran = ((try? String(contentsOf: r14Marker, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if r14Ran.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
    }
    expect(r14Took < 0.5 && r14Ran == "events --deliver-once",
           "R14: spawning a 5s deliverer returns in " + String(format: "%.3fs", r14Took)
           + " and the deliverer really ran (\"\(r14Ran)\")")
    try? FileManager.default.removeItem(at: r14Dir)

    runUpdatedOverWireChecks()
}

// MARK: - W5 (begin): two wait.updated for one request, over real HTTP

/// R7 proves the two keys differ in the spool and through an injected sender; this is the same pair
/// through `defaultEventSender` to a loopback sink, so the headers asserted are the ones on the wire.
func runUpdatedOverWireChecks() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-waitevents-w5-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let receiver = LoopbackReceiver(logFile: dir.appendingPathComponent("receiver.log"))
    _ = writeEventSinkConfig(EventSinkConfig(url: receiver.url, secret: "w5", createdAt: now), dir: dir)
    var suspected = t6Request
    suspected.confidence = SessionWaitConfidence.suspected.rawValue
    suspected.tool = nil
    var confirmed = suspected
    confirmed.confidence = SessionWaitConfidence.confirmed.rawValue
    let updates = reconcileWaitRequests(previous: suspected, current: confirmed, resolution: nil,
                                        identity: identity, provider: "claude", now: now)
        + reconcileWaitRequests(previous: confirmed, current: t6Request, resolution: nil,
                                identity: identity, provider: "claude", now: now)
    for event in updates { appendSessionWaitEvent(event, dir: dir) }
    _ = deliverPendingEvents(replayDeadLetter: false, dir: dir, sleeper: { _ in }, handoff: {})
    let posts = receiver.requests
    let keys = posts.map { $0.headers["x-tally-idempotency-key"] ?? "" }
    let bodyKeys = posts.map {
        (try? sessionWaitEventDecoder().decode(SessionWaitEvent.self, from: $0.body))?.idempotencyKey ?? "?"
    }
    expect(updates.count == 2 && posts.count == 2
           && posts.allSatisfy { $0.headers["x-tally-event"] == SessionWaitEventKind.updated.rawValue },
           "W5: two wait.updated for one request reach the sink as two POSTs with X-Tally-Event wait.updated "
           + "(\(posts.count) posts)")
    expect(keys.count == 2 && !keys[0].isEmpty && keys[0] != keys[1],
           "W5: ...carrying two different X-Tally-Idempotency-Key headers (\(keys))")
    expect(keys.count == 2 && keys == bodyKeys,
           "W5: ...each equal to its own body's idempotencyKey (\(bodyKeys))")
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - W5 (end)
