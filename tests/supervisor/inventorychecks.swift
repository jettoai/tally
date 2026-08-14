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
    // A third live supervisor, and the one this block exists for: it has registered and published
    // where it is, and its conversation has not had a turn yet. pid 1 is alive on every machine
    // this runs on (`supervisorAlive` counts EPERM), which is the whole of what is needed here.
    let freshSupervisor = "1"
    let deadPid = String((30_000 ... 99_999).first { !supervisorAlive(pid_t($0)) } ?? 99_999)

    // THE PRESENCE ENTRY IS THE ROSTER, written before a supervisor spawns anything, so every
    // fixture here registers the way a real one does (`markSupervisorLive`, Supervisor.swift).
    for pid in [trunkSupervisor, lineSupervisor, freshSupervisor, deadPid] {
        markSupervisorLive(pid: pid, dir: dir)
    }
    writeSessionContext(SupervisedSession(accountID: "claude:.claude", contextTokens: 400_000,
                                          updatedAt: at), pid: trunkSupervisor, dir: dir)
    writeSupervisorChild(child, pid: trunkSupervisor, dir: dir)
    writeSupervisorCwd("/x/repo", pid: trunkSupervisor, dir: dir)
    writeSupervisorAccount("claude:.claude", pid: trunkSupervisor, dir: dir)
    // The parallel line, on the SAME account: two lines of one repository is the case the whole
    // block exists for, and it is also the case the per-account reading cannot express. NO account
    // document, deliberately: this is what a supervisor from a build before that file looks like,
    // and its reading is all such a session can be attributed by.
    writeSessionContext(SupervisedSession(accountID: "claude:.claude", contextTokens: 12_000,
                                          updatedAt: at), pid: lineSupervisor, dir: dir)
    writeSupervisorCwd("/x/repo-cart", pid: lineSupervisor, dir: dir)
    // The session with nothing published about it yet, launched from a SUBDIRECTORY of its
    // checkout, which is the ordinary way `tally claude` is typed inside a repository.
    writeSupervisorCwd("/x/other/deep", pid: freshSupervisor, dir: dir)
    writeSupervisorAccount("claude:.claude3", pid: freshSupervisor, dir: dir)
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
        switch cwd {
        case "/x/repo-cart": return (mainRepo: "/x/repo", checkout: "/x/repo-cart")
        // A directory INSIDE a checkout: git answers with the checkout, which is what the session
        // has to be published at.
        case "/x/other/deep": return (mainRepo: "/x/other", checkout: "/x/other")
        default: return (mainRepo: "/x/repo", checkout: "/x/repo")
        }
    }
    /// Both shapes, from the one scan that produced them: asking for either alone is what this
    /// assembly is not allowed to do.
    func readings(sockets: String) -> SessionReadings {
        sessionReadings(dir: dir, socketDir: sockets, identity: identity)
    }
    func inventory(sockets: String) -> [StatusReport.Session] { readings(sockets: sockets).sessions }

    let first = readings(sockets: empty)
    let listed = first.sessions
    // What ONE pass asked git, captured before any later pass adds to it.
    let askedOnce = asked
    check("every live session is listed, including two on one account",
          listed.count == 3
              && listed.filter { $0.accountID == "claude:.claude" }.count == 2)
    check("a supervisor that has exited is not listed at all",
          !listed.contains { $0.directory == "/x/gone" })
    // THE ROSTER IS THE PRESENCE ENTRY, NOT THE READING. A session publishes no context until its
    // conversation has had a turn with usage in it, and the commonest moment to ask what is running
    // is right after starting one - so a roster keyed on the reading answers with everything except
    // the session being asked about (codex review of d2d620e).
    let fresh = listed.first { $0.accountID == "claude:.claude3" }
    check("a session that has not written a turn yet is on the roster all the same",
          fresh != nil && listed.count == liveSupervisorPids(dir: dir).count)
    check("…named by the account its spawn published, which exists from that instant",
          fresh?.accountID == "claude:.claude3")
    check("…and a supervisor too old to publish one is still attributed by its reading",
          listed.first { $0.directory == "/x/repo-cart" }?.accountID == "claude:.claude")
    // THE CHECKOUT, WHICH IS WHAT THE FIELD PROMISES. `tally claude` typed in a subdirectory
    // supervises the session from there, and publishing that cwd would put two sessions of one
    // checkout at two addresses - so a peer matching on checkout finds neither.
    check("a session launched inside its checkout is published at the checkout, not at its cwd",
          fresh?.directory == "/x/other" && fresh?.project == "/x/other")
    // The per-account reading is the same scan folded, and it keeps ONE of those two: the assertion
    // is that the two shapes disagree by design, which is why a reader asking "which sessions are
    // running" has to start from the list.
    check("…while the per-account reading keeps only the largest of them",
          first.accountSessions["claude:.claude"]?.contextTokens == 400_000)
    // …and the session with nothing published is in the roster without being on that map at all:
    // there is no reading to attribute, which is not the same as there being no session.
    check("a session with no reading is on the roster and on no account row",
          first.accountSessions["claude:.claude3"] == nil)
    // ONE SCAN FOR BOTH BLOCKS, asserted where the report is actually assembled, because that is
    // the only place the invariant can be broken: a supervisor exiting, starting, or handing its
    // session to another account between two scans is a report saying a session is on an account in
    // one block and does not exist in the other (codex review of d2d620e). The type makes the whole
    // of it available at once; this is what keeps the caller from going around it.
    let cli = (try? String(contentsOfFile: "TallyCLI/main.swift", encoding: .utf8)) ?? ""
    check("the report is handed both blocks out of a single scan",
          cli.contains("let live = sessionReadings()")
              && cli.contains("accountSessions: live.accountSessions")
              && cli.contains("sessions: live.sessions"))
    check("the list is ordered by supervisor pid, not by whatever the directory returned",
          listed.map(\.directory)
              == ["/x/other"] + (getpid() < getppid() ? ["/x/repo-cart", "/x/repo"]
                                                      : ["/x/repo", "/x/repo-cart"]))

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
          askedOnce.sorted() == ["/x/other/deep", "/x/repo", "/x/repo-cart"])

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

    // MARK: - A HANDOFF THE READING DID NOT KEEP UP WITH

    // Both documents naming this session's account move at the handoff itself now (Supervisor.swift
    // writes the sidecar beside `accountChanged`, asserted in contextchecks), so on the ordinary
    // path they agree and there is no window to land in. What is left is the reading going STALE ON
    // ITS OWN: it is published best-effort through a writer holding an in-memory copy of what it
    // believes is on disk, so a write that silently fails leaves the old account in the file while
    // the copy moves on - and the thousand-token delta then suppresses every retry, so an idle
    // session keeps the old account for as long as it runs (codex review of ff5b2a0). The sidecar
    // has no memory to disagree with: each write replaces the whole of it. The fixture is that
    // failure: sidecar moved, reading did not.
    writeSupervisorAccount("claude:.claudeMOVED", pid: trunkSupervisor, dir: dir)
    let afterHandoff = readings(sockets: empty)
    check("a session whose reading went stale is reported on the account the sidecar names",
          afterHandoff.sessions.first { $0.directory == "/x/repo" }?.accountID
              == "claude:.claudeMOVED")
    // …and a session with no sidecar at all is still attributed by its reading, which is the whole
    // of what a supervisor from an older build published. The two rules are one rule: ask the
    // document written for this question, and fall back to the one that has to answer it in passing.
    check("…while a supervisor with no sidecar is still named by its reading",
          afterHandoff.sessions.first { $0.directory == "/x/repo-cart" }?.accountID
              == "claude:.claude")

    // MARK: - WHAT EACH SESSION IS DOING, AND WHY

    // The state record's own fields, carried through the join rather than re-decided here: only the
    // supervisor can decide one (SessionState.swift), so everything this block does is pass it on.
    //
    // ASSERTED HERE RATHER THAN IN tests/statusjson, and that gap is why this block exists: the JSON
    // suite builds `StatusReport.Session` values by hand, so it pins the CONTRACT while saying
    // nothing about whether anything fills it. A mutant that dropped all three of the "why" fields
    // on the floor in this file passed that suite untouched (caught by mutation, 2026-08-15).
    writeSessionState(SessionStateRecord(state: "blocked", since: at, updatedAt: at,
                                         reason: "Claude is waiting for your input",
                                         noticeType: "idle_prompt", quiet: true),
                      pid: trunkSupervisor, dir: dir)
    writeSessionState(SessionStateRecord(state: "working", since: at, updatedAt: at, quiet: false),
                      pid: lineSupervisor, dir: dir)
    let doing = readings(sockets: empty).sessions
    check("a session publishes what it is doing, and since when",
          doing.first { $0.directory == "/x/repo" }?.state == "blocked"
              && doing.first { $0.directory == "/x/repo" }?.stateSince == at)
    // THE THREE THAT ANSWER "WHY", which a state word alone cannot: which sentence Claude Code said,
    // which of the events it was, and how quiet the conversation was when it was judged.
    check("…and what it is waiting for, from which event, against which quiet reading",
          doing.first { $0.directory == "/x/repo" }?.reason == "Claude is waiting for your input"
              && doing.first { $0.directory == "/x/repo" }?.noticeType == "idle_prompt"
              && doing.first { $0.directory == "/x/repo" }?.quiet == true)
    check("a session that is not waiting still publishes the reading it was judged by",
          doing.first { $0.directory == "/x/repo-cart" }?.quiet == false
              && doing.first { $0.directory == "/x/repo-cart" }?.reason == nil
              && doing.first { $0.directory == "/x/repo-cart" }?.noticeType == nil)
    // A supervisor from before the board shipped publishes no record at all, and absence has to stay
    // "this Tally cannot say" rather than becoming a reading of its own.
    check("a session whose supervisor published no state says nothing about any of it",
          doing.first { $0.directory == "/x/other" }.map {
              $0.state == nil && $0.stateSince == nil && $0.reason == nil && $0.noticeType == nil
                  && $0.quiet == nil
          } == true)

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
