import Darwin
import Foundation

// Taking a worktree's processes down, and leaving the terminal they were using in a state a person
// can type into afterwards.
//
// Two failures seen in the field on 2026-07-27, both after a teardown that reported success:
//
//   - The tab was left unusable. A full-screen TUI puts the terminal in raw mode, turns on mouse
//     tracking and switches to the alternate screen, and undoes all of it on the way out. Killed,
//     it never gets to: `ISIG` stays off so Ctrl+C arrives as a byte instead of a signal, and mouse
//     movement prints "35;10;45M" style reports as text. The user's only way out was `stty sane`
//     typed blind, or closing the tab.
//   - A killed session came back. The supervisor's whole job is to relaunch the child it is
//     watching, so signalling parent and child together races: notice the dead child first and it
//     starts a fresh one, which is not in the list being killed and outlives the teardown. The tell
//     is "restarting this session on the new build" appearing during a removal.
//
// Both fixes are best-effort in the same direction: never let restoring a terminal, or a stubborn
// respawn, stop the teardown from finishing.

/// How many times the kill loop may find new processes and go round again. One pass plus two
/// rescans: enough for a supervisor that got a relaunch in before it died (and for that child to
/// have started one of its own), while a bounded count means a process that respawns forever ends
/// the command with a warning instead of spinning in it.
let worktreeKillRounds = 3

// MARK: - Order (pure)

/// The two waves a batch is signalled in: the supervisors first, then everything else in the order
/// it was scanned.
///
/// A supervisor here is a target that PARENTS another target, or one wearing our own binary's name
/// (the relationship is the real signal; the name covers a scan where libproc would not give a
/// parent). Signalling it first, and confirming it is gone before touching its children, is what
/// keeps it from doing its job at the worst moment: the relaunch it would fire on noticing a dead
/// child produces a process that no list from before the kill can name.
func killWaves(_ targets: [ProcInfo]) -> (supervisors: [ProcInfo], rest: [ProcInfo]) {
    let parentPids = Set(targets.map(\.ppid))
    let isSupervisor = { (process: ProcInfo) in
        parentPids.contains(process.pid) || process.name == "tally"
    }
    return (targets.filter(isSupervisor), targets.filter { !isSupervisor($0) })
}

/// The distinct controlling terminals of the processes we signalled, first seen first, skipping the
/// ones libproc would not name. Only terminals belonging to processes this teardown actually killed
/// are ever touched: nothing scans for tabs, and a session running elsewhere is none of our
/// business.
func terminalsToRestore(_ processes: [ProcInfo]) -> [String] {
    var seen = Set<String>()
    return processes.compactMap { process in
        guard let tty = process.tty, !tty.isEmpty, seen.insert(tty).inserted else { return nil }
        return tty
    }
}

// MARK: - Killing

/// SIGTERM the matched processes, poll up to 2 seconds for a graceful exit, then SIGKILL the
/// survivors. Supervisors go first and are confirmed dead before their children are touched; after
/// the last one is down, `rescan` is asked whether anything new appeared in the worktree, and the
/// round repeats up to `worktreeKillRounds`. Prints "terminated <pid> <name>" for those that exited
/// on the TERM and "killed <pid> <name>" for those that needed the KILL. Returns how many were
/// signalled in total, respawns included. Finally hands back every terminal they were using.
func killWorktreeProcesses(_ targets: [ProcInfo], rescan: () -> [ProcInfo] = { [] }) -> Int {
    guard !targets.isEmpty else { return 0 }
    var batch = targets
    var signalled: [ProcInfo] = []
    var round = 1
    while true {
        let waves = killWaves(batch)
        signalTargets(waves.supervisors)
        signalTargets(waves.rest)
        signalled += batch
        guard round < worktreeKillRounds else { break }
        round += 1
        let respawned = rescan()
        guard !respawned.isEmpty else { break }
        warn("\(respawned.count) process\(respawned.count == 1 ? "" : "es") respawned in the "
            + "worktree; killing again")
        batch = respawned
    }
    let leftovers = rescan()
    if !leftovers.isEmpty {
        warn("\(leftovers.count) process\(leftovers.count == 1 ? "" : "es") still running in the "
            + "worktree after \(worktreeKillRounds) rounds; continuing")
    }
    restoreTerminals(terminalsToRestore(signalled))
    return signalled.count
}

