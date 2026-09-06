import Darwin
import Foundation

// Ending a supervised child at a handoff, AND EVERYTHING IT STARTED.
//
// What the handoff did before this file existed was `kill(childPID, SIGTERM)` followed by a
// blocking `waitpid`, which is two assumptions rather than one act:
//
//   - that the signal reaches the process doing the work. It reaches the process this supervisor
//     spawned, which is `claude` on every machine measured. If a PATH ever puts a fork-style
//     launcher in front of it (a shim that starts the real binary and waits), the TERM lands on the
//     launcher, the wait returns at once, and the conversation's actual head is left running on the
//     account the session just left.
//   - that claude taking the signal ends its work. It does not: a turn caught mid tool call has a
//     `pnpm e2e`, an `xcodebuild` or a dev server of its own, and none of them is signalled by a
//     TERM sent to their parent. They are reparented to launchd and go on writing, on the old
//     account's config home, while the new child resumes the same conversation and does the work
//     again. That is the reported "two heads after an account move" in its cheapest form: not two
//     claudes, but one claude and the process tree of the turn it was killed inside.
//
// And a third, from the other end: a child that IGNORES the TERM parks the supervisor in `waitpid`
// for ever, with the session neither moved nor usable.
//
// So the shape here is `WorktreeKill.swift`'s, which was written for the same failure one command
// over (a teardown that reported success over processes still running): TERM, poll for two seconds,
// KILL whoever is left. Two waves, the child first so it gets its SessionEnd cleanup, then whatever
// of its tree outlived it.
//
// WHY THE TREE IS SNAPSHOT BEFORE THE FIRST SIGNAL. Once claude is gone its children are reparented
// to launchd, so a walk rooted at its pid finds nothing at all: by the time there is something to
// clean up, the relationship that names it has been erased. The list is therefore taken while the
// child is still alive, and every entry is re-checked against the machine before it is signalled.

/// One live process, reduced to what this decision needs: who its parent is, and enough identity to
/// tell it from a LATER process wearing the same number.
///
/// The start time is not decoration. Between the snapshot and the KILL two seconds pass, and a pid
/// freed in that window can be handed to something else; signalling on a number alone would then
/// kill a stranger, which is the one mistake in this file that cannot be taken back. Both fields
/// come out of the same libproc record, so the identity costs the walk nothing.
struct HandoffProcess: Equatable {
    let pid: pid_t
    let parent: pid_t
    /// Microseconds since the epoch, as `proc_bsdinfo` reports the process's start.
    let startedAt: Int64
}

/// How long a wave is given to exit on its own before it is killed. Two seconds, the same grace
/// `killWorktreeProcesses` gives the same processes for the same reason: it is long enough for a
/// TUI to put a terminal back and for a shell to reap what it started, and short enough that a
/// handoff nobody is watching does not sit here.
let handoffKillGrace: TimeInterval = 2

/// How often that grace is looked at. 100ms, so an ordinary child (which exits in far less) costs
/// the handoff one poll rather than the whole window.
private let handoffKillPollInterval: UInt32 = 100_000

// MARK: - Which processes (pure)

/// Everything under `child`, breadth first from the child itself, `excluding` and their subtrees
/// left out.
///
/// PURE, over a table handed in, because the alternative is a decision that can only be exercised by
/// starting real processes and killing them. What it must get right is not subtle but it is
/// unforgiving: a descendant missed is a process that outlives the move, and a process included that
/// is not one is a kill of something nobody asked about.
///
/// `pid > 1` throughout, and `excluding` on top of it: launchd and the kernel task are not anybody's
/// descendants, and the supervisor asks about its own pid so that a table which somehow describes a
/// cycle cannot walk into the process doing the killing. A pid tree has no cycles, which is exactly
/// why the guard is cheap - it says so rather than resting on it.
func childTreeDescendants(of child: pid_t, in table: [HandoffProcess],
                          excluding: Set<pid_t> = []) -> [HandoffProcess] {
    guard child > 1, !excluding.contains(child) else { return [] }
    var byParent: [pid_t: [HandoffProcess]] = [:]
    for process in table where process.pid > 1 && process.pid != child
        && !excluding.contains(process.pid) {
        byParent[process.parent, default: []].append(process)
    }
    var found: [HandoffProcess] = []
    var seen: Set<pid_t> = [child]
    var frontier: [pid_t] = [child]
    var index = 0
    while index < frontier.count {
        let parent = frontier[index]
        index += 1
        for process in byParent[parent] ?? [] where seen.insert(process.pid).inserted {
            found.append(process)
            frontier.append(process.pid)
        }
    }
    return found
}

/// Whether the process wearing `recorded.pid` right now is still the one that was recorded.
///
/// A pid that answers nothing has gone, which is the ordinary outcome and needs no signal. A pid
/// that answers with a different start time is a DIFFERENT process that inherited the number, and
/// the whole point of asking is that those two look identical to `kill(pid, 0)`.
func stillTheSameProcess(_ recorded: HandoffProcess, asOf current: HandoffProcess?) -> Bool {
    guard let current else { return false }
    return current.pid == recorded.pid && current.startedAt == recorded.startedAt
}

