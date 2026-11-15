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
// The bundle's Info.plist must also be byte for byte the one embedded in that executable (its
// __TEXT,__info_plist section): the signature binds the embedded bytes, and a bundle executed with
// any other Info.plist is judged unsigned and killed by AMFI at exec (issue #24). So the plist is
// synced from the executable, and the bundle is verified before it is returned.
//
// Applied at the moment of exec only, never at resolution: a resolved path is also printed into
// commands a person runs later (renew login, the Terminal fallback), and by then the bundle may be
// an old version again.

/// Where one native install lives. A value so tests can point it at a scratch directory.
struct ClaudeNativeInstall: Sendable {
    var launcher: URL
    var root: URL
    /// Verifies the bundle directory (0 = valid). A seam for tests that use unsigned stand-ins.
    var signatureCheck: @Sendable (String) -> OSStatus = { stableBundleSignatureIsValid($0) }

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
    if !stableSameFile(bundle, latest) { stableRelink(latest, to: install.bundleExecutable) }
    guard stableSameFile(bundle, latest) else { return fallingBack("relink-failed") }
    // Only now: the plist has to belong to the executable that was just linked in. An executable
    // without a readable embedded plist leaves an existing Info.plist to the signature check below.
    if let expected = claudeEmbeddedInfoPlist(latest) {
        guard stableSyncInfoPlist(infoPlist, expected: expected) else { return fallingBack("plist-sync-failed") }
    } else if !FileManager.default.fileExists(atPath: infoPlist.path) {
        return fallingBack("no-embedded-plist")
    }
    let status = install.signatureCheck(install.bundleContents.deletingLastPathComponent().path)
    guard status == 0 else { return fallingBack("signature-invalid status=\(status)") }
    return access(bundle, X_OK) == 0 ? bundle : fallingBack("not-executable")
}

private let stableLog = Logger(subsystem: "ai.jetto.tally", category: "stable-exec")

