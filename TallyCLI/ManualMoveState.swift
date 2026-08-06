import Foundation

// What one supervised session REMEMBERS about the moves its user asked for by hand, and the
// bookkeeping a served request owes. Split from SessionSwitch.swift at its size cap; the division is
// the one the feature already had - SwitchDecision.swift decides what a request means, this holds
// what the session carries between ticks and across relaunches, and SessionSwitch.swift wires the
// two into the poll loop.
//
// Everything here is IN MEMORY and per session, with two deliberate exceptions that reach for disk
// because the session outlives this process: the served stamp is seeded from the request file, and a
// cancellation notice is picked back up off the status-line file after a self-update exec keeps the
// pid but replaces the image.

/// What the supervisor remembers about the moves its user has asked for by hand. Held across
/// relaunches, like the recovery fuse and the quarantine.
struct ManualMoveState {
    /// This session's address: the supervisor's own pid, the same key the request file is named for.
    let sessionKey: String
    /// The newest switch stamp this supervisor has served.
    var servedEpoch: Int
    /// The account a `tally switch` pinned THIS session to, for as long as the session lasts: the
    /// sticky half of the command (see the header). nil means automatic selection is in charge,
    /// which is where every session starts and where `tally switch --auto` puts it back.
    var sessionPin: String?
    /// LEGACY, and only ever handed in: the pin a session was moved off by a supervisor from a
    /// build before the pin above existed, carried across that build's self-update exec
    /// (`--pin-override`, SelfUpdate.swift). Nothing in this build writes it - a switch now records
    /// `sessionPin`, which outranks every pin rather than just the one it overrode - but a session
    /// upgrading mid-life arrives holding one, and dropping it would hand that session straight
    /// back to the pin its user had moved it off, minutes later, for no reason they can see.
    var overriddenPin: String?
    /// Why a request is being held rather than served, for the status line's badge; nil when nothing
    /// is being held for a reason worth showing. Re-derived every tick from live state, like every
    /// other badge (PendingNotice.swift), so it disappears the moment the reason does.
    var waiting: PendingBadge?
    /// A request this supervisor CANCELLED, which is news rather than a state: the thing it
    /// describes is gone by the time it is read, so nothing re-derives it and it has to be HELD.
    ///
    /// Which is exactly why it needs an end of its own. Every other badge on this track disappears
    /// when its condition does; this one has no condition left to watch, so until it was given the
    /// bound below it simply stayed - a "switch: account removed" was still on the status line long
    /// after the account was back, outliving even the app update that replaced the supervisor
    /// (2026-08-06; the file that carried it across that exec is PendingNotice.swift's half of the
    /// same report).
    var cancelled: PendingBadge?
    /// When that news was raised, so it can stop being news. nil whenever `cancelled` is.
    var cancelledAt: Date?

    /// The one badge the status line gets from this session's manual moves: a live wait outranks
    /// old news, because it is the thing that is still true.
    var badge: PendingBadge? { waiting ?? cancelled }

    /// The cancellation notice has been READ, so it stops being shown: the user has said something
    /// themselves since it was raised.
    ///
    /// THE USER, not the session. The obvious signal is the one the cap recovery uses - an assistant
    /// event newer than the thing being cleared (CapDetection.swift) - and it is wrong here for a
    /// reason specific to this command: `tally switch` is normally run BY the agent, as a tool call,
    /// from inside a turn. A tool call is followed by its result and by more assistant events within
    /// that same turn, so "an assistant event happened since" is true a second or two after the
    /// notice is raised, and the notice would come down while the user is still reading the answer
    /// it belongs to - never seen, which is the whole thing it exists to be (caught in review,
    /// 2026-08-06). Their next prompt is the first moment they demonstrably have.
    ///
    /// A prompt rather than a timer for the same reason a timer was refused before: it would expire
    /// unread on a session nobody is watching, and linger on one being worked in.
    ///
    /// `lastUserTurnAt` is per CHILD, so a relaunch resets it to nil: a notice that outlives a
    /// restart then waits for the first prompt after it, which is the same promise measured from
    /// the same place.
    mutating func expireCancellation(lastUserTurnAt: Date?) {
        guard let cancelledAt, let lastUserTurnAt, lastUserTurnAt > cancelledAt else { return }
        cancelled = nil
        self.cancelledAt = nil
    }

    /// Pick a cancellation notice back up off disk, which is how it survives a self-update.
    ///
    /// The exec keeps the pid and starts this state from nothing, so the notice the replaced image
    /// had just raised exists only in `<pid>.notice` - and the seeded writer's first honest "nothing
    /// is pending" would unlink it (PendingNotice.swift). The file carries everything needed to put
    /// it back, including WHEN it was raised (`since`), so the expiry measures from the original
    /// moment rather than from the upgrade.
    ///
    /// Only a cancellation is adopted. Every other badge on this track is re-derived from live state
    /// within a tick or two of the new image starting, so adopting those would be picking up a value
    /// that is about to be recomputed anyway - and picking up a stale one if the condition has since
    /// cleared.
    ///
    /// TWO WAYS TO RECOGNISE ONE, and the second is a cross-version arm rather than a second rule.
    /// `kind` is what identifies a notice from here on, but the upgrade this has to survive FIRST is
    /// the one out of the build that introduced the notice and not the field (0.38.0 → 0.38.1, which
    /// is the path every session on this machine is about to take): those files carry no `kind`, the
    /// structural test alone would refuse them, and the very next sync would unlink exactly the
    /// notice this exists to keep. So a legacy notice is recognised by its badge text - the one
    /// string the cancellation has ever been written under (`switchCancelledBadge`, which is now
    /// where that string is spelled, so the two cannot drift). It stays a WHITELIST either way: a
    /// wait badge with no kind is still not news and is still not adopted.
    ///
    /// The writer only rewrites the file when the badge TEXT changes (PendingNotice.swift), so a
    /// notice adopted through the legacy arm keeps its kind-less file until it is replaced - which
    /// is why that arm is not a one-release measure and is documented rather than dated. What it
    /// does not cost is the stamp: leaving the file alone is what preserves `since`.
    mutating func adoptCancellation(_ notice: PendingNotice?) {
        guard let notice,
              notice.kind == cancellationNoticeKind || notice.badge == switchCancelledBadge
        else { return }
        // Always stamped with the kind, whichever arm let it through, so what this session writes
        // from here on is recognisable by the structural test alone.
        cancelled = PendingBadge(notice.badge, detail: notice.detail,
                                 kind: cancellationNoticeKind)
        cancelledAt = notice.since
    }

