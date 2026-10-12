import Darwin
import Foundation

/// Where provider CLIs live on this machine, as the user's own login shell sees it.
///
/// A GUI app inherits launchd's PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), so a CLI installed under a
/// version manager or a custom npm prefix (nvm, fnm, volta, asdf, `~/.local/node`) is invisible to
/// it. And an npm CLI that IS found still cannot start: its first line is `#!/usr/bin/env node`, and
/// `node` is not on that PATH either (issue #8). The login shell is asked once for its PATH, off the
/// main thread, and that one answer serves both questions: where a CLI is, and which PATH the
/// child it runs gets.
///
/// Once read, the login PATH is kept for the app's lifetime (running the user's rc files again on
/// every miss would repeat their side effects); only a failed read is retried, after a pause.
///
/// Only PATH is taken from the shell, never the rest of its environment: a variable such as
/// `CLAUDE_CONFIG_DIR` exported by an rc file would otherwise override the account Tally picked.
final class CLISearchPath: @unchecked Sendable {
    static let shared = CLISearchPath()

    static let beginMarker = "__TALLY_LOGIN_PATH_BEGIN__"
    static let endMarker = "__TALLY_LOGIN_PATH_END__"

    let home: String
    let systemDirectories: [String]
    let loginShell: String
    let shimDirectory: String
    let probeTimeout: TimeInterval
    let retryAfterFailure: TimeInterval

    // Guarded by `lock`.
    private let lock = NSLock()
    private var cached: [String]?
    private var lastProbe: Date?
    private var inFlight: DispatchGroup?

    init(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
         systemDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin"],
         loginShell: String = CLISearchPath.userShell(),
         // Mirrors IntegrationsStore.binDirURL (~/.tally/bin), as TallyCLI's tallyShimDirectory
         // does; not imported, because the small test suites compile this file on its own.
         shimDirectory: String = FileManager.default.homeDirectoryForCurrentUser
             .appendingPathComponent(".tally/bin", isDirectory: true).path,
         probeTimeout: TimeInterval = 5,
         retryAfterFailure: TimeInterval = 300) {
        self.home = home
        self.systemDirectories = systemDirectories
        self.loginShell = loginShell
        self.shimDirectory = URL(fileURLWithPath: shimDirectory).resolvingSymlinksInPath().path
        self.probeTimeout = probeTimeout
        self.retryAfterFailure = retryAfterFailure
    }

    /// Starts reading the login PATH in the background, so the first refresh finds it ready.
    func warm() { _ = loginPATH(waitIfCold: false) }

    /// The CLI's path, or nil. The fixed install locations first (what every release before this
    /// one checked, so a typical install resolves exactly as before and without waiting), then the
    /// login shell's PATH, then the app's own. Tally's shim directory is skipped everywhere.
    ///
    /// On the main thread this never waits for the shell: with nothing cached yet it answers from
    /// the other two sources and leaves the read running for the next caller.
    func resolve(_ name: String) -> String? {
        let fixed = ["\(home)/.local/bin"] + systemDirectories + ["\(home)/.claude/local"]
        if let hit = firstRunnable(name, in: fixed) { return hit }
        if let login = loginPATH(waitIfCold: !Thread.isMainThread),
           let hit = firstRunnable(name, in: login) { return hit }
        return firstRunnable(name, in: Self.split(ProcessInfo.processInfo.environment["PATH"]))
    }

