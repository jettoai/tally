import Darwin
import Foundation

// THE APPEND-ONLY LOG THIS FEATURE PUBLISHES TO, and the only place a wait event exists once a tick
// has decided one. `~/.tally/events/` (plan §5.1): `spool.jsonl` one line per event, `seq` the
// counter an appender hands out next, `cursor` (owned by `EventDelivery.swift`, a later package)
// how far a delivery attempt has gotten. This file owns the first two; `dir` defaults to the real
// directory (matching `ReloadRequest.swift:53`'s `supervisorStateDir` pattern) and is threaded
// through every function so a test can point it at a `mktemp -d` instead.
//
// EVERY FAILURE HERE IS SILENT, on the same rule `UserNotice.swift:110-111` states for its own
// write: a hook or a tick that could not spool an event must never change what it does because of
// that, since the wait itself is still real whether or not this side channel could record it.

/// `~/.tally/events`, alongside `~/.tally/supervisor-state` (`ReloadRequest.swift`).
let tallyEventsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/events")

private let spoolFileName = "spool.jsonl"
private let seqFileName = "seq"
private let cursorFileName = "cursor"
/// The lock every appender takes before it touches the spool, and the reason it is a file of its own
/// rather than the spool itself: the trim below `rename`s a new spool into place, so a lock held on
/// the spool's fd guards an inode that has just left the path. A writer that opened before the rename
/// and waited on that lock then wrote into the orphan, and a writer that opened after it locked the
/// new inode at the same moment (judge probe on 0e34324: 8 concurrent appends, 7 lost, 5 of 5 runs).
/// Nothing ever renames this file, so the lock it carries is one lock for the life of the directory.
/// Not `deliver.lock` (EventDelivery.swift): delivery and appending must not wait on each other.
private let spoolLockFileName = "spool.lock"

/// A spool line may be at most this many bytes (§5.2 step 4): a shared machine's disk is a shared
/// resource, and an unbounded `request.summary` (a model's own prose, in the worst case) is the one
/// field here with no fixed shape.
private let spoolLineByteLimit = 4096

/// The spool is rewritten once it passes this size and the cursor has moved through at least half
/// of what is in it (§5.2's spool trim), so `tally events --since` keeps working on a machine that
/// never restarts its supervisors.
private let spoolTrimBytes: UInt64 = 8 * 1024 * 1024
private let spoolTrimKeepBack = 1000

private func spoolFile(dir: URL) -> URL { dir.appendingPathComponent(spoolFileName) }
private func seqFile(dir: URL) -> URL { dir.appendingPathComponent(seqFileName) }
private func cursorFile(dir: URL) -> URL { dir.appendingPathComponent(cursorFileName) }
private func spoolLockFile(dir: URL) -> URL { dir.appendingPathComponent(spoolLockFileName) }

/// One of the two single-integer files beside the spool (`seq`, `cursor`): a decimal integer and
/// nothing else, missing entirely until the first thing that needs it writes it.
private func readCounter(_ file: URL) -> Int? {
    guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
}

private func writeCounter(_ value: Int, to file: URL) {
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? "\(value)".write(to: file, atomically: true, encoding: .utf8)
}

/// The line this event encodes to, or nil if it somehow cannot (a shape `JSONEncoder` refuses,
/// which nothing in `SessionWaitEvent` should produce, but a spool write is exactly the place a
/// silent `nil` is the correct answer rather than a crash). Embedded newlines are stripped
/// defensively: the encoder never emits one for this shape, but "one line, one event" (§3.1) is the
/// contract this whole file exists to keep, and a stray control character reaching disk unchecked
/// is how that contract breaks quietly.
private func spoolLine(for event: SessionWaitEvent) -> String? {
    guard let data = try? sessionWaitEventEncoder().encode(event),
          let json = String(data: data, encoding: .utf8) else { return nil }
    return json.replacingOccurrences(of: "\n", with: " ")
}

private func writeRaw(_ line: String, fd: Int32) {
    let data = Data((line + "\n").utf8)
    _ = data.withUnsafeBytes { raw in
        Darwin.write(fd, raw.baseAddress, raw.count)
    }
}

