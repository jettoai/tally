import Darwin
import Foundation
import os

// Claude Code's native installer keeps two names for one program: the launcher symlink
// (~/.local/bin/claude -> ~/.local/share/claude/versions/<version>) and an app bundle
// (~/.local/share/claude/ClaudeCode.app) whose executable is meant to be a hard link to the
// current version. macOS privacy permissions follow what was executed: through the symlink that
// is a new versioned file after every update, so every update asks again; through the bundle it is
// one bundle identity across updates.
//
// The updater moves the symlink but does not reliably move the bundle's link, and a bundle left on
// an older version must never run (Gatekeeper has refused one as damaged). So the bundle is used
// only after it is proven to be the very file the launcher points at (same device and inode),
// re-linked first when it is not, and the launcher is used whenever that proof cannot be made.
//
// Applied at the moment of exec only, never at resolution: a resolved path is also printed into
// commands a person runs later (renew login, the Terminal fallback), and by then the bundle may be
// an old version again.

/// Where one native install lives. A value so tests can point it at a scratch directory.
struct ClaudeNativeInstall: Sendable {
    var launcher: URL
    var root: URL

    var versions: URL { root.appendingPathComponent("versions", isDirectory: true) }
    var bundleContents: URL { root.appendingPathComponent("ClaudeCode.app/Contents", isDirectory: true) }
    var bundleExecutable: URL { bundleContents.appendingPathComponent("MacOS/claude") }

    static let current: ClaudeNativeInstall = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ClaudeNativeInstall(
            launcher: home.appendingPathComponent(".local/bin/claude"),
            root: home.appendingPathComponent(".local/share/claude", isDirectory: true))
    }()
}

/// The program to exec for `executable`. Anything that is not this install's current version
/// comes back untouched (codex, a Homebrew or npm claude, a wrapper script, a dev stand-in, a bare
/// name, a version the user pinned on purpose). The current version comes back as the bundle
/// executable when the bundle is, or can be made, that same file; otherwise as the launcher.
func claudeStableExecutable(_ executable: String,
                            install: ClaudeNativeInstall = .current) -> String {
    guard let latest = stableRealPath(install.launcher.path),
          let versions = stableRealPath(install.versions.path),
          latest.hasPrefix(versions + "/"),
          stableIsRegularFile(latest), access(latest, X_OK) == 0,
          let chosen = stableRealPath(executable) else { return executable }
    let bundle = install.bundleExecutable.path
    let bundleDirectory = stableRealPath(install.bundleExecutable.deletingLastPathComponent().path)
    let choseBundle = bundleDirectory.map { chosen == $0 + "/claude" } ?? false
    guard chosen == latest || choseBundle else { return executable }
    // Whatever happens below, the answer is never the bundle unless it IS the latest version.
    let fallback = chosen == latest ? executable : install.launcher.path
    func fallingBack(_ reason: String) -> String {
        stableLog.notice("stable-exec=fallback reason=\(reason, privacy: .public)")
        return fallback
    }
    // No Contents at all: the bundle may have been thrown away on purpose (Gatekeeper's "damaged,
    // move to Trash"), so nothing is rebuilt. Contents without Info.plist is the half-made shell
    // other tools leave behind (`mkdir -p` + `ln`), and it is completed instead (B-565, 2026-10-04).
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: install.bundleContents.path, isDirectory: &isDirectory),
          isDirectory.boolValue else { return fallingBack("no-contents") }
    let infoPlist = install.bundleContents.appendingPathComponent("Info.plist")
    if !FileManager.default.fileExists(atPath: infoPlist.path) { stableWriteInfoPlist(infoPlist) }
    guard FileManager.default.fileExists(atPath: infoPlist.path) else { return fallingBack("plist-write-failed") }
    if !stableSameFile(bundle, latest) { stableRelink(latest, to: install.bundleExecutable) }
    guard stableSameFile(bundle, latest) else { return fallingBack("relink-failed") }
    return access(bundle, X_OK) == 0 ? bundle : fallingBack("not-executable")
}

private let stableLog = Logger(subsystem: "ai.jetto.tally", category: "stable-exec")

/// Byte for byte the Info.plist Claude Code 2.1.289 itself writes into this bundle (918 bytes,
/// identical to the one an earlier Claude Code left in place). Written only when the file is
/// missing; Claude Code overwrites it with its own whenever it maintains the bundle.
let claudeBundleInfoPlist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.anthropic.claude-code</string>\
<key>CFBundleName</key><string>Claude Code</string><key>CFBundleDisplayName</key><string>Claude Code</string>\
<key>CFBundleExecutable</key><string>claude</string><key>CFBundlePackageType</key><string>APPL</string>\
<key>LSUIElement</key><true/><key>NSMicrophoneUsageDescription</key>\
<string>Claude Code uses the microphone for voice dictation.</string><key>NSAppleEventsUsageDescription</key>\
<string>Claude Code needs to send Apple Events to open URLs and control applications you authorize.</string>\
<key>NSLocalNetworkUsageDescription</key>\
<string>Claude Code connects to servers and devices on your local network when commands you run need to reach them.</string>\
</dict></plist>

"""

/// A uniquely named file moved in with RENAME_EXCL, so the plist is never seen half written and one
/// that already exists (Claude Code's own, or a concurrent caller's) is never replaced.
private func stableWriteInfoPlist(_ target: URL) {
    let temporary = target.deletingLastPathComponent()
        .appendingPathComponent(".Info.plist.tally-\(getpid())-\(UUID().uuidString)")
    guard (try? Data(claudeBundleInfoPlist.utf8).write(to: temporary, options: .withoutOverwriting)) != nil else { return }
    _ = renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL))
    Darwin.unlink(temporary.path)
}

/// Atomic `ln -f`: a uniquely named link renamed over the target, so the bundle executable is never
/// missing for a moment and concurrent callers cannot trip over each other's temporary names.
/// Any failure (read-only volume, permissions, a different volume, a directory in the way) leaves
/// the bundle as it was and removes the temporary name.
private func stableRelink(_ latest: String, to bundle: URL) {
    let directory = bundle.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let temporary = directory.appendingPathComponent(".claude.tally-\(getpid())-\(UUID().uuidString)").path
    guard Darwin.link(latest, temporary) == 0 else { return }
    // Unlinked either way: when another caller has already linked the same file in, rename(2) sees
    // two names for one file, succeeds, and leaves the temporary name in place.
    Darwin.rename(temporary, bundle.path)
    Darwin.unlink(temporary)
}

/// Same device and inode, with the bundle side read WITHOUT following links: a symlink there would
/// make the exec resolve back into versions/, which is the identity this exists to avoid.
private func stableSameFile(_ bundle: String, _ latest: String) -> Bool {
    var a = stat(), b = stat()
    guard lstat(bundle, &a) == 0, (a.st_mode & S_IFMT) == S_IFREG, stat(latest, &b) == 0 else { return false }
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino
}

private func stableIsRegularFile(_ path: String) -> Bool {
    var s = stat()
    return stat(path, &s) == 0 && (s.st_mode & S_IFMT) == S_IFREG
}

/// realpath(3), not `URL.resolvingSymlinksInPath`: the Foundation call drops a leading /private,
/// which would make a scratch install under /tmp compare unequal to itself.
private func stableRealPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}
