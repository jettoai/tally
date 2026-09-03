import Darwin
import Foundation

/// WHAT THE GROUP LEDGER ASKS OF THE MACHINE: the file it is kept in, and whether a group it still
/// claims has a member left.
///
/// SPLIT OFF THE RULES RATHER THAN OFF THE SIZE. Everything in `SessionProcessGroups.swift` decides
/// what a ledger MEANS and can be asserted against a literal, and everything here has an effect
/// outside the process - a lock, an atomic write, a signal sent to nothing. The pure half takes the
/// probe below as a parameter for exactly that reason (`absences`), so a test can say "the group is
/// alive" without a process being alive.
extension SessionProcessGroups {
    /// Whether a process group still has a member on this machine, asked of the kernel.
    ///
    /// THE ONE QUESTION THE PROCESS TABLE CANNOT ANSWER. A walk is built from `proc_pidinfo`, which
    /// answers for neither a process the caller may not read nor one that exits mid-walk, so a job
    /// running under another uid - anything a session started with `sudo` - is absent from every
    /// walk this app will ever make. Counting those absences retires the claim on exactly the kind
    /// of long-lived job the ledger was written for (`absences`, `groupGrace`).
    ///
    /// `killpg(group, 0)` sends no signal and asks directly. `ESRCH` is "no such group", the only
    /// answer that means the last member has gone; `EPERM` is "there are members and they are not
    /// yours", which is the case the walk is blind to. Anything else is read as alive, because the
    /// two mistakes do not cost the same: a wrong "gone" loses an attribution for good, and a wrong
    /// "alive" costs one more tick of grace.
    static func stillAlive(_ group: pid_t) -> Bool {
        // `errno` is thread-local and belongs to the call that just failed, so it is read here and
        // not a line later.
        guard killpg(group, 0) != 0 else { return true }
        return stillAliveAfter(errno)
    }

    /// The verdict on its own, which is the half that can be asserted: nothing but `ESRCH` means the
    /// group has gone. Split out because the call above reaches for the kernel and a test cannot
    /// make it fail in a chosen way, and this is precisely where the asymmetry above is decided. A
    /// name of its own rather than an overload: `pid_t` IS `Int32`, so the two would be one
    /// signature and a reference to either by name would be ambiguous.
    static func stillAliveAfter(_ failure: Int32) -> Bool { failure != ESRCH }

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
                       liveGroups: Set<pid_t> = [], absentFor: (pid_t) -> Int = { _ in 0 },
                       in url: URL = fileURL()) -> [SessionProcessGroup] {
        var result: [SessionProcessGroup] = []
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        withWriteLock(for: url) {
            let held = load(from: url)
            let next = swept(held + claims, sessions: sessions, liveGroups: liveGroups,
                             absentFor: absentFor)
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
