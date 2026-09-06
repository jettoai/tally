import Darwin
import Foundation

// Ending a supervised child at a handoff, along with the tree under it and, when that handoff
// moves the session to another account, the jobs that tree has already been detached from.
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
//
// AND WHY THE TREE IS NOT THE WHOLE LIST. That snapshot only reaches what is STILL attached to the
// child, and the jobs most worth ending are the ones that detached before the handoff began. Claude
// Code's Bash tool puts each command in a job of its own, so `nohup pnpm dev > log 2>&1 &` leaves
// the command shell dead within milliseconds; measured on this machine (2026-09-06) the surviving
// server read `ppid 1, pgid 28909`, launchd for a parent and the group of a shell that had already
// exited. Parentage cannot name it and neither can the group, because nothing alive carries that
// number any more. What can is the mark it was started with: every child a supervisor spawns is
// given `TALLY_SUPERVISOR_PID` and `TALLY_SUPERVISOR_STARTED_AT` (`supervisedChildEnvironment`) and
// everything those children spawn inherits both, so a stray process naming this supervisor's pid
// AND its generation was started inside this session and nothing else was. The generation is there
// because the pid alone is a number the machine hands out again: an orphan of an older session
// under the same number can go on forking, and its children are younger than this supervisor. It is
// the claim `SessionProcessGroups.swift` keeps as a ledger for the app's attribution, generation
// check included, asked here of the process itself because a handoff needs the answer at one
// instant and has no tick behind it.
//
// AND WHY THE DETACHED HALF IS ASKED FOR ONLY WHEN THE ACCOUNT MOVES. The tree is ended on every
// handoff, because an attached process is part of the turn being ended and loses its parent
// whichever way the relaunch goes. A detached job is the opposite case: it was detached precisely
// so that it would outlive the turn, and what makes ending it right is the account it would go on
// working against rather than the relaunch itself. So the caller says which of the two this is
// (`sweepDetached`), and a relaunch that stays on the same account takes the tree alone, the way
// every handoff did before this sweep existed. That is the common case rather than the corner:
// 965 of the 1289 handoffs on this machine are same-account by construction, 818 of them the app's
// own self-update, with reload, model fallback, safeguard and cap-fallback behind it.
//
// WHAT THIS DOES NOT COVER, said plainly because a list that reads as complete is how the last
// version of this file misled its reader. A process whose environment the kernel will not hand over
// (another user's, an Apple platform binary) and one started with the environment cleared (`env -i`,
// a daemon that scrubs its own) carry nothing this can read, and are left running. So is anything
// older than this supervisor, and anything naming another generation, whatever pid it is marked
// with. The direction is deliberate in all of them: silence is not evidence, and the one mistake in
// this file that cannot be taken back is signalling a stranger.
//
// One gap is left open on purpose and is meant to close by itself: a child spawned by a supervisor
// older than the generation stamp carries a pid and no generation, so for that session the sweep is
// back to the pid plus a start time, which the recycled-pid case can still slip through. Requiring
// the generation outright would NOT mean that no handoff sweeps anything: the tree kill is
// untouched, and every supervisor that STARTED on a stamping build stamps and sweeps normally from
// its first handoff. The cost is one process wide, and it is the self-update exec that makes it
// exist at all: `execv` keeps the pid and the start time, so a supervisor that upgraded into
// v0.72.1 that way would never sweep the detached jobs it started before the upgrade, for as long
// as that process lives. The fallback can be deleted once no supervisor process predating v0.72.1
// is still running.

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

/// The variable a supervisor stamps its own pid into, for every child it spawns
/// (`supervisedChildEnvironment`). Named here as well as at the writing end because this is the
/// other half of that contract, and the suite pins the two against each other by asking the writer
/// for a child environment and reading it back with this key.
let supervisorPIDEnvKey = "TALLY_SUPERVISOR_PID"

/// And the generation of the supervisor wearing that pid, in the unit the process table states
/// (`HandoffProcess.startedAt`, microseconds). A pid alone cannot say WHICH supervisor: the number
/// is handed out again, and the sweep below would otherwise take the newer supervisor's word for a
/// job an older one's session started. Stamped by the same spawn and read back by the same suite.
///
/// A supervisor whose own start time the machine will not state stamps the variable NOT AT ALL,
/// rather than empty: absent is read below as "spawned before this stamp existed" and falls back to
/// the older rule, which is the right answer to a reading nobody could take, while an empty string
/// is a generation that matches nothing and would quietly stop that session sweeping anything.
let supervisorStartedAtEnvKey = "TALLY_SUPERVISOR_STARTED_AT"

