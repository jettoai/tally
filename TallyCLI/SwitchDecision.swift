import Foundation

// What one poll tick DECIDES about a `tally switch` request: what the fleet (and the disk) say about
// the account it names, and what to do about that. Pure, every one of it - no files, no clock, no
// child - which is why it is split from SessionSwitch.swift, where the same decision is carried out
// against live state and the file that carries it is consumed.
//
// The order these are asked in is part of the contract, and it is stated where each function makes
// its own call. What is shared between them is the standard of proof: a wait is cheap and reversible
// (the next tick asks again), while cancelling a request the user typed cannot be undone, so nothing
// here reaches for the irreversible answer on the strength of one observation.

/// What the fleet says about the account a request names, read at the tick that could act on it.
///
/// The distinction between the last two is the same one `pinnedAccountIsSignedOut` draws for a pin
/// (AccountPick.swift), and for a sharper reason here. An account id is derived from its config
/// home's name, so a removed `~/.claude3` that is recreated and logged into IS `claude:.claude3`
/// again (AccountRemovals.swift says so, and builds its tombstone expiry on it). A request held
/// against an id that has left the fleet is therefore not waiting for its account to come back: it
/// is waiting for ANY account to claim that name, and it would then resume the conversation onto a
/// login the user never named.
enum SwitchTargetState: Equatable {
    /// There and logged in.
    case launchable(Snapshot.Account)
    /// Listed with no launch home: Tally is publishing "this one is dormant", so the login is gone
    /// and the account is not. Waiting is exactly right - renewing it makes the switch happen.
    case signedOut
    /// Not in this snapshot, but its config home is still on disk: the fleet's own record and the
    /// filesystem disagree, and the filesystem is the one that cannot blink. Held like a dormant
    /// account - the next snapshot that lists it again performs the switch on its own.
    case unlisted
    /// Not in this snapshot AND no config home to be found: the account is gone. Tally publishes
    /// every account it discovers, so an id missing from a snapshot we can read, whose directory is
    /// missing too, is one that has left the fleet.
    case removed
    /// No snapshot to judge by (the app has not run, or the file is unreadable). Says nothing about
    /// the account, so it can only mean wait - reading it as "removed" would cancel every pending
    /// switch on the machine the moment the snapshot went missing.
    case unreadable

    /// The account to launch, when there is one. Both readers below want the same thing out of the
    /// launchable case, and neither wants to spell the pattern match to get it.
    var account: Snapshot.Account? {
        guard case .launchable(let account) = self else { return nil }
        return account
    }
}

/// Pure classification, so the four ways an account can fail to be launchable stay testable and stay
/// distinct. `accounts` is nil when there is no readable snapshot, which is NOT the same as an empty
/// one: an empty snapshot really does list no accounts.
///
/// CANCELLING NEEDS EVIDENCE, NOT AN OBSERVATION. A snapshot is what the app saw on its last refresh,
/// and an account drops out of one for reasons that have nothing to do with the user removing it (a
/// Keychain probe that did not answer, a rescan in flight, an app that has not run since the account
/// was added). Every one of those is a minute long; cancelling is for ever. So absence from the
/// fleet only reaches `.removed` once the disk agrees, and `homeOnDisk` is asked in that one branch
/// and nowhere else - on the ticks that matter (a live request, a pin being resolved) it costs
/// nothing, because there is nothing missing to ask about. (A live `tally switch` was cancelled by a
/// snapshot that momentarily listed four of five accounts, 2026-08-06; AccountHome.swift.)
func switchTargetState(_ accountID: String, provider: String, accounts: [Snapshot.Account]?,
                       homeOnDisk: (String, String) -> Bool = {
                           accountHomeExists($0, provider: $1)
                       }) -> SwitchTargetState {
    guard let accounts else { return .unreadable }
    let named = accounts.filter { $0.id == accountID && $0.provider == provider }
    guard !named.isEmpty else {
        return homeOnDisk(accountID, provider) ? .unlisted : .removed
    }
    guard let launchable = named.first(where: { $0.launchHome != nil }) else { return .signedOut }
    return .launchable(launchable)
}

/// What one poll tick does about the switch request it just read.
enum SwitchDecision: Equatable {
    case none          // no request, or one this supervisor has already served
    case unavailable   // the account it names cannot be launched right now: hold it, and say so
    case cancelled     // the account it names has left the fleet: drop the request, and say why
    case alreadyThere  // the session is on that account already (a handoff got there first)
    case relaunch      // move now
    case queued        // the session is mid-turn: hold the request until it goes quiet
    case unpin         // `tally switch --auto`: drop the pin, move nothing
}

/// Pure decision, so the bookkeeping is testable without a child. A request fires exactly once (it
/// must be strictly newer than the stamp this supervisor captured at startup, which is what stops a
/// leftover file addressed to a REUSED pid from moving an unrelated session), and a busy session
/// holds it rather than losing it.
///
/// ORDER IS PART OF THE CONTRACT: what the target IS gets asked before whether the session is
/// quiet, because those are different waits and the badge has to name the right one.
///
/// A dormant or unknowable target is HELD: the wait is visible (the status line badge below), the
/// account coming back is a state the next tick simply reads, and dropping it would be a decision
/// made on the user's behalf about an instruction they gave by hand. A REMOVED one is cancelled
/// instead, and that is not a change of heart about holding: the id can be re-earned by a different
/// login (`SwitchTargetState`), so holding stops meaning "wait for that account" and starts meaning
/// "resume this conversation onto whoever takes the name next".
///
/// `--auto` is answered before anything else and without any of the waits, because it is the one
/// request that moves nothing: there is no child to be careful of, no account to be launchable, and
/// a release that waited for a quiet moment would leave the pin in force for exactly as long as the
/// user kept working - which is when they are least likely to want it.
func switchDecision(served: Int, request: SwitchRequest, target: SwitchTargetState, onTarget: Bool,
                    isQuiet: Bool) -> SwitchDecision {
    guard request.epoch > served else { return .none }
    guard !request.isUnpin else { return .unpin }
    switch target {
    case .removed: return .cancelled
    case .signedOut, .unreadable, .unlisted: return .unavailable
    case .launchable:
        if onTarget { return .alreadyThere }
        return isQuiet ? .relaunch : .queued
    }
}
