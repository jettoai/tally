import Darwin
import Foundation

// Keyboard-aware idleness, the second half of the quiet bar a NON-URGENT relaunch waits for.
//
// A transcript goes quiet the moment a turn ends, but a user composing the NEXT prompt writes
// nothing to any file until they press enter. Two minutes of typing a long prompt therefore looks
// exactly like two minutes of an abandoned terminal, and the relaunch takes the half-typed text
// with it (the self-update wave of 2026-07-26 restarted sessions their owner considered mid-work).
//
// The keyboard is readable with no permission prompt and no process list: the child reads the
// user's keystrokes off the controlling terminal, and a read stamps that device node's atime. The
// supervisor shares the terminal, so one stat answers "has anything been typed in here lately".
//
// MEASURED on this machine 2026-07-26, because the whole idea rests on it:
//
//   - a pty in RAW mode (what a TUI runs in) stamps atime on every keystroke: five keys 1.5s apart
//     each left the node 0.3s fresh. In canonical mode the line discipline holds the bytes and only
//     the newline stamps it, so this tracks the child's reads, not the user's fingers directly.
//   - with nothing typed, atime moved 0.000s across 14s and then aged second for second.
//   - output is NOT input: across three minutes of the nine real supervised sessions on this
//     machine, /dev/ttys012 streamed a response continuously (mtime age pinned at 0s) while its
//     atime aged 93s -> 261s, and every other session aged linearly too. Nothing the child does
//     touches the node except a keystroke arriving.
//
// One reader shape would defeat this: polling the fd non-blockingly stamps atime on every EAGAIN,
// pinning it at age zero forever. The linear ageing above is what rules that out for the child we
// actually run (it waits on kqueue and reads only once a key has arrived). The note stays because
// a future child that busy-polls would make this answer "busy" always, and the symptom would be
// non-urgent relaunches quietly never firing rather than anything that looks like a fault.

/// Whether the keyboard has been still for `bar` seconds, given when input was last read off the
/// terminal.
///
/// `lastInput` is nil when there is no terminal to read (started from a script, a pipe, CI) or the
/// stat failed. Absence of a terminal is evidence of neither typing nor stillness, so it answers
/// TRUE and the check vanishes, leaving the caller with exactly the transcript rule it had before.
func keyboardIdle(lastInput: Date?, bar: TimeInterval, now: Date = Date()) -> Bool {
    guard let lastInput else { return true }
    return now.timeIntervalSince(lastInput) >= bar
}

/// This process's controlling terminal, or nil when it has none.
///
/// Resolved once: a process cannot change its controlling terminal, and this is asked on every 2s
/// poll. stdin first, since that is the terminal the child inherits and reads the keystrokes from;
/// stdout and stderr after it, because a supervisor started with its input redirected still shares
/// the user's terminal on the other two. No fd being a terminal is the "no keyboard here" case.
let controllingTTYPath: String? = {
    for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] where isatty(fd) == 1 {
        guard let name = ttyname(fd) else { continue }
        return String(cString: name)
    }
    return nil
}()

/// When input was last read off the controlling terminal, nil when there is none or the stat fails
/// (the terminal went away with its window). Both nil cases mean the same thing to the caller: no
/// evidence either way, so do what the transcript alone says.
func lastKeyboardInput(path: String? = controllingTTYPath) -> Date? {
    guard let path else { return nil }
    // `lstat` rather than `stat` because the imported struct shadows the C function of that name,
    // so `stat(path, &info)` will not compile. Identical here: a terminal is a device node, and
    // `ttyname` returns the node itself, never a symlink to one.
    var info = Darwin.stat()
    guard lstat(path, &info) == 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(info.st_atimespec.tv_sec)
        + TimeInterval(info.st_atimespec.tv_nsec) / 1_000_000_000)
}

/// The keyboard half of the quiet bar, ready to stand beside the transcript half.
///
/// The default bar is the 5s `isQuiet` defaults to, so a call site that gives neither of them a bar
/// has both halves answering the same question. All the glue lives here: everything above the stat
/// takes the answer as a plain value, so the rule is testable on a machine with no terminal at all.
func keyboardIdleNow(_ bar: TimeInterval = 5, now: Date = Date()) -> Bool {
    keyboardIdle(lastInput: lastKeyboardInput(), bar: bar, now: now)
}
