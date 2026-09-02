import Darwin
import Foundation

/// THE ONE CASE WHERE NOTHING HAS TO BE INFERRED: a file this machine's own harness wrote, naming a
/// server tree, and the process that wrote it is gone.
///
/// `/dev-watch` runs a dev server under a supervisor that restarts it (the harness's
/// `skills/dev-watch/assets/supervisor.sh`). On the way up the supervisor writes four files, and
/// they are the whole contract:
///
///     /tmp/<project>.devwatch.pid           its own pid, written ONCE and never rewritten
///     /tmp/<project>.devwatch.pid.child     the current server tree's root pid, rewritten per start
///     /tmp/<project>.devwatch.pid.port      the port, which the statusline reads to draw a green dot
///     /tmp/<project>.devwatch.starttimeout  a flag the start watchdog raises
///
/// WHY THE MTIME IS THE LEASE'S BIRTHDAY, and why nothing here asks for a new field. The first file
/// is written once, so its modification time IS the instant the supervisor started - which turns
/// "is the process holding this number still the one that wrote this" into a comparison anybody can
/// make, with no change to a contract the harness has twenty-six assertions pinned to
/// (`scripts/test-hooks/42-dev-watch.sh`). Same for the child, whose file is rewritten on each
/// restart and so stamps the generation it names.
///
/// WHAT THIS TIER ACTUALLY CATCHES, said plainly because it is narrower than it sounds: the
/// supervisor's `EXIT` trap kills its server tree and deletes all four files on every ordinary way
/// out - a `TERM`, a crashloop bailout, `/dev-watch` tearing it down. So a lease left standing over
/// a live tree means the trap did not run: a `SIGKILL`, a panic, a power cut. Precise, and small.
/// The ordinary leftover has NO lease at all and is reached by tier B (`OrphanReclaim.verdict`).
///
/// AND THE SUPERVISOR'S OWN PID IS NOT A WAY IN. By the time this matters the supervisor is dead and
/// its descendants have been re-parented to launchd, so nothing can be walked down from its number:
/// the child file is what makes the tree reachable at all, which is why it is read rather than
/// treated as a detail.
struct OrphanLease: Equatable {
    /// The `<project>` part of the filename, which is the harness's own name for the server rather
    /// than a checkout path. Carried for the message, never for a decision.
    var project: String
    /// `/tmp/<project>.devwatch.pid`, the path the other three are derived from.
    var pidFile: String
    /// Who wrote it.
    var supervisor: pid_t
    /// When, taken from the file rather than from any field inside it.
    var bornAt: Date
    /// The server tree's root, when the child file could be read.
    var child: pid_t?
    /// And when THAT file was last written, which stamps the generation the pid above names.
    var childBornAt: Date?

    /// The four files a reclaim has to delete once it has ended the tree.
    ///
    /// ALL FOUR, AND THE PORT FILE IS THE REASON THIS IS A LIST. The statusline reads
    /// `<pidfile>.port` and draws `dev:<port>` from its mere existence, so a tree ended with the
    /// files left behind leaves a green light on somebody's prompt pointing at nothing - the same
    /// class of error as the rest of this feature (a confident statement about a machine that has
    /// moved on), arriving one surface over.
    /// Derived by dropping the pid file's own suffix rather than by rewriting the path: a
    /// `replacingOccurrences` would also rewrite a DIRECTORY that happened to contain the same
    /// text, which is the class of error that deletes something nobody meant to name.
    var files: [String] {
        [pidFile, pidFile + ".child", pidFile + ".port",
         String(pidFile.dropLast(OrphanLeases.suffix.count)) + ".devwatch.starttimeout"]
    }
}

extension OrphanReclaim {

    /// How far after the lease was written a process may have started and still be its writer.
    ///
    /// The supervisor writes its own pid in the line after it begins and the child's immediately
    /// after the spawn, so the true gap is milliseconds; this is for filesystem timestamp
    /// granularity and for a machine under load, not for a real delay. Small on purpose - the
    /// window is exactly what a recycled pid has to land inside to be mistaken for the owner.
    static let leaseSlack: TimeInterval = 2

    /// WHETHER THE PROCESS HOLDING A LEASED NUMBER IS THE ONE THAT LEASED IT.
    ///
    /// - Parameter startedAt: what the machine says about that pid NOW, in the unit the process
    ///   table states (`ProcessIdentity.startedAt`), or nil when no process holds the number.
    /// - Returns: nil when nothing holds it (the writer is gone), false when something holds it but
    ///   started after the lease was written (the number was handed out again, so the writer is
    ///   also gone), true when it is still the writer.
    static func holder(_ startedAt: Int64?, of bornAt: Date) -> Bool? {
        guard let startedAt else { return nil }
        let began = Date(timeIntervalSince1970: Double(startedAt) / 1_000_000)
        return began.timeIntervalSince(bornAt) <= leaseSlack
    }

