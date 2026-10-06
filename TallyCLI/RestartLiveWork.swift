import Foundation

// WHAT A CHILD STILL HAD RUNNING WHEN TALLY RESTARTED IT (B-5730).
//
// A restart owes the next child a line only when the child it replaces had work the restart took:
// a background shell, a Monitor, a background subagent, or a session-only cron ("not written to
// disk, dies when Claude exits"). The roster (AgentRoster.swift) counts the first three at each
// turn end but never sees a cron, and on 2026-10-02 it handed a turn-boundary move a zero while a
// Monitor was delivering events every minute. So the child's own transcript is asked as well
// (`restartOwed`, RestartWake.swift, decides).
//
// A task id is live from the tool result that started it, or from any Monitor event it delivered
// (a Monitor armed before a /clear left its start in the other transcript), until a notice gives
// it a terminal status, a Monitor event says it expired, or a TaskStop reports it stopped.
// Post-launch lines only: a relaunch kills every task, so anything older died with the previous
// process. Every misreading errs towards a line: a tool result that merely quotes a start adds a
// task and costs one line, which is the price of "when unsure, send".

let liveBackgroundShellMarker = "Command running in background with ID: "
let liveMonitorMarker = "Monitor started (task "
let liveAsyncAgentMarker = "Async agent launched successfully"
let liveAgentIDMarker = "agentId: "
let taskStoppedMarker = "Successfully stopped task: "
let monitorEventMarker = "<summary>Monitor event:"
let monitorExpiredMarker = "Monitor expired after"
let terminalTaskStatuses: Set<Substring> = ["completed", "failed", "killed", "stopped"]
let sessionOnlyCronMarker = "Session-only (not written to disk"
let cronDeleteMarker = "\"name\":\"CronDelete\""
/// The id CronDelete was given: its own input, not the first `"id":"` on the line (the message and
/// the tool call carry ids of their own ahead of it). A call still streaming writes `"input":{}`.
let cronDeleteIDMarker = "\"name\":\"CronDelete\",\"input\":{\"id\":\""

/// Whether a cap resume waits for the next real message when the capped child had nothing running
/// (B-5730: 22 resumes in 48h, each rewriting a 337K prefix). One switch, so it is one line to undo.
let capResumeRequiresLiveWork = true

struct RestartLiveWork: Equatable {
    var tasks = Set<String>()
    /// Session-only crons by id, with the end of a one-shot's fire minute (nil: recurring, or a
    /// schedule this cannot read, which stays live).
    var crons: [String: Date?] = [:]

    func liveCron(now: Date) -> Bool { crons.values.contains { $0.map { $0 > now } ?? true } }

    /// Fold one post-launch line. `notice` is the structural task-notification test the scan
    /// already makes (origin kind, or content opening with the tag), so a prompt that quotes a
    /// notice changes nothing.
    mutating func fold(_ text: Substring, at ts: Date, notice: Bool, toolResult: Bool,
                       calendar: Calendar = .current) {
        if notice {
            let ids = taskNotificationIDs(text)
            if let status = tagValue(text, "status"), terminalTaskStatuses.contains(status) {
                tasks.subtract(ids)
            } else if text.contains(monitorExpiredMarker) {
                tasks.subtract(ids)
            } else if text.contains(monitorEventMarker) {
                tasks.formUnion(ids)
            }
            return
        }
        if text.contains(cronDeleteMarker), let id = token(after: cronDeleteIDMarker, in: text) {
            crons[id] = nil
        }
        guard toolResult else { return }
        for marker in [liveBackgroundShellMarker, liveMonitorMarker] {
            if let id = token(after: marker, in: text) { tasks.insert(id) }
        }
        if text.contains(liveAsyncAgentMarker), let id = token(after: liveAgentIDMarker, in: text) {
            tasks.insert(id)
        }
        if let id = token(after: taskStoppedMarker, in: text) { tasks.remove(id) }
        if text.contains(sessionOnlyCronMarker), let created = scheduledCron(text) {
            crons[created.id] = created.oneShot
                ? oneShotFireEnd(created.schedule, createdAt: ts, calendar: calendar) : nil
        }
    }
}

// MARK: - Readers (substring, like the rest of the scan)

/// `<task-id>` values, `__orphan_summary__` markers left out (same rule as `stoppedTaskNotice`).
func taskNotificationIDs(_ text: Substring) -> Set<String> {
    var ids = Set<String>()
    var rest = text[...]
    while let open = rest.range(of: "<task-id>"),
          let close = rest[open.upperBound...].range(of: "</task-id>") {
        let id = rest[open.upperBound..<close.lowerBound]
        if !id.hasPrefix("__orphan_summary__") { ids.insert(String(id)) }
        rest = rest[close.upperBound...]
    }
    return ids
}

func tagValue(_ text: Substring, _ tag: String) -> Substring? {
    guard let open = text.range(of: "<\(tag)>"),
          let close = text[open.upperBound...].range(of: "</\(tag)>") else { return nil }
    return text[open.upperBound..<close.lowerBound]
}

/// The id right after `marker`: letters, digits, `_` and `-`, at least 4 of them.
func token(after marker: String, in text: Substring) -> String? {
    guard let at = text.range(of: marker) else { return nil }
    let id = text[at.upperBound...].prefix {
        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
    }
    return id.count >= 4 ? String(id) : nil
}

/// `Scheduled one-shot task a2998ea6 (58 11 1 10 *).` gives the id, the schedule, and one-shot.
func scheduledCron(_ text: Substring) -> (id: String, schedule: Substring, oneShot: Bool)? {
    guard let s = text.range(of: "Scheduled "),
          let paren = text[s.upperBound...].range(of: " ("),
          let close = text[paren.upperBound...].range(of: ")") else { return nil }
    let head = text[s.upperBound..<paren.lowerBound]
    guard let id = head.split(separator: " ").last, id.count >= 4 else { return nil }
    return (String(id), text[paren.upperBound..<close.lowerBound], head.contains("one-shot"))
}

/// The end of a one-shot's fire minute, for a fixed `m h dom mon *` schedule in local time; nil for
/// anything else (which then counts as live). The next such minute at or after creation.
func oneShotFireEnd(_ schedule: Substring, createdAt: Date, calendar: Calendar) -> Date? {
    let f = schedule.split(separator: " ")
    guard f.count == 5, f[4] == "*", let minute = Int(f[0]), let hour = Int(f[1]),
          let day = Int(f[2]), let month = Int(f[3]) else { return nil }
    var c = DateComponents(year: calendar.component(.year, from: createdAt), month: month,
                           day: day, hour: hour, minute: minute)
    guard var fire = calendar.date(from: c) else { return nil }
    if fire.addingTimeInterval(60) <= createdAt, let year = c.year {
        c.year = year + 1
        fire = calendar.date(from: c) ?? fire
    }
    return fire.addingTimeInterval(60)
}
