import CryptoKit
import Darwin
import Foundation

// THE OUTBOUND HALF OF THIS FEATURE: everything between a decided `SessionWaitEvent` sitting in
// `spool.jsonl` (TallyCLI/SessionWaitSpool.swift) and an external watcher's webhook actually
// receiving it (plan §5.3-5.5). This file owns `sink.json` (the one configured destination),
// `cursor` (how far delivery has gotten - a SEPARATE counter from the spool's own `seq`, which only
// ever counts up as events are decided, never as they are delivered) and `dead-letter.jsonl` (events
// that could not be delivered after every retry, or that failed permanently).
//
// `cursor` and `seq` share nothing but a directory: `SessionWaitSpool.swift` keeps `seq`/`spool.jsonl`
// private to itself (this file reads the spool only through its public `readSessionWaitEvents`), so
// the small integer-file helpers below are this file's own, not a reuse of that file's private ones.
//
// EVERY SENDER AND SLEEP HERE IS INJECTABLE (`EventSender`, `sleeper`) because this function's
// caller (`tests/waitevents/main.swift` T12) has to prove a five-attempt exhausted retry without
// spending the real 0+2+8+30+120 = 160 seconds of backoff a live delivery would take.

/// The one destination this machine's supervisors deliver events to. `~/.tally/events/sink.json`
/// (plan §5.1), 0600 from the moment it is created (§5.4's secrets rule: this is the only file on
/// disk that holds the webhook secret in the clear, because HMAC signing needs it in the clear).
struct EventSinkConfig: Codable {
    var url: String
    var secret: String
    var createdAt: Date
}

/// One event that ran out of retries or failed permanently (§5.5), with just enough about the
/// attempt to explain why: `attempts` is how many times `deliverOne` tried (1-5, or 0 when the event
/// or the sink URL itself could not even be turned into a request), `lastError` is the last thing the
/// sender said. The event itself is carried whole, unmodified, so `--replay-dead-letter` has
/// everything it needs to try again.
struct DeadLetterEntry: Codable {
    var event: SessionWaitEvent
    var attempts: Int
    var lastError: String
}

/// What sends one HTTP POST and reports back a status code (0 for "never got a response" - a
/// timeout or a transport error) and, when there is one, a human-readable reason. Injectable so a
/// test can stand in for the network entirely (T12: "always 500").
typealias EventSender = (URL, Data, [String: String]) -> (status: Int, error: String?)

/// The real sender: `URLSession.shared` blocked on with a semaphore, because this only ever runs
/// inside `tally events --deliver-once`, a detached one-shot child process (plan §5.3) whose entire
/// job is this HTTP call - blocking it is correct, not a smell, the same reasoning §6.6 states for
/// why this file uses a semaphore rather than async/await.
func defaultEventSender(_ url: URL, _ body: Data, _ headers: [String: String]) -> (status: Int, error: String?) {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.timeoutInterval = 5
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

    let semaphore = DispatchSemaphore(value: 0)
    let outcome = SendOutcome()
    let task = URLSession.shared.dataTask(with: request) { _, response, error in
        if let error {
            outcome.set((0, error.localizedDescription))
        } else if let http = response as? HTTPURLResponse {
            outcome.set((http.statusCode, nil))
        } else {
            outcome.set((0, "no HTTP response"))
        }
        semaphore.signal()
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 6)
    return outcome.get
}

