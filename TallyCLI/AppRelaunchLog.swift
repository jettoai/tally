import Foundation

// WHAT THE STATION THAT REOPENS THE APP DECIDED, AND WHEN: the one file that answers that question
// afterwards (AppRelaunch.swift holds the deciding).
//
// The seam is SessionInputLog.swift's: nothing in this file decides anything, and everything in it
// is a sentence somebody reads back after the next report. It exists because the first three of
// those reports were told apart by hand. A station that never armed and a machine that had no
// supervisor watching at all produce the same evidence - none - so the third report cost hours of
// reading `/usr/bin/log show` to reach a conclusion the station itself could have stated in a line.
//
// THIRTY SECONDS IS THE BAR this file is written to. Reading it after an update that left no app
// behind has to settle which of four things happened, without any other source: no lines at all
// (nobody was watching, so nothing could have opened it), `watching` with no `armed` (the swap was
// never recognised as one), `armed` followed by `disarmed` (held back, and the reason is the next
// field along), or `opened`.

/// The audit trail, beside the one `tally session send` keeps. 0644 like `handoff.log` and unlike
/// the input log: every line here is an event ABOUT the app, and none of it is anybody's content.
let appRelaunchLog = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/logs/app-relaunch.log")

/// One decision of the station, on its way to a line. Carried on the state and drained by the tick,
/// so the decision itself stays a pure function of its readings.
enum AppRelaunchEvent: Equatable {
    /// This supervisor has a version to compare against from now on. Once per process, and the line
    /// whose ABSENCE says nobody was watching.
    case watching(String)
    /// The bundle moved forward while the app was there for it. The relaunch is now owed.
    case armed(String)
    /// It is no longer owed, and why.
    case disarmed(String, reason: String)
    case opened(String)
    /// Another supervisor on this machine won the one open this version gets.
    case claimLost(String)

    var outcome: String {
        switch self {
        case .watching: return "watching"
        case .armed: return "armed"
        case .disarmed: return "disarmed"
        case .opened: return "opened"
        case .claimLost: return "claim-lost"
        }
    }

    /// Why an arming ended, and `-` for every event that is not an ending. A column that is always
    /// present rather than one that appears on some lines: the fields after it stay at a fixed
    /// offset for an eye and for a `grep`, which is the rule sessionInputLogLine states.
    var reason: String {
        if case let .disarmed(_, reason) = self { return reason }
        return "-"
    }

    var version: String {
        switch self {
        case let .watching(version), let .armed(version), let .disarmed(version, _),
             let .opened(version), let .claimLost(version):
            return version
        }
    }
}

/// One line per decision. Pure, so the shape can be asserted without a home directory.
///
/// THE BUNDLE PATH GOES LAST, the rule its neighbour states about the text it carries: it is the one
/// field that can contain a space, so everything before it stays where the eye left it. The pid is
/// second because a machine carries as many of these stations as it has supervised sessions - ten
/// the day of the 2026-09-22 report - and every one of them writes here.
func appRelaunchLogLine(_ event: AppRelaunchEvent, bundle: String, pid: String = String(getpid()),
                        now: Date = Date()) -> String {
    "\(ISO8601DateFormatter().string(from: now)) pid=\(pid) app-relaunch=\(event.outcome) "
        + "reason=\(event.reason) version=\(event.version) bundle=\(bundle)\n"
}

/// Append one line. `appendHandoffLine` is the whole of the writing, creating `~/.tally/logs` on
/// its way in: this log has nothing of its own to add on top, unlike the input log beside it, which
/// wraps the same call to keep a mode (`sessionInputLogMode`).
func appendAppRelaunchLine(_ event: AppRelaunchEvent, bundle: String, now: Date = Date(),
                           to log: URL = appRelaunchLog) {
    appendHandoffLine(appRelaunchLogLine(event, bundle: bundle, now: now), to: log)
}
