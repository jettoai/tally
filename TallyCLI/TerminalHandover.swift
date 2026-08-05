import Darwin
import Foundation

// Handing the terminal from one child to the next.
//
// The supervised child is a TUI: it puts the terminal in raw mode and it TALKS to the terminal
// emulator, which talks back. Claude Code 2.1.222 asks three questions in its first 300ms
// (measured 2026-08-05 through a pty proxy): `ESC [ > 0 q` (which terminal are you), `ESC [ c`
// (device attributes) and `ESC [ ? 2026 $ p` (do you do synchronized output). Every answer comes
// back the way a keystroke does, as bytes in the terminal's INPUT queue, and the child also turns
// on modes whose notifications arrive unprompted later: focus reporting (`?1004h`) and
// colour-scheme changes (`?2031h`).
//
// A relaunch kills that child and starts another on the same terminal, and the gap between them
// belongs to nobody. Whatever the terminal queues in it - the answer to a question the dead child
// asked and never collected, a focus report, whatever the user typed into a terminal whose reader
// had just been killed - stays on the device, and the FIRST read of the NEXT child collects all of
// it. An answer is not text anyone typed, but by the time the new TUI's input handler sees it, it
// is only bytes: it lands in the prompt box. That is the "odd characters in the input box after a
// restart" this exists to stop, reported 2026-08-05 in two different projects, one of them on a
// "model change at idle" relaunch.
//
// The shape of the two samples says where to look if it ever comes back. Both were short runs of
// unrelated characters, one of them ending in a stray CJK glyph, which is what an X10 mouse report
// looks like when something else consumes its `ESC [ M` introducer: three raw bytes (button, column
// and row, each offset by 32) rendered as text, and any byte past 0x7f pulled into a multi-byte
// glyph. Claude Code turns mouse tracking off on its way out (`?1006l ?1003l ?1002l ?1000l`,
// captured), which is also the evidence that it turns it on, and a moving mouse produces a report
// per movement: exactly the kind of traffic that is in the air when a restart lands.
//
// MEASURED 2026-08-05, tally's own spawn/kill sequence driving stand-in children inside a real
// terminal emulator, each child tagging its cursor-position query with a distinct ROW so the
// answer's origin is not a matter of opinion. Child A asked from row 5 and was killed; child B
// asked from row 9. B's first read, byte for byte:
//
//     1b 5b 35 3b 31 52 1b 50 3e 7c ...        ESC[5;1R  ESC P >|tmux 3.6a ESC \  ESC[?1;2;4c
//     (A's answer, then A's terminal-name answer, then B's own)
//
// and with four characters typed into the gap, they arrived in the middle of it. With the drain
// below in place, B read its own answer and nothing else, five runs out of five.
//
// The graceful path is not exempt, which is the part worth stating: the dying child restores the
// terminal to canonical mode on its way out, and that does NOT discard the queue - the bytes are
// carried over to the canonical side and handed to the next reader that asks for raw. The one
// thing that DOES discard them is entering raw mode with `TCSAFLUSH`, and the real child does not:
// libuv (node, so Ink, so claude) enters raw mode with `TCSADRAIN`.

/// How long the drain waits before its second flush.
///
/// An answer is generated when the emulator PROCESSES the query, so nearly everything the dying
/// child left behind is queued before it has even been reaped (measured through a pty proxy: the
/// answers to claude's startup queries at 0.307s arrived inside the same millisecond, and the
/// kill-to-spawn path costs more than that on its own). The wait is margin for the case where that
/// is not true - an emulator busy repainting answers late - and it is bounded because it is paid on
/// every relaunch, where it sits beside the second or more the new child spends starting up.
let terminalDrainSettle: TimeInterval = 0.12

/// Discard whatever the terminal has queued for a reader: once now, once after the settle, so an
/// answer still being written when the first flush ran does not survive the second.
///
/// WHAT IT COSTS, stated plainly: keystrokes typed into the gap are discarded along with the rest.
/// They were already lost - the child that would have received them is dead, and the new one starts
/// with an empty prompt - so what is really at stake is whether that fragment is dropped or pasted
/// into the next session's input box on top of whatever the terminal replied. There is no third
/// option available here: nothing on this side can tell a keystroke from an answer, because the
/// terminal delivers both as bytes on the same queue.
///
/// `tcflush` rather than reading the bytes away, and the difference is not stylistic: the
/// supervisor's non-urgent gates read the terminal's ATIME to tell whether anyone is typing
/// (KeyboardIdle.swift), a read stamps it, and even a read that returns EAGAIN stamps it. Draining
/// by reading would forge the very signal those gates exist to measure.
///
/// It reports nothing about what it discarded on purpose. The obvious counter (`FIONREAD` before
/// each flush) was written first and measured wrong: at handover the terminal is back in canonical
/// mode, where that ioctl answers with the bytes in COMPLETED LINES, so it said 0 about a queue
/// that demonstrably still held 30 bytes of the dead child's answer. A number that reads zero when
/// the thing it counts is present is worse than no number.
///
/// Best-effort throughout: a flush that fails costs a clean prompt, never the relaunch.
func drainTerminalInput(fd: Int32 = STDIN_FILENO, settle: TimeInterval = terminalDrainSettle,
                        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
    // Only a terminal has an input queue to drain. With stdin on a pipe or a file the child reads
    // that instead, and there is no shared device for stale bytes to sit on.
    guard isatty(fd) == 1 else { return }
    tcflush(fd, TCIFLUSH)
    guard settle > 0 else { return }
    sleep(settle)
    tcflush(fd, TCIFLUSH)
}
