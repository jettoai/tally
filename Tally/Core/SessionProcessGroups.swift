import Darwin
import Foundation

/// WHICH JOBS A SESSION HAS STARTED, WRITTEN DOWN WHILE SOMETHING STILL KNOWS.
///
/// THE TREE WALK LOSES A JOB THE MOMENT THE PROCESS THAT MADE THE GROUP DIES. Membership is
/// parentage plus the root's own job (`ProcessTree.members`), and the job half only holds while the
/// group number IS the root's pid. An agent's background server is not in that group: Claude Code's
/// Bash tool puts each command in a job of its OWN so it can signal the job rather than one process,
/// so the group number is the command shell's pid, not the supervisor's. While that shell is alive
/// the walk still reaches everything through parentage. When it exits, its survivors are re-parented
/// to launchd, their group keeps a number nothing in the tree carries any more, and the whole job
/// falls out of the session's readings in one tick.
///
/// Measured, and this is the incident the file exists for (2026-08-25): a `taiwanbigdata` session
/// dispatched a twelve-worker transcription run through `uv`; the `uv` root ended up with PPID 1 and
/// a group of 72593, which was neither its supervisor's pid nor anything else the walk could reach.
/// Twelve of sixteen cores were busy and the session's card read 2%. The board could not even say
/// WHO had started it - the attribution was reconstructed afterwards by hand out of a scratchpad
/// path that happened to be in the command line, which is luck rather than a mechanism.
///
/// THE GROUP IS THE IDENTITY THAT SURVIVES, which `ProcessTree.members` already says and only half
/// uses. Re-parenting does not touch a process group, so a group number seen INSIDE a session's tree
/// is a durable claim by that session over everything that number will ever carry. What was missing
/// was somewhere to keep the claim, since by the time it is needed nothing alive is in the group any
/// more. So every group the tree carries is written down as it is seen, and an orphan is matched
/// back against that ledger.
///
/// A LEDGER, NOT A GUESS. Nothing here reads a command line, a name or a heuristic about what a
/// process looks like: an orphan is this session's or it is nobody's, decided on a number this app
/// watched the session carry. The two ways that number can lie are both closed below (`claimant`):
/// a supervisor pid handed out again, and a GROUP number handed out again.
///
/// The file is `~/.tally/session-groups.json`, versioned and additive like the other contracts in
/// that folder (`WorktreeOrigins` is the shape this follows, lock and atomic write included).
struct SessionProcessGroup: Codable, Equatable, Sendable {
    /// The supervisor pid, as the board spells its rows (`SessionRosterStore.SessionRow.id`).
    var session: String
    /// When THAT supervisor started, in the unit the process table states
    /// (`ProcessIdentity.startedAt`).
    ///
    /// A PID IS NOT AN IDENTITY, and this ledger outlives the sessions it describes: without this,
    /// a supervisor given a dead session's number would inherit its claims and adopt a stranger's
    /// processes onto its own card. Same rule, same unit and same spelling as the port cache's
    /// holder (`ProcessPortHolder`) and the supervisor's own child stamp (`ProcessStamp`).
    var sessionStartedAt: Int64
    /// The process group this session's tree was carrying.
    var group: pid_t
    /// When the group's LEADER started, when the leader was alive to be asked at the moment the
    /// claim was written.
    ///
    /// THIS IS WHAT MAKES A GROUP NUMBER SAFE TO HOLD ACROSS HOURS. The leader's pid IS the group
    /// number, so a group whose leader has exited leaves a number the machine is free to hand out
    /// again, and a later job given it would be adopted by a session that never started it. When
    /// the leader is alive at match time and started at a different instant, the number has been
    /// recycled and the claim is refused. Nil when the leader had already gone by the time the
    /// claim was written, which is a claim that can only ever be checked by the weaker test below.
    var leaderStartedAt: Int64?
    /// The earliest start time among the members seen carrying this group.
    ///
    /// The weaker test, and the only one available once the leader is gone: a process that started
    /// BEFORE the oldest member this app ever saw in the group cannot be of the same generation of
    /// it. It does not prove the generation is the same, which is why it is the fallback rather
    /// than the rule.
    var earliestMemberStart: Int64
    /// When this claim was first written (ISO8601 with fractional seconds), which is what decides a
    /// contest between two sessions claiming one group (`claimant`).
    var firstSeen: String
    /// What to call the job, for a person reading the file: the EXECUTABLE's name of the earliest
    /// member (`ProcessTree.displayName`), never its command line. Same rule the card's own culprit
    /// names follow, for the same reason: argv is a string that can carry a token
    /// (`ProcessFootprint.memoryLeader`).
    var name: String?
}