    /// PATH for a child that runs `executable`: the executable's own directory first (an npm CLI's
    /// `node` usually sits right beside it), then the login shell's PATH, then the app's. The shim
    /// directory is left out, so a CLI the app runs never lands back in account picking.
    func childPATH(for executable: String, inherited: String?) -> String {
        var entries: [String] = []
        if executable.hasPrefix("/") {
            entries.append((executable as NSString).deletingLastPathComponent)
        }
        entries += loginPATH(waitIfCold: !Thread.isMainThread) ?? []
        entries += Self.split(inherited)
        var seen = Set<String>()
        return entries.filter { !isShimDirectory($0) && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    /// `base` with PATH replaced by `childPATH`. Every spawn of a resolved provider CLI goes
    /// through here.
    func environment(for executable: String,
                     base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["PATH"] = childPATH(for: executable, inherited: base["PATH"])
        return env
    }

    // MARK: - Login PATH cache

    func loginPATH(waitIfCold: Bool) -> [String]? {
        lock.lock()
        if let cached { lock.unlock(); return cached }
        let due = lastProbe.map { Date().timeIntervalSince($0) >= retryAfterFailure } ?? true
        let group = inFlight ?? (due ? startProbeLocked() : nil)
        lock.unlock()
        guard waitIfCold, let group else { return nil }
        _ = group.wait(timeout: .now() + probeTimeout + 1)
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// Caller holds `lock`.
    private func startProbeLocked() -> DispatchGroup {
        let group = DispatchGroup()
        group.enter()
        inFlight = group
        let shell = loginShell, timeout = probeTimeout
        DispatchQueue.global(qos: .utility).async { [self] in
            let answer = Self.probe(shell: shell, timeout: timeout)
            lock.lock()
            cached = answer
            lastProbe = Date()
            inFlight = nil
            lock.unlock()
            group.leave()
        }
        return group
    }

    // MARK: - The shell

    /// The user's login shell: the account record first (a GUI app's SHELL is not guaranteed),
    /// then SHELL, then zsh. Only shells whose flags below are known are used.
    static func userShell() -> String {
        var candidates: [String] = []
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            candidates.append(String(cString: shell))
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"] { candidates.append(shell) }
        return candidates.first {
            knownShells.contains(($0 as NSString).lastPathComponent)
                && FileManager.default.isExecutableFile(atPath: $0)
        } ?? "/bin/zsh"
    }

    private static let knownShells: Set<String> = ["zsh", "bash", "fish", "sh", "ksh", "dash"]

    static func arguments(forShell shell: String) -> [String] {
        let script = "/bin/echo \(beginMarker); /usr/bin/printenv PATH; /bin/echo \(endMarker)"
        // Interactive too: nvm and fnm put their setup in .zshrc / .bashrc, which only an
        // interactive shell reads.
        let interactive = ["zsh", "bash", "fish"].contains((shell as NSString).lastPathComponent)
        return (interactive ? ["-i", "-l", "-c"] : ["-l", "-c"]) + [script]
    }

    /// One login shell's PATH, or nil. Never waits for end of file: an rc file that leaves a
    /// background job holding stdout would otherwise hold this read open with it. Waits for the
    /// end marker, end of file, or the timeout, whichever comes first.
    static func probe(shell: String, timeout: TimeInterval) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments(forShell: shell)
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        let collected = ProbeOutput()
        let finished = DispatchSemaphore(value: 0)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty || collected.append(chunk) { finished.signal() }
        }
        guard (try? process.run()) != nil else {
            stdout.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        _ = finished.wait(timeout: .now() + timeout)
        stdout.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        return parse(collected.text)
    }

    /// The PATH between the last begin marker and the end marker after it. Anything an rc file
    /// prints around them, including text that looks like a PATH, is ignored.
    static func parse(_ output: String) -> [String]? {
        guard let begin = output.range(of: beginMarker + "\n", options: .backwards),
              let end = output.range(of: "\n" + endMarker, range: begin.upperBound..<output.endIndex)
        else { return nil }
        let entries = split(String(output[begin.upperBound..<end.lowerBound]))
        return entries.isEmpty ? nil : entries
    }

    static func split(_ path: String?) -> [String] {
        (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - Walking directories

    private func firstRunnable(_ name: String, in directories: [String]) -> String? {
        for directory in directories where !isShimDirectory(directory) {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            guard Self.isRunnableFile(candidate.path) else { continue }
            // The file itself may be a symlink onto the shim script.
            if isUnderShim(candidate.resolvingSymlinksInPath().path) { continue }
            return candidate.path   // unresolved: its directory is what childPATH puts first
        }
        return nil
    }

    private func isShimDirectory(_ directory: String) -> Bool {
        isUnderShim(URL(fileURLWithPath: directory).resolvingSymlinksInPath().path)
    }

    private func isUnderShim(_ path: String) -> Bool {
        path == shimDirectory || path.hasPrefix(shimDirectory + "/")
    }

    /// Executable, existing, and not a directory (a searchable directory passes X_OK).
    private static func isRunnableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}

/// The probe's stdout so far. A class with its own lock because the readability handler runs on a
/// queue of the system's choosing while the caller reads the result after its wait.
private final class ProbeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private static let end = Data(CLISearchPath.endMarker.utf8)

    /// Appends, and answers whether the end marker has arrived.
    func append(_ chunk: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        return data.range(of: Self.end) != nil
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
