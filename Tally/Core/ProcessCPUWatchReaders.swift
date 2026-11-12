import Foundation

/// THE ONE READING THE ONE-PROCESS CPU WATCH TAKES (B-4496): the machine's process table with each
/// process's cumulative CPU time. Foundation only, so tests/processcpu runs it for real.
///
/// WHY `/bin/ps` AND NOT LIBPROC, which every other reader here prefers. `proc_pid_rusage` answers
/// -1 for another user's process: on 2026-11-13, 226 of 1388 pids on this Mac, fseventsd among them,
/// and fseventsd was the process that held a core for an hour. `/bin/ps` is setuid root and sees all
/// of them. One run costs about 0.07 s of wall clock and 0.04 s of CPU, once a minute.
enum ProcessCPUWatchReaders {
    enum Failure: String, Error {
        /// `ps` could not be started.
        case spawn
        /// `ps` did not finish in time and was terminated.
        case timeout
        /// `ps` ran and printed nothing.
        case empty
    }

    /// `ps -A -o pid=,etime=,cputime=,comm=` (`comm` is the executable path, never argv, so no
    /// argument that carries a secret can reach the log). Call it OFF the main thread.
    static func table(timeout: TimeInterval = 5) -> Result<String, Failure> {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid=,etime=,cputime=,comm="]
        // The C locale, so a decimal comma never reaches the parser.
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        ps.environment = environment
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return .failure(.spawn) }
        let pid = ps.processIdentifier
        let watchdog = DispatchWorkItem { if pid > 0 { kill(pid, SIGTERM) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Read before waiting: the table is far larger than a pipe buffer, and waiting first is the
        // deadlock this repo has already paid for once (PromptHookBackstop.swift states the rule).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        watchdog.cancel()
        if ps.terminationReason == .uncaughtSignal { return .failure(.timeout) }
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return .failure(.empty) }
        return .success(text)
    }
}
