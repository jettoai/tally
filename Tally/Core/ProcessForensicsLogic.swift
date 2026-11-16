import Foundation

// THE RULES OF THE EVIDENCE FILE THE ONE-PROCESS CPU WATCH LEAVES BEHIND (B-4616). Foundation only,
// so tests/processcpu compiles it with fake probes and a fixture clock.
//
// WHY A FILE. On 2026-11-13 fseventsd held a core for an hour and the only trace was one
// `process-cpu=alarm` line: nobody could tell afterwards what was hammering it. The file is written
// within seconds of the alarm, while the cause is still running.
//
// WHAT NEEDS NO PRIVILEGE. `sample` works on this user's own processes only. For a root process
// (fseventsd) the file carries what an ordinary user can read: the paths the whole machine is
// writing, who in this account writes most, the process's threads, and (fseventsd only) who keeps
// registering listeners with it. The header says so (`privilege=none missing=root`), so a missing
// stack reads as a permission gap and not as a failed capture. With the one-time root helper
// installed (ProcessForensicsPrivilege.swift) the same file also carries `sample` and `fs_usage`.
//
// THE FILE IS ALWAYS WRITTEN, even when every probe failed: the log line and the banner name it
// before it exists, and a name pointing at nothing is worse than a file that says why it is empty.

/// What one alarm got: a file (complete or partial) or the reason there is none.
enum ProcessForensicsOutcome: Equatable, Sendable {
    case file(String, partial: Bool)
    case skipped(String)
}

/// One alarmed process, as far as the capture needs to know it.
struct ProcessForensicsPlan: Equatable, Sendable {
    var pid: Int32
    var name: String
    var path: String
    var percent: Double?
    var since: Date
    /// `pid` plus start time: the same process alarming twice is one capture.
    var identity: String
    var fileName: String
    var capturedAt: Date
}

struct ProcessForensicsEntry: Equatable, Sendable {
    var name: String
    var size: Int
    var modified: Date
}

enum ProcessForensicsDecision: Equatable, Sendable { case capture, repeated, rateLimited }

/// Every reading the capture takes, injected so a test drives the file's shape without a machine.
struct ProcessForensicsProbes: Sendable {
    /// Whether this user may inspect the pid (`proc_pid_rusage` answers).
    var canRead: @Sendable (Int32) -> Bool
    var sample: @Sendable (Int32) -> Result<String, ProcessForensicsFailure>
    var fsEvents: @Sendable () -> Result<String, ProcessForensicsFailure>
    var writers: @Sendable () -> Result<String, ProcessForensicsFailure>
    var threads: @Sendable (Int32) -> Result<String, ProcessForensicsFailure>
    var registrations: @Sendable () -> Result<String, ProcessForensicsFailure>
    /// Whether `sudo -n -l` lets this account run the root helper (`tally forensics setup`): the one way
    /// to get `sample` and `fs_usage` of a process that is not this account's.
    var rootHelper: @Sendable () -> Bool = { false }
    var privileged: @Sendable (Int32) -> Result<String, ProcessForensicsFailure> =
        { _ in .failure(ProcessForensicsFailure(reason: "no root helper")) }
}

struct ProcessForensicsFailure: Error, Equatable, Sendable { var reason: String }

typealias ProcessForensicsJob = @Sendable () -> Result<String, ProcessForensicsFailure>

/// The probes' answers, one slot each, written from several threads at once.
private final class ProcessForensicsResults: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [Result<String, ProcessForensicsFailure>?]
    init(count: Int) { slots = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ result: Result<String, ProcessForensicsFailure>) {
        lock.lock(); slots[index] = result; lock.unlock()
    }
    var all: [Result<String, ProcessForensicsFailure>?] { lock.lock(); defer { lock.unlock() }; return slots }
}

enum ProcessForensicsLogic {
    static let maxFileBytes = 5 * 1024 * 1024
    static let maxDirectoryBytes = 100 * 1024 * 1024
    static let retention: TimeInterval = 14 * 86_400
    static let rateWindow: TimeInterval = 86_400
    static let maxPerWindow = 12
    static let maxNameLength = 40
    static let folder = "process-forensics"

    /// Next to the watch's log, Dev and other unshipped builds in their own folder.
    static func directory(unshipped: Bool) -> URL {
        ProcessCPUWatchLogic.logFile(unshipped: unshipped).deletingLastPathComponent()
            .appendingPathComponent(folder, isDirectory: true)
    }

    // MARK: - names

    /// Allowed characters only (`[A-Za-z0-9._-]`), at most 40 of them.
    static func safeName(_ raw: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let kept = String(keystrokeStripped(raw).filter { allowed.contains($0) }.prefix(maxNameLength))
        return kept.isEmpty ? "unknown" : kept
    }

    /// `20261115T050301Z-pid665-fseventsd.txt`: UTC, no colon.
    static func fileName(pid: Int32, name: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return "\(formatter.string(from: date))-pid\(pid)-\(safeName(name)).txt"
    }

    static func identity(pid: Int32, startedAt: Date) -> String {
        "\(pid)@\(Int(startedAt.timeIntervalSince1970))"
    }