/// The Info.plist bytes embedded in `executable`'s `__TEXT,__info_plist` section, from the slice for
/// this machine's architecture (thin or fat Mach-O). Raw bytes, not `SecCodeCopySigningInformation`'s
/// parsed dictionary: the signature binds the bytes. nil on anything unexpected, never a guess.
func claudeEmbeddedInfoPlist(_ executable: String) -> Data? {
    let fd = open(executable, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    let maxPlist = 64 * 1024, maxCommands = 256 * 1024
    guard let magicBytes = stablePread(fd, 0, 4) else { return nil }
    var base = 0
    if (stableInt(magicBytes, 0) as UInt32?) != 0xfeedfacf {  // MH_MAGIC_64
        // FAT_MAGIC / FAT_MAGIC_64: a big-endian table of slices.
        guard let fatMagic = stableInt(magicBytes, 0, bigEndian: true) as UInt32?,
              fatMagic == 0xcafebabe || fatMagic == 0xcafebabf,
              let counts = stablePread(fd, 4, 4), let n = stableInt(counts, 0, bigEndian: true) as UInt32?,
              n > 0, n <= 16 else { return nil }
        let wide = fatMagic == 0xcafebabf, entry = wide ? 32 : 20
        #if arch(arm64)
        let cpu: UInt32 = 0x0100000c
        #else
        let cpu: UInt32 = 0x01000007
        #endif
        guard let table = stablePread(fd, 8, Int(n) * entry) else { return nil }
        var found: Int?
        for i in 0..<Int(n) where (stableInt(table, i * entry, bigEndian: true) as UInt32?) == cpu {
            found = wide ? (stableInt(table, i * entry + 8, bigEndian: true) as UInt64?).flatMap { Int(exactly: $0) }
                         : (stableInt(table, i * entry + 8, bigEndian: true) as UInt32?).map { Int($0) }
        }
        guard let slice = found, let inner = stablePread(fd, slice, 4),
              (stableInt(inner, 0) as UInt32?) == 0xfeedfacf else { return nil }
        base = slice
    }
    // mach_header_64 is 32 bytes: ncmds at 16, sizeofcmds at 20.
    guard let header = stablePread(fd, base, 32),
          let ncmds = stableInt(header, 16) as UInt32?, let size = stableInt(header, 20) as UInt32?,
          ncmds <= 1024, size <= maxCommands,
          let commands = stablePread(fd, base + 32, Int(size)) else { return nil }
    var position = 0
    for _ in 0..<Int(ncmds) {
        guard let cmd = stableInt(commands, position) as UInt32?,
              let cmdsize = stableInt(commands, position + 4) as UInt32?,
              cmdsize >= 8, position + Int(cmdsize) <= commands.count else { return nil }
        defer { position += Int(cmdsize) }
        // LC_SEGMENT_64: 72 bytes, then nsects section_64 records of 80 bytes.
        guard cmd == 0x19, cmdsize >= 72, let nsects = stableInt(commands, position + 64) as UInt32?,
              72 + Int(nsects) * 80 <= Int(cmdsize) else { continue }
        for i in 0..<Int(nsects) {
            let section = position + 72 + i * 80
            guard stableName(commands, section) == "__info_plist", stableName(commands, section + 16) == "__TEXT" else { continue }
            guard let length = stableInt(commands, section + 40) as UInt64?,
                  let offset = stableInt(commands, section + 48) as UInt32?,
                  length > 0, length <= UInt64(maxPlist) else { return nil }
            return stablePread(fd, base + Int(offset), Int(length))
        }
    }
    return nil
}

/// Makes `target` byte for byte `expected`: untouched when it already is, otherwise a uniquely named
/// file renamed over it (never seen half written; concurrent callers write the same bytes, so
/// whoever lands last is the same). False, with the temporary name removed, when it cannot be done.
private func stableSyncInfoPlist(_ target: URL, expected: Data) -> Bool {
    if FileManager.default.contents(atPath: target.path) == expected { return true }
    let temporary = target.deletingLastPathComponent()
        .appendingPathComponent(".Info.plist.tally-\(getpid())-\(UUID().uuidString)")
    guard (try? expected.write(to: temporary, options: .withoutOverwriting)) != nil else { return false }
    guard Darwin.rename(temporary.path, target.path) == 0 else {
        Darwin.unlink(temporary.path)
        return false
    }
    stableLog.notice("stable-exec=plist-synced bytes=\(expected.count)")
    return true
}

/// 0 when the bundle's signature holds up for what AMFI checks at exec. The flags are deliberate and
/// must not go back to the defaults: Claude Code's bundle has no sealed resources, so default flags
/// reject the one that runs fine (-67056) every time, and would also hash the 347 MB executable page
/// by page (about 140 ms warm, 0.9 s cold). Executable and resources are skipped; the Info.plist
/// binding, which is what AMFI kills on, is still checked (-67030 / -67062 when it does not match).
/// Successes are remembered per file identity; failures are not, so a later repair is seen.
func stableBundleSignatureIsValid(_ bundleRoot: String) -> OSStatus {
    let executable = bundleRoot + "/Contents/MacOS/claude", plist = bundleRoot + "/Contents/Info.plist"
    var e = stat(), p = stat()
    let key = stat(executable, &e) == 0 && stat(plist, &p) == 0
        ? "\(bundleRoot)|\(e.st_dev):\(e.st_ino)|\(p.st_dev):\(p.st_ino):\(p.st_size):\(p.st_mtimespec.tv_sec).\(p.st_mtimespec.tv_nsec)"
        : nil
    if let key, stableSignatureCache.withLock({ $0.contains(key) }) { return 0 }
    var code: SecStaticCode?
    let created = SecStaticCodeCreateWithPath(URL(fileURLWithPath: bundleRoot) as CFURL, [], &code)
    guard created == errSecSuccess, let code else { return created }
    let flags = SecCSFlags(rawValue: kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources)
    let status = SecStaticCodeCheckValidity(code, flags, nil)
    if status == 0, let key { stableSignatureCache.withLock { _ = $0.insert(key) } }
    return status
}

private let stableSignatureCache = OSAllocatedUnfairLock(initialState: Set<String>())

private func stablePread(_ fd: Int32, _ offset: Int, _ count: Int) -> Data? {
    guard offset >= 0, count >= 0, count <= 1 << 20 else { return nil }
    var buffer = Data(count: count)
    let got = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
    return got == count ? buffer : nil
}

private func stableInt<T: FixedWidthInteger>(_ data: Data, _ offset: Int, bigEndian: Bool = false) -> T? {
    guard offset >= 0, offset + MemoryLayout<T>.size <= data.count else { return nil }
    let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    return bigEndian ? T(bigEndian: raw) : T(littleEndian: raw)
}

/// A fixed 16-byte, NUL-padded Mach-O name field.
private func stableName(_ data: Data, _ offset: Int) -> String? {
    guard offset >= 0, offset + 16 <= data.count else { return nil }
    return String(decoding: data[offset..<offset + 16].prefix { $0 != 0 }, as: UTF8.self)
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
