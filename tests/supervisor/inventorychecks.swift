import Foundation

// The session inventory (SessionInventory.swift): the `sessions` block of `tally status --json`,
// which is what lets one session find another across accounts. Claude Code's own peer roster is
// partitioned by config home, so the answer has to come from the process that supervises every
// account, and the whole assembly is asserted here rather than only its pieces: the join is where a
// live address can turn into a stale one.

func runSessionInventoryChecks() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-inventory-\(UUID().uuidString)")
    // Short, and under /tmp: a unix socket's whole path has to fit in `sun_path` (104 bytes), and
    // the per-user temp directory alone is most of that. A bind that failed for length would leave
    // these assertions passing on a socket that was never made.
    let socketDir = "/tmp/tally-inv-\(UUID().uuidString.prefix(8))"
    let empty = "/tmp/tally-inv-none-\(UUID().uuidString.prefix(8))"
    try? FileManager.default.createDirectory(atPath: socketDir, withIntermediateDirectories: true)
    let at = Date(timeIntervalSince1970: 1_800_000_000)

    // A REAL PARENT AND CHILD, because the pid is only published when the process is alive AND is
    // that supervisor's own child: this process and the one that started it are exactly such a pair
    // (the same fixture the witness checks use).
    let child = getpid()
    let trunkSupervisor = String(getppid())
    let lineSupervisor = String(getpid())
    let deadPid = String((30_000 ... 99_999).first { !supervisorAlive(pid_t($0)) } ?? 99_999)

    writeSessionContext(SupervisedSession(accountID: "claude:.claude", contextTokens: 400_000,
                                          updatedAt: at), pid: trunkSupervisor, dir: dir)
    writeSupervisorChild(child, pid: trunkSupervisor, dir: dir)
    writeSupervisorCwd("/x/repo", pid: trunkSupervisor, dir: dir)
    // The parallel line, on the SAME account: two lines of one repository is the case the whole
    // block exists for, and it is also the case the per-account reading cannot express.
    writeSessionContext(SupervisedSession(accountID: "claude:.claude", contextTokens: 12_000,
                                          updatedAt: at), pid: lineSupervisor, dir: dir)
    writeSupervisorCwd("/x/repo-cart", pid: lineSupervisor, dir: dir)
    // A session whose supervisor has exited: swept eventually, but a reader running before the
    // sweep must not publish an address for a conversation that is over.
    writeSessionContext(SupervisedSession(accountID: "claude:.claude2", contextTokens: 90_000,
                                          updatedAt: at), pid: deadPid, dir: dir)
    writeSupervisorCwd("/x/gone", pid: deadPid, dir: dir)

    // Git's answers, stubbed, so the rule can be asserted without a repository on disk - and
    // counted, because asking per session rather than per directory multiplies the subprocesses on
    // a machine running ten agents in one project. Under a lock because these answers are gathered
    // concurrently, which is the same reason the real ones are.
    let tally = NSLock()
    nonisolated(unsafe) var asked: [String] = []
    let identity: SessionDirectoryIdentity = { cwd in
        tally.lock()
        asked.append(cwd)
        tally.unlock()
        return cwd == "/x/repo-cart" ? (mainRepo: "/x/repo", checkout: "/x/repo-cart")
                                     : (mainRepo: "/x/repo", checkout: "/x/repo")
    }
    func inventory(sockets: String) -> [StatusReport.Session] {
        liveSessionInventory(dir: dir, socketDir: sockets, identity: identity)
    }

    let listed = inventory(sockets: empty)
    check("every live session is listed, including two on one account",
          listed.count == 2 && listed.allSatisfy { $0.accountID == "claude:.claude" })
    check("a supervisor that has exited is not listed at all",
          !listed.contains { $0.directory == "/x/gone" })
    // The per-account reading is the same scan folded, and it keeps ONE of those two: the assertion
    // is that the two shapes disagree by design, which is why a reader asking "which sessions are
    // running" has to start from the list.
    check("…while the per-account reading keeps only the largest of them",
          supervisedSessionsByAccount(dir: dir).count == 1
              && supervisedSessionsByAccount(dir: dir)["claude:.claude"]?.contextTokens == 400_000)
    check("the list is ordered by supervisor pid, not by whatever the directory returned",
          listed.map(\.directory)
              == (getpid() < getppid() ? ["/x/repo-cart", "/x/repo"] : ["/x/repo", "/x/repo-cart"]))

    let trunk = listed.first { $0.directory == "/x/repo" }
    let line = listed.first { $0.directory == "/x/repo-cart" }
    // THE TWO PROJECT FIELDS ARE NOT ONE FIELD TWICE. A worktree keeps its own inbox, so a caller
    // that could only match the repository would deliver to the trunk; a caller that could only
    // match the checkout could not ask about the repository at all.
    check("a parallel line reports its own checkout beside the repo it belongs to",
          line?.project == "/x/repo" && line?.worktree == "cart")
    check("…and the trunk reports the two as the same directory, with no line name",
          trunk?.project == "/x/repo" && trunk?.worktree == nil)
    check("git is asked once per directory, not once per session",
          asked.sorted() == ["/x/repo", "/x/repo-cart"])

    // THE PID, and the reason it is only on one of them: the other supervisor published no child, so
    // there is nothing proved to address. Absent reads as "cannot say" rather than as a guess.
    check("the Claude Code pid is published for the session that has one",
          trunk?.pid == Int(child) && line?.pid == nil)

    // THE ADDRESS, TWO STATES ON ONE FIXTURE. Same sessions, same pids, two socket directories: the
    // field appears only when a socket is really there, which is what keeps a reader from dialling
    // an address nothing is behind once Claude Code moves where it listens.
    check("no socket on disk, no address published",
          trunk?.messagingSocket == nil && line?.messagingSocket == nil)
    bindTestSocket(at: "\(socketDir)/\(child).sock")
    let addressed = inventory(sockets: socketDir)
    check("a socket that is really there is published, whole",
          addressed.first { $0.directory == "/x/repo" }?.messagingSocket
              == "\(socketDir)/\(child).sock")
    check("…and the session with no pid still gets none",
          addressed.first { $0.directory == "/x/repo-cart" }?.messagingSocket == nil)
    // The path itself is the tripwire, so the shape it composes is pinned rather than eyeballed:
    // Claude Code names each socket for the pid listening on it, in one machine-wide directory.
    check("the address is the socket Claude Code names for that pid",
          claudeMessagingSocket(childPid: Int(child), dir: socketDir)
              == "\(socketDir)/\(child).sock"
              && claudeMessagingSocketDir == "/tmp/cc-socks")
    // …and the three ways a composed path is NOT an address, asserted on the resolver directly
    // because the inventory can only reach the first of them through a real supervisor.
    check("a pid with no socket resolves to nothing",
          claudeMessagingSocket(childPid: 9_999, dir: socketDir) == nil)
    try? "".write(toFile: "\(socketDir)/7777.sock", atomically: true, encoding: .utf8)
    check("a regular file at a socket's name is not published as one",
          claudeMessagingSocket(childPid: 7_777, dir: socketDir) == nil)
    check("and neither is a directory that has never held Claude Code",
          claudeMessagingSocket(childPid: Int(child), dir: empty) == nil)

    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.removeItem(atPath: socketDir)
}

/// A real listening socket, because what is under test is a file TYPE check: a stand-in regular file
/// would pass a check that only asked whether something is there.
func bindTestSocket(at path: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let room = MemoryLayout.size(ofValue: addr.sun_path)
    withUnsafeMutablePointer(to: &addr.sun_path) { field in
        field.withMemoryRebound(to: CChar.self, capacity: room) { _ = strlcpy($0, path, room) }
    }
    _ = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    close(fd)
}
