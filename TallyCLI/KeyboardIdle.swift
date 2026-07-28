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
//
// That symptom then arrived (2026-07-28), from a source the note did not predict: not a busy-poll,
// but sparse control traffic reaching the terminal as input. `KeyboardActivity` below is the
// answer, and carries the measurement.

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

// MARK: - Bursts, because "how long since the last stamp" cannot tell typing from chatter

/// Two stamps this close together are a typing burst; a lone stamp is control chatter.
///
/// MEASURED 2026-07-28 on a live idle session (dd704ccc, /dev/ttys015), with the user working in
/// another window: the node was stamped four times across three minutes, 23 to 60 seconds apart,
/// and its age never once passed 61s. Against a rule that only asks how old the newest stamp is,
/// the 120s bar on that terminal is not merely hard to reach, it is arithmetically unreachable, and
/// every non-urgent relaunch (reload, follow adoption, rebalance, self-update) quietly never fired.
/// The three file gates had all been open for the whole of it.
///
/// What the pair sees and the single stamp cannot: a pty in RAW mode stamps on every keystroke, so
/// composing a prompt arrives as a RUN of stamps seconds apart, while a focus report or a terminal
/// query reply arrives ALONE. This gap sits an order of magnitude above keystroke spacing and below
/// the smallest chatter interval measured.
let keyboardBurstGap: TimeInterval = 15

/// The terminal as the supervisor watches it over time: the newest stamp, and when two stamps last
/// landed close enough together to be a person typing.
///
/// One per child, fed `lastKeyboardInput()` on every poll tick, because a burst lives in the GAP
/// between successive stamps and no single stat can see one. The 2s tick is comfortably finer than
/// `keyboardBurstGap`, so no burst can slip between two readings.
///
/// THE TRADE-OFF, taken deliberately: a lone stamp now holds the gate for `keyboardBurstGap`
/// seconds rather than the caller's full bar, so text PASTED in (one read, one stamp) and then left
/// unsent for longer than that can be taken by a queued relaunch. Weighed against what it replaces:
/// on a chattering terminal the gate never opened at all, so the queued relaunch never landed, and
/// the user restarted the session by hand and lost that same text anyway.
struct KeyboardActivity {
    /// The newest atime seen on the terminal, whatever put it there.
    var lastStamp: Date?
    /// The newest stamp that arrived within `keyboardBurstGap` of the one before it.
    var lastBurstAt: Date?

    /// Take one poll's reading. Nil (no terminal, or a stat that failed) and a repeat of the stamp
    /// already held both mean nothing new arrived: the node is re-stamped only by input.
    ///
    /// The gap is required to be FORWARD as well as short. A stamp older than the one already held
    /// is not a keystroke that arrived quickly, it is time moving backwards (a clock adjustment, a
    /// terminal replaced under the same path), and reading its negative gap as "close together"
    /// would invent a burst and hold every non-urgent relaunch for the full 120s on no input at all.
    mutating func observe(stamp: Date?) {
        guard let stamp, stamp != lastStamp else { return }
        if let previous = lastStamp,
           (0 ... keyboardBurstGap).contains(stamp.timeIntervalSince(previous)) {
            lastBurstAt = stamp
        }
        lastStamp = stamp
    }

    /// Whether the keyboard has been still for `bar` seconds.
    ///
    /// A burst holds the caller's FULL bar: that was someone typing, and "have they stopped for two
    /// minutes" is exactly what the 120s bar asks. A lone stamp holds only until the burst window
    /// closes, since a second stamp inside that window is the very thing that would have made it
    /// typing. The `min` keeps the 5s call sites at their old meaning: a stamp 6s old was idle at
    /// that bar before any of this existed, and still is.
    func idle(_ bar: TimeInterval = 5, now: Date = Date()) -> Bool {
        if let lastBurstAt, now.timeIntervalSince(lastBurstAt) < bar { return false }
        if let lastStamp, now.timeIntervalSince(lastStamp) < min(keyboardBurstGap, bar) {
            return false
        }
        return true
    }
}
