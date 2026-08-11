import Foundation

// WHICH SESSIONS ARE RUNNING, AS `tally status --json` REPORTS THEM.
//
// The join, and a file of its own because it is the only place allowed to know both halves:
// StatusReport.swift is a pure value type that must not learn where a supervisor publishes
// anything, and SessionContext.swift must not learn what the JSON contract looks like. What used to
// live in main.swift under that same reasoning moved here when the join grew a second question to
// answer, so that the whole assembly can be asserted rather than only its pieces.
//
// Two shapes come out of ONE scan, deliberately: the per-account reading the `accounts` rows carry
// (the largest conversation on each account) and the inventory of every session there is. Two scans
// would let the same report say a session is on an account in one block and not exist in the other.
// SAID IN THE TYPE rather than in this paragraph (codex review of d2d620e): the caller is handed
// both shapes at once, so there is no way left to take the roster twice - a supervisor that exits,
// starts, or hands its session to another account between two scans is what the paragraph was
// describing, and prose does not serialise anything.

/// What git can say about a session's directory: the main repo it belongs to, and the checkout it
/// stands in. The two differ exactly when the session is on a parallel line, which is what names
/// that line (`pickProject`).
///
/// A function value rather than a call, so the assembly below can be asserted without a repository
/// on disk, and so the answer is asked once per DIRECTORY rather than once per session: several
/// agents in one project is the ordinary case here, not the exotic one, and each answer costs
/// several subprocesses (`resolveMainRepo` asks git two to four times, and this asks once more).
/// `@Sendable` because the answers are gathered concurrently below, which is a fact about how this
/// is used rather than a detail of it: an implementation that read shared mutable state would be a
/// data race, and the compiler is the right place for that to be said once.
typealias SessionDirectoryIdentity = @Sendable (String) -> SessionDirectoryAnswer

typealias SessionDirectoryAnswer = (mainRepo: String?, checkout: String?)

/// `@Sendable` on the declaration rather than at each use: it is the default the callers below take,
/// and a plain function converted to that type is a warning at every one of them.
@Sendable func gitSessionDirectoryIdentity(_ cwd: String) -> SessionDirectoryAnswer {
    let top = runGit(["rev-parse", "--path-format=absolute", "--show-toplevel"], cwd: cwd)
    return (resolveMainRepo(cwd: cwd),
            top.code == 0 && !top.out.isEmpty ? realpathString(top.out) : nil)
}

/// Both shapes the report publishes about sessions, folded from one roster.
///
/// A value type rather than two returns, because the invariant is that they describe the SAME
/// moment: a caller holding this cannot have taken the roster twice.
struct SessionReadings {
    /// The per-account reading the `accounts` rows carry.
    let accountSessions: [String: StatusReport.SessionSummary]
    /// Every session there is.
    let sessions: [StatusReport.Session]
}

/// THE ONE SCAN, AND BOTH FOLDS OF IT. The only door in: the folds below are private, so a caller
/// that wanted one of them cannot take a roster of its own to get it.
func sessionReadings(dir: URL = supervisorStateDir,
                     socketDir: String = claudeMessagingSocketDir,
                     identity: SessionDirectoryIdentity = gitSessionDirectoryIdentity)
    -> SessionReadings {
    let live = liveSupervisors(dir: dir)
    return SessionReadings(accountSessions: statusSessions(live),
                           sessions: liveSessionInventory(live, dir: dir, socketDir: socketDir,
                                                          identity: identity))
}