/// One wave: TERM everything in it, poll for two seconds, KILL whoever is left. Returns once every
/// target is gone (or has been sent a KILL), which is what lets the caller treat "supervisor first"
/// as a real ordering rather than a hint.
private func signalTargets(_ targets: [ProcInfo]) {
    guard !targets.isEmpty else { return }
    for target in targets { kill(target.pid, SIGTERM) }
    var remaining = targets
    let deadline = Date().addingTimeInterval(2)
    while !remaining.isEmpty, Date() < deadline {
        usleep(100_000)
        var stillAlive: [ProcInfo] = []
        for target in remaining {
            if kill(target.pid, 0) == 0 {
                stillAlive.append(target)
            } else {
                warn("terminated \(target.pid) \(target.name)")
            }
        }
        remaining = stillAlive
    }
    for target in remaining {
        kill(target.pid, SIGKILL)
        warn("killed \(target.pid) \(target.name)")
    }
}

// MARK: - Handing the terminal back

/// What a terminal needs told after a full-screen program died without cleaning up: mouse reporting
/// off in every mode it might have enabled (normal, button-event, any-event, and the SGR encoding
/// that produced the "35;10;45M" text on screen), bracketed paste and focus reporting off, back off
/// the alternate screen, cursor visible, attributes reset.
private let terminalResetSequence =
    "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l"   // mouse tracking, all modes
    + "\u{1B}[?2004l\u{1B}[?1004l"                           // bracketed paste, focus reporting
    + "\u{1B}[?1049l\u{1B}[?47l"                             // leave the alternate screen
    + "\u{1B}[?25h\u{1B}[0m"                                 // cursor back, attributes reset

/// The line left in the tab afterwards.
///
/// The shell in it was deliberately not killed (killing one closes the user's tab), so what remains
/// is a working prompt whose cwd has just been deleted: every `ls` and every tab-completion fails
/// for a reason nothing on screen explains. One line says who did it and what to do about it. It
/// claims only what is already true when it is written, since the git removal that follows can
/// still refuse.
let worktreeShellNotice = "[tally] tally worktree remove closed the agents running here; "
    + "this worktree directory is going away, so cd elsewhere to keep using this shell"

/// Put each terminal back into a state a shell can be used in. Every step is best-effort and
/// failure is silent: a terminal that has already gone away, or that we may not open, is not a
/// reason to report a teardown as failed. It has none of the side effects the teardown proper does.
func restoreTerminals(_ paths: [String]) {
    for path in paths { restoreTerminal(path) }
}

private func restoreTerminal(_ path: String) {
    // O_NOCTTY so opening someone else's terminal cannot make it ours; O_NONBLOCK so a tty with no
    // reader on the other end cannot park the teardown in open().
    let descriptor = open(path, O_WRONLY | O_NOCTTY | O_NONBLOCK)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    write(descriptor, terminalResetSequence)
    var settings = termios()
    guard tcgetattr(descriptor, &settings) == 0 else { return }
    // The line discipline the shell expects: canonical input with echo, and the keys that make
    // signals (Ctrl+C above all) doing so again. Raw mode had turned exactly these off.
    settings.c_lflag |= tcflag_t(ICANON | ISIG | ECHO | ECHOE | ECHOK | IEXTEN)
    settings.c_iflag |= tcflag_t(ICRNL | BRKINT | IXON)
    settings.c_oflag |= tcflag_t(OPOST | ONLCR)
    guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else { return }
    // Last, and only once the terminal can render it: the same bytes sent through a raw-mode tty
    // would arrive as the mess this is here to replace. The leading CR ends whatever half-drawn
    // line the killed program left the cursor on.
    write(descriptor, "\r\n\(worktreeShellNotice)\n")
}

/// Write a whole string to a descriptor, ignoring the result: nothing here is worth failing a
/// teardown over, and a partial write to a tty that is going away changes nothing.
private func write(_ descriptor: Int32, _ text: String) {
    _ = text.withCString { write(descriptor, $0, strlen($0)) }
}
