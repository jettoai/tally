import Darwin
import Foundation

// B-565: a claude launch execs the installer's app bundle when it is provably the current version,
// so macOS permissions survive Claude Code updates, and never an older version left in the bundle.
// The fake versions print "$0", the path they were executed through: the only reliable proof of
// which name ran (ps shows argv[0], and lsof / proc_pidpath name a hard link by whichever name the
// vnode cache holds).

private struct StableFixture {
    let root: URL
    let install: ClaudeNativeInstall
    var old: String { root.appendingPathComponent("versions/1.0.0").path }
    var latest: String { root.appendingPathComponent("versions/1.0.1").path }
    var macOS: URL { install.bundleExecutable.deletingLastPathComponent() }
    var bundle: String { install.bundleExecutable.path }
    var launcher: String { install.launcher.path }
}

private enum BundleShape { case sameInode, oldInode, emptyMacOS, noMacOS, symlinkToLatest, directory, noInfoPlist }

private func makeStableFixture(_ shape: BundleShape) -> StableFixture {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tally-stable-\(UUID().uuidString)")
    let fixture = StableFixture(root: root, install: ClaudeNativeInstall(
        launcher: root.appendingPathComponent("bin/claude"), root: root))
    try! fm.createDirectory(at: root.appendingPathComponent("versions"), withIntermediateDirectories: true)
    try! fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
    for version in [fixture.old, fixture.latest] {
        try! "#!/bin/bash\nprintf '%s' \"$0\" > \"$1\"\n".write(toFile: version, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: version)
    }
    try! fm.createSymbolicLink(atPath: fixture.launcher, withDestinationPath: fixture.latest)
    let contents = fixture.install.bundleContents
    try! fm.createDirectory(at: contents, withIntermediateDirectories: true)
    if shape != .noInfoPlist { try! "<plist/>".write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8) }
    if shape != .noMacOS { try! fm.createDirectory(at: fixture.macOS, withIntermediateDirectories: true) }
    switch shape {
    case .sameInode: precondition(link(fixture.latest, fixture.bundle) == 0)
    case .oldInode: precondition(link(fixture.old, fixture.bundle) == 0)
    case .symlinkToLatest: try! fm.createSymbolicLink(atPath: fixture.bundle, withDestinationPath: fixture.latest)
    case .directory:
        try! fm.createDirectory(atPath: fixture.bundle, withIntermediateDirectories: true)
        try! "x".write(toFile: fixture.bundle + "/keep", atomically: true, encoding: .utf8)
    case .emptyMacOS, .noMacOS, .noInfoPlist: break
    }
    return fixture
}

private func sameFile(_ a: String, _ b: String) -> Bool {
    var x = stat(), y = stat()
    return lstat(a, &x) == 0 && stat(b, &y) == 0 && x.st_dev == y.st_dev && x.st_ino == y.st_ino
}

private func isRegular(_ path: String) -> Bool {
    var s = stat()
    return lstat(path, &s) == 0 && (s.st_mode & S_IFMT) == S_IFREG
}

private func leftoverTemporaries(_ fixture: StableFixture) -> Bool {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: fixture.macOS.path)) ?? []
    return names.contains { $0.hasPrefix(".claude.tally-") }
}

private func allPaths(under root: URL) -> [String] {
    (FileManager.default.subpaths(atPath: root.path) ?? []).sorted()
}

/// Run `argv` through the real `spawnChild` with PATH pointed at the fixture's bin, and return the
/// "$0" the child wrote.
private func spawnedPath(_ argv: [String], path: String, install: ClaudeNativeInstall, in root: URL) -> String? {
    let marker = root.appendingPathComponent("ran-\(UUID().uuidString)")
    let previousPath = ProcessInfo.processInfo.environment["PATH"]
    setenv("PATH", path, 1)
    defer { if let previousPath { setenv("PATH", previousPath, 1) } else { unsetenv("PATH") } }
    guard let pid = spawnChild(argv + [marker.path], environment: ["PATH": path],
                               shimDirectory: root.appendingPathComponent("no-shim"),
                               claudeInstall: install) else { return nil }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1, errno == EINTR {}
    return try? String(contentsOf: marker, encoding: .utf8)
}

