import Darwin
import Foundation

// Brings an interactive Codex launch past codex's own startup update menu, which nobody answers in
// a window Tally opened unattended: update first with `codex update` (the same action the menu's
// "Update now" runs, same install-method detection, no confirmation), and open with the menu
// switched off only when that could not be done. Switching it off unconditionally would also stop
// codex refreshing version.json, so Tally would never see a newer version again.

let codexUpdateTimeout: TimeInterval = 180
private let codexUpdateStateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tally")
/// Once per process: true when the launch must open with the menu switched off.
nonisolated(unsafe) private var codexUpdateSkipMenu: Bool?

private struct CodexUpdateAttempt: Codable {
    var version: String
    var failedAt: Date
}

func prepareCodexLaunch(_ args: [String], home: String, interactive: Bool) -> [String] {
    let typed = optionsOnly(args)
    guard interactive, !typed.contains(where: { ["--help", "-h", "--version", "-V"].contains($0) }),
          [nil, "resume", "fork"].contains(codexSubcommand(typed)),
          !codexTypedConfigOverride(typed, keys: ["check_for_update_on_startup"]) else { return args }
    let skip = codexUpdateSkipMenu ?? runCodexUpdatePreflight(home: home)
    codexUpdateSkipMenu = skip
    return skip ? injectingOptions(args, ["-c", "check_for_update_on_startup=false"]) : args
}

