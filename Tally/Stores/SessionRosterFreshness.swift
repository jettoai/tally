import Foundation

// WHICH SESSIONS ARE STILL BEING WATCHED BY YESTERDAY'S BUILD, and how a card says so.
//
// An app update replaces the binary under every live supervisor at once, and none of them takes it
// there and then: each goes on running the logic it was launched with until the next moment its own
// session is idle, when it replaces itself with the new one (SelfUpdate.swift). That is the right
// behaviour - a supervisor that exec'd itself mid-turn would take the turn with it - and it leaves a
// window, sometimes hours long, in which a board of eight sessions holds one or two running code
// that is no longer what is installed. Nothing outside those terminals could see it: the status line
// says so inside the session it is about (`SupervisionStatus`), which is exactly where somebody
// looking at the board is not.
//
// A FILE OF ITS OWN because the store is at its size cap, and split along the seam the reading is
// on: everything here is about the SUPERVISOR watching a session rather than about the session, and
// it is the only question on the board whose answer is normally nothing at all.
//
// AN EXCEPTION RATHER THAN A FIELD, which is the whole design (Albert, 2026-08-23). A resident
// version on every card would spend a segment of the identity line, on every card, for a reading
// that is worth acting on for a few minutes after an update and is noise for the rest of the week -
// and the action it prompts is nothing, since the update happens on its own.

extension SessionRosterStore.SessionRow {
    /// The build this session's supervisor is running, as it published it. nil from a supervisor
    /// older than the field, which says "cannot compare" rather than "out of date"
    /// (`SessionStateRecord.supervisorVersion`).
    var supervisorVersion: String? { record?.supervisorVersion }

    /// The version to SAY on this card, or nil when there is nothing to say - which is what an
    /// ordinary card answers and what most cards answer even on the day of an update.
    var outdatedSupervisorVersion: String? {
        outdatedSupervisorBuild(supervisorVersion, installed: BuildVariant.version)
    }
}

/// Whether a supervisor's published build is one to say something about, and what to say.
///
/// DIFFERENT RATHER THAN OLDER, which is the same test the status line inside the session already
/// makes (`supervisionStatus`, whose `.outdated` is literally "not equal") and therefore the same
/// answer in both places. Ordering the two versions would need the CLI's own comparison, which the
/// app does not compile, and would buy nothing a person acts on: a supervisor that does not match
/// what is installed is running other code either way.
///
/// BOTH ENDS MUST BE KNOWN. A record from before the field carries nil, and an app bundle can carry
/// no version at all (`BuildVariant.version`); either way there is no comparison to make, and
/// drawing one anyway would light the badge on every card on the machine the day this ships.
func outdatedSupervisorBuild(_ published: String?, installed: String?) -> String? {
    guard let published, let installed, published != installed else { return nil }
    return published
}

extension SessionRosterStore {
    /// How many sessions are being watched by a build other than this one: the board's one
    /// exceptional count, and zero on an ordinary machine. The summary that shows it draws nothing
    /// at all when it is zero, unlike the four state counts beside it which keep their slots
    /// (`sessionsSummary`).
    var updatingCount: Int { rows.filter { $0.outdatedSupervisorVersion != nil }.count }
}
