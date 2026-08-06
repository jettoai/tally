import Darwin
import Foundation

// One supervised child's exit status, remembered.
//
// Lifted out of the poll loop (Supervisor.swift is at the repo's file-size cap) unchanged in
// behaviour: it is the same two calls around `waitpid` the loop has always made, with the same
// reason for holding the answer.
//
// THE MEMORY IS THE POINT, not the convenience. A reaped pid cannot be waited on twice - the second
// call answers -1/ECHILD - and this is asked from three places that do not know about each other:
// the poll at the top of every tick, the blocking wait after a child exits on its own, and the
// handoff that terminates one deliberately. Without a remembered status the second of those to run
// would read a live child as gone, or a dead one as still running.

/// A child process this supervisor spawned, and what became of it.
struct ChildReaper {
    let pid: pid_t
    /// nil until the child has been reaped; the raw `waitpid` status afterwards.
    private var status: Int32?

    init(pid: pid_t) { self.pid = pid }

    /// Whether the child is still going, as far as this reaper has been told. False only after a
    /// `poll` or a `wait` has actually collected it.
    var isRunning: Bool { status == nil }

    /// Collect the child if it has already exited; return immediately if it has not (WNOHANG).
    mutating func poll() {
        guard status == nil else { return }
        var collected: Int32 = 0
        if waitpid(pid, &collected, WNOHANG) == pid { status = collected }
    }

    /// The child's exit status, blocking until it has one. EINTR is retried rather than reported: a
    /// signal arriving while we wait is not the child exiting, and every caller here wants the
    /// status rather than a reason it could not be read yet.
    mutating func wait() -> Int32 {
        if let status { return status }
        var collected: Int32 = 0
        while waitpid(pid, &collected, 0) == -1, errno == EINTR {}
        status = collected
        return collected
    }
}

/// The process exit code a supervisor should leave with, given the status its child left behind: the
/// child's own code when it exited normally, and the shell's `128 + signal` convention when a signal
/// killed it. Pure, so the encoding is assertable without spawning anything.
func supervisorExitCode(childStatus status: Int32) -> Int32 {
    (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
}