/// Every live session, as the report's own value type.
///
/// Everything here is published per supervisor pid and read back through the guards that own it:
/// the Claude Code pid only while that process is alive and still that supervisor's child
/// (SwitchRequest.swift), the socket only while one is really there (MessagingSocket.swift). So an
/// entry names an address that can be dialled, or names none at all; it never names a stale one.
private func liveSessionInventory(_ live: [LiveSupervisor], dir: URL = supervisorStateDir,
                                  socketDir: String = claudeMessagingSocketDir,
                                  identity: SessionDirectoryIdentity = gitSessionDirectoryIdentity)
    -> [StatusReport.Session] {
    // What every session says about itself, from files and the process table: cheap, and the same
    // order the report publishes.
    //
    // THE ACCOUNT COMES FROM THE DOCUMENT WRITTEN FOR THAT ONE QUESTION, and from the context
    // reading only when a supervisor too old to publish one is being asked about. The two move
    // together now - a handoff writes both where it decides, and the spawn rewrites the sidecar
    // again - so this is a question of which one can be WRONG rather than which is fresher: the
    // reading is written best-effort while its writer's in-memory copy moves on regardless, so a
    // publish that silently fails leaves the old account on disk with the delta suppressing every
    // retry (codex review of ff5b2a0). The sidecar is rewritten whole at both moments and has no
    // such memory. Preferring it is also what keeps this block and the per-account one describing
    // the same instant, because both are folded from this one scan.
    let sessions = live.map {
        (accountID: readSupervisorAccount(pid: $0.supervisorPid, dir: dir)
            ?? $0.session?.accountID,
         pid: readSupervisorChild(pid: $0.supervisorPid, dir: dir),
         cwd: readSupervisorCwd(pid: $0.supervisorPid, dir: dir))
    }
    let answers = sessionDirectoryIdentities(Set(sessions.compactMap(\.cwd)), identity: identity)
    return sessions.map { session in
        var directory: String?
        var project: String?
        var worktree: String?
        if let cwd = session.cwd, let git = answers[cwd] {
            // Both from the one pair of answers: the key the launch profile is written in, and the
            // line's identity as the pick panel writes it. Two callers, one resolution.
            project = projectPolicyKey(cwd: cwd, mainRepo: git.mainRepo)
            // THE CHECKOUT, WHICH IS WHAT THIS FIELD PROMISES, and the supervisor's own cwd only
            // when git can say nothing about it: `tally claude` run from a subdirectory supervises
            // the session from there, so publishing that cwd would put two lines of one repository
            // at two addresses one of which no peer can match (codex review of d2d620e). Through
            // `pickProject`, which is where the rule already lives (`let home = checkout ?? cwd`).
            let line = pickProject(cwd: cwd, mainRepo: git.mainRepo, checkout: git.checkout)
            directory = line.path
            worktree = line.worktree
        }
        return StatusReport.Session(
            accountID: session.accountID, pid: session.pid, directory: directory,
            project: project, worktree: worktree,
            messagingSocket: session.pid.flatMap {
                claudeMessagingSocket(childPid: $0, dir: socketDir)
            })
    }
}

/// Git's answer for each of those directories, asked ALL AT ONCE.
///
/// Per directory rather than per session, and concurrently, because the cost here is not git: a
/// `Process` spawn out of a Foundation binary is ~75ms against ~8ms for the same command in a
/// shell, and resolving one directory takes several of them. Serially, a machine running eleven
/// agents spent 3.3s inside this one block, on a command scripts poll for quota (measured
/// 2026-08-11: 3.48s serial against 0.32s for the same 44 spawns concurrently). The work is
/// read-only, independent per directory, and nothing here writes anything a later answer reads.
func sessionDirectoryIdentities(_ directories: Set<String>, identity: SessionDirectoryIdentity)
    -> [String: SessionDirectoryAnswer] {
    let asking = Array(directories)
    let sink = SessionIdentitySink()
    DispatchQueue.concurrentPerform(iterations: asking.count) { index in
        sink.record(asking[index], identity(asking[index]))
    }
    return sink.collected
}

/// Where that pass puts its answers. A small class with a lock of its own rather than a captured
/// var, because a var written from several threads IS a data race and saying so in a comment does
/// not serialise anything; this does, in the one place that needs it.
private final class SessionIdentitySink: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: SessionDirectoryAnswer] = [:]

    func record(_ directory: String, _ answer: SessionDirectoryAnswer) {
        lock.lock()
        answers[directory] = answer
        lock.unlock()
    }

    var collected: [String: SessionDirectoryAnswer] {
        lock.lock()
        defer { lock.unlock() }
        return answers
    }
}

/// The per-account reading the `accounts` rows carry: the published figure per account
/// (SessionContext.swift) turned into the report's own value type.
private func statusSessions(_ live: [LiveSupervisor]) -> [String: StatusReport.SessionSummary] {
    supervisedSessionsByAccount(live).mapValues {
        StatusReport.SessionSummary(contextTokens: $0.contextTokens, model: $0.sessionModel,
                                    effort: $0.sessionEffort)
    }
}