    /// `servedEpoch` defaults to whatever is pending right now, so a request written before this
    /// supervisor existed is never replayed (the file is addressed by pid, and pids come round
    /// again). A test supplies it directly, and so does the ONE caller for which that default is
    /// wrong: a self-update exec keeps the pid and IS the same session, so a request written
    /// moments before it was written for this conversation and would be swallowed by the seed
    /// (`resumed`, Supervisor.swift).
    ///
    /// `sessionPin` is likewise handed over across that exec (`--session-pin`, SelfUpdate.swift),
    /// and so is `overriddenPin` before it (`--pin-override`): both are promises about the user's
    /// SESSION rather than about this process, and a new image that started without them would undo
    /// by itself an instruction the user gave by hand.
    init(sessionKey: String, servedEpoch: Int? = nil, sessionPin: String? = nil,
         overriddenPin: String? = nil, dir: URL = switchRequestDir) {
        self.sessionKey = sessionKey
        self.servedEpoch = servedEpoch
            ?? (readSwitchRequest(sessionKey: sessionKey, dir: dir)?.epoch ?? 0)
        self.sessionPin = sessionPin
        self.overriddenPin = overriddenPin
    }

    func pinOverridden(_ pinnedAccountID: String) -> Bool { pinnedAccountID == overriddenPin }

    /// A relaunch is about to happen for `reason`: whether it is the one move allowed past the
    /// session pin, which therefore ends it. True exactly once per pin, and the pin is gone by the
    /// time this returns - the caller's only job is to SAY so (`sessionPinClearedByCapNotice`) and
    /// to name the audit line accordingly.
    ///
    /// The cap alone. Every other automatic mover is prevented from planning anything at all while
    /// a pin stands (`sessionPolicy`), so nothing else can reach here holding one; a cap can,
    /// because a session that cannot answer is worse than a session that moved. Clearing rather
    /// than remembering is what stops the pin from dragging the conversation back to a capped
    /// account on the next quiet tick.
    mutating func pinClearedByCap(_ reason: String) -> Bool {
        guard reason == "cap", sessionPin != nil else { return false }
        sessionPin = nil
        return true
    }
}

/// The status-line badge a cancelled `tally switch` leaves behind. A constant because two places
/// have to agree on it exactly: the branch that raises it, and the cross-version arm that recognises
/// one written by a build that stamped no `kind` (`adoptCancellation`). It is also the string a user
/// has already seen on their status line, so it is not free to change casually.
let switchCancelledBadge = "switch: account removed"

/// What the user is told when a cap takes a pinned session anyway. A constant because it is the one
/// sentence tying the two halves of that decision together (the move happened, the pin is gone), and
/// a copy of it drifting in a test would assert nothing.
let sessionPinClearedByCapNotice =
    "session pin cleared (cap hit); re-pin with `tally switch <account>` once quota is back"

/// The bookkeeping a PLANNED switch owes, carried from the decision to the execution point and
/// written only once the relaunch is certain.
///
/// Recording it while planning is what the unresolved-fork hold turns into a lost request: the tick
/// stands the relaunch down, and a stamp already marked served makes every later tick read the
/// request as one it has handled (StandDown.swift, where a `tally reload` proved it). Nothing here
/// is undone on a stand-down because nothing has been written yet.
struct PendingSwitchConsumption {
    let epoch: Int
    /// Where the session pin stands once this request has been served: the account it named, or nil
    /// for a `--auto` that released it. A branch that changes nothing about the pin passes what is
    /// already there.
    let sessionPin: String?
    let dir: URL

    /// The file is unlinked only when it still holds the request that was SERVED. Between planning
    /// and here the child is terminated, and a second `tally switch` typed in that window overwrites
    /// the same path with a newer stamp: an unconditional unlink would delete an instruction nobody
    /// has carried out, and the millisecond stamps exist precisely so that two switches in quick
    /// succession are two switches. A newer stamp left on disk fires on the next tick, because
    /// `servedEpoch` records the epoch this consumption served rather than "whatever is pending".
    ///
    /// Not airtight, and knowingly so: a write landing between the read and the unlink is still
    /// lost. Closing that needs an atomic compare-and-unlink the filesystem does not offer for this
    /// shape, and the window shrinks from "the whole relaunch" (a child terminated, a transcript
    /// located and shared, a process spawned) to two syscalls.
    func commit(_ state: inout ManualMoveState) {
        state.servedEpoch = epoch
        state.sessionPin = sessionPin
        state.waiting = nil
        if readSwitchRequest(sessionKey: state.sessionKey, dir: dir)?.epoch == epoch {
            clearSwitchRequest(sessionKey: state.sessionKey, dir: dir)
        }
    }
}