    /// WHAT A LEASE SAYS THIS ROUND.
    enum LeaseState: Equatable {
        /// The supervisor is alive: its server is its business and none of this app's.
        case tended
        /// The supervisor is gone and the tree it named is still running, so these pids can be
        /// ended on the lease alone (`Verdict.reclaim(.leaseOwnerGone)`).
        case abandoned(root: pid_t)
        /// The supervisor is gone and so is its tree: nothing to end, and the files are stale.
        /// Left exactly as they are, because a stale file this app did not write is not this app's
        /// to delete - `/dev-watch` reads them itself, and deleting one it is about to write is a
        /// race with no upside.
        case spent
        /// The table did not hold the supervisor and the kernel would not say either. Nothing is
        /// done and nothing is claimed: the tree stays a stray and goes to tier B, which needs two
        /// rounds and a clean veto sweep before it can end anything.
        case unsure
    }

    /// The lease's verdict, out of what the process table says about the two pids it names.
    ///
    /// A TABLE MISSING A PROCESS IS NOT THE PROCESS BEING GONE, and this tier used to read it as
    /// exactly that: `supervisorStartedAt == nil` went straight to `abandoned`, which sends a
    /// `SIGTERM` in the same round with no second opinion of any kind - no two rounds, no vetoes,
    /// no resource bar. One transient `proc_pidinfo` failure inside the table walk was therefore
    /// enough to end a perfectly healthy dev server whose supervisor was sitting right there (codex
    /// review, 2026-09-02). So where the table is silent the kernel is asked about that one pid
    /// directly, and only `ProcessPresence.gone` proceeds.
    ///
    /// THE PROBE IS A CLOSURE, and lazily called, for two reasons: it is a syscall that the common
    /// case (a tended lease) must not pay for, and a harness can state all three of its answers.
    ///
    /// A RECYCLED NUMBER NEEDS NO PROBE. Where the table DOES hold the pid and it started after the
    /// lease was written, the writer is gone as a matter of arithmetic rather than of observation,
    /// and asking whether "the supervisor" is running would get a yes about a stranger.
    ///
    /// THE CHILD IS CHECKED AGAINST ITS OWN FILE, not against the supervisor's. The child file is
    /// rewritten on every restart, so a lease written this morning can legitimately name a server
    /// started ten minutes ago - comparing that pid against the morning's stamp would call every
    /// restarted server a recycled number and reclaim nothing at all.
    ///
    /// AND A CHILD FILE THAT CANNOT BE READ MEANS `spent` RATHER THAN A SEARCH. Without it there is
    /// no way down to the tree (the supervisor's descendants have been re-parented), and guessing
    /// from the port or the name is exactly the inference this tier exists to avoid.
    static func state(of lease: OrphanLease, supervisorStartedAt: Int64?,
                      presence: () -> ProcessPresence,
                      childStartedAt: Int64?) -> LeaseState {
        switch holder(supervisorStartedAt, of: lease.bornAt) {
        case .some(true):
            return .tended
        case .some(false):
            break
        case .none:
            switch presence() {
            case .running: return .tended
            case .unknown: return .unsure
            case .gone: break
            }
        }
        guard let child = lease.child, let childBornAt = lease.childBornAt,
              holder(childStartedAt, of: childBornAt) == true else { return .spent }
        return .abandoned(root: child)
    }
}

/// Reading the leases off the disk, which is the one part of the above that touches a filesystem.
enum OrphanLeases {
    /// Where `/dev-watch` puts them. A parameter everywhere below so the harness can point at a
    /// directory of its own.
    static let directory = "/tmp"

    /// The suffix that makes a file a lease.
    static let suffix = ".devwatch.pid"

    /// Every lease on the machine, with the two pids and the two stamps each of them carries.
    ///
    /// SILENT ABOUT EVERYTHING IT CANNOT READ, which is the direction the rest of this feature
    /// leans: a lease whose pid file holds something that is not a number, or whose stamp the
    /// filesystem will not state, is simply not returned - so it is never a reason to end anything,
    /// and the tree it would have named falls to tier B like any other leftover.
    static func all(in directory: String = OrphanLeases.directory) -> [OrphanLease] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory) else { return [] }
        return names.filter { $0.hasSuffix(suffix) }.sorted().compactMap { name in
            let path = directory + "/" + name
            guard let supervisor = pid(inFileAt: path), let bornAt = modified(path) else {
                return nil
            }
            let childPath = path + ".child"
            return OrphanLease(project: String(name.dropLast(suffix.count)), pidFile: path,
                               supervisor: supervisor, bornAt: bornAt,
                               child: pid(inFileAt: childPath), childBornAt: modified(childPath))
        }
    }

    /// The one number a pid file holds, or nothing when it holds anything else.
    static func pid(inFileAt path: String) -> pid_t? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = pid_t(trimmed), value > 1 else { return nil }
        return value
    }

    /// When a file was last written.
    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Delete the four files of a lease whose tree has just been ended.
    static func clear(_ lease: OrphanLease) {
        for file in lease.files { try? FileManager.default.removeItem(atPath: file) }
    }
}
