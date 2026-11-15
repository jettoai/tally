import Darwin
import Foundation

// B-565: a claude launch execs the installer's app bundle when it is provably the current version,
// so macOS permissions survive Claude Code updates, and never an older version left in the bundle.
// The fake versions print "$0", the path they were executed through: the only reliable proof of
// which name ran (ps shows argv[0], and lsof / proc_pidpath name a hard link by whichever name the
// vnode cache holds).
//
// Issue #24: the bundle's Info.plist must be byte for byte the one embedded in the executable, or
// AMFI kills the exec. T18 to T25 use a real ad-hoc signed Mach-O built with /usr/bin/clang (never
// `cc`, a shell alias for `tally claude` on the author's machine), so the verdict under test is the
// Security framework's, not a stand-in's.

private struct StableFixture {
    let root: URL
    let install: ClaudeNativeInstall
    var old: String { root.appendingPathComponent("versions/1.0.0").path }
    var latest: String { root.appendingPathComponent("versions/1.0.1").path }
    var macOS: URL { install.bundleExecutable.deletingLastPathComponent() }
    var bundle: String { install.bundleExecutable.path }
    var launcher: String { install.launcher.path }
}

private enum BundleShape { case sameInode, oldInode, emptyMacOS, noMacOS, symlinkToLatest, directory, noInfoPlist, oldInodeNoInfoPlist, noContents }

