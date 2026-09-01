import Foundation

// WHAT A HELD MOVE SAYS ON THE STATUS LINE, for both of the arms that can hold one.
//
// Split out of SessionSwitch.swift when that file ran out of room, along the seam it was already
// organised by: over there is WHO decides a session moves and WHEN, here is what the one row a
// person actually reads says while it has not happened. The two arms word the same three questions,
// and keeping their vocabularies side by side is what stops them answering differently: a typed
// `tally switch` and a pin moved in the panel are held by the same fleet for the same reasons, and
// for a while only the first of them said so at all.
//
// SHORT FORM AND LONG FORM ARE DIFFERENT THINGS HERE. The badge shares its row with the quota
// meters, so it is a few words and a test pins them; the detail beside it is composed, and always
// names the account the session is staying on meanwhile, because the question behind every badge on
// this track is "so where am I right now".

/// The status-line badge a switch leaves while the gate holds it. A constant because the wording is
/// asserted in a test and read by a person on the same line, and a copy of it drifting in one of the
/// two would assert nothing - the model axis keeps its own for that reason
/// (`sessionModelWaitingBadge`), and this is the same wait one axis over.
///
/// Short because it shares its row with the quota meters, like every badge on this track: WHICH
/// account the session is moving to, and which one it sits on until then, are the detail's job.
///
/// THE STATE, NOT A DEADLINE, which is the rule the long form already follows (`quietGateHolding`
/// carries the review): "after this turn" told the reader WHEN, and the gate reports only the first
/// term that said no, so the named moment arrived with nothing happening. It also promised a turn
/// this arm cannot promise - one Bool covers a live turn, an open tool call, an unresolved fork and
/// a subagent, so the badge says what the reload axis's short form has always said about the same
/// term (`reloadWaitReason`): the session is busy (codex review of fe4462d).
let switchQueuedBadge = "switch: session busy"

/// The other two waits the same gate produces, described the same way. `reloadQuiet` is three terms
/// (SessionSwitch asks it through `reloadQuiet` itself) and only the first is the transcript: a
/// prompt being typed and a session that has not written a turn at all both hold the move too. The
/// reader can only act on one of the three, which is the whole reason the reload axis names its gate
/// as well (`reloadWaitReason`).
let switchQueuedTypingBadge = "switch: typing"
let switchQueuedStartupBadge = "switch: starting up"
/// The fourth arm of `QuietGate`, which no caller can reach today: a gate term added there and not
/// here would land on a badge that is vague rather than wrong.
let switchQueuedIdleBadge = "switch: in use"

/// Which of the four badges above a gate wears. Apart from the wording below because the SHORT form
/// is a constant a test pins and a person reads on the same row, while the long form is composed.
private func queuedSwitchBadge(_ gate: QuietGate) -> String {
    switch gate {
    case .transcript: return switchQueuedBadge
    case .keyboard: return switchQueuedTypingBadge
    case .startup: return switchQueuedStartupBadge
    case .unknown: return switchQueuedIdleBadge
    }
}

/// What a queued switch says on the status line, and at length beside it: the gate that is actually
/// holding the move, named. `target` is where the session is going and `staying` where it sits until
/// then, which is the question behind every badge on this track.
///
/// DESCRIBED, NOT PROMISED. The long form used to finish each arm with when the move would happen
/// ("once the keyboard is quiet"), and the gate cannot support that: it reports the first term that
/// said no, and a second term can be false at the same moment, so the promised moment arrived with
/// nothing happening (`quietGateHolding` carries the review and the reasoning). The clause comes
/// from that one place now, and this axis words only what it is waiting to DO.
func switchQueuedWait(gate: QuietGate, target: String, staying: String) -> PendingBadge {
    PendingBadge(queuedSwitchBadge(gate),
                 detail: "\(quietGateHolding(gate)), so the move waits: switching to \(target); "
                     + "staying on \(staying) until then")
}

