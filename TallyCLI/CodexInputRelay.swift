import Darwin
import Foundation

/// A private PTY between a Codex supervisor and the Codex it launched.
///
/// The relay owns the child side, so a direct send can only reach that exact child. It never uses
/// a process-global keyboard API, a frontmost window, or `TIOCSTI` on a terminal shared with a
/// person. The outer terminal is copied byte for byte into the child's PTY while it is running.
final class CodexInputRelay {
    /// The slave PTY the child owns. This is published only after `terminalReady` proves the child
    /// still owns this generation and is its foreground process group.
    let path: String

    private let outer: Int32
    private let master: Int32
    private let childDevice: dev_t
    private var slave: Int32
    private var savedOuterMode: termios
    private var savedWindowSize: winsize
    private var didRestore = false
    private var didSpawn = false
    private var bracketedPaste = false
    private var submissionUncertain = false
    private var outputTail: [UInt8] = []
    private var inputClassifier = CodexTerminalInputClassifier()

    /// A real keyboard edit observed while relaying. Terminal replies, focus changes and mouse
    /// reports deliberately do not become a draft stamp.
    private(set) var lastHumanInputAt: Date?
    /// An incomplete input escape sequence is not evidence that the composer is clear. The
    /// supervisor holds queued input until it can classify the remainder on a later pump.
    private(set) var inputPending = false

    /// `true` only after Codex has opted into bracketed paste and the relay still owns an open PTY.
    var canSend: Bool { !didRestore && didSpawn && !submissionUncertain && bracketedPaste && master >= 0 }

    init?() {
        guard isatty(STDIN_FILENO) == 1, let outerName = ttyname(STDIN_FILENO) else { return nil }
        let outerPath = String(cString: outerName)
        let outer = open(outerPath, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard outer >= 0 else { return nil }

        var opened = stat(), standardInput = stat(), process = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard fstat(outer, &opened) == 0,
              fstat(STDIN_FILENO, &standardInput) == 0,
              opened.st_rdev == standardInput.st_rdev,
              proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &process, infoSize) == infoSize,
              process.e_tdev == UInt32(bitPattern: opened.st_rdev)
        else {
            Darwin.close(outer)
            return nil
        }

        var mode = termios(), size = winsize()
        guard tcgetattr(outer, &mode) == 0, ioctl(outer, TIOCGWINSZ, &size) == 0 else {
            Darwin.close(outer)
            return nil
        }

        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, &size) == 0,
              let childName = ttyname(slave) else {
            if master >= 0 { Darwin.close(master) }
            if slave >= 0 { Darwin.close(slave) }
            Darwin.close(outer)
            return nil
        }
        var child = stat()
        guard fstat(slave, &child) == 0 else {
            Darwin.close(master)
            Darwin.close(slave)
            Darwin.close(outer)
            return nil
        }

        // The outer end must yield bytes as they are typed. Codex sets its own slave mode after
        // launch, and the original outer settings are restored by `close()` on every exit path.
        var raw = mode
        cfmakeraw(&raw)
        guard tcsetattr(outer, TCSANOW, &raw) == 0,
              codexRelaySetNonBlocking(master), codexRelaySetNonBlocking(outer) else {
            _ = tcsetattr(outer, TCSANOW, &mode)
            Darwin.close(master)
            Darwin.close(slave)
            Darwin.close(outer)
            return nil
        }