enum SessionProcessGroups {
    /// How many claims are kept. A session that runs commands all day is a claim per job, so this
    /// is bounded by attrition as well as by the sweep below: the oldest go first.
    static let limit = 4000

    /// `~/.tally/session-groups.json`. The home is a parameter so an assertion harness can use a
    /// fixture tree, exactly as `WorktreeOrigins.fileURL` is.
    static func fileURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".tally/session-groups.json")
    }

    // MARK: The pure rules

    /// One group a tree was seen carrying, before it is a record.
    struct Observation: Equatable {
        var group: pid_t
        var leaderStartedAt: Int64?
        var earliestMemberStart: Int64
        var name: String?
    }

    /// Every process group a set of tree members carries, with what identifies each one.
    ///
    /// GROUP 0 AND GROUP 1 ARE NOT JOBS. Zero is what a record that could not be read reports, and
    /// one is launchd's own group, which half the machine's daemons are in: claiming either would
    /// hand a session everything on the machine the first time an orphan turned up.
    ///
    /// - Parameters:
    ///   - members: the identities of the pids in the tree, out of the table walk the tick has
    ///     already made.
    ///   - startedAt: when any pid on the machine began, asked as a function so this stays pure and
    ///     so the leader can be looked up even when it is outside the tree (a job whose leader is
    ///     the shell that has already exec'd elsewhere).
    ///   - name: what to call a pid, on the same terms.
    static func observed(members: some Sequence<ProcessIdentity>,
                         startedAt: (pid_t) -> Int64?,
                         name: (pid_t) -> String?) -> [Observation] {
        var byGroup: [pid_t: Observation] = [:]
        for member in members where member.group > 1 {
            var seen = byGroup[member.group]
                ?? Observation(group: member.group,
                               leaderStartedAt: startedAt(member.group),
                               earliestMemberStart: member.startedAt,
                               name: nil)
            // The oldest member names the job, and a member whose program could not be read leaves
            // the name to whoever can: a claim with no name is still a claim, and the name is only
            // ever read by a person opening the file.
            if seen.name == nil || member.startedAt < seen.earliestMemberStart {
                seen.earliestMemberStart = min(seen.earliestMemberStart, member.startedAt)
                seen.name = name(member.pid) ?? seen.name
            }
            byGroup[member.group] = seen
        }
        return byGroup.values.sorted { $0.group < $1.group }
    }

    /// The claims a tick would add to what is already on file: the observations the ledger does not
    /// already answer for, as records.
    ///
    /// ALREADY ANSWERED MEANS THE SAME SESSION HOLDS THE SAME GROUP OF THE SAME GENERATION, which is
    /// what keeps a repeating writer silent: a session runs the same jobs for minutes at a time, and
    /// a ledger rewritten on every tick would be a lock and an atomic write twice a second for a
    /// file that had not changed (the rule `WorktreeOrigins.recordNew` is built on, and the reason
    /// this returns the delta rather than the whole file).
    ///
    /// A GENERATION IS PART OF THE COMPARISON rather than only of the match: a group number reused
    /// inside one session's life is a NEW job, and a ledger that called it answered would go on
    /// vouching for the dead one's earliest member.
    static func claims(_ observations: [Observation], session: String, sessionStartedAt: Int64,
                       against existing: [SessionProcessGroup],
                       at instant: String) -> [SessionProcessGroup] {
        var held: [pid_t: SessionProcessGroup] = [:]
        for record in existing where record.session == session
            && record.sessionStartedAt == sessionStartedAt {
            held[record.group] = record
        }
        return observations.compactMap { observation in
            if let record = held[observation.group],
               record.leaderStartedAt == observation.leaderStartedAt,
               record.earliestMemberStart <= observation.earliestMemberStart { return nil }
            return SessionProcessGroup(session: session, sessionStartedAt: sessionStartedAt,
                                       group: observation.group,
                                       leaderStartedAt: observation.leaderStartedAt,
                                       earliestMemberStart: observation.earliestMemberStart,
                                       firstSeen: instant, name: observation.name)
        }
    }

    /// WHICH SESSION AN UNCLAIMED PROCESS BELONGS TO, or none.
    ///
    /// Three tests, and each of them is a way the number could lie:
    ///
    ///   - THE SESSION IS STILL THE SESSION. The claim names a supervisor pid AND when it started,
    ///     and `sessions` is what the board currently holds. A supervisor given a dead one's number
    ///     matches nothing.
    ///   - THE GROUP IS STILL THE GROUP. Where the claim recorded a live leader, the leader has to
    ///     be that same process now. A group number handed out again to an unrelated job is refused
    ///     outright rather than adopted - which is the failure that would put a stranger's cores on
    ///     somebody's card, and the one this app has no second chance to notice.
    ///   - THE PROCESS COULD BE OF THIS GENERATION. It cannot have started before the oldest member
    ///     the claim ever saw. This is all that is left once the leader has exited, and it is stated
    ///     as the weaker test it is: it refuses the obvious impostor and cannot refuse a subtle one.
    ///
    /// A CONTEST GOES TO THE CLAIM WRITTEN LAST, which is the innermost session: a `tally claude`
    /// started inside a supervised terminal is genuinely inside its parent's tree, so both may hold
    /// the group, and the one that started the job is the one that saw it later. Ties fall to the
    /// session with the lower pid, which is arbitrary and only has to be DECIDABLE: an adoption that
    /// changed hands from tick to tick would move cores between two cards every two seconds.
    ///
    /// - Parameters:
    ///   - sessions: the live supervisors, pid string to when that supervisor started.
    ///   - startedAt: when a pid on the machine began, for the leader test.
    static func claimant(of process: ProcessIdentity, ledger: [SessionProcessGroup],
                         sessions: [String: Int64], startedAt: (pid_t) -> Int64?) -> String? {
        guard process.group > 1 else { return nil }
        var best: SessionProcessGroup?
        for record in ledger where record.group == process.group {
            guard sessions[record.session] == record.sessionStartedAt else { continue }
            if let leader = record.leaderStartedAt, let now = startedAt(record.group),
               now != leader { continue }
            guard process.startedAt >= record.earliestMemberStart else { continue }
            guard let held = best else { best = record; continue }
            if record.firstSeen > held.firstSeen
                || (record.firstSeen == held.firstSeen && record.session < held.session) {
                best = record
            }
        }
        return best?.session
    }

    /// Every unclaimed process matched back to the session that started its job, and the seeds a
    /// walk then descends from: an adopted server goes on spawning children of its own, and those
    /// are as much the session's as it is (the reason `ProcessTree.members` seeds its own walk from
    /// the job as well as from the root).
    ///
    /// - Parameter unclaimed: the processes no session's tree already holds. Passing the whole
    ///   machine would work and would be wrong: a process that IS in a tree is already counted, and
    ///   counting it again on a second card is the one thing an attribution must not do.
    static func adoptions(unclaimed: some Sequence<ProcessIdentity>,
                          ledger: [SessionProcessGroup], sessions: [String: Int64],
                          startedAt: (pid_t) -> Int64?) -> [String: Set<pid_t>] {
        var adopted: [String: Set<pid_t>] = [:]
        for process in unclaimed {
            guard let session = claimant(of: process, ledger: ledger, sessions: sessions,
                                         startedAt: startedAt) else { continue }
            adopted[session, default: []].insert(process.pid)
        }
        return adopted
    }

    /// The ledger with every claim of a session the board no longer holds dropped, and the newest
    /// `limit` kept.
    ///
    /// SWEPT AGAINST THE BOARD RATHER THAN AGAINST A CLOCK, the same rule the trend ring's own
    /// retention follows (`FootprintTrendSeries.retain`): a claim is meaningless once its session
    /// has gone, and a claim of a LIVE session is worth keeping however old it is - a dev server
    /// started at nine in the morning is exactly what somebody is looking for at five.
    ///
    /// NEVER SWEPT AGAINST AN EMPTY BOARD, which is not a special case for tidiness: the sampler
    /// takes no reading at all when the roster is empty, so an empty set here means "not asked"
    /// rather than "nothing is running", and acting on it would empty the file on the first tick
    /// after a relaunch.
    static func swept(_ ledger: [SessionProcessGroup],
                      sessions: [String: Int64]) -> [SessionProcessGroup] {
        guard !sessions.isEmpty else { return ledger }
        return Array(ledger.filter { sessions[$0.session] == $0.sessionStartedAt }.suffix(limit))
    }

    // MARK: The file

    /// The claims on file, oldest first; empty when the file is absent or unreadable. Fail-open in
    /// the direction attribution already fails: not knowing costs a card its background job, and a
    /// decode that threw would cost the whole board its readings.
    static func load(from url: URL = fileURL()) -> [SessionProcessGroup] {
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data)
        else { return [] }
        return document.entries
    }

    /// The instant a claim was written, spelled the way this folder's ledgers spell instants
    /// (`WorktreeOrigins.timestamp`): fractional seconds, because two claims of one tick are
    /// microseconds apart and whole seconds would call that a tie.
    static func timestamp(_ instant: Date = Date()) -> String {
        fractionalClock.string(from: instant)
    }

    nonisolated(unsafe) private static let fractionalClock: ISO8601DateFormatter = {
        let clock = ISO8601DateFormatter()
        clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return clock
    }()

    /// Add claims and drop the ones whose sessions have gone, under the write lock.
    ///
    /// NOTHING TO SAY WRITES NOTHING, which is what makes this affordable on a two-second tick: the
    /// common case is a session running the jobs it was already running, so `claims` is empty and
    /// the sweep changes nothing, and the file is neither locked nor rewritten.
    ///
    /// Serialised across processes and written atomically, exactly as the worktree ledger beside it
    /// is: this app is the only writer today, and a second instance of it (a dev build beside the
    /// installed one) is an ordinary state on this machine rather than a hypothetical.
    static func record(_ claims: [SessionProcessGroup], sessions: [String: Int64],
                       in url: URL = fileURL()) -> [SessionProcessGroup] {
        var result: [SessionProcessGroup] = []
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        withWriteLock(for: url) {
            let held = load(from: url)
            let next = swept(held + claims, sessions: sessions)
            result = next
            guard next != held else { return }
            write(next, to: url)
        }
        return result
    }

    private static func write(_ entries: [SessionProcessGroup], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Document(version: 1, entries: entries)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Run `body` holding an exclusive `flock` on `<file>.lock`. Fail-open in both directions, on
    /// the terms `WorktreeOrigins.withWriteLock` states: bookkeeping must never be the thing that
    /// stops a reading being taken.
    private static func withWriteLock(for url: URL, _ body: () -> Void) {
        let descriptor = open(url.appendingPathExtension("lock").path,
                              O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return body() }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return body() }
        defer { flock(descriptor, LOCK_UN) }
        body()
    }

    /// The file itself. `version` is written and never gated on: the contract is additive, so a
    /// reader from an older build must keep understanding what a newer one wrote.
    private struct Document: Codable {
        var version: Int
        var entries: [SessionProcessGroup]
    }
}