/// What a held switch says on the status line: one badge per REASON the move has not happened, and
/// they are kept apart because the reader can only act on one of them.
///
/// A dormant account is theirs to renew, and the badge says so. An account the fleet has momentarily
/// stopped listing is Tally's to notice again and needs nothing from them. A snapshot that cannot be
/// read at all is a third thing again - the app is not running, or its file is unreadable - and until
/// this existed all three said "signed out", which sends someone to re-authenticate a login that was
/// never the problem.
///
/// `staying` is the account the session remains on meanwhile, named in every detail line because the
/// question behind the badge is always "so where am I right now".
///
/// The two states that are not waits answer nil: a launchable target is not held, and a removed one
/// is cancelled rather than held (a `cancelled` badge, which is news rather than a state).
func switchWaitBadge(_ target: SwitchTargetState, staying: String) -> PendingBadge? {
    switch target {
    case .signedOut:
        return PendingBadge("switch: signed out",
                            detail: "the account `tally account` named has no login right now; "
                                + "staying on \(staying) until it is renewed")
    case .unlisted:
        return PendingBadge("switch: not listed",
                            detail: "the account `tally account` named is not in the current fleet "
                                + "snapshot, though its config home is still on disk; staying on "
                                + "\(staying) until Tally lists it again")
    case .unreadable:
        return PendingBadge("switch: no snapshot",
                            detail: "there is no fleet snapshot to find that account in - is "
                                + "Tally.app running? - so the move is held; staying on \(staying) "
                                + "until one can be read")
    case .launchable, .removed:
        return nil
    }
}

/// WHY A FLEET PIN HAS NOT MOVED THIS SESSION YET, which was said nowhere at all until this existed.
///
/// The pin switch narrows on three cells (`applyPinSwitch`) and only the last of them ends on a
/// clock: a quarantine expires on its TTL, while a snapshot nothing can read and an account with
/// nothing left to serve last exactly as long as they last. Under a FLEET pin nobody else ends that
/// wait either, and that is the whole of why it needs a badge: every preventive mover stands down on
/// `mode == "manual"`, the cap handoff answers `.waitPinned`, and this arm is the one station left,
/// so the session simply stays where it is while the board and the status line both draw it as
/// pinned to the account it is not on (`SessionPinScope`). A typed `tally switch` held by the same
/// fleet says why (`switchWaitBadge`); moving the pin in the panel said nothing.
///
/// TOLD APART RATHER THAN JOINED, on the same ground the switch badge separates its three: a reader
/// who cannot tell a quarantine from an empty account cannot tell "a few minutes" from "this is
/// where you live until the window resets".
enum PinSwitchWait: Equatable {
    /// No fleet snapshot to judge on: unreadable, too old to trust, or not naming the account this
    /// session is running on.
    case unreadable
    /// The pinned account is not in the snapshot at all.
    case unlisted
    /// Listed, and with nothing to serve: a failed poll, an error, a held-over row, or no headroom
    /// left in the window this session is running.
    case spent
    /// Listed and able to serve, and the cap handoff has just walked this session off it.
    case quarantined
}

/// What each of those reads on the status line. Short, like every badge sharing that row, with the
/// account it is staying on named in the detail because the question behind the badge is always "so
/// where am I right now".
func pinSwitchWaitBadge(_ wait: PinSwitchWait, pinned: String, staying: String) -> PendingBadge {
    switch wait {
    case .unreadable:
        return PendingBadge("pin: no snapshot",
                            detail: "there is no fleet snapshot to judge the pin against, is "
                                + "Tally.app running? so the move is held; staying on \(staying) "
                                + "until one can be read")
    case .unlisted:
        return PendingBadge("pin: not listed",
                            detail: "\(pinned) is pinned in Tally but is not in the current fleet "
                                + "snapshot; staying on \(staying) until Tally lists it again")
    case .spent:
        return PendingBadge("pin: nothing left",
                            detail: "\(pinned) is pinned in Tally and has nothing left to serve "
                                + "this session; staying on \(staying) until its window resets")
    case .quarantined:
        return PendingBadge("pin: just capped",
                            detail: "\(pinned) is pinned in Tally and just hit a wall, so the move "
                                + "is deferred rather than dropped; staying on \(staying) until "
                                + "that record expires")
    }
}

