import Foundation

// THE RULES THE HOST-HEALTH STATION IS DECIDED BY, split from the station itself for the reason
// QuotaKnockLogic.swift is split from QuotaKnock.swift: everything here is arithmetic over values
// handed in, so an assertion harness can state every case with no report on disk, no supervisor and
// no terminal, and everything there writes bytes.
//
// FOUNDATION ONLY, deliberately: this file names no file, opens nothing and asks the machine
// nothing.

/// What this session has been told about the machine, and what it last read.
///
/// THE READING IS A CACHE AND THE ANNOUNCEMENT IS NOT. `seenAt` and `report` are there so the
/// ordinary tick costs one `stat` and no decode; `announced` is the feature itself: it is the
/// instant of the alarm this conversation has already heard about, so a report rewritten every
/// minute for an hour produces one sentence.
struct HostHealthKnockState: Equatable {
    /// The modification time the cached report was decoded from.
    var seenAt: Date?
    /// The report as it stood then, and nil when there was nothing readable there.
    var report: HostHealthReport?
    /// The `lastAlarm.at` this session has been told about.
    var announced: Date?
}

enum HostHealthKnockLogic {

    /// Fold one tick's look at the report into the state, answering the alarm this session is OWED
    /// a sentence about and nil when it is owed none.
    ///
    /// IT DOES NOT RECORD THE ANNOUNCEMENT, and that is the same division `QuotaKnockState.observe`
    /// and `spend` are under: what marks a sentence spent is the moment its bytes are on their way,
    /// so a tick whose gate holds asks again rather than having quietly used the alarm up.
    ///
    /// - Parameter stamp: when the report was last rewritten, or nil when there is no report at
    ///   all. A report that has GONE drops the cache with it: an app closed mid-alarm is not a
    ///   machine that recovered, and a session should be told again when it comes back.
    /// - Parameter now: this tick's instant, handed in rather than read here so that every case
    ///   below can be stated with no clock: it is what the report's age is measured against.
    /// - Parameter read: the decode, called only when the stamp has moved.
    static func observe(_ state: inout HostHealthKnockState, stamp: Date?, now: Date,
                        read: () -> HostHealthReport?) -> HostHealthAlarm? {
        guard let stamp else {
            state.seenAt = nil
            state.report = nil
            return nil
        }
        if stamp != state.seenAt {
            state.seenAt = stamp
            state.report = read()
        }
        // Nothing is owed about a machine that is fine, nor about an alarmed report carrying no
        // alarm this build can read: an alarm with no instant on it could never be said once.
        guard let report = state.report, report.state == .alarmed, let alarm = report.lastAlarm,
              state.announced != alarm.at
        else { return nil }
        // AND A READING NOBODY HAS REWRITTEN IN A WHILE IS HISTORY RATHER THAN NEWS. The gone-report
        // case above is the same thought one step further along, and this is the half it does not
        // reach: the document OUTLIVES the app, so an app closed mid-alarm leaves an alarmed file on
        // disk that reads exactly like a machine in trouble right now, and every supervisor that
        // starts afterwards would say so - hours or days later, in a sentence with no age in it.
        // A stale report is treated as no report (`HostHealthLogic.staleAfter`).
        //
        // THE CACHE IS DELIBERATELY LEFT STANDING: this is not a decision about the document, only
        // about what may be said off it. The app coming back rewrites it, the stamp moves, and a
        // machine still in trouble is announced off that fresh reading, alarm instant and all.
        guard now.timeIntervalSince(report.sampledAt) <= HostHealthLogic.staleAfter else {
            return nil
        }
        return alarm
    }

    /// What a FILED host-health sentence may say at the moment a hook finally delivers it, and nil
    /// when it may say nothing.
    ///
    /// A filed sentence waits for the session's next hook, which can be hours after the filing
    /// (B-537: filed at load 181, delivered 3h16m later while the machine sat at 12). So the hook
    /// re-reads the report and re-asks the same questions `observe` asks: still alarmed, an alarm on
    /// record, and a sample no older than `HostHealthLogic.staleAfter`. The figures come from the
    /// report as it stands now; the alarm's instant and top list stay the filed alarm's.
    static func current(_ report: HostHealthReport?, now: Date) -> HostHealthAlarm? {
        guard let report, report.state == .alarmed, var alarm = report.lastAlarm,
              now.timeIntervalSince(report.sampledAt) <= HostHealthLogic.staleAfter
        else { return nil }
        alarm.load1 = report.load1
        alarm.freeBytes = report.freeBytes
        return alarm
    }
}
