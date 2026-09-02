import Foundation

// The audit half of the folder trust a relaunch seeds (Tally/Core/TrustSeed.swift holds the act
// itself, and the incident that asked for it).
//
// A file of its own rather than a fifteenth line formatter in SupervisorRuntime.swift, which sits
// at the 500-line cap this repo keeps. The seam is honest as well as arithmetic: everything there
// records where a session MOVED, while this records something Tally wrote into another program's
// state file on the session's behalf, which is the one act on this path a reader may want to audit
// long after the relaunch it belongs to has been forgotten.

/// The line a SEEDED FOLDER TRUST leaves (grep `trust-seeded`): this relaunch would have put the
/// child in front of a trust dialog nobody was there to answer, and Tally wrote the answer the
/// running session had already given by being there.
///
/// Written only when the state file actually CHANGED, so the log records an act rather than an
/// attempt and a relaunch into an already-trusted folder stays silent. Pure, for the reason every
/// other line on this track is: the point of the fields is that somebody reads them back weeks
/// later, and a format nothing asserts is a format that drifts.
///
/// `home` is the config home's PATH and is reduced here to its own name (`.claude`, `.claude2`),
/// which is the naming every caller wants and none of them should have to spell: the account label
/// would be friendlier and can contain a space, and `handoffLogLine`'s rule is that `cwd` is the
/// only field allowed one, because everything before it is read at a fixed offset by eye and by
/// `grep`. That is also why `cwd` goes last here.
func trustSeedLine(sessionID: String?, pid: String, home: String, cwd: String,
                   now: Date = Date()) -> String {
    let sid = sessionID.map { String($0.prefix(8)) } ?? "unknown"
    let name = URL(fileURLWithPath: home).lastPathComponent
    return "\(ISO8601DateFormatter().string(from: now)) session=\(sid) pid=\(pid) "
        + "trust-seeded home=\(name) cwd=\(cwd)\n"
}