/// §5.2, in order: take the exclusive `spool.lock`, THEN open the spool append-only, hand out the
/// next `seq`, write exactly one line, trim if due, release the lock. The lock is held across the
/// seq read-and-bump, the write and the trim, so two supervisors racing this at once (two sessions on
/// the same machine, both deciding something at once) cannot hand out the same `seq` twice, and the
/// open comes after the lock so the fd written to is always the inode the path names now, never one
/// a trim has just renamed away.
///
/// AN EVENT IS ONLY DROPPED WHEN CUTTING `summary` ALONE STILL LEAVES THE LINE OVER THE LIMIT: a
/// line over the 4096-byte cap first has `request.summary` shrunk to a smaller budget, and only if
/// that still does not fit is the summary dropped outright. If the line is STILL over the cap once
/// `summary` is gone (every field left is what is too long), `appendSessionWaitEvent` returns
/// without writing a line at all. Both shrink attempts recompute the WHOLE line rather than estimate
/// the savings, because JSON string escaping does not shrink a UTF-8 byte count by a predictable
/// amount.
func appendSessionWaitEvent(_ event: SessionWaitEvent, dir: URL = tallyEventsDir) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let lockFD = spoolLockFile(dir: dir).path.withCString { open($0, O_RDWR | O_CREAT, 0o600) }
    guard lockFD >= 0 else { return }
    defer { close(lockFD) }
    guard flock(lockFD, LOCK_EX) == 0 else { return }
    defer { flock(lockFD, LOCK_UN) }
    let fd = spoolFile(dir: dir).path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o600) }
    guard fd >= 0 else { return }
    defer { close(fd) }

    var stamped = event
    stamped.seq = readCounter(seqFile(dir: dir)) ?? 1

    guard var line = spoolLine(for: stamped) else { return }
    if line.utf8.count > spoolLineByteLimit, let summary = stamped.request?.summary {
        stamped.request?.summary = sessionWaitSummary(summary, byteLimit: 64)
        line = spoolLine(for: stamped) ?? line
    }
    if line.utf8.count > spoolLineByteLimit {
        stamped.request?.summary = nil
        guard let fitted = spoolLine(for: stamped) else { return }
        line = fitted
    }
    guard line.utf8.count <= spoolLineByteLimit else { return }

    writeCounter(stamped.seq + 1, to: seqFile(dir: dir))
    writeRaw(line, fd: fd)
    trimSpoolIfNeeded(dir: dir)
}

/// Every event with `seq > since`, oldest first (the spool is append-only, so file order already is
/// seq order), up to `limit`. A line this build cannot decode is skipped rather than aborting the
/// whole read: one bad line must not hide every good one behind it (judgement 1's over-count belt,
/// applied to a reader instead of a hook).
func readSessionWaitEvents(since: Int, limit: Int = 500, dir: URL = tallyEventsDir) -> [SessionWaitEvent] {
    guard let raw = try? String(contentsOf: spoolFile(dir: dir), encoding: .utf8) else { return [] }
    let decoder = sessionWaitEventDecoder()
    var events: [SessionWaitEvent] = []
    for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let data = line.data(using: .utf8),
              let decoded = try? decoder.decode(SessionWaitEvent.self, from: data),
              decoded.seq > since else { continue }
        events.append(decoded)
        if events.count >= limit { break }
    }
    return events
}

/// §5.2's spool trim, run only by `appendSessionWaitEvent` while it holds `spool.lock`. Only fires past `spoolTrimBytes` AND once delivery (`cursor`) has caught up
/// with at least half of what is on disk, so a spool that is growing faster than it is being
/// delivered is never trimmed out from under a consumer that has not seen those lines yet. Rewrites
/// to a temp file and `rename`s it into place (POSIX atomic on the same volume), the same "tmp then
/// rename" shape every other atomic write on this track uses, so a reader mid-scan sees either the
/// old file or the new one, never a half-written one.
func trimSpoolIfNeeded(dir: URL = tallyEventsDir) {
    let target = spoolFile(dir: dir)
    guard let size = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? UInt64,
          size > spoolTrimBytes,
          let raw = try? String(contentsOf: target, encoding: .utf8) else { return }
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    guard !lines.isEmpty else { return }

    let decoder = sessionWaitEventDecoder()
    func seq(of line: String) -> Int? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? decoder.decode(SessionWaitEvent.self, from: data).seq
    }

    // An undecodable line reads as `Int.max`: never counted as delivered, always kept.
    let seqs = lines.map { seq(of: $0) ?? Int.max }
    let cursor = readCounter(cursorFile(dir: dir)) ?? 0
    let deliveredCount = seqs.filter { $0 <= cursor }.count
    guard deliveredCount * 2 >= lines.count else { return }

    let keepAfter = cursor - spoolTrimKeepBack
    let kept = zip(lines, seqs).filter { $0.1 > keepAfter }.map(\.0)
    let body = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"

    let tmp = dir.appendingPathComponent("\(spoolFileName).tmp-\(UUID().uuidString)")
    guard (try? body.write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return }
    let renamed = tmp.path.withCString { tmpC in
        target.path.withCString { targetC in rename(tmpC, targetC) }
    }
    if renamed != 0 { try? FileManager.default.removeItem(at: tmp) }
}
