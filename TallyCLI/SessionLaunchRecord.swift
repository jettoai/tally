import Foundation

/// HOW A SUPERVISED SESSION WAS LAUNCHED, kept beside its presence entry in `supervisorStateDir` as
/// `<supervisorPID>.launch` so a later build can open the same session again after a reboot: the
/// directory it ran in, the arguments it was started with, the tmux session it lived in and the
/// terminal program it was typed into. Written once at start-up by both supervisors.
///
/// The same rules as every other document on that track: best-effort (a failed write costs the
/// restore, never the session), read only while the supervisor is alive (a dead pid's file is
/// swept with the rest by suffix, `supervisorStateSuffixes`), and fields are only ever ADDED. A
/// field added later must be optional, so a record an older build wrote still decodes.
///
/// NO CREDENTIAL IS EVER HERE. `args` is the command line the user typed (it may carry their first
/// prompt, which is why the file is owner-only); the account, the pin and the token are not part of
/// a launch and are not recorded.
struct SessionLaunchRecord: Codable, Equatable {
    var cwd: String
    /// The arguments after `tally claude` / `tally codex`, as received.
    var args: [String]
    /// `#S` of the tmux session the supervisor runs in; empty outside tmux or when tmux did not answer.
    var tmuxSession: String
    /// `$TERM_PROGRAM` (ghostty, Apple_Terminal, iTerm.app, tmux...); empty when unset.
    var terminal: String
    /// "claude" or "codex".
    var provider: String
}

/// Registered by literal in `supervisorStateSuffixes` (PendingNotice.swift), which keeps that list
/// free of a dependency on this file; a test holds the two spellings together.
let sessionLaunchSuffix = ".launch"

func sessionLaunchFile(pid: String, dir: URL = supervisorStateDir) -> URL {
    dir.appendingPathComponent(pid + sessionLaunchSuffix)
}

extension SessionLaunchRecord {
    /// Atomic, owner-only. Best-effort: nothing is thrown.
    func write(pid: String, dir: URL = supervisorStateDir) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        let file = sessionLaunchFile(pid: pid, dir: dir)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// The record of a LIVE supervisor, or nil when there is none, it is damaged, or the pid is no
    /// longer a supervisor of ours. `isLive` is injectable so a test needs no real process.
    static func read(pid: String, dir: URL = supervisorStateDir,
                     isLive: ((pid_t) -> Bool)? = nil) -> SessionLaunchRecord? {
        guard let number = pid_t(pid) else { return nil }
        let live = isLive ?? { supervisorPresenceIsLive(pid: $0, dir: dir) }
        guard live(number),
              let data = try? Data(contentsOf: sessionLaunchFile(pid: pid, dir: dir)) else { return nil }
        return try? JSONDecoder().decode(SessionLaunchRecord.self, from: data)
    }

    /// The record for a launch happening now. `tmuxName` is asked only when `$TMUX` is set.
    static func current(provider: String, args: [String], cwd: String,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        tmuxName: () -> String? = { sessionLaunchTmuxName() }) -> SessionLaunchRecord {
        let inTmux = !(environment["TMUX"] ?? "").isEmpty
        return SessionLaunchRecord(cwd: realpathString(cwd), args: args,
                                   tmuxSession: inTmux ? (tmuxName() ?? "") : "",
                                   terminal: environment["TERM_PROGRAM"] ?? "", provider: provider)
    }
}

/// Publish this supervisor's launch record. A self-update exec (`resumed`) keeps the record the
/// first image wrote: the arguments it inherited were rewritten for the new child, and the original
/// launch is the one worth reopening.
func publishSessionLaunch(provider: String, args: [String], cwd: String, pid: String,
                          resumed: Bool, dir: URL = supervisorStateDir) {
    if resumed, FileManager.default.fileExists(atPath: sessionLaunchFile(pid: pid, dir: dir).path) { return }
    SessionLaunchRecord.current(provider: provider, args: args, cwd: cwd).write(pid: pid, dir: dir)
}

/// The name of the tmux session this process runs in, or nil when tmux does not answer in time.
func sessionLaunchTmuxName(timeout: TimeInterval = 2) -> String? {
    let name = runWithTimeout("/usr/bin/env", ["tmux", "display-message", "-p", "#S"], timeout: timeout)
    return (name?.isEmpty ?? true) ? nil : name
}

/// Run a program and return its trimmed standard output, or nil when it cannot start, exits
/// non-zero, or is still running after `timeout` seconds (it is then terminated). Output is read
/// after exit, which is safe only for the few bytes the callers here expect.
func runWithTimeout(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    guard (try? process.run()) != nil else { return nil }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