        self.outer = outer
        self.master = master
        self.slave = slave
        childDevice = child.st_rdev
        path = String(cString: childName)
        savedOuterMode = mode
        savedWindowSize = size
    }

    deinit { close() }

    /// Spawn a child into the relay slave. `SETSID` happens before the file action opens the slave,
    /// which makes it that new session's controlling terminal instead of borrowing the outer one.
    func spawn(_ argv: [String], environment: [String: String]) -> pid_t? {
        guard !didRestore, !didSpawn, slave >= 0, !argv.isEmpty else { return nil }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        let opened = path.withCString {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, $0, O_RDWR, 0)
        }
        guard opened == 0,
              posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, master) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
        else { return nil }

        let program = argv[0].contains("/") ? argv[0] : resolveProviderExecutable(argv[0])
        guard let trampoline = Bundle.main.executablePath ?? CommandLine.arguments.first,
              !trampoline.isEmpty else { return nil }
        let trampolineArgs = [trampoline, codexPTYChildCommand, program] + argv.dropFirst()
        var cArgs: [UnsafeMutablePointer<CChar>?] = trampolineArgs.map { strdup($0) }
        cArgs.append(nil)
        var cEnvironment: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnvironment.append(nil)
        defer { for pointer in cArgs + cEnvironment { free(pointer) } }

        var child: pid_t = 0
        guard posix_spawn(&child, trampoline, &actions, &attributes, cArgs, cEnvironment) == 0 else { return nil }
        Darwin.close(slave)
        slave = -1
        didSpawn = true
        return child
    }

    /// Copy available bytes. Passing `false` drains only Codex output: submission uses that during
    /// its short settle pause so human input stays queued in the real terminal and cannot interleave.
    @discardableResult
    func pump(forwardInput: Bool = true, timeout: TimeInterval = 0) -> Bool {
        guard !didRestore, master >= 0, syncWindowSize() else { return false }
        var descriptors = [pollfd(fd: master, events: Int16(POLLIN), revents: 0)]
        if forwardInput { descriptors.append(pollfd(fd: outer, events: Int16(POLLIN), revents: 0)) }
        let milliseconds = max(0, min(Int(timeout * 1_000), Int(Int32.max)))
        let count = poll(&descriptors, nfds_t(descriptors.count), Int32(milliseconds))
        if count < 0 { return errno == EINTR }
        if count == 0 { return true }

        var hungUp = false
        for descriptor in descriptors {
            if descriptor.revents & Int16(POLLNVAL | POLLERR) != 0 { return false }
            guard descriptor.revents & Int16(POLLIN) != 0 else {
                hungUp = hungUp || descriptor.revents & Int16(POLLHUP) != 0
                continue
            }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let received = read(descriptor.fd, &bytes, bytes.count)
            if received == 0 { return false }
            if received < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                return false
            }
            let packet = Array(bytes.prefix(Int(received)))
            if descriptor.fd == master {
                observeCodexOutput(packet)
                guard writeAll(packet, to: STDOUT_FILENO) else { return false }
            } else {
                observeOuterInput(packet)
                guard writeAll(packet, to: master) else { return false }
            }
            hungUp = hungUp || descriptor.revents & Int16(POLLHUP) != 0
        }
        return !hungUp
    }

    /// Forward final child output without reading the outer terminal. A child commonly leaves its
    /// final bytes and `POLLHUP` in one kernel event, so shutdown drains data before restoring it.
    func drainOutput(timeout: TimeInterval = 0.1) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            guard poll(&descriptor, 1, Int32(remaining * 1_000)) > 0,
                  descriptor.revents & Int16(POLLIN) != 0 else { return }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let received = read(master, &bytes, bytes.count)
            guard received > 0 else { return }
            let packet = Array(bytes.prefix(Int(received)))
            observeCodexOutput(packet)
            guard writeAll(packet, to: STDOUT_FILENO) else { return }
        }
    }

    /// Send one whole prompt. The paste is written before the 400ms settle pause and Return follows
    /// only if the exact child generation still owns this raw foreground terminal.
    func submit(_ text: String, child: Int32, startedAt: Int64,
                shouldContinue: () -> Bool = { true }) -> SessionInputInjection {
        guard shouldContinue() else { return .failed(EINTR) }
        guard terminalReady(child: child, startedAt: startedAt), canSend else { return .failed(ENOTTY) }
        // Do not read or forward a byte once submission begins. A byte already waiting belongs to
        // the person at this terminal, and the regular relay pump will deliver and classify it on
        // the next loop instead of racing a Tally paste into the same composer.
        guard !inputPending, !outerInputIsReady() else { return .held }
        let bytes = Array(text.utf8)
        let payload = bytes.isEmpty ? [] : sessionInputPasteStart + bytes + sessionInputPasteEnd
        submissionUncertain = true
        guard writeAll(payload, to: master) else { return .uncertain }

        let deadline = ProcessInfo.processInfo.systemUptime + sessionInputSubmitPause
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard shouldContinue() else { return .uncertain }
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            guard pump(forwardInput: false, timeout: min(0.05, remaining)) else { return .uncertain }
        }
        guard shouldContinue() else { return .uncertain }
        guard terminalReady(child: child, startedAt: startedAt), bracketedPaste,
              writeAll([sessionInputReturnByte], to: master) else { return .uncertain }
        submissionUncertain = false
        return .done
    }

    /// An uncertain paste or native receipt requires a fresh supervisor, never a second writer.
    func disableDirectSend() { submissionUncertain = true }

    /// This check is intentionally redundant with the caller's state check. A PID alone may have
    /// been reused, and a PTY path alone can describe a sibling tab, so all identities must agree.
    func terminalReady(child: Int32, startedAt: Int64) -> Bool {
        var info = proc_bsdinfo(), mode = termios()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard !didRestore, didSpawn, SessionMonitoring.generation(child) == startedAt,
              proc_pidinfo(child, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.e_tdev == UInt32(bitPattern: childDevice),
              tcgetpgrp(master) > 0, tcgetpgrp(master) == getpgid(child),
              tcgetattr(master, &mode) == 0,
              mode.c_lflag & tcflag_t(ICANON | ECHO) == 0 else { return false }
        return true
    }

    /// Restore the real terminal before closing the descriptors. Explicit callers do this on every
    /// signal and child exit path; `deinit` is only a final backstop for tests and early failures.
    func close() {
        guard !didRestore else { return }
        didRestore = true
        _ = tcsetattr(outer, TCSANOW, &savedOuterMode)
        _ = ioctl(outer, TIOCSWINSZ, &savedWindowSize)
        if slave >= 0 { Darwin.close(slave); slave = -1 }
        Darwin.close(master)
        Darwin.close(outer)
    }

    private func syncWindowSize() -> Bool {
        var size = winsize()
        guard ioctl(outer, TIOCGWINSZ, &size) == 0 else { return false }
        if size.ws_row != savedWindowSize.ws_row || size.ws_col != savedWindowSize.ws_col
            || size.ws_xpixel != savedWindowSize.ws_xpixel || size.ws_ypixel != savedWindowSize.ws_ypixel {
            guard ioctl(master, TIOCSWINSZ, &size) == 0 else { return false }
            savedWindowSize = size
        }
        return true
    }

    private func observeCodexOutput(_ bytes: [UInt8]) {
        let combined = outputTail + bytes
        let enable = Array("\u{1B}[?2004h".utf8)
        let disable = Array("\u{1B}[?2004l".utf8)
        var cursor = 0
        while cursor < combined.count {
            if combined[cursor...].starts(with: enable) { bracketedPaste = true; cursor += enable.count }
            else if combined[cursor...].starts(with: disable) { bracketedPaste = false; cursor += disable.count }
            else { cursor += 1 }
        }
        outputTail = Array(combined.suffix(16))
    }

    private func observeOuterInput(_ bytes: [UInt8]) {
        if inputClassifier.consume(bytes) { lastHumanInputAt = Date() }
        inputPending = inputClassifier.pending
    }

    private func outerInputIsReady() -> Bool {
        var descriptor = pollfd(fd: outer, events: Int16(POLLIN), revents: 0)
        let result = poll(&descriptor, 1, 0)
        return result > 0 && descriptor.revents != 0
    }

    private func writeAll(_ bytes: [UInt8], to descriptor: Int32) -> Bool {
        guard !bytes.isEmpty else { return true }
        var written = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { raw -> Int in
                Darwin.write(descriptor, raw.baseAddress!.advanced(by: written), bytes.count - written)
            }
            if count > 0 { written += count; continue }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                var waiter = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
                if remaining > 0, poll(&waiter, 1, Int32(remaining * 1_000)) > 0 { continue }
            }
            return false
        }
        return true
    }
}