/// Everything a handoff must end: the tree under the child, plus the processes this session started
/// that are attached to nothing of ours any more.
///
/// PURE, over a table and an environment reading handed in, for the reason the walk above is. Both
/// of its mistakes are expensive and neither is visible: one missed is a dev server that outlives
/// the move and goes on working on the account the session just left, one included that is not ours
/// is a kill of something nobody asked about.
///
/// TWO MARKS KEEP THE SECOND ONE OUT, because a pid is not an identity. Pids are handed out again,
/// so a process marked with this supervisor's NUMBER may have been started under a previous
/// supervisor that wore it, and the start times alone do not separate the two: the old session's
/// orphan is older than this supervisor and drops out, but anything that orphan forks AFTERWARDS is
/// younger than this supervisor, carries the inherited number, and would read exactly like our own.
/// So the generation is asked for as well, and a process that names a different one is not ours
/// however new it is.
///
/// THE ONE PLACE THAT STILL RESTS ON THE START TIME is a child spawned by a supervisor from before
/// this stamp existed: it carries the number and no generation at all. Silence there is read as the
/// old rule (the number, plus being younger than this supervisor) rather than as a refusal, because
/// the alternative is a changeover in which no handoff sweeps anything. It can be tightened to
/// "generation or nothing" once no supervisor without one is left running, and until then the
/// recycled-pid case above stays open for those sessions only.
///
/// A table that cannot say when this supervisor started falls back to the tree alone, which is the
/// same direction every unreadable answer takes here: the smaller list.
///
/// `sweepDetached` IS THE ACCOUNT MOVE, and it asks a different question rather than a cheaper
/// version of the same one: with it false this returns the tree and reads no environment at all.
/// The distinction is the file head's - an attached process is part of the turn being ended, a
/// detached one was detached so that it would outlive the turn - and a same-account relaunch (a
/// self-update, a reload, a model fallback) leaves no account and asks for none of it to stop.
func handoffKillList(child: pid_t, supervisor: pid_t, in table: [HandoffProcess],
                     sweepDetached: Bool = true,
                     environmentValue: (pid_t, String) -> String?) -> [HandoffProcess] {
    let descendants = childTreeDescendants(of: child, in: table, excluding: [supervisor])
    // The tree on every handoff, the detached jobs only on a move. Nothing is read out of any
    // process's environment on the other path: there is no question there to answer.
    guard sweepDetached else { return descendants }
    guard let supervisorStart = table.first(where: { $0.pid == supervisor })?.startedAt else {
        return descendants
    }
    var accounted = Set(descendants.map(\.pid))
    accounted.insert(supervisor)
    accounted.insert(child)
    let mark = String(supervisor)
    let generation = String(supervisorStart)
    // The cheap tests first and the reading of the machine last: an environment is fetched only for
    // what is younger than this supervisor and not already spoken for, which mid-session is a
    // handful of processes rather than the whole table. The generation is asked for only of what
    // already carries the number, so the second reading costs nothing on everything else.
    let orphans = table.filter {
        $0.pid > 1 && !accounted.contains($0.pid) && $0.startedAt > supervisorStart
    }.filter { process in
        guard environmentValue(process.pid, supervisorPIDEnvKey) == mark else { return false }
        guard let stamped = environmentValue(process.pid, supervisorStartedAtEnvKey) else {
            return true   // spawned before this stamp existed; the number is all there is to go on
        }
        return stamped == generation
    }
    return descendants + orphans
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
    return pids.prefix(scannedPidCount(returned, capacity: pids.count)).compactMap { pid in
        pid > 0 ? handoffProcess(pid) : nil
    }
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
/// The list is `handoffKillList`'s, so it is the tree AND the jobs of this session that have
/// already lost their place in it; the two kinds of process it cannot name are in the file head.
///
/// The child's own KILL is new too, and it is what the blocking `waitpid` here used to cost: a child
/// that ignores a TERM parked the supervisor in that call for the rest of the session, with the
/// account move neither performed nor abandoned.
///
/// `sweepDetached` decides whether the second kind is in that list at all, and the caller is the
/// one that knows: the tree goes on every handoff because an attached process is part of the turn
/// being ended, while a job the turn DETACHED was detached so that it would outlive the turn, and
/// only a move to another account gives a reason to end it. A same-account relaunch therefore
/// passes false and takes the tree alone.
func endChildTree(_ child: inout ChildReaper, supervisor: pid_t = getpid(),
                  sweepDetached: Bool = true,
                  grace: TimeInterval = handoffKillGrace) {
    // Taken BEFORE the signal: after the child dies its children are reparented and no walk can
    // find them (this file's head states the whole reason). The tree plus, on a move, whatever
    // detached from it earlier in the turn, which only the mark on the process itself can still
    // name.
    let descendants = handoffKillList(
        child: child.pid, supervisor: supervisor, in: handoffProcessTable(),
        sweepDetached: sweepDetached,
        environmentValue: { processEnvironmentValue(ofProcess: Int($0), key: $1) })
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
