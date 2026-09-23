import Foundation

// Every stamp the keyboard tracker classified while a reload was queued, with what it decided.
// The 2026-09-23 wait could only be reconstructed from WindowServer logs after the fact; this is
// that record kept by the one process that made the decision. Bounded, one file per supervisor,
// swept with the rest of supervisor-state when the supervisor dies (PendingNotice.swift).

let keyboardTraceMaxLines = 200

func keyboardTraceFile(pid: String, dir: URL = supervisorStateDir) -> URL {
    dir.appendingPathComponent(pid + keyboardTraceSuffix)
}

/// One line per observation: time, gap, burst, focus offset, nearest focus. Pure.
func keyboardTraceLine(_ o: KeyboardObservation) -> String {
    func secs(_ v: TimeInterval?) -> String { v.map { String(format: "%.3f", $0) } ?? "-" }
    return "\(traceTimestamp(o.stamp)) gap=\(secs(o.gap)) burst=\(o.burst ? 1 : 0) "
        + "focus=\(secs(o.focusOffset)) nearest=\(secs(o.nearestFocus))"
}

func traceTimestamp(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

struct KeyboardTrace {
    private(set) var lines: [String] = []
    /// The reload epoch the last header was written for.
    private var headerEpoch: Int?

    /// Add this tick's observations while `epoch` is queued. Returns true when something changed.
    mutating func record(_ observations: [KeyboardObservation], queuedEpoch epoch: Int?,
                         now: Date = Date()) -> Bool {
        guard let epoch else { return false }
        var changed = false
        if headerEpoch != epoch {
            lines.append("\(traceTimestamp(now)) queued epoch=\(epoch)")
            headerEpoch = epoch
            changed = true
        }
        for o in observations { lines.append(keyboardTraceLine(o)); changed = true }
        if lines.count > keyboardTraceMaxLines { lines.removeFirst(lines.count - keyboardTraceMaxLines) }
        return changed
    }

    func write(pid: String, dir: URL = supervisorStateDir) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: keyboardTraceFile(pid: pid, dir: dir), atomically: true, encoding: .utf8)
    }
}