/// A stand-in program that writes "$0" into the file named by its first argument.
private func writeFakeProgram(_ path: String) {
    try! "#!/bin/bash\nprintf '%s' \"$0\" > \"$1\"\n".write(toFile: path, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
}

private func makeStableFixture(_ shape: BundleShape) -> StableFixture {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tally-stable-\(UUID().uuidString)")
    // The bash stand-ins carry no signature: the signature gate is a pass-through here (T18 to T25
    // exercise the real one).
    let fixture = StableFixture(root: root, install: ClaudeNativeInstall(
        launcher: root.appendingPathComponent("bin/claude"), root: root, signatureCheck: { _ in 0 }))
    try! fm.createDirectory(at: root.appendingPathComponent("versions"), withIntermediateDirectories: true)
    try! fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
    for version in [fixture.old, fixture.latest] { writeFakeProgram(version) }
    try! fm.createSymbolicLink(atPath: fixture.launcher, withDestinationPath: fixture.latest)
    if shape == .noContents { return fixture }
    let contents = fixture.install.bundleContents
    try! fm.createDirectory(at: contents, withIntermediateDirectories: true)
    if shape != .noInfoPlist && shape != .oldInodeNoInfoPlist { try! "<plist/>".write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8) }
    if shape != .noMacOS { try! fm.createDirectory(at: fixture.macOS, withIntermediateDirectories: true) }
    switch shape {
    case .sameInode: precondition(link(fixture.latest, fixture.bundle) == 0)
    case .oldInode, .oldInodeNoInfoPlist: precondition(link(fixture.old, fixture.bundle) == 0)
    case .symlinkToLatest: try! fm.createSymbolicLink(atPath: fixture.bundle, withDestinationPath: fixture.latest)
    case .directory:
        try! fm.createDirectory(atPath: fixture.bundle, withIntermediateDirectories: true)
        try! "x".write(toFile: fixture.bundle + "/keep", atomically: true, encoding: .utf8)
    case .emptyMacOS, .noMacOS, .noInfoPlist, .noContents: break
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
    let fm = FileManager.default
    let names = ((try? fm.contentsOfDirectory(atPath: fixture.macOS.path)) ?? [])
        + ((try? fm.contentsOfDirectory(atPath: fixture.install.bundleContents.path)) ?? [])
    return names.contains { $0.hasPrefix(".claude.tally-") || $0.hasPrefix(".Info.plist.tally-") }
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

private let localArch: String = {
    #if arch(arm64)
    return "arm64"
    #else
    return "x86_64"
    #endif
}()

/// Runs a tool to completion; its stderr text (codesign speaks there) is returned with the status.
private func runTool(_ path: String, _ args: [String]) -> (ok: Bool, stderr: String) {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = pipe
    guard (try? process.run()) != nil else { return (false, "") }
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus == 0, text)
}

private func fixturePlist(_ identifier: String) -> Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>\(identifier)</string>\
    <key>CFBundleExecutable</key><string>claude</string><key>CFBundleName</key><string>Fixture</string>\
    <key>CFBundlePackageType</key><string>APPL</string></dict></plist>

    """.utf8)
}

/// A Mach-O that writes the path it was executed through into the file named by its first argument
/// (what the bash stand-ins print as "$0"), with `plist` embedded in `__TEXT,__info_plist`.
private func compileFixture(in dir: URL, name: String, plist: Data, arch: String = localArch, sign: Bool) -> URL? {
    let source = dir.appendingPathComponent("main.c"), plistFile = dir.appendingPathComponent("\(name).plist")
    let output = dir.appendingPathComponent(name)
    let code = "#include <mach-o/dyld.h>\n#include <stdio.h>\nint main(int c, char **v) { char p[4096]; unsigned n = sizeof p;"
        + " if (c < 2 || _NSGetExecutablePath(p, &n) != 0) return 1; FILE *f = fopen(v[1], \"w\"); if (!f) return 1;"
        + " fputs(p, f); fclose(f); return 0; }\n"
    guard (try? code.write(to: source, atomically: true, encoding: .utf8)) != nil,
          (try? plist.write(to: plistFile)) != nil,
          runTool("/usr/bin/clang", ["-arch", arch, "-o", output.path, source.path,
                                     "-Wl,-sectcreate,__TEXT,__info_plist,\(plistFile.path)"]).ok else { return nil }
    if sign, !runTool("/usr/bin/codesign", ["-s", "-", "-f", output.path]).ok { return nil }
    return output
}

private enum RealShape { case sameInode, oldInode }

/// An install whose versions are the real signed Mach-O and whose bundle is shaped as asked;
/// `plist` is what Contents/Info.plist holds (nil: no file).
private func makeRealFixture(_ program: URL, _ shape: RealShape, plist: Data?) -> StableFixture {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tally-stable-\(UUID().uuidString)")
    let fixture = StableFixture(root: root, install: ClaudeNativeInstall(
        launcher: root.appendingPathComponent("bin/claude"), root: root))
    try! fm.createDirectory(at: root.appendingPathComponent("versions"), withIntermediateDirectories: true)
    try! fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
    for version in [fixture.old, fixture.latest] { try! fm.copyItem(at: program, to: URL(fileURLWithPath: version)) }
    try! fm.createSymbolicLink(atPath: fixture.launcher, withDestinationPath: fixture.latest)
    try! fm.createDirectory(at: fixture.macOS, withIntermediateDirectories: true)
    if let plist { try! plist.write(to: fixture.install.bundleContents.appendingPathComponent("Info.plist")) }
    precondition(link(shape == .sameInode ? fixture.latest : fixture.old, fixture.bundle) == 0)
    return fixture
}

private func infoPlistBytes(_ fixture: StableFixture) -> Data? {
    FileManager.default.contents(atPath: fixture.install.bundleContents.appendingPathComponent("Info.plist").path)
}

private func infoPlistModified(_ fixture: StableFixture) -> Date? {
    (try? FileManager.default.attributesOfItem(
        atPath: fixture.install.bundleContents.appendingPathComponent("Info.plist").path))?[.modificationDate] as? Date
}

/// What `codesign -v --strict` says about the bundle: an independent reading of the Info.plist
/// binding. A mismatched plist is "invalid Info.plist" for Claude Code's Developer ID signature and
/// "code object is not signed at all" for these ad-hoc fixtures; a matching one leaves only "code has
/// no resources" (the same leftover the real, working Claude Code bundle has, and not what AMFI kills on).
private func codesignComplaint(_ fixture: StableFixture) -> String {
    runTool("/usr/bin/codesign", ["-v", "--strict", "--verbose=4",
                                  fixture.install.bundleContents.deletingLastPathComponent().path]).stderr
}

private func plistBindingBroken(_ complaint: String) -> Bool {
    complaint.contains("invalid Info.plist") || complaint.contains("not signed at all")
}

private func plistBindingHolds(_ complaint: String) -> Bool {
    complaint.contains("code has no resources") && !plistBindingBroken(complaint)
}

func runStableClaudeChecks() {
    let fm = FileManager.default
    let kitDirectory = fm.temporaryDirectory.appendingPathComponent("tally-stable-kit-\(UUID().uuidString)")
    try! fm.createDirectory(at: kitDirectory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: kitDirectory) }
    let embedded = fixturePlist("ai.jetto.tally.stablefixture")
    let program = compileFixture(in: kitDirectory, name: "signed", plist: embedded, sign: true)
    check("stable: the signed fixture program builds (/usr/bin/clang and codesign are required)", program != nil)

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
        let plist = try? String(contentsOf: f.install.bundleContents.appendingPathComponent("Info.plist"), encoding: .utf8)
        check("stable: an old bundle inode is re-linked to the latest and used, its Info.plist left as it was",
              got == f.bundle && sameFile(f.bundle, f.latest) && fm.fileExists(atPath: f.old) && !leftoverTemporaries(f)
              && plist == "<plist/>")
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
    // T8 (D7): no installer bundle at all (it may have been thrown away on purpose): unchanged,
    // and nothing created.
    do {
        let f = makeStableFixture(.noContents); defer { try? fm.removeItem(at: f.root) }
        let before = allPaths(under: f.root)
        check("stable: without a bundle Contents the executable is returned untouched and nothing is created",
              claudeStableExecutable(f.launcher, install: f.install) == f.launcher && allPaths(under: f.root) == before)
    }
    // T8b (B-565, #24): Contents without Info.plist, the shell a `mkdir -p` + `ln` leaves. With no
    // embedded plist to copy (the bash stand-in) there is nothing to complete it from: the launcher.
    do {
        let f = makeStableFixture(.noInfoPlist); defer { try? fm.removeItem(at: f.root) }
        check("stable: a bundle missing Info.plist with no embedded plist to copy falls back to the launcher",
              claudeStableExecutable(f.launcher, install: f.install) == f.launcher
              && !fm.fileExists(atPath: f.install.bundleContents.appendingPathComponent("Info.plist").path)
              && !leftoverTemporaries(f))
    }
    if let program {
        // The same shell around a real executable: the plist is written from its embedded section.
        let f = makeRealFixture(program, .sameInode, plist: nil); defer { try? fm.removeItem(at: f.root) }
        check("stable: a bundle missing Info.plist gets the executable's embedded plist, byte for byte, and is used",
              claudeStableExecutable(f.launcher, install: f.install) == f.bundle && infoPlistBytes(f) == embedded
              && !leftoverTemporaries(f))
    }
    // T8c (B-565, the 2026-10-04 11:39 shape): an older version in a bundle missing Info.plist,
    // through the real spawnChild and a real signed executable: completed, re-linked, and it runs
    // from the bundle (an unsigned-looking bundle would be killed before it could write its marker).
    if let program {
        let f = makeRealFixture(program, .oldInode, plist: nil); defer { try? fm.removeItem(at: f.root) }
        let bin = f.root.appendingPathComponent("bin").path
        check("stable: an old bundle missing Info.plist is completed, re-linked, and spawnChild execs it",
              spawnedPath(["claude"], path: bin, install: f.install, in: f.root) == f.bundle
              && sameFile(f.bundle, f.latest) && fm.fileExists(atPath: f.old) && infoPlistBytes(f) == embedded
              && !leftoverTemporaries(f))
    }
    // T8d: a plist that cannot be written (read-only Contents): the launcher, nothing created. The
    // executable is re-linked first by design (the plist has to match the one linked in), so the
    // bundle's own state is not asserted.
    if let program {
        let f = makeRealFixture(program, .oldInode, plist: nil)
        chmod(f.install.bundleContents.path, 0o555)
        defer { chmod(f.install.bundleContents.path, 0o755); try? fm.removeItem(at: f.root) }
        check("stable: an unwritable Contents falls back to the launcher and no Info.plist is created",
              claudeStableExecutable(f.launcher, install: f.install) == f.launcher
              && !fm.fileExists(atPath: f.install.bundleContents.appendingPathComponent("Info.plist").path)
              && !leftoverTemporaries(f))
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
        for path in [wrapper, codex] { writeFakeProgram(path) }
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
        writeFakeProgram(codex)
        check("stable: spawnChild runs codex from its own path",
              spawnedPath([codex], path: bin, install: f.install, in: f.root) == codex)
    }
    // T15 / T16 (app): CLIRunner.run the same way.
    do {
        let f = makeStableFixture(.oldInode); defer { try? fm.removeItem(at: f.root) }
        check("stable: CLIRunner.run execs claude through the bundle",
              runnerPath(f.launcher, install: f.install, in: f.root) == f.bundle)
        let codex = f.root.appendingPathComponent("bin/codex").path
        writeFakeProgram(codex)
        check("stable: CLIRunner.run runs codex from its own path",
              runnerPath(codex, install: f.install, in: f.root) == codex)
    }
    stableSignedChecks(program: program, embedded: embedded, kitDirectory: kitDirectory)
    // T17: commands printed for a person to run later keep the launcher; the exec points map once.
    func occurrences(_ file: String) -> Int {
        ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").components(separatedBy: "claudeStableExecutable(").count - 1
    }
    check("stable: deferred command text is never mapped onto the bundle",
          occurrences("Tally/Core/LoginTerminalFallback.swift") == 0)
    check("stable: each immediate exec point maps exactly once",
          ["Tally/Core/RenewLoginRunner.swift", "Tally/Core/EffortLevels.swift", "TallyCLI/Snapshot.swift",
           "Tally/Core/CLIRunner.swift", "TallyCLI/SupervisorRuntime.swift"].allSatisfy { occurrences($0) == 1 })
}


/// T18 to T25 (#24): the Info.plist sync and the signature gate, against a real signed executable.
private func stableSignedChecks(program: URL?, embedded: Data, kitDirectory: URL) {
    let fm = FileManager.default
    let stale = Data("<plist/>".utf8)
    guard let program else { return }
    // T18: plist already the embedded bytes: the bundle, and not one write.
    do {
        let f = makeRealFixture(program, .sameInode, plist: embedded); defer { try? fm.removeItem(at: f.root) }
        let before = allPaths(under: f.root), modified = infoPlistModified(f)
        check("stable: a bundle whose Info.plist already matches the embedded one is used with no write",
              claudeStableExecutable(f.launcher, install: f.install) == f.bundle
              && allPaths(under: f.root) == before && infoPlistModified(f) == modified)
    }
    // T19: the #24 regression. A stale Info.plist beside the current executable: codesign calls it
    // invalid before, and the plist is synced so that it is not after.
    do {
        let f = makeRealFixture(program, .sameInode, plist: stale); defer { try? fm.removeItem(at: f.root) }
        let complaintBefore = codesignComplaint(f)
        let got = claudeStableExecutable(f.launcher, install: f.install)
        check("stable: a stale Info.plist is synced to the embedded bytes and the bundle verifies (issue #24)",
              plistBindingBroken(complaintBefore) && got == f.bundle && infoPlistBytes(f) == embedded
              && plistBindingHolds(codesignComplaint(f)) && stableBundleSignatureIsValid(f.install.bundleContents
                  .deletingLastPathComponent().path) == 0 && !leftoverTemporaries(f))
    }
    // T20: the reporter's whole shape: an older executable AND an older plist in the bundle.
    do {
        let f = makeRealFixture(program, .oldInode, plist: stale); defer { try? fm.removeItem(at: f.root) }
        let got = claudeStableExecutable(f.launcher, install: f.install)
        check("stable: an old executable with an old Info.plist is re-linked and synced, then used",
              got == f.bundle && sameFile(f.bundle, f.latest) && infoPlistBytes(f) == embedded
              && plistBindingHolds(codesignComplaint(f)) && !leftoverTemporaries(f))
    }
    // T21: a stale plist that cannot be replaced (read-only Contents): the launcher, plist untouched.
    do {
        let f = makeRealFixture(program, .sameInode, plist: stale)
        chmod(f.install.bundleContents.path, 0o555)
        defer { chmod(f.install.bundleContents.path, 0o755); try? fm.removeItem(at: f.root) }
        check("stable: a stale Info.plist that cannot be replaced falls back to the launcher and stays as it was",
              claudeStableExecutable(f.launcher, install: f.install) == f.launcher
              && infoPlistBytes(f) == stale && !leftoverTemporaries(f))
    }
    // T22: the signature verdict decides: a failing check returns the launcher, which a real
    // spawnChild then runs; a passing one returns the bundle.
    do {
        let f = makeStableFixture(.sameInode); defer { try? fm.removeItem(at: f.root) }
        var failing = f.install
        failing.signatureCheck = { _ in -67030 }
        let bin = f.root.appendingPathComponent("bin").path
        check("stable: a failing signature check returns the launcher and spawnChild runs that",
              claudeStableExecutable(f.launcher, install: failing) == f.launcher
              && spawnedPath(["claude"], path: bin, install: failing, in: f.root) == f.launcher
              && claudeStableExecutable(f.launcher, install: f.install) == f.bundle)
    }
    // T23: eight callers at once on a stale plist: every answer is usable, the end state is synced.
    do {
        let f = makeRealFixture(program, .oldInode, plist: stale); defer { try? fm.removeItem(at: f.root) }
        let results = StableResults()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let got = claudeStableExecutable(f.launcher, install: f.install)
            results.add(got == f.launcher || (got == f.bundle && sameFile(f.bundle, f.latest)))
        }
        check("stable: concurrent callers on a stale Info.plist all get a usable answer and leave it synced",
              results.allTrue(count: 8) && infoPlistBytes(f) == embedded && sameFile(f.bundle, f.latest)
              && !leftoverTemporaries(f))
    }
    // T24: the flags are the whole point (default flags reject Claude Code's own working bundle).
    do {
        let source = (try? String(contentsOfFile: "Tally/Core/ClaudeStableExecutable.swift", encoding: .utf8)) ?? ""
        check("stable: the signature check skips the executable and the resources, and never uses default flags",
              source.contains("kSecCSDoNotValidateExecutable") && source.contains("kSecCSDoNotValidateResources")
              && source.contains("SecCSFlags(rawValue: kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources)"))
    }
    // T25: the Mach-O reader: thin, fat (one slice, and two where only the local one counts), and
    // everything that is not a plain readable section.
    do {
        let thin = compileFixture(in: kitDirectory, name: "thin", plist: embedded, sign: false)
        let other = compileFixture(in: kitDirectory, name: "other", plist: fixturePlist("ai.jetto.tally.otherarch"),
                                   arch: localArch == "arm64" ? "x86_64" : "arm64", sign: false)
        let big = compileFixture(in: kitDirectory, name: "big", plist: Data(count: 70_000), sign: false)
        let fat1 = kitDirectory.appendingPathComponent("fat1"), fat2 = kitDirectory.appendingPathComponent("fat2")
        if let thin { _ = runTool("/usr/bin/lipo", ["-create", thin.path, "-output", fat1.path]) }
        if let thin, let other { _ = runTool("/usr/bin/lipo", ["-create", other.path, thin.path, "-output", fat2.path]) }
        let truncated = kitDirectory.appendingPathComponent("truncated"), text = kitDirectory.appendingPathComponent("text")
        try? (fm.contents(atPath: program.path) ?? Data()).prefix(100).write(to: truncated)
        try? Data("not a Mach-O\n".utf8).write(to: text)
        check("stable: the embedded plist is read from a thin Mach-O", thin.flatMap { claudeEmbeddedInfoPlist($0.path) } == embedded)
        check("stable: the embedded plist is read from a one-slice fat file", claudeEmbeddedInfoPlist(fat1.path) == embedded)
        check("stable: the slice for this machine is the one read from a two-slice fat file",
              claudeEmbeddedInfoPlist(fat2.path) == embedded)
        check("stable: a truncated file, a text file and a missing file have no embedded plist",
              claudeEmbeddedInfoPlist(truncated.path) == nil && claudeEmbeddedInfoPlist(text.path) == nil
              && claudeEmbeddedInfoPlist(kitDirectory.appendingPathComponent("absent").path) == nil)
        check("stable: an embedded section over the size limit is not read",
              big != nil && claudeEmbeddedInfoPlist(big!.path) == nil)
    }
}

private final class StableResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func add(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
    func allTrue(count: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return values.count == count && !values.contains(false) }
}