/// Where `defaultEventSender` puts the completion handler's answer. A small class with a lock of
/// its own rather than a captured `var`, because a `var` written from the completion handler's
/// thread while the timeout races it IS a data race and saying so in a comment does not serialise
/// anything; this does, in the one place that needs it.
private final class SendOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (status: Int, error: String?) = (0, "no response")

    func set(_ newValue: (status: Int, error: String?)) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    var get: (status: Int, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// §5.4: `HMAC-SHA256(key: secret, message: "<timestamp>.<body>")`, lowercase hex. A pure function on
/// purpose (T11 calls it directly against a vector computed once with Python's own `hmac` module, per
/// the work order) - the signing math is the one piece of this file worth proving byte-for-byte
/// independent of any HTTP call.
func hmacSignatureHex(secret: String, timestamp: String, body: String) -> String {
    let key = SymmetricKey(data: Data(secret.utf8))
    let message = Data("\(timestamp).\(body)".utf8)
    let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
    return mac.map { String(format: "%02x", $0) }.joined()
}

// MARK: - File layout (own copies of the small helpers `SessionWaitSpool.swift` keeps private to
// itself - see this file's header for why they are not shared).

private let sinkFileName = "sink.json"
private let cursorFileName = "cursor"
private let lockFileName = "deliver.lock"
private let deadLetterFileName = "dead-letter.jsonl"

private func sinkFile(dir: URL) -> URL { dir.appendingPathComponent(sinkFileName) }
private func cursorFile(dir: URL) -> URL { dir.appendingPathComponent(cursorFileName) }
private func lockFile(dir: URL) -> URL { dir.appendingPathComponent(lockFileName) }
private func deadLetterFile(dir: URL) -> URL { dir.appendingPathComponent(deadLetterFileName) }

// MARK: - Sink configuration

func readEventSinkConfig(dir: URL = tallyEventsDir) -> EventSinkConfig? {
    guard let data = try? Data(contentsOf: sinkFile(dir: dir)) else { return nil }
    return try? sessionWaitEventDecoder().decode(EventSinkConfig.self, from: data)
}

/// Always rewrites the file from scratch (remove, then create) rather than overwrite-in-place, so
/// the 0600 mode is reapplied every time (§5.4: the file is created at mode 0600 from the start)
/// instead of relying on whatever mode an
/// earlier write happened to leave behind.
@discardableResult
func writeEventSinkConfig(_ config: EventSinkConfig, dir: URL = tallyEventsDir) -> Bool {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let data = try? sessionWaitEventEncoder().encode(config) else { return false }
    let path = sinkFile(dir: dir).path
    try? FileManager.default.removeItem(atPath: path)
    return FileManager.default.createFile(atPath: path, contents: data,
                                          attributes: [.posixPermissions: 0o600])
}

func clearEventSinkConfig(dir: URL = tallyEventsDir) {
    try? FileManager.default.removeItem(at: sinkFile(dir: dir))
}

// MARK: - Cursor (how far delivery has gotten, separate from the spool's own `seq`)

/// Public (not `private`) because `tests/waitevents/main.swift` (T12) has to read it back after a
/// `deliverPendingEvents` call to prove the cursor advanced even for a dead-lettered event.
func readEventDeliveryCursor(dir: URL = tallyEventsDir) -> Int {
    guard let raw = try? String(contentsOf: cursorFile(dir: dir), encoding: .utf8),
          let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return 0 }
    return value
}

private func writeEventDeliveryCursor(_ value: Int, dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? "\(value)".write(to: cursorFile(dir: dir), atomically: true, encoding: .utf8)
}

// MARK: - Dead letter

/// Public for the same reason `readEventDeliveryCursor` is: T12 reads this back to assert an
/// exhausted event actually landed here with `attempts == 5`.
func readDeadLetterEntries(dir: URL = tallyEventsDir) -> [DeadLetterEntry] {
    guard let raw = try? String(contentsOf: deadLetterFile(dir: dir), encoding: .utf8) else { return [] }
    let decoder = sessionWaitEventDecoder()
    var entries: [DeadLetterEntry] = []
    for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let data = line.data(using: .utf8),
              let entry = try? decoder.decode(DeadLetterEntry.self, from: data) else { continue }
        entries.append(entry)
    }
    return entries
}

/// One dead-letter line (no trailing newline), or nil when the entry cannot be encoded.
private func deadLetterLine(_ entry: DeadLetterEntry, encoder: JSONEncoder) -> String? {
    guard let data = try? encoder.encode(entry), let json = String(data: data, encoding: .utf8)
    else { return nil }
    return json.replacingOccurrences(of: "\n", with: " ")
}

private func appendDeadLetter(_ event: SessionWaitEvent, attempts: Int, lastError: String, dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let entry = DeadLetterEntry(event: event, attempts: attempts, lastError: lastError)
    guard let line = deadLetterLine(entry, encoder: sessionWaitEventEncoder()) else { return }
    let fd = deadLetterFile(dir: dir).path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o600) }
    guard fd >= 0 else { return }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { return }
    defer { flock(fd, LOCK_UN) }
    let out = Data((line + "\n").utf8)
    _ = out.withUnsafeBytes { raw in Darwin.write(fd, raw.baseAddress, raw.count) }
}

