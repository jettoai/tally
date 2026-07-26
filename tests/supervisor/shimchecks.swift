import Darwin
import Foundation

// Regression for the 2026-07-26 handoff defect (session c80ebeb2). The supervisor respawned its
// child as the bare name "claude", the first `claude` on PATH was Tally's own shim, and the shim
// re-ran the account pick and steered the session straight back to the account the handoff had just
// left it. These checks cover the resolution that skips the shim, and the spawn that has to use it.

/// A tiny executable that records which copy of "claude" actually ran, by writing `marker` to the
/// path it is given as its first argument.
private func writeFakeCLI(_ url: URL, marker: String) {
    let fm = FileManager.default
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! "#!/bin/bash\nprintf '%s' '\(marker)' > \"$1\"\n".write(to: url, atomically: true,
                                                                 encoding: .utf8)
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

/// Run `argv` through the real `spawnChild`, wait for it, and return what the child recorded.
/// `path` is installed as this process's PATH for the duration (and restored): both the resolution
/// inside `spawnChild` and posix_spawnp's own fallback walk read the caller's PATH, so a fixture
/// that only reached the child's environment would prove nothing.
private func markerAfterSpawn(_ argv: [String], shimDirectory: URL, path: String,
                              in root: URL) -> String? {
    let marker = root.appendingPathComponent("ran-\(UUID().uuidString)")
    let previousPath = ProcessInfo.processInfo.environment["PATH"]
    setenv("PATH", path, 1)
    defer {
        if let previousPath { setenv("PATH", previousPath, 1) } else { unsetenv("PATH") }
    }
    guard let pid = spawnChild(argv + [marker.path], environment: ["PATH": path],
                               shimDirectory: shimDirectory) else { return nil }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1, errno == EINTR {}
    return try? String(contentsOf: marker, encoding: .utf8)
}

func runShimChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tally-shim-\(UUID().uuidString)")
    // A fake home whose shim directory sits where the real one does relative to it, plus a real
    // binary further along PATH: the exact shape of the machine the defect happened on.
    let shimDir = root.appendingPathComponent("home/.tally/bin")
    let realDir = root.appendingPathComponent("opt/bin")
    writeFakeCLI(shimDir.appendingPathComponent("claude"), marker: "shim")
    writeFakeCLI(realDir.appendingPathComponent("claude"), marker: "real")
    let realPath = realDir.appendingPathComponent("claude").path
    defer { try? fm.removeItem(at: root) }

    // 1. The fix: PATH order puts the shim first, and the resolution takes the next one anyway.
    let shimFirst = "\(shimDir.path):\(realDir.path)"
    check("resolution skips the shim and takes the next executable on PATH",
          resolveProviderExecutable("claude", path: shimFirst, shimDirectory: shimDir) == realPath)

    // 2. The shim directory reached through a symlinked PATH entry is still the shim. Someone whose
    //    PATH names a linked bin dir (or a linked home) must not fall back into it.
    let linkedBin = root.appendingPathComponent("linked-bin")
    try! fm.createSymbolicLink(at: linkedBin, withDestinationURL: shimDir)
    check("a shim directory reached via a symlinked PATH entry is still skipped",
          resolveProviderExecutable("claude", path: "\(linkedBin.path):\(realDir.path)",
                                    shimDirectory: shimDir) == realPath)
    // The other link shape: an ordinary PATH directory holding a symlink AT the shim script.
    let linkingDir = root.appendingPathComponent("linking")
    try! fm.createDirectory(at: linkingDir, withIntermediateDirectories: true)
    try! fm.createSymbolicLink(at: linkingDir.appendingPathComponent("claude"),
                               withDestinationURL: shimDir.appendingPathComponent("claude"))
    check("a symlink pointing at the shim script is still skipped",
          resolveProviderExecutable("claude", path: "\(linkingDir.path):\(realDir.path)",
                                    shimDirectory: shimDir) == realPath)

    // 3. Nothing but the shim (or nothing at all): fall back to the bare name, so a machine with no
    //    shim installed, and one whose only claude IS the shim, both behave exactly as before.
    check("no non-shim match falls back to the bare name",
          resolveProviderExecutable("claude", path: shimDir.path, shimDirectory: shimDir) == "claude")
    check("an empty PATH falls back to the bare name",
          resolveProviderExecutable("claude", path: "", shimDirectory: shimDir) == "claude")
    check("an absent PATH falls back to the bare name",
          resolveProviderExecutable("claude", path: nil, shimDirectory: shimDir) == "claude")

    // 4. The walk matches what the system would do with the same PATH: a non-executable file and a
    //    directory of that name are both passed over rather than returned as the program.
    let noise = root.appendingPathComponent("noise")
    try! fm.createDirectory(at: noise.appendingPathComponent("claude"), withIntermediateDirectories: true)
    let unreadable = root.appendingPathComponent("plain")
    try! fm.createDirectory(at: unreadable, withIntermediateDirectories: true)
    try! "not executable".write(to: unreadable.appendingPathComponent("claude"), atomically: true,
                                encoding: .utf8)
    check("a directory named like the CLI is not a match",
          resolveProviderExecutable("claude", path: "\(noise.path):\(realDir.path)",
                                    shimDirectory: shimDir) == realPath)
    check("a non-executable file is not a match",
          resolveProviderExecutable("claude", path: "\(unreadable.path):\(realDir.path)",
                                    shimDirectory: shimDir) == realPath)

    // 5. The spawn actually receives it. Same PATH both times, so the only difference is whether
    //    the shim directory is recognised: pointed at an unrelated directory, nothing is skipped
    //    and posix_spawnp lands on the shim (the defect, live); pointed at the real shim directory,
    //    the child is the real binary (the fix).
    let elsewhere = root.appendingPathComponent("not-the-shim")
    try! fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    check("with the shim unrecognised the spawned child IS the shim",
          markerAfterSpawn(["claude"], shimDirectory: elsewhere, path: shimFirst, in: root) == "shim")
    check("the spawned child is the resolved real binary",
          markerAfterSpawn(["claude"], shimDirectory: shimDir, path: shimFirst, in: root) == "real")
    // And with no shim on PATH at all the spawn still works, which is the fallback arm end to end.
    check("a spawn with no shim on PATH still runs the real binary",
          markerAfterSpawn(["claude"], shimDirectory: shimDir, path: realDir.path, in: root) == "real")
}
