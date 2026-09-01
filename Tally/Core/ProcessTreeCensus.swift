import Foundation

/// WHICH PROCESSES A READING IS ABOUT, AND WHOSE THE THING BEING HELD IS.
///
/// Three rules that decide membership and ownership at ONE INSTANT: which pids the count on the
/// card is counting, which single process is holding the memory the card prints, and which one is
/// holding a port. None of them differences two readings, which is the seam this file was split
/// from `ProcessTreeStats.swift` along: the CPU's and the disk's own blame cannot be moved here,
/// because deciding who burned a rate is the same arithmetic as deciding how big the rate was
/// (`ProcessTree.cpuPercent`, `blame`, now in `ProcessTreeRates.swift`). `leader(of:)` stays over
/// there with them and is asked from both sides - it is the one rule shared by every kind of blame
/// this app makes.
///
/// PURE, like everything either file holds, so the assertion harness can state each of these with
/// no processes around it.
/// WHO WAS HOLDING A PORT, AND WHICH PROCESS THAT WAS.
///
/// THE START TIME IS CARRIED AS WELL AS THE PID BECAUSE THE PID IS NOT AN IDENTITY. The ports are
/// read on their own slow beat and held in between - every third visible tick, and dropped
/// altogether when the last viewer goes (`ProcessFootprintStore.endViewing`), so what is held here
/// is at most two visible ticks old. The machine hands pid numbers out again, and a name looked up
/// from the CURRENT table of programs against a pid from the OLD reading is a confident wrong
/// answer: `:3000 (esbuild)` beside a process that has never held 3000. Recording WHEN the holder
/// started turns that into a comparison anybody can make (`ProcessTree.portNames`).
///
/// THE PROGRAM'S PATH WOULD NOT HAVE DONE, which is what this used to record. Two processes running
/// the same program have the same path, and a program being restarted is exactly how a pid comes to
/// be reused inside a tree of node and python workers - so the one recycling that produces a WRONG
/// name rather than a missing one is the one a path comparison cannot see. A start time is
/// different for every holder of a number (`ProcessIdentity.startedAt`), which is the property the
/// supervisor already identifies a Claude Code by (`ProcessStamp`): one pid identity rule in this
/// repository rather than one per subsystem.
///
/// This is the same shape as the fork join-key defect this repository has already been bitten by
/// four times (memory `tally-fork-join-key-incident`): a stale key looked up in a fresh table.
struct ProcessPortHolder: Equatable {
    var pid: pid_t
    /// When it started, or nothing when the machine would not say. Nothing is not a wildcard: a
    /// holder the table could not state then cannot be confirmed as the same process now, so it is
    /// never named.
    var startedAt: Int64?
}

extension ProcessTree {

    /// WHAT THE SESSION STARTED: the tree it was measured over, less the one process at its head.
    ///
    /// A COUNT OF THE FAN-OUT, NOT OF THE SESSION EXISTING. Every card on this board has a Claude
    /// Code (or a Codex) in it by construction, so counting that one makes `1 proc` the reading of
    /// a session that has started nothing at all, and the number a reader has to subtract one from
    /// before it says anything: `2 procs` was what a session running a single MCP server reported
    /// (Albert, 2026-08-16, third time this line was queried). Taken out, the count is what the row
    /// it leads is read as being about - how much work this session has put on the machine.
    ///
    /// BY THE PID THE SUPERVISOR PUBLISHED, NEVER BY THE PROGRAM'S NAME. The supervisor spawned the
    /// child and writes its pid down (`SessionStateRecord.childPid`), which buys three things a
    /// name cannot: a Codex session drops `codex` under the very same rule, with nothing here
    /// knowing what a provider is; a Claude Code the session ITSELF started (`claude -p` in a
    /// script, a nested agent) is still counted, which is exactly what the count exists to show;
    /// and a wrapper script that has not yet exec'd into the CLI is still the child, where a name
    /// test would have matched nothing for that moment.
    ///
    /// A SESSION WHOSE CHILD IS NOT PUBLISHED KEEPS ITS OLD READING - a supervisor too old to write
    /// the field, or the first tick of one that has not yet. Nothing is guessed in its place: the
    /// honest cost is one card on a mixed board counting one more process than its neighbours, and
    /// every fallback available here (the root's own direct child, the first process called
    /// `claude`) is wrong on the sessions it would fire on, since the supervisor spawns ordinary
    /// commands of its own and a name is not an identity.
    ///
    /// A KNOWN EDGE THIS DOES NOT CLOSE: a session started INSIDE another one (`tally claude` from
    /// a supervised terminal) is counted twice - once on its own card and once on its parent's,
    /// whose tree it genuinely is in. Only the nested SUPERVISOR comes out (`ownFamily` knows Tally
    /// by its program), and its Claude Code and everything under it stay in the parent's numbers,
    /// memory included. Which of the two readings is right is a question about what a session is,
    /// not a defect in this rule.
    static func dispatched(_ pids: some Sequence<pid_t>, child: pid_t?) -> Set<pid_t> {
        var started = Set(pids)
        if let child { started.remove(child) }
        return started
    }