/// ECMA-48 private parameter leaders. A parameter string that starts with one of these belongs to
/// a private-use control, which in practice is only ever a terminal answering a query: kitty
/// keyboard flags (`CSI ? <flags> u`), device attributes (`CSI ? ... c`, `CSI > ... c`), DECRPM
/// (`CSI ? <mode>;<value> $ y`) and SGR mouse reports (`CSI < ... M`). No keyboard encoding starts
/// here: kitty spells a key as `CSI <code>;<mods> u`, xterm's modifyOtherKeys as `CSI 27;... ~`,
/// and a cursor key carries no parameter at all. Listing the replies instead was the bug this
/// replaces: `CSI ? 0 u` was missing from the list, so every Ghostty, kitty, WezTerm and modern
/// iTerm2 start-up looked like a person typing and held every direct send for the whole session.
private let codexPrivateParameterLeaders = Array("?><=".utf8)

/// Introducers of the control strings a terminal replies with: DCS (XTVERSION, XTGETTCAP), APC,
/// PM and SOS. They are read to their terminator exactly like OSC.
private let codexControlStringIntroducers = Array("]P_^X".utf8)

/// Splits what arrives from the outer terminal into keyboard edits and the terminal's own replies.
/// It is a value of its own so the grammar can be exercised without owning a PTY.
struct CodexTerminalInputClassifier {
    private var carry: [UInt8] = []

