import Foundation
import CoreServices
import Darwin

/// THE READINGS BEHIND THE EVIDENCE FILE (B-4616); the rules are ProcessForensicsLogic.swift's.
/// Every reading is bounded by its own timeout, none needs root, and none reads an argument vector
/// (names and paths only, the rule ProcessCPUWatchReaders states). Call all of it OFF the main thread.
enum ProcessForensicsReaders {
    // MARK: - subprocesses

    /// Output of a tool, read to the end BEFORE waiting (the table can outgrow a pipe buffer; the
    /// rule ProcessCPUWatchReaders.table states), ended with SIGTERM when it outlives `timeout`.
    private static func run(_ path: String, _ arguments: [String],
                            timeout: TimeInterval) -> Result<String, ProcessForensicsFailure> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        task.environment = environment
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return .failure(ProcessForensicsFailure(reason: "could not start \(path)")) }
        let pid = task.processIdentifier
        let watchdog = DispatchWorkItem { if pid > 0 { kill(pid, SIGTERM) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()
        if task.terminationReason == .uncaughtSignal {
            return .failure(ProcessForensicsFailure(reason: "timeout after \(Int(timeout)) s"))
        }
        let text = String(decoding: data, as: UTF8.self)
        if task.terminationStatus != 0 && text.isEmpty {
            return .failure(ProcessForensicsFailure(reason: "\(path) exited \(task.terminationStatus)"))
        }
        return .success(text)
    }

    // MARK: - libproc

    private static func writtenBytes(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return rc == 0 ? info.ri_diskio_byteswritten : nil
    }

    /// `proc_pid_rusage` answers -1 for another user's process: that, and not a path guess, decides
    /// whether `sample` can work.
    static func canRead(_ pid: Int32) -> Bool { writtenBytes(pid) != nil }

    private static func allPids() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return filled > 0 ? Array(pids.prefix(Int(filled)).filter { $0 > 0 }) : []
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "?" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Bytes each process of this account wrote during `seconds`, the heaviest ten.
    static func writers(seconds: Double) -> Result<String, ProcessForensicsFailure> {
        func snapshot() -> [pid_t: UInt64] {
            Dictionary(allPids().compactMap { pid in writtenBytes(pid).map { (pid, $0) } },
                       uniquingKeysWith: { a, _ in a })
        }
        let before = snapshot()
        guard !before.isEmpty else { return .failure(ProcessForensicsFailure(reason: "no process readable")) }
        Thread.sleep(forTimeInterval: seconds)
        let after = snapshot()
        let rows = after.compactMap { pid, now -> (pid_t, UInt64)? in
            guard let was = before[pid], now > was else { return nil }
            return (pid, now - was)
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.prefix(10)
        let lines = rows.map { "\($0.1) bytes  pid \($0.0)  \(keystrokeStripped(name(of: $0.0)))" }
        return .success("readable=\(after.count)\n" + (lines.isEmpty ? "(no writes seen)" : lines.joined(separator: "\n")))
    }

    // MARK: - FSEvents

    private final class PathCounts {
        let lock = NSLock()
        var counts: [String: Int] = [:]
        var events = 0
        func add(_ paths: [String]) {
            lock.lock(); defer { lock.unlock() }
            for path in paths {
                events += 1
                let prefix = "/" + path.split(separator: "/").prefix(4).joined(separator: "/")
                counts[prefix, default: 0] += 1
            }
        }
    }

    /// The machine-wide stream a user may subscribe to: which paths are being written, by their
    /// first four components, the thirty busiest. No pid comes with it; the prefix usually names the writer.
    static func fsEvents(seconds: Double) -> Result<String, ProcessForensicsFailure> {
        let box = PathCounts()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info, count > 0 else { return }
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            Unmanaged<PathCounts>.fromOpaque(info).takeUnretainedValue().add(list)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, ["/"] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else {
            return .failure(ProcessForensicsFailure(reason: "FSEventStreamCreate failed"))
        }
        let queue = DispatchQueue(label: "ai.jetto.tally.process-forensics.fsevents")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return .failure(ProcessForensicsFailure(reason: "FSEventStreamStart failed"))
        }
        Thread.sleep(forTimeInterval: seconds)
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // Stop is asynchronous on the stream's queue; reading through the same queue waits for it.
        let (events, counts) = queue.sync { box.lock.lock(); defer { box.lock.unlock() }; return (box.events, box.counts) }
        let top = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(30)
        return .success("events=\(events)\n" + top.map { "\($0.value)  \(keystrokeStripped($0.key))" }.joined(separator: "\n"))
    }

    // MARK: - the rest

    /// Which pids keep registering a listener with fseventsd, from the unified log (readable by any user).
    static func registrations() -> Result<String, ProcessForensicsFailure> {
        let result = run("/usr/bin/log", ["show", "--last", "15m", "--style", "compact", "--predicate",
                                          "process == \"fseventsd\" AND eventMessage CONTAINS \"fsevent_add_client\""],
                         timeout: 30)
        guard case .success(let text) = result else { return result }
        var counts: [String: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: " for pid ") else { continue }
            let digits = line[range.upperBound...].prefix(while: \.isNumber)
            if !digits.isEmpty { counts[String(digits), default: 0] += 1 }
        }
        let top = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(10)
        return .success(top.isEmpty ? "(no registrations seen)"
                        : top.map { "\($0.value)  pid \($0.key)" }.joined(separator: "\n"))
    }

    /// The real probes. `seconds` is how long the sampling ones watch (10 in the app, 1 in a test).
    static func live(seconds: Double) -> ProcessForensicsProbes {
        ProcessForensicsProbes(
            canRead: { canRead($0) },
            sample: { run("/usr/bin/sample", [String($0), String(Int(max(1, seconds))), "-mayDie"], timeout: seconds + 40) },
            fsEvents: { fsEvents(seconds: seconds) },
            writers: { writers(seconds: seconds) },
            threads: { run("/bin/ps", ["-M", "-p", String($0)], timeout: 5) },
            registrations: { registrations() })
    }

    // MARK: - the folder

    static func entries(in directory: URL) -> [ProcessForensicsEntry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension == "txt" }.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), let size = values.fileSize,
                  let modified = values.contentModificationDate else { return nil }
            return ProcessForensicsEntry(name: url.lastPathComponent, size: size, modified: modified)
        }
    }

    /// Capture and write: prune first, then the file (0600). Blocks for as long as the slowest probe.
    @discardableResult
    static func write(_ plan: ProcessForensicsPlan, probes: ProcessForensicsProbes, directory: URL,
                      now: Date = Date()) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        for name in ProcessForensicsLogic.prune(entries(in: directory), now: now,
                                                reserve: ProcessForensicsLogic.maxFileBytes) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        let text = ProcessForensicsLogic.compose(plan, probes: probes)
        return fm.createFile(atPath: directory.appendingPathComponent(plan.fileName).path,
                             contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
    }
}