    /// Which single process is holding MORE THAN HALF of what the tree holds, or nobody.
    ///
    /// THE SAME OVER-HALF RULE THE RATES ARE BLAMED BY (`leader`), on an instant rather than on a
    /// difference: memory needs no earlier reading, so this is the one culprit a card can name on
    /// its very first tick, before there is any interval to state a CPU percentage over.
    ///
    /// Tally's own are out of it for the reason they are out of the sum this names the holder of
    /// (`ProcessResourceSample.memoryBytes`): a card must not answer "what is holding your memory"
    /// with the meter that is reading it.
    static func memoryLeader(_ sample: ProcessResourceSample) -> pid_t? {
        var held: [pid_t: Double] = [:]
        for (pid, bytes) in sample.memory where !sample.ours.contains(pid) && bytes > 0 {
            held[pid] = Double(bytes)
        }
        return leader(of: held)
    }

    /// Who holds each port, out of every (port, pid) pair the descriptor walk found
    /// (`listeningPorts`).
    ///
    /// THE LOWEST PID WINS A PORT TWO PROCESSES ARE ON, and the choice is arbitrary on purpose:
    /// with `SO_REUSEPORT` (a node cluster, a worker pool) several processes really are listening
    /// on 3000, so any of them is a true answer and none is the whole one. What matters is that the
    /// answer is DECIDABLE - the walk visits pids in whatever order a Set hands them over, so "the
    /// first one seen" is not a rule at all and would give the card a name that changed every third
    /// tick.
    ///
    /// Port zero is not a port: it is what an unbound or unreadable socket reports, and a card
    /// saying `:0` would be reporting the read rather than the machine.
    static func holders(of found: some Sequence<(port: UInt16, pid: pid_t)>) -> [UInt16: pid_t] {
        var holders: [UInt16: pid_t] = [:]
        for one in found where one.port > 0 {
            holders[one.port] = holders[one.port].map { min($0, one.pid) } ?? one.pid
        }
        return holders
    }

    /// The same answer with each holder's start time recorded beside it, which is what makes the
    /// reading safe to CACHE (`ProcessPortHolder`).
    ///
    /// - Parameter startedAt: when a pid began, out of the same table walk the tree's membership
    ///   comes from (`ProcessTree.liveProcesses`), asked as a function for the reason `ownFamily`
    ///   asks for a program that way - this stays pure, and the harness can state it with no
    ///   processes around it.
    static func held(_ holders: [UInt16: pid_t],
                     startedAt: (pid_t) -> Int64?) -> [UInt16: ProcessPortHolder] {
        holders.mapValues { ProcessPortHolder(pid: $0, startedAt: startedAt($0)) }
    }

    /// What to print beside each held port, which is a name only where the holder is STILL THE
    /// PROCESS THAT WAS HOLDING IT.
    ///
    /// THREE WAYS TO END UP WITH NO NAME, and all three are the same answer for the same reason -
    /// this app cannot say who has that port right now: the pid has gone (nothing to compare), the
    /// pid belongs to a process that started after the port was read (a recycled number, whether or
    /// not it is running the same program), or the machine would not state the start time at either
    /// end. The card then prints the bare number, which is the fact it is sure of.
    ///
    /// AND THE NAME IS READ FROM THE CURRENT TABLE once that comparison passes, rather than being
    /// carried from the reading: the same process is the right thing to name whatever it is running
    /// now, so a wrapper script that has since exec'd into the program it wraps is named as the
    /// program (`displayName`) instead of not at all.
    static func portNames(_ holders: [UInt16: ProcessPortHolder],
                          startedAt: (pid_t) -> Int64?,
                          executable: (pid_t) -> String?) -> [UInt16: String] {
        holders.compactMapValues { holder in
            guard let began = holder.startedAt, startedAt(holder.pid) == began,
                  let path = executable(holder.pid) else { return nil }
            return displayName(forPath: path)
        }
    }
}