/// Rewrites the whole dead-letter file to hold exactly `entries` (tmp-then-rename, the same atomic
/// shape `SessionWaitSpool.swift`'s trim uses): called after a replay pass, where some entries
/// succeeded (dropped) and some did not (kept, with `attempts` bumped).
private func rewriteDeadLetterFile(_ entries: [DeadLetterEntry], dir: URL) {
    let encoder = sessionWaitEventEncoder()
    let lines = entries.compactMap { deadLetterLine($0, encoder: encoder) }
    let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    let tmp = dir.appendingPathComponent("\(deadLetterFileName).tmp-\(UUID().uuidString)")
    guard (try? body.write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return }
    let renamed = tmp.path.withCString { tmpC in
        deadLetterFile(dir: dir).path.withCString { targetC in rename(tmpC, targetC) }
    }
    if renamed != 0 { try? FileManager.default.removeItem(at: tmp) }
}

// MARK: - Delivery

/// §5.5's schedule: the first attempt is immediate, then 2s, 8s, 30s, 120s - five attempts total.
private let deliveryBackoffSeconds: [Double] = [0, 2, 8, 30, 120]

/// §5.5: a 4xx OTHER than 408 (request timeout) or 429 (rate limited) is permanent - retrying it
/// would never succeed, so it goes straight to dead-letter on the first attempt that sees it.
private func isPermanentFailureStatus(_ status: Int) -> Bool {
    guard (400...499).contains(status) else { return false }
    return status != 408 && status != 429
}

/// The JSON body a delivery POSTs for `event`, or nil when it cannot be encoded.
private func deliveryBody(for event: SessionWaitEvent) -> String? {
    guard let data = try? sessionWaitEventEncoder().encode(event) else { return nil }
    return String(data: data, encoding: .utf8)
}

/// §5.4's headers for one attempt, signed over the current second: every attempt (fresh or replayed)
/// gets its own timestamp, so a receiver's replay window measures the attempt, not the event.
private func signedDeliveryHeaders(for event: SessionWaitEvent, body: String,
                                   secret: String) -> [String: String] {
    let timestamp = String(Int(Date().timeIntervalSince1970))
    let signature = hmacSignatureHex(secret: secret, timestamp: timestamp, body: body)
    return [
        "Content-Type": "application/json",
        "X-Tally-Timestamp": timestamp,
        "X-Tally-Signature": "sha256=\(signature)",
        "X-Tally-Idempotency-Key": event.idempotencyKey,
        "X-Tally-Event": event.kind,
    ]
}

/// One event, all the way through its retry schedule. Always resolves to either a 2xx (silent
/// success, nothing written) or a dead-letter append - never leaves the event in limbo, which is
/// what lets the caller advance `cursor` unconditionally once this returns (§5.5: cursor advances
/// regardless).
private func deliverOne(_ event: SessionWaitEvent, sink: EventSinkConfig, dir: URL,
                        sender: EventSender, sleeper: (TimeInterval) -> Void) {
    guard let url = URL(string: sink.url) else {
        appendDeadLetter(event, attempts: 0, lastError: "sink url does not parse", dir: dir)
        return
    }
    guard let body = deliveryBody(for: event) else {
        appendDeadLetter(event, attempts: 0, lastError: "event failed to encode", dir: dir)
        return
    }

    for (index, delay) in deliveryBackoffSeconds.enumerated() {
        if delay > 0 { sleeper(delay) }
        let attemptNumber = index + 1
        let headers = signedDeliveryHeaders(for: event, body: body, secret: sink.secret)
        let result = sender(url, Data(body.utf8), headers)
        if (200...299).contains(result.status) { return }

        if isPermanentFailureStatus(result.status) || attemptNumber == deliveryBackoffSeconds.count {
            appendDeadLetter(event, attempts: attemptNumber,
                             lastError: result.error ?? "http \(result.status)", dir: dir)
            return
        }
    }
}