    /// An incomplete escape sequence is not evidence that the composer is clear. The supervisor
    /// holds queued input until it can classify the remainder on a later pump.
    var pending: Bool { !carry.isEmpty }

    /// `true` when this chunk carried at least one byte a person could have typed. Bytes may split
    /// across chunks, so an unfinished sequence is carried into the next call rather than judged.
    mutating func consume(_ bytes: [UInt8]) -> Bool {
        carry += bytes
        var index = 0
        var human = false
        while index < carry.count {
            guard carry[index] == 0x1B else { human = true; index += 1; continue }
            guard index + 1 < carry.count else { break }
            let next = carry[index + 1]
            if next == UInt8(ascii: "[") {
                guard let end = csiEnd(from: index) else { break }
                if !isTerminalControlCSI(carry[index...end]) { human = true }
                index = end + 1
            } else if codexControlStringIntroducers.contains(next) {
                // OSC comes from terminal integration, and DCS, APC, PM and SOS carry version and
                // capability replies. Retaining an incomplete string as pending is conservative,
                // and a completed reply is not a composer edit. A meta keypress spelled the same
                // way (Alt+Shift+P) is held instead of stamped, which is the safe direction: it
                // refuses a send rather than overwriting a draft.
                guard let end = controlStringEnd(from: index) else { break }
                index = end + 1
            } else {
                // Meta keys and unfamiliar escape sequences are user input. They must hold a send.
                human = true
                index += 2
            }
        }
        carry = index < carry.count ? Array(carry[index...]) : []
        if carry.count > 256 {
            // A terminal reply cannot reasonably remain unbounded. Treat it as an edit rather than
            // risk declaring a very long, malformed sequence harmless.
            human = true
            carry.removeAll()
        }
        return human
    }

    private func csiEnd(from start: Int) -> Int? {
        // Legacy X10 mouse reports have `ESC [ M` plus exactly three binary bytes.
        if start + 2 < carry.count, carry[start + 2] == UInt8(ascii: "M") {
            return start + 5 < carry.count ? start + 5 : nil
        }
        guard start + 2 < carry.count else { return nil }
        return ((start + 2)..<carry.count).first { (0x40...0x7E).contains(carry[$0]) }
    }

    private func controlStringEnd(from start: Int) -> Int? {
        var index = start + 2
        while index < carry.count {
            if carry[index] == 0x07 { return index }
            if carry[index] == 0x1B {
                guard index + 1 < carry.count else { return nil }
                if carry[index + 1] == UInt8(ascii: "\\") { return index + 1 }
            }
            index += 1
        }
        return nil
    }

    private func isTerminalControlCSI(_ sequence: ArraySlice<UInt8>) -> Bool {
        let bytes = Array(sequence)
        guard bytes.count >= 3 else { return false }
        let final = bytes.last!
        let body = bytes.dropFirst(2).dropLast()
        if bytes == [0x1B, 0x5B, 0x49] || bytes == [0x1B, 0x5B, 0x4F] { return true } // focus
        if let leader = body.first, codexPrivateParameterLeaders.contains(leader) { return true }
        if final == UInt8(ascii: "R"), body.allSatisfy({ "0123456789;".utf8.contains($0) }) { return true }
        return false
    }
}

private func codexRelaySetNonBlocking(_ descriptor: Int32) -> Bool {
    let flags = fcntl(descriptor, F_GETFL)
    return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
}

let codexPTYChildCommand = "--internal-codex-pty-child"

/// The relay's child-side entry. `posix_spawn` has made this process a session leader and opened
/// the slave; macOS requires this explicit claim before the provider exec inherits the terminal.
@discardableResult
func runCodexPTYChildIfRequested() -> Bool {
    let arguments = CommandLine.arguments
    guard arguments.count >= 3, arguments[1] == codexPTYChildCommand else { return false }
    guard ioctl(STDIN_FILENO, TIOCSCTTY, 0) == 0 else { exit(127) }
    let program = arguments[2]
    guard !program.isEmpty else { exit(127) }
    var argv: [UnsafeMutablePointer<CChar>?] = ([program] + arguments.dropFirst(3)).map { strdup($0) }
    argv.append(nil)
    defer { for pointer in argv { free(pointer) } }
    if program.contains("/") { execv(program, &argv) }
    else { execvp(program, &argv) }
    exit(127)
}