/// Same through the app's `CLIRunner.run`.
private func runnerPath(_ executable: String, install: ClaudeNativeInstall, in root: URL) -> String? {
    let marker = root.appendingPathComponent("ran-\(UUID().uuidString)").path
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        _ = await CLIRunner.run(executable, arguments: [marker], claudeInstall: install)
        done.signal()
    }
    done.wait()
    return try? String(contentsOfFile: marker, encoding: .utf8)
}

func runStableClaudeChecks() {
    let fm = FileManager.default

    // T1 (D1): already the current version: the bundle, nothing written.
    do {
        let f = makeStableFixture(.sameInode); defer { try? fm.removeItem(at: f.root) }
        let before = allPaths(under: f.root)
        check("stable: a bundle already on the latest inode is used as is",
              claudeStableExecutable(f.launcher, install: f.install) == f.bundle && allPaths(under: f.root) == before)
    }
    // T2 (D2): an older version in the bundle is re-linked, the old version stays installed.
    do {
        let f = makeStableFixture(.oldInode); defer { try? fm.removeItem(at: f.root) }
        let got = claudeStableExecutable(f.launcher, install: f.install)
        check("stable: an old bundle inode is re-linked to the latest and used",
              got == f.bundle && sameFile(f.bundle, f.latest) && fm.fileExists(atPath: f.old) && !leftoverTemporaries(f))
    }
    // T3 (D3) / T4 (D4): an empty or missing MacOS directory is filled in.
    for (shape, label) in [(BundleShape.emptyMacOS, "an empty MacOS directory"), (.noMacOS, "a missing MacOS directory")] {
        let f = makeStableFixture(shape); defer { try? fm.removeItem(at: f.root) }
        check("stable: \(label) gets the latest linked in",
              claudeStableExecutable(f.launcher, install: f.install) == f.bundle && sameFile(f.bundle, f.latest))
    }
    // T5 (D5): a symlink in the bundle would resolve back into versions/; it becomes a hard link.
    do {
        let f = makeStableFixture(.symlinkToLatest); defer { try? fm.removeItem(at: f.root) }
        check("stable: a symlinked bundle executable is replaced by a hard link",
              claudeStableExecutable(f.launcher, install: f.install) == f.bundle && isRegular(f.bundle) && sameFile(f.bundle, f.latest))
    }
    // T6 (D6): the bundle cannot be written: the launcher, the bundle untouched, no temporaries.
    do {
        let f = makeStableFixture(.oldInode)
        chmod(f.macOS.path, 0o555)
        defer { chmod(f.macOS.path, 0o755); try? fm.removeItem(at: f.root) }
        check("stable: an unwritable bundle falls back to the launcher and stays as it was",
              claudeStableExecutable(f.launcher, install: f.install) == f.launcher && sameFile(f.bundle, f.old) && !leftoverTemporaries(f))
    }
    // T7 (D6): a directory where the executable belongs: rename fails, nothing left behind.
    do {
        let f = makeStableFixture(.directory); defer { try? fm.removeItem(at: f.root) }
        check("stable: a directory in the bundle's place falls back to the launcher",
              claudeStableExecutable(f.launcher, install: f.install) == f.launcher && !leftoverTemporaries(f))
    }
    // T8 (D7): no installer bundle: unchanged, and nothing created.
    do {
        let f = makeStableFixture(.noInfoPlist); defer { try? fm.removeItem(at: f.root) }
        let before = allPaths(under: f.root)
        check("stable: without Info.plist the executable is returned untouched and nothing is created",
              claudeStableExecutable(f.launcher, install: f.install) == f.launcher && allPaths(under: f.root) == before)
    }
    // T9 (D9): asked for the bundle itself while it holds an old version that cannot be fixed.
    do {
        let f = makeStableFixture(.oldInode)
        chmod(f.macOS.path, 0o555)
        defer { chmod(f.macOS.path, 0o755); try? fm.removeItem(at: f.root) }
        check("stable: an old bundle asked for by name is never run; the launcher is",
              claudeStableExecutable(f.bundle, install: f.install) == f.launcher)
    }
    // T10 (D10): a version the user pinned on purpose is not swapped.
    do {
        let f = makeStableFixture(.oldInode); defer { try? fm.removeItem(at: f.root) }
        check("stable: a pinned older version is left alone and the bundle is not touched",
              claudeStableExecutable(f.old, install: f.install) == f.old && sameFile(f.bundle, f.old))
    }
    // T11 (D11): a claude outside this install, and codex, pass through.
    do {
        let f = makeStableFixture(.oldInode); defer { try? fm.removeItem(at: f.root) }
        let outside = f.root.appendingPathComponent("elsewhere")
        try! fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let wrapper = outside.appendingPathComponent("claude").path
        let codex = outside.appendingPathComponent("codex").path
        for path in [wrapper, codex] {
            try! "#!/bin/bash\nprintf '%s' \"$0\" > \"$1\"\n".write(toFile: path, atomically: true, encoding: .utf8)
            try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        check("stable: a claude outside the install and codex pass through untouched",
              claudeStableExecutable(wrapper, install: f.install) == wrapper
              && claudeStableExecutable(codex, install: f.install) == codex && sameFile(f.bundle, f.old))
    }
    // T12 (D12, D13): a bare name, and a missing launcher.
    do {
        let f = makeStableFixture(.oldInode); defer { try? fm.removeItem(at: f.root) }
        let noLauncher = ClaudeNativeInstall(launcher: f.root.appendingPathComponent("bin/missing"), root: f.root)
        check("stable: a bare name and a missing launcher return the input",
              claudeStableExecutable("claude", install: f.install) == "claude"
              && claudeStableExecutable(f.latest, install: noLauncher) == f.latest && sameFile(f.bundle, f.old))
    }
    // T13 (D14): eight callers at once: each gets the bundle only if it is the latest, no leftovers.
    do {
        let f = makeStableFixture(.oldInode); defer { try? fm.removeItem(at: f.root) }
        let results = StableResults()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let got = claudeStableExecutable(f.launcher, install: f.install)
            results.add(got == f.launcher || (got == f.bundle && sameFile(f.bundle, f.latest)))
        }
        check("stable: concurrent re-links all answer the latest and leave no temporaries",
              results.allTrue(count: 8) && sameFile(f.bundle, f.latest) && !leftoverTemporaries(f))
    }
    // T14 / T16 (CLI): a supervised spawn runs the bundle for claude, codex unchanged.
    do {
        let f = makeStableFixture(.oldInode); defer { try? fm.removeItem(at: f.root) }
        let bin = f.root.appendingPathComponent("bin").path
        check("stable: spawnChild execs claude through the bundle",
              spawnedPath(["claude"], path: bin, install: f.install, in: f.root) == f.bundle)
        let codex = f.root.appendingPathComponent("bin/codex").path
        try! "#!/bin/bash\nprintf '%s' \"$0\" > \"$1\"\n".write(toFile: codex, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex)
        check("stable: spawnChild runs codex from its own path",
              spawnedPath([codex], path: bin, install: f.install, in: f.root) == codex)
    }
    // T15 / T16 (app): CLIRunner.run the same way.
    do {
        let f = makeStableFixture(.oldInode); defer { try? fm.removeItem(at: f.root) }
        check("stable: CLIRunner.run execs claude through the bundle",
              runnerPath(f.launcher, install: f.install, in: f.root) == f.bundle)
        let codex = f.root.appendingPathComponent("bin/codex").path
        try! "#!/bin/bash\nprintf '%s' \"$0\" > \"$1\"\n".write(toFile: codex, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex)
        check("stable: CLIRunner.run runs codex from its own path",
              runnerPath(codex, install: f.install, in: f.root) == codex)
    }
    // T17: commands printed for a person to run later keep the launcher; the exec points map once.
    func occurrences(_ file: String) -> Int {
        ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").components(separatedBy: "claudeStableExecutable(").count - 1
    }
    check("stable: deferred command text is never mapped onto the bundle",
          occurrences("TallyCLI/HookArtifact.swift") == 0 && occurrences("Tally/Core/LoginTerminalFallback.swift") == 0)
    check("stable: each immediate exec point maps exactly once",
          ["Tally/Core/RenewLoginRunner.swift", "Tally/Core/EffortLevels.swift", "TallyCLI/Snapshot.swift",
           "Tally/Core/CLIRunner.swift", "TallyCLI/SupervisorRuntime.swift"].allSatisfy { occurrences($0) == 1 })
}

private final class StableResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func add(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
    func allTrue(count: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return values.count == count && !values.contains(false) }
}