/// True when the update menu would still come up and has to be switched off for this launch.
private func runCodexUpdatePreflight(home: String) -> Bool {
    let homeURL = URL(fileURLWithPath: home)
    let config = (try? String(contentsOf: homeURL.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
    // Files only on the common path: `codex --version` runs only when the cache names a candidate.
    guard let candidate = codexCachedUpdateCandidate(
        cache: try? Data(contentsOf: homeURL.appendingPathComponent("version.json")),
        checkDisabled: codexConfigDisablesUpdateCheck(config)) else { return false }
    let codex = resolveProviderExecutable("codex")
    switch codexUpdateNeed(candidate: candidate, installed: codexInstalledVersionRemembered(codex)) {
    case .none:
        return false
    case .installedUnknown(let latest):
        warn(codexUpdateFailureLine(latest: latest, reason: "could not read the installed codex version"))
        return true
    case .available(let latest):
        return !updateCodex(codex, to: latest, home: home)
    }
}

private func updateCodex(_ codex: String, to latest: String, home: String) -> Bool {
    let attemptURL = codexUpdateStateDir.appendingPathComponent("codex-update-attempt.json")
    let decoder = JSONDecoder(), encoder = JSONEncoder()
    decoder.dateDecodingStrategy = .iso8601
    encoder.dateEncodingStrategy = .iso8601
    let attempt = (try? Data(contentsOf: attemptURL)).flatMap { try? decoder.decode(CodexUpdateAttempt.self, from: $0) }
    if let attempt, codexUpdateBackedOff(attempt: (attempt.version, attempt.failedAt), latest: latest, now: Date()) {
        let minutes = Int(Date().timeIntervalSince(attempt.failedAt) / 60)
        warn(codexUpdateFailureLine(latest: latest, reason: "last attempt failed \(minutes)m ago"))
        return false
    }
    warn("Codex \(latest) is available; running `codex update` before opening (up to 3 min)...")
    let deadline = Date().addingTimeInterval(codexUpdateTimeout)
    func fail(_ reason: String) -> Bool {
        if let data = try? encoder.encode(CodexUpdateAttempt(version: latest, failedAt: Date())) {
            try? data.write(to: attemptURL, options: .atomic)
        }
        warn(codexUpdateFailureLine(latest: latest, reason: reason))
        return false
    }

    // Several windows opening at once update once: the rest wait here, then find it done.
    try? FileManager.default.createDirectory(at: codexUpdateStateDir, withIntermediateDirectories: true)
    let lock = open(codexUpdateStateDir.appendingPathComponent("codex-update.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    defer { if lock >= 0 { close(lock) } }
    while lock >= 0, flock(lock, LOCK_EX | LOCK_NB) != 0 {
        guard Date() < deadline else { return fail("timed out after \(Int(codexUpdateTimeout))s") }
        usleep(200_000)
    }
    if let installed = codexInstalledVersion(codex), !codexIsNewer(latest, than: installed) { return true }

    let run = codexRunInherited([codex, "update"], home: home, deadline: deadline)
    if run.timedOut { return fail("timed out after \(Int(codexUpdateTimeout))s") }
    guard let status = run.status else { return fail("codex update could not start") }
    guard status == 0 else { return fail("codex update exited with status \(status)") }
    // rc 0 alone is not proof: a package manager that finds nothing to do also exits 0.
    guard let after = codexInstalledVersion(codex) else { return fail("could not read the installed codex version") }
    guard !codexIsNewer(latest, than: after) else { return fail("still at \(after) after the update") }
    try? FileManager.default.removeItem(at: attemptURL)
    warn("Codex updated to \(after)")
    return true
}

/// What `codex --version` said for one executable file. The cache usually names the installed
/// version itself, so without this every launch would run a child process to learn nothing new.
private struct CodexInstalledStamp: Codable {
    var path: String
    var modified: Double
    var size: UInt64
    var version: String
}

/// `codex --version`, read back while the resolved executable is the same file (path, mtime, size).
/// An upgrade replaces that file (brew points the link at a new Caskroom directory), so it asks again.
private func codexInstalledVersionRemembered(_ codex: String) -> String? {
    let url = codexUpdateStateDir.appendingPathComponent("codex-installed-version.json")
    let resolved = URL(fileURLWithPath: codex).resolvingSymlinksInPath().path
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
          let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970,
          let size = (attributes[.size] as? NSNumber)?.uint64Value else { return codexInstalledVersion(codex) }
    if let data = try? Data(contentsOf: url),
       let stamp = try? JSONDecoder().decode(CodexInstalledStamp.self, from: data),
       stamp.path == resolved, stamp.modified == modified, stamp.size == size {
        return stamp.version
    }
    guard let version = codexInstalledVersion(codex) else { return nil }
    if let data = try? JSONEncoder().encode(CodexInstalledStamp(path: resolved, modified: modified,
                                                                size: size, version: version)) {
        try? FileManager.default.createDirectory(at: codexUpdateStateDir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
    return version
}

private func codexInstalledVersion(_ codex: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [codex, "--version"]
    process.standardInput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return nil }
    let deadline = Date().addingTimeInterval(10)
    while process.isRunning, Date() < deadline { usleep(20_000) }
    if process.isRunning {
        process.terminate()
        return nil
    }
    return codexVersionFromOutput(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

/// Runs `argv` with the terminal's output (the person or the tmux pane sees the package manager's
/// progress, as with the menu's own update) and stdin on /dev/null, so a prompt fails instead of
/// hanging. Its own process group, so a timeout takes the package manager's children with it.
private func codexRunInherited(_ argv: [String], home: String, deadline: Date) -> (status: Int32?, timedOut: Bool) {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { return (nil, false) }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawnattr_init(&attributes) == 0 else { return (nil, false) }
    defer { posix_spawnattr_destroy(&attributes) }
    guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0,
          posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0 else { return (nil, false) }
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = home
    var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cArgs.append(nil)
    var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
    cEnv.append(nil)
    defer { for pointer in cArgs + cEnv { free(pointer) } }

    var pid: pid_t = 0
    guard posix_spawnp(&pid, argv[0], &actions, &attributes, cArgs, cEnv) == 0 else { return (nil, false) }
    var status: Int32 = 0
    while waitpid(pid, &status, WNOHANG) != pid {
        guard Date() < deadline else {
            killpg(pid, SIGTERM)
            let graceEnd = Date().addingTimeInterval(5)
            var reaped = false
            while Date() < graceEnd {
                if waitpid(pid, &status, WNOHANG) == pid { reaped = true; break }
                usleep(100_000)
            }
            killpg(pid, SIGKILL)
            if !reaped { _ = waitpid(pid, &status, 0) }
            return (nil, true)
        }
        usleep(100_000)
    }
    let signal = status & 0x7f
    return (signal == 0 ? (status >> 8) & 0xff : 128 + signal, false)
}