/// The one line a handoff leaves when the turn it ended had processes of its own still running.
///
/// Said because it is the only visible trace of work being taken down: an `xcodebuild` or a dev
/// server ending mid-flight otherwise looks like the machine dropping something. Pure, so the
/// wording is assertable without a process table.
func handoffSurvivorNotice(count: Int) -> String {
    count == 1
        ? "1 process the ended turn started is still running; ending it too"
        : "\(count) processes the ended turn started are still running; ending them too"
}

// MARK: - Reading the machine

/// Every live process this user can inspect, as parent and identity only.
///
/// Deliberately NOT `defaultListProcesses` (WorktreeProcessScan.swift), which reads a cwd, an
/// executable path and a controlling terminal for every pid on the machine: this runs inside a
/// handoff, wants two integers per process, and asking libproc for the rest would be three more
/// calls per pid for fields no decision here reads.
///
/// `scannedPidCount` is shared with that scan rather than spelled again, and the reason is written
/// there: the second `proc_listallpids` returns a COUNT of pids and not a byte count, and dividing
/// it by the pid size ends the walk a quarter of the way through the machine. A tree walk that
/// stopped there would silently leave the deepest processes running, which is the exact failure
/// this file exists to end.
func handoffProcessTable() -> [HandoffProcess] {
    let capacity = proc_listallpids(nil, 0)
    guard capacity > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(capacity))
    let returned = proc_listallpids(&pids, Int32(Int(capacity) * MemoryLayout<pid_t>.size))
    var table: [HandoffProcess] = []
    for pid in pids.prefix(scannedPidCount(returned, capacity: pids.count)) where pid > 0 {
        if let process = handoffProcess(pid) { table.append(process) }
    }
    return table
}

/// One process's parent and start time, or nil when the machine will not answer for it (it has
/// ended, or it belongs to another user - either way it is not a child of ours to signal).
func handoffProcess(_ pid: pid_t) -> HandoffProcess? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    // Saturating rather than converting, for the reason `ProcessTree.liveProcesses` states about
    // the same two fields: the kernel's seconds are unsigned, and a plain multiply traps on a
    // value it cannot represent. A nonsense reading stays nonsense and stays comparable with
    // itself, which is all the identity check above asks of it.
    let seconds = min(Int64(clamping: info.pbi_start_tvsec), Int64.max / 1_000_000)
    return HandoffProcess(pid: pid, parent: pid_t(info.pbi_ppid),
                          startedAt: seconds * 1_000_000 + Int64(clamping: info.pbi_start_tvusec))
}

// MARK: - Ending it

/// Terminate the child and everything it started: TERM, up to `grace` seconds, then KILL. Returns
/// once the child has been reaped and every survivor of its tree has been signalled.
///
/// TWO WAVES RATHER THAN ONE, and the order is the same one `killWaves` argues next door. The child
/// goes first and alone, so `claude` gets its SessionEnd cleanup and the ordinary case (a session
/// between turns, nothing else running) ends exactly as it always did. Only what OUTLIVES it is
/// signalled, which is what keeps this quiet on every handoff that interrupts nothing.
///
/// The child's own KILL is new too, and it is what the blocking `waitpid` here used to cost: a child
/// that ignores a TERM parked the supervisor in that call for the rest of the session, with the
/// account move neither performed nor abandoned.
func endChildTree(_ child: inout ChildReaper, supervisor: pid_t = getpid(),
                  grace: TimeInterval = handoffKillGrace) {
    // Taken BEFORE the signal: after the child dies its children are reparented and no walk can
    // find them (this file's head states the whole reason).
    let descendants = childTreeDescendants(of: child.pid, in: handoffProcessTable(),
                                           excluding: [supervisor])
    kill(child.pid, SIGTERM)   // let claude run its SessionEnd cleanup
    var deadline = Date().addingTimeInterval(grace)
    child.poll()
    while child.isRunning, Date() < deadline {
        usleep(handoffKillPollInterval)
        child.poll()
    }
    if child.isRunning { kill(child.pid, SIGKILL) }
    _ = child.wait()

    // Re-checked against the machine, never signalled off the snapshot alone: most of these ended
    // with their parent, and a pid freed since could be somebody else's now.
    var remaining = descendants.filter { stillTheSameProcess($0, asOf: handoffProcess($0.pid)) }
    guard !remaining.isEmpty else { return }
    // The terminal is ours between a tear-down and the next spawn, which is the one window a line
    // like this may use (PendingNotice.swift states the rule).
    warn(handoffSurvivorNotice(count: remaining.count))
    for process in remaining { kill(process.pid, SIGTERM) }
    deadline = Date().addingTimeInterval(grace)
    while !remaining.isEmpty, Date() < deadline {
        usleep(handoffKillPollInterval)
        remaining = remaining.filter { stillTheSameProcess($0, asOf: handoffProcess($0.pid)) }
    }
    for process in remaining { kill(process.pid, SIGKILL) }
}