    // MARK: - how many, how long kept

    /// The same process never twice; and at most 12 files in any 24 hours, counting the ones this
    /// reading has already accepted (`accepted`) because they are not on disk yet.
    static func decide(identity: String, seen: Set<String>, entries: [ProcessForensicsEntry],
                       accepted: Int, now: Date) -> ProcessForensicsDecision {
        if seen.contains(identity) { return .repeated }
        let recent = entries.filter { now.timeIntervalSince($0.modified) < rateWindow }.count + accepted
        return recent >= maxPerWindow ? .rateLimited : .capture
    }

    /// The names to delete before a new file goes in: older than 14 days, then the oldest until the
    /// rest, plus `reserve` for the file about to be written, fits in 100 MB.
    static func prune(_ entries: [ProcessForensicsEntry], now: Date, reserve: Int = 0) -> [String] {
        var doomed = entries.filter { now.timeIntervalSince($0.modified) > retention }.map(\.name)
        var kept = entries.filter { now.timeIntervalSince($0.modified) <= retention }
            .sorted { $0.modified < $1.modified }
        var total = kept.reduce(0) { $0 + $1.size } + reserve
        while total > maxDirectoryBytes, let oldest = kept.first {
            doomed.append(oldest.name)
            total -= oldest.size
            kept.removeFirst()
        }
        return doomed
    }

    /// The text cut to fit in 5 MB with the marker, never longer than the limit in bytes.
    static func clipped(_ text: String, limit: Int = maxFileBytes) -> String {
        guard text.utf8.count > limit else { return text }
        let marker = "\ntruncated=yes\n"
        let room = max(0, limit - marker.utf8.count)
        return String(decoding: Array(text.utf8.prefix(room)), as: UTF8.self) + marker
    }

    // MARK: - the file

    private static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private static func section(_ title: String, _ result: Result<String, ProcessForensicsFailure>) -> String {
        switch result {
        case .success(let text): return "\n== \(title) ==\n\(text)\(text.hasSuffix("\n") ? "" : "\n")"
        case .failure(let failure): return "\n== \(title) ==\nunavailable: \(failure.reason)\n"
        }
    }

    /// The whole file. Probes run side by side so the capture takes as long as the slowest one.
    /// Blocking: call it off the main thread.
    static func compose(_ plan: ProcessForensicsPlan, probes: ProcessForensicsProbes) -> String {
        let own = probes.canRead(plan.pid)
        // Asked at capture time, so a rule removed since the alarm falls back to the no-root file.
        let root = !own && probes.rootHelper()
        var queued: [(String, ProcessForensicsJob)] = []
        if own { queued.append(("sample", { probes.sample(plan.pid) })) }
        queued.append(("fsevents paths (machine-wide)", { probes.fsEvents() }))
        queued.append(("writes by this account", { probes.writers() }))
        if !own {
            queued.append(("threads (ps -M)", { probes.threads(plan.pid) }))
            if plan.name == "fseventsd" {
                queued.append(("fseventsd listener registrations (last 15 min)", { probes.registrations() }))
            }
        }
        // Last on purpose: fs_usage is machine-wide and can fill the whole 5 MB, so the clip must cut its tail, not the parts above.
        if root { queued.append(("sample and fs_usage (root helper)", { probes.privileged(plan.pid) })) }
        let jobs = queued
        let results = ProcessForensicsResults(count: jobs.count)
        DispatchQueue.concurrentPerform(iterations: jobs.count) { results.set($0, jobs[$0].1()) }
        var text = "tally process forensics v1\n"
        text += "captured=\(stamp(plan.capturedAt)) pid=\(plan.pid) name=\(plan.name)\n"
        text += "path=\(keystrokeStripped(plan.path))\n"
        text += "over_since=\(stamp(plan.since))"
        if let percent = plan.percent { text += " pct=\(Int(percent.rounded()))" }
        if own {
            text += "\nprivilege=own\n"
        } else if root {
            text += "\nprivilege=root (sample, fs_usage through the Tally evidence helper)\n"
        } else {
            text += "\nprivilege=none missing=root (sample, fs_usage need root)\n"
        }
        for (job, result) in zip(jobs, results.all) {
            text += section(job.0, result ?? .failure(ProcessForensicsFailure(reason: "not run")))
        }
        return clipped(text)
    }

    // MARK: - the words

    /// The banner's last line: where the file is, and for a root process what it lacks.
    static func noticeLine(_ outcome: ProcessForensicsOutcome, localized: (String) -> String) -> String? {
        guard case .file(let name, let partial) = outcome else { return nil }
        let place = "\(folder)/\(name)"
        return String(format: localized(partial
            ? "Partial evidence (no root permission for sample and fs_usage): %@" : "Evidence: %@"), place)
    }

    /// The log token: the file's name, or `skipped_<why>`.
    static func logToken(_ outcome: ProcessForensicsOutcome) -> String {
        switch outcome {
        case .file(let name, _): return name
        case .skipped(let why): return "skipped_\(why)"
        }
    }
}