/// One attempt per dead-letter entry (plan §5.5: replay once), not the full five-attempt schedule a
/// fresh event gets - this is a manual, operator-invoked retry, not the automatic path. A success
/// drops the entry; a failure keeps it with `attempts` bumped and `lastError` refreshed.
private func replayDeadLetterEntries(dir: URL, sink: EventSinkConfig, sender: EventSender) {
    let existing = readDeadLetterEntries(dir: dir)
    guard !existing.isEmpty else { return }
    guard let url = URL(string: sink.url) else { return }

    var remaining: [DeadLetterEntry] = []
    for entry in existing {
        guard let body = deliveryBody(for: entry.event) else {
            remaining.append(entry)
            continue
        }
        let headers = signedDeliveryHeaders(for: entry.event, body: body, secret: sink.secret)
        let result = sender(url, Data(body.utf8), headers)
        if (200...299).contains(result.status) { continue }
        remaining.append(DeadLetterEntry(event: entry.event, attempts: entry.attempts + 1,
                                         lastError: result.error ?? "http \(result.status)"))
    }
    rewriteDeadLetterFile(remaining, dir: dir)
}

private func openDeliverLock(dir: URL) -> Int32 {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return lockFile(dir: dir).path.withCString { open($0, O_CREAT | O_RDWR, 0o600) }
}

/// §5.3-5.5, the whole delivery pass: acquire the single-delivery-process lock (losing the race is
/// not an error, it means another supervisor's spawned child is already delivering - exit 0), replay
/// dead-letter when asked, then walk every event past `cursor` and deliver it. No sink configured is
/// also not an error (nothing to do yet) - both are ordinary, silent no-ops, the same "never change
/// behaviour on failure" rule the spool itself follows (SessionWaitSpool.swift's header).
func deliverPendingEvents(replayDeadLetter: Bool, dir: URL = tallyEventsDir,
                          sender: EventSender = defaultEventSender,
                          sleeper: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                          rounds: Int = deliveryPassRounds,
                          handoff: () -> Void = spawnDetachedEventDeliverer) -> Int32 {
    guard let sink = readEventSinkConfig(dir: dir) else { return 0 }

    let lockFD = openDeliverLock(dir: dir)
    guard lockFD >= 0 else { return 0 }
    defer { close(lockFD) }

    // WHY IT RE-READS, TWICE OVER. An exit path appends its closing events and then spawns a forced
    // deliverer; if an older pass holds the lock, that spawn loses `LOCK_NB` and exits, so the
    // holder is the only process left that can send them. Under the lock it therefore re-reads past
    // the cursor until nothing is left, and after unlocking it looks once more: an append that
    // landed between its last read and its unlock belongs to a spawn that failed while it still held
    // the lock, so if anything is past the cursor it takes the lock again. Both loops are bounded so
    // an appender that never stops cannot pin this process; reaching the bound with events still
    // past the cursor hands them to one fresh detached deliverer (`handoff`) instead of leaving them
    // for a later launch. Only when this pass moved the cursor, though: a cursor that cannot be
    // written (a full disk, a directory in its place) never moves, and handing off then would be a
    // chain of processes posting the same event forever with no supervisor alive.
    let cursorAtEntry = readEventDeliveryCursor(dir: dir)
    var replay = replayDeadLetter
    for _ in 0..<rounds {
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { return 0 }
        if replay {
            replayDeadLetterEntries(dir: dir, sink: sink, sender: sender)
            replay = false
        }
        for _ in 0..<rounds {
            let pending = readSessionWaitEvents(since: readEventDeliveryCursor(dir: dir),
                                                limit: 1_000_000, dir: dir)
            if pending.isEmpty { break }
            for event in pending {
                deliverOne(event, sink: sink, dir: dir, sender: sender, sleeper: sleeper)
                // Unconditional: a dead-lettered event must not be retried forever by every later
                // tick's spawn just because it never succeeded (§5.5's own words: no single entry
                // may block the whole queue forever).
                writeEventDeliveryCursor(event.seq, dir: dir)
            }
        }
        flock(lockFD, LOCK_UN)
        if readSessionWaitEvents(since: readEventDeliveryCursor(dir: dir), limit: 1, dir: dir).isEmpty {
            return 0
        }
    }
    if readEventDeliveryCursor(dir: dir) > cursorAtEntry { handoff() }
    return 0
}

/// How many times one delivery pass re-reads the spool under its lock, and how many times it takes
/// the lock again after finding events past the cursor (`deliverPendingEvents`).
let deliveryPassRounds = 5
