import Darwin
import Foundation

// The handover drain (TerminalHandover.swift), tested against a real pseudo-terminal rather than a
// model of one, because every claim it rests on is a claim about what the tty line discipline does:
// that the queue survives the dying child's return to canonical mode, that `tcflush` empties it
// anyway, and that a pipe is left alone.
//
// The sequence each case reproduces is the one measured on 2026-08-05 with stand-in children under
// a real terminal emulator: bytes arrive while the terminal is in CANONICAL mode (the dead child
// restored it on its way out), and the next child then switches to raw with `TCSADRAIN` - what
// libuv, and so node, and so claude, does - which preserves them. `TCSAFLUSH` would discard them
// and prove nothing, so it is never used here.

/// A pty pair, plus the two things the tests do to it.
private struct TestTerminal {
    let primary: Int32     // the emulator's side: writing here is the terminal "sending" input
    let terminal: Int32    // the child's side: what a supervised process has on stdin

    init() {
        var primary: Int32 = 0
        var terminal: Int32 = 0
        // Fails only if the machine is out of ptys, in which case every check below is meaningless.
        guard openpty(&primary, &terminal, nil, nil, nil) == 0 else {
            fatalError("cannot allocate a pty")
        }
        self.primary = primary
        self.terminal = terminal
        // Echo off. A real terminal is attached to an emulator that reads the other side
        // continuously, so echoed input goes somewhere; here nobody reads it, the output queue
        // fills, and the first `tcsetattr(TCSADRAIN)` - which waits for output to drain - never
        // returns. It changes nothing under test: the drain is about the INPUT queue.
        var settings = termios()
        tcgetattr(terminal, &settings)
        settings.c_lflag &= ~UInt(ECHO)
        tcsetattr(terminal, TCSANOW, &settings)
    }

    /// Send bytes the way a terminal emulator does: an answer to a query, or a keystroke.
    func send(_ text: String) {
        _ = text.withCString { write(primary, $0, strlen($0)) }
        usleep(20_000)   // let the line discipline take them before anything is asked about them
    }

    /// What the next child does before its first read. TCSADRAIN, deliberately: see above.
    func enterRawMode() {
        var settings = termios()
        tcgetattr(terminal, &settings)
        cfmakeraw(&settings)
        tcsetattr(terminal, TCSADRAIN, &settings)
        _ = fcntl(terminal, F_SETFL, fcntl(terminal, F_GETFL, 0) | O_NONBLOCK)
    }

    /// Everything readable right now, as the new child's first read would collect it.
    func read() -> String {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(terminal, &buffer, buffer.count)
        guard count > 0 else { return "" }
        return String(decoding: buffer[0 ..< count], as: UTF8.self)
    }

    func close() {
        Darwin.close(primary)
        Darwin.close(terminal)
    }
}

/// What the terminal answered the DEAD child: a cursor-position report and a terminal-name reply,
/// the shapes actually captured crossing a handover.
private let staleAnswer = "\u{1b}[5;1R\u{1b}P>|ghostty 1.2.0\u{1b}\\"

func runTerminalDrainChecks() {
    // MARK: - The premise: without a drain, the dead child's answer reaches the next one

    // This is the bug, and it is checked first so the cases below cannot pass vacuously: if the
    // bytes never reached the queue at all, everything after this would "drain" nothing and agree.
    let unrained = TestTerminal()
    unrained.send(staleAnswer)
    unrained.enterRawMode()
    check("without a drain the next child reads the dead child's answer",
          unrained.read() == staleAnswer)
    unrained.close()

    // MARK: - The drain

    let drained = TestTerminal()
    drained.send(staleAnswer)
    drainTerminalInput(fd: drained.terminal, settle: 0)
    drained.enterRawMode()
    check("after a drain there is nothing left to read", drained.read() == "")
    drained.close()

    // Keystrokes typed into the gap go with it - the deliberate cost, since nothing on this side
    // can tell them from an answer.
    let typed = TestTerminal()
    typed.send("half a prompt")
    drainTerminalInput(fd: typed.terminal, settle: 0)
    typed.enterRawMode()
    check("text typed into the gap is discarded too", typed.read() == "")
    typed.close()

    // MARK: - The settle, which is the second flush

    // An answer the emulator was still writing when the first flush ran: sent from inside the
    // sleep, so only a drain that flushes AGAIN afterwards can catch it.
    let late = TestTerminal()
    late.send(staleAnswer)
    var slept = false
    drainTerminalInput(fd: late.terminal, settle: 0.05) { _ in
        slept = true
        late.send("\u{1b}[?1;2;4c")
    }
    late.enterRawMode()
    check("the settle runs when one is asked for", slept)
    check("an answer arriving during the settle is flushed too", late.read() == "")
    late.close()

    // And no settle means no wait: the callers that pass 0 are not paying for a sleep.
    let immediate = TestTerminal()
    var sleptWithoutSettle = false
    drainTerminalInput(fd: immediate.terminal, settle: 0) { _ in sleptWithoutSettle = true }
    check("settle 0 never sleeps", !sleptWithoutSettle)
    immediate.close()

    // MARK: - Not a terminal, not touched

    // With stdin on a pipe the child reads the pipe, not a shared device, and discarding it would
    // be throwing away data nobody else can deliver.
    var pipeEnds: [Int32] = [0, 0]
    pipe(&pipeEnds)
    _ = "queued".withCString { write(pipeEnds[1], $0, strlen($0)) }
    // The settle is asked for here on purpose: `tcflush` on a pipe fails harmlessly by itself, so
    // whether the guard is present shows in what it SKIPS, and the sleep is the visible half. A
    // drain that ran anyway would spend the settle on every non-terminal launch.
    var sleptOnPipe = false
    drainTerminalInput(fd: pipeEnds[0], settle: 0.05) { _ in sleptOnPipe = true }
    check("a fd that is not a terminal is left alone entirely", !sleptOnPipe)
    var buffer = [UInt8](repeating: 0, count: 64)
    let read = Darwin.read(pipeEnds[0], &buffer, buffer.count)
    // And the data is still there, which is the check that survives a rewrite: a drain that
    // emptied the queue by READING would take a pipe's contents with it.
    check("a pipe is never flushed",
          String(decoding: buffer[0 ..< max(read, 0)], as: UTF8.self) == "queued")
    close(pipeEnds[0])
    close(pipeEnds[1])

    // MARK: - The bar the settle is set at

    // Long enough to cover an emulator answering late, short enough to disappear beside the second
    // or more the new child spends starting up.
    check("the settle is bounded", terminalDrainSettle > 0 && terminalDrainSettle <= 0.5)
}
