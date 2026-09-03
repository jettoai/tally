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
    /// recycled and the claim is refused. Nil only when the leader had already gone the FIRST time
    /// this session saw the group, which is a claim that can only ever be checked by the weaker
    /// test below; once a stamp has been written the later claims of that group carry it forward
    /// rather than losing it with the leader (`claims`).
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
    /// is bounded by attrition as well as by the sweep below.
    ///
    /// AND THE CAP DROPS THE WRONG END, said rather than implied: `swept` keeps the newest `limit`,
    /// so the first claim to go is the OLDEST claim of a live session - which is the one the sweep's
    /// own note calls the most worth keeping (a dev server started at nine in the morning).
    ///
    /// THIS FILE REACHED THE CAP, which the note here used to say nothing had come near. Measured
    /// (2026-09-03): 4000 claims, exactly the cap, 1.0MB on disk, 3003 groups, of which 19 still
    /// had a member alive. Every Bash tool call is a job of its own, so a working day is thousands
    /// of them, and the sweep only ever dropped the claims of sessions the board had LOST: what a
    /// LIVE session accumulated had nothing bounding it but this number. The costs were not of the
    /// cap being reached but of the file it grew: a megabyte rewritten whenever any session started
    /// a command, and four thousand records scanned per unclaimed process per tick (`Index`).
    /// Bounding it is now the sweep's own job (`groupGrace`), which leaves this the backstop the
    /// paragraph above describes.
    static let limit = 4000

    /// How many consecutive NON-EMPTY walks a process group has to have been missing from before
    /// the claims on it are dropped (`swept`). The unit is walks rather than seconds because that
    /// is what the evidence is: a tick that walked nothing asked nothing.
    ///
    /// WHY A GROUP WITH NO MEMBER LEFT CANNOT COME BACK: a group exists while something is in it,
    /// and `setpgid` only ever joins one that already exists, so a number whose last member has
    /// gone names nothing, and anything later carrying it is a NEW job holding a recycled number.
    /// A claim on such a group can therefore only be wrong, never right: a job that could still be
    /// adopted is a job that is still running, and a running job keeps its group alive. Dropping it
    /// takes away a chance for the weak generation test to be the only thing standing between a
    /// stranger and somebody's card (`claimant`).
    ///
    /// AND THREE RATHER THAN ONE BECAUSE A WALK CAN MISS: `proc_pidinfo` answers for neither a
    /// process the caller may not read nor one that exits mid-walk (`ProcessTreeReaders`), so one
    /// tick's silence is not evidence. Three is six seconds with the board open and thirty behind
    /// it, both well inside the life of anything worth adopting.
    static let groupGrace = 3

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

    /// THE LEDGER WITH THE ONE QUESTION EVERY READING ASKS OF IT ANSWERED IN ADVANCE: which claims
    /// are on a given group.
    ///
    /// Both readers below want the claims of ONE group and nothing else - `claimant` per unclaimed
    /// process, `claims` per observation - and both used to walk the whole file to find them. The
    /// cost of that is not the comparison but the COPY: an element of an array of these leaves the
    /// iterator as a value holding four strings, retained and released once per record per process.
    /// Measured (2026-09-03) with 1370 unclaimed processes against 4000 claims: five and a half
    /// million copies a tick, 350ms of the main thread every two seconds, nothing on screen moving.
    ///
    /// THE BUCKETS KEEP THE LEDGER'S OWN ORDER, which is not tidiness. `claimant` settles a contest
    /// on three keys and then falls back to the order it met the records in, and `claims` takes the
    /// LAST claim a session wrote on a group as the one on file. Sorted buckets would answer both
    /// differently while every assertion here still passed, because those fallbacks only ever
    /// separate records that agree on everything a test can see.
    struct Index {
        /// The ledger as it stands, in file order: what is swept, compared and written back.
        let entries: [SessionProcessGroup]
        private let byGroup: [pid_t: [SessionProcessGroup]]

        init(_ entries: [SessionProcessGroup] = []) {
            self.entries = entries
            var byGroup: [pid_t: [SessionProcessGroup]] = [:]
            for record in entries { byGroup[record.group, default: []].append(record) }
            self.byGroup = byGroup
        }

        /// The claims on one group, in the order the ledger holds them.
        func claims(on group: pid_t) -> [SessionProcessGroup] { byGroup[group] ?? [] }
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
    ///
    /// AND THE LEADER'S STAMP SURVIVES THE LEADER, which is the whole of what keeps the strongest
    /// refusal on the MAIN PATH rather than on an edge of it. `observed` can only ask the process
    /// table, and the table stops answering for a group the instant its leader exits - which is not
    /// a rare state here, it is the state this file exists for: the leader IS the command shell
    /// whose exit re-parents the job. A tick that took the table's silence for the answer wrote a
    /// SECOND claim on the same group with no stamp at all, and `claimant` skips its recycled-number
    /// test on a stamp-less claim, so the weak test stood alone and any newborn stranger carrying
    /// that number passed it. The stamp this session already wrote down is the answer to a question
    /// the table can no longer be asked, so it is carried forward, and the comparison above is made
    /// against the carried value - otherwise the same claim is rewritten on every tick for as long
    /// as the job runs, which is a lock and a whole-file write twice a second.
    static func claims(_ observations: [Observation], session: String, sessionStartedAt: Int64,
                       against existing: Index,
                       at instant: String) -> [SessionProcessGroup] {
        observations.compactMap { observation in
            // WHAT THIS SESSION ALREADY HOLDS ON THIS GROUP, which is the LAST claim it wrote on
            // it: a group claimed twice by one session is a re-stamping, and the later record is
            // the one the file answers with. The whole-ledger scan this replaced arrived at the
            // same record by overwriting as it went, and the buckets keep the order that makes the
            // two the same answer (`Index`).
            let record = existing.claims(on: observation.group).last {
                $0.session == session && $0.sessionStartedAt == sessionStartedAt
            }
            let leaderStartedAt = observation.leaderStartedAt ?? record?.leaderStartedAt
            if let record, record.leaderStartedAt == leaderStartedAt,
               record.earliestMemberStart <= observation.earliestMemberStart { return nil }
            return SessionProcessGroup(session: session, sessionStartedAt: sessionStartedAt,
                                       group: observation.group,
                                       leaderStartedAt: leaderStartedAt,
                                       earliestMemberStart: observation.earliestMemberStart,
                                       firstSeen: instant, name: observation.name)
        }
    }

    /// The same, against a ledger nobody has indexed yet.
    static func claims(_ observations: [Observation], session: String, sessionStartedAt: Int64,
                       against existing: [SessionProcessGroup],
                       at instant: String) -> [SessionProcessGroup] {
        claims(observations, session: session, sessionStartedAt: sessionStartedAt,
               against: Index(existing), at: instant)
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
    /// the group, and the one that started the job is the one that saw it later.
    ///
    /// AND THE NESTED CASE IS A TIE ON THAT KEY RATHER THAN A CONTEST, which is why there is a
    /// second one. The inner supervisor is ALREADY in the outer session's tree, so a job it starts
    /// is first seen by both cards in the same pass of the same tick, and one tick writes one
    /// instant for every claim it makes (`ProcessFootprintStore.sample`): the "written last" rule
    /// can only separate sessions that saw the job on DIFFERENT ticks. So the tie is settled on
    /// which SUPERVISOR started later, and the inner one always did - it was started from inside
    /// the outer one's terminal. That says outright what the rule above only meant to say. Ties on
    /// both keys fall to the session with the lower pid, which is arbitrary and only has to be
    /// DECIDABLE: an adoption that changed hands from tick to tick would move cores between two
    /// cards every two seconds.
    ///
    /// - Parameters:
    ///   - sessions: the live supervisors, pid string to when that supervisor started.
    ///   - startedAt: when a pid on the machine began, for the leader test.
    static func claimant(of process: ProcessIdentity, in ledger: Index,
                         sessions: [String: Int64], startedAt: (pid_t) -> Int64?) -> String? {
        guard process.group > 1 else { return nil }
        var best: SessionProcessGroup?
        for record in ledger.claims(on: process.group) {
            guard sessions[record.session] == record.sessionStartedAt else { continue }
            if let leader = record.leaderStartedAt, let now = startedAt(record.group),
               now != leader { continue }
            guard process.startedAt >= record.earliestMemberStart else { continue }
            guard let held = best else { best = record; continue }
            if record.firstSeen > held.firstSeen
                || (record.firstSeen == held.firstSeen
                    && (record.sessionStartedAt > held.sessionStartedAt
                        || (record.sessionStartedAt == held.sessionStartedAt
                            && record.session < held.session))) {
                best = record
            }
        }
        return best?.session
    }

    /// The same, against a ledger nobody has indexed yet. One process against one ledger is what
    /// the assertions ask; a tick asks it of a thousand processes and indexes once (`adoptions`).
    static func claimant(of process: ProcessIdentity, ledger: [SessionProcessGroup],
                         sessions: [String: Int64], startedAt: (pid_t) -> Int64?) -> String? {
        claimant(of: process, in: Index(ledger), sessions: sessions, startedAt: startedAt)
    }

    /// Every unclaimed process matched back to the session that started its job, and the seeds a
    /// walk then descends from: an adopted server goes on spawning children of its own, and those
    /// are as much the session's as it is (the reason `ProcessTree.members` seeds its own walk from
    /// the job as well as from the root).
    ///
    /// - Parameter unclaimed: the processes no session's tree already holds. Passing the whole
    ///   machine would work and would be wrong: a process that IS in a tree is already counted, and
    ///   counting it again on a second card is the one thing an attribution must not do.
    ///
    /// A BLIND SPOT THIS DOES NOT CLOSE, named rather than claimed away: the rule above holds for
    /// the pids handed back here (each is claimed by at most one session, and every pid already in
    /// a tree was excluded before being offered), and it does NOT hold for what the walk then
    /// descends to. `ProcessTree.members(root:processes:adopting:)` continues from an adopted
    /// orphan through its progeny with no test for crossing into another root, so if a second
    /// session's supervisor happens to be descended from an orphan this session adopted - a
    /// `tally claude` started from a shell that had already detached - that whole tree is counted
    /// on both cards. It needs the adopted orphan to be an ANCESTOR of another live supervisor,
    /// which has not been observed on this machine; it is written here because the alternative is a
    /// reader taking the paragraph above for a closed case. A project's total does not inherit it
    /// while both cards are in one project: the two cards share pids, and a project adds up only
    /// one of any pair that does (`MachineLoadRollup.nested`, which tests for a shared pid rather
    /// than for a contained tree, precisely because the containment this paragraph describes is not
    /// the only shape the sharing comes in).
    static func adoptions(unclaimed: some Sequence<ProcessIdentity>,
                          in ledger: Index, sessions: [String: Int64],
                          startedAt: (pid_t) -> Int64?) -> [String: Set<pid_t>] {
        var adopted: [String: Set<pid_t>] = [:]
        for process in unclaimed {
            guard let session = claimant(of: process, in: ledger, sessions: sessions,
                                         startedAt: startedAt) else { continue }
            adopted[session, default: []].insert(process.pid)
        }
        return adopted
    }

    /// The same, against a ledger nobody has indexed yet.
    static func adoptions(unclaimed: some Sequence<ProcessIdentity>,
                          ledger: [SessionProcessGroup], sessions: [String: Int64],
                          startedAt: (pid_t) -> Int64?) -> [String: Set<pid_t>] {
        adoptions(unclaimed: unclaimed, in: Index(ledger), sessions: sessions, startedAt: startedAt)
    }

    /// WHAT A TICK'S WALK SAYS ABOUT THE GROUPS THE LEDGER STILL CLAIMS: how long each of them has
    /// been missing, and whether any has been missing long enough to be dropped (`groupGrace`).
    ///
    /// COUNTED OVER THE LEDGER RATHER THAN OVER THE MACHINE: what is watched is the numbers this
    /// app wrote down, not the thousand groups a machine carries.
    struct Absences {
        /// Per still-claimed group, how many consecutive non-empty walks it has been missing from.
        /// A group the walk saw again is simply absent from this, which is how a count resets.
        let ticks: [pid_t: Int]
        /// Whether the sweep would now drop something, which is one of the three things that gives
        /// a tick anything to write at all (`ProcessFootprintStore.sample`).
        let expired: Bool
    }

    /// The absence counts a tick leaves behind, given the ones it inherited.
    ///
    /// ONLY EVER CALLED ON A NON-EMPTY WALK, which is the unit `groupGrace` is stated in: a tick
    /// that walked nothing saw nothing, and counting it would retire a live job over a question
    /// nobody asked (the same rule `swept` applies to an empty `sessions`).
    ///
    /// AND A WALK'S SILENCE IS NOT AN ABSENCE, which is the whole reason this takes a second
    /// witness. Missing from the walk means "not seen": `proc_pidinfo` answers for neither a
    /// process the caller may not read nor one that exits mid-walk (`ProcessTreeReaders`), so a job
    /// a session started under `sudo` is missing from EVERY walk this app makes while it goes on
    /// burning cores, and three misses running would retire its claim for good. Only `stillAlive`
    /// means "really gone", and it is asked of the kernel rather than of a table
    /// (`SessionProcessGroups.stillAlive`, where `ESRCH` is no such group and `EPERM` is the case
    /// the walk cannot see: there are members and they are not ours).
    ///
    /// - Parameter stillAlive: whether a group has any member left on this machine. Injected
    ///   rather than called here so this stays a rule that can be asserted against a literal, and
    ///   so a test can say a group is alive without a process being alive.
    static func absences(in ledger: Index, seeing liveGroups: Set<pid_t>,
                         after previous: [pid_t: Int],
                         stillAlive: (pid_t) -> Bool) -> Absences {
        var ticks: [pid_t: Int] = [:]
        // A group is asked about ONCE however many claims stand on it: the answer is a syscall, and
        // a ledger at its cap holds thousands of claims over hundreds of groups (`limit`).
        var asked: Set<pid_t> = []
        var expired = false
        for record in ledger.entries where !liveGroups.contains(record.group) {
            let group = record.group
            guard asked.insert(group).inserted else { continue }
            // NOT COUNTED AND NOT CARRIED EITHER: the probe outranks the walk, so a group the
            // kernel says is there resets to nothing rather than holding the misses it had.
            guard !stillAlive(group) else { continue }
            let count = (previous[group] ?? 0) + 1
            ticks[group] = count
            expired = expired || count >= groupGrace
        }
        return Absences(ticks: ticks, expired: expired)
    }

    /// The ledger with every claim of a session the board no longer holds dropped, every claim of a
    /// group with no member left on the machine dropped, and the newest `limit` kept.
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
    ///
    /// AND SWEPT AGAINST THE MACHINE'S OWN GROUPS AS WELL AS AGAINST THE BOARD, which is the half
    /// that actually bounds the file (`groupGrace` carries why a group with no member left is gone
    /// for good, and `limit` what it used to cost that nothing said so). The empty set means the
    /// same thing on this axis as on the other one: no walk was made, so the group half is skipped
    /// rather than read as "no group on this machine is alive", which would empty the file on the
    /// first tick after a relaunch just as surely.
    ///
    /// - Parameters:
    ///   - liveGroups: every process group the tick's walk saw, taken over the WHOLE table rather
    ///     than over the trees: a job that has left its tree is the case this ledger exists for,
    ///     and it is still a live group.
    ///   - absentFor: how many consecutive non-empty walks a group has been missing from, counted
    ///     by the caller because a pure function cannot remember (`absences`).
    static func swept(_ ledger: [SessionProcessGroup], sessions: [String: Int64],
                      liveGroups: Set<pid_t> = [],
                      absentFor: (pid_t) -> Int = { _ in 0 }) -> [SessionProcessGroup] {
        guard !sessions.isEmpty else { return ledger }
        return Array(ledger.filter {
            sessions[$0.session] == $0.sessionStartedAt
                && (liveGroups.isEmpty || liveGroups.contains($0.group)
                    || absentFor($0.group) < groupGrace)
        }.suffix(limit))
    }

    // The file this ledger is kept in, and the one question about a group that the process
    // table cannot answer, are both in `SessionProcessGroupsFile.swift`: everything above is a
    // pure rule, and everything there reaches for the machine.
}
