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

func gitSessionDirectoryIdentity(_ cwd: String) -> SessionDirectoryAnswer {
    let top = runGit(["rev-parse", "--path-format=absolute", "--show-toplevel"], cwd: cwd)
    return (resolveMainRepo(cwd: cwd),
            top.code == 0 && !top.out.isEmpty ? realpathString(top.out) : nil)
}

/// Every live session, as the report's own value type.
///
/// Everything here is published per supervisor pid and read back through the guards that own it:
/// the Claude Code pid only while that process is alive and still that supervisor's child
/// (SwitchRequest.swift), the socket only while one is really there (MessagingSocket.swift). So an
/// entry names an address that can be dialled, or names none at all; it never names a stale one.
func liveSessionInventory(dir: URL = supervisorStateDir,
                          socketDir: String = claudeMessagingSocketDir,
                          identity: SessionDirectoryIdentity = gitSessionDirectoryIdentity)
    -> [StatusReport.Session] {
    // What every session says about itself, from files and the process table: cheap, and the same
    // order the report publishes.
    let live = liveSupervisedSessions(dir: dir).map {
        (accountID: $0.session.accountID,
         pid: readSupervisorChild(pid: $0.supervisorPid, dir: dir),
         cwd: readSupervisorCwd(pid: $0.supervisorPid, dir: dir))
    }
    let answers = sessionDirectoryIdentities(Set(live.compactMap(\.cwd)), identity: identity)
    return live.map { session in
        var project: String?
        var worktree: String?
        if let cwd = session.cwd, let git = answers[cwd] {
            // Both from the one pair of answers: the key the launch profile is written in, and the
            // line's name as the pick panel writes it. Two callers, one resolution.
            project = projectPolicyKey(cwd: cwd, mainRepo: git.mainRepo)
            worktree = pickProject(cwd: cwd, mainRepo: git.mainRepo, checkout: git.checkout).worktree
        }
        return StatusReport.Session(
            accountID: session.accountID, pid: session.pid, directory: session.cwd,
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
func statusSessions(dir: URL = supervisorStateDir) -> [String: StatusReport.SessionSummary] {
    supervisedSessionsByAccount(dir: dir).mapValues {
        StatusReport.SessionSummary(contextTokens: $0.contextTokens, model: $0.sessionModel,
                                    effort: $0.sessionEffort)
    }
}
