import Darwin

// HOW A `tally claude` SUPERVISOR IS TOLD TO END, and why it no longer simply dies.
//
// SIGINT and SIGQUIT are ignored (Supervisor.swift): the foreground group shares them with the
// child, and they mean "interrupt the turn". SIGHUP (the terminal went away: a closed window, a
// `tmux kill-session`) and SIGTERM (somebody asked this process to stop) used to take the default
// action, which killed the supervisor mid-sleep with its exit path never run: no `session.ended`,
// no `wait.resolved(session-ended)` for a wait still standing, no delivery of either (real CLI run,
// 2026-09-23: a killed tmux session left zero new spool lines, where Codex's supervisor, which
// already trapped both, wrote both events).
//
// So the handler does the one async-signal-safe thing, records which signal came, and the poll
// loop does the rest on its own thread: it forwards the signal to the child (for SIGHUP the child
// usually has it already, from the same hangup; a second one is harmless) and leaves through the
// ordinary exit path, the same one a child exiting on its own takes. The loop polls with a 2s
// `usleep`, which a handled signal interrupts, so the flag is read on the next pass rather than
// after a blocking wait.
//
// Handlers do not survive `execv`, so a self-update image installs its own at startup; a
// relaunch (handoff) never execs and keeps them.

nonisolated(unsafe) private var claudeSupervisorSignal: Int32 = 0

/// Called once at startup, beside the SIGINT/SIGQUIT ignores.
func installSupervisorTerminationHandlers() {
    signal(SIGTERM) { claudeSupervisorSignal = $0 }
    signal(SIGHUP) { claudeSupervisorSignal = $0 }
}

/// The termination signal this supervisor has received, or 0.
var supervisorTerminationSignal: Int32 { claudeSupervisorSignal }

/// True when a termination signal has arrived, after forwarding it to the child if it is still
/// running. The pid is safe to signal while `isRunning` holds: an unreaped child keeps its pid.
func forwardSupervisorTermination(to child: ChildReaper) -> Bool {
    let received = claudeSupervisorSignal
    guard received != 0 else { return false }
    if child.isRunning { kill(child.pid, received) }
    return true
}
