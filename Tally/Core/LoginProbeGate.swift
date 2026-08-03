import Foundation

/// When the login-status probe may run, and what a finished round leaves behind.
///
/// The probe is throttled to five minutes because a credential does not change as often as a quota
/// does - but it changes the instant the user signs back in, and the chip saying "Login expired" is
/// read off the verdict that throttle is holding. So a renewal has to be able to force a round, and
/// forcing it turned out to be harder than passing a flag:
///
///   1. the forcing refresh can be COALESCED into one already in flight, and the merged refresh used
///      to drop the flag (UsageStore.refresh);
///   2. the forced round can arrive while another probe round is out, and a guard that only stops
///      two rounds overlapping used to drop it on the floor - after which the interval skipped the
///      next few rounds too;
///   3. the CLI reports a login landed a moment before the credential is on disk, so even a round
///      that does run can read the OLD answer and hold it for the rest of the interval.
///
/// That is the shape of the bug Albert hit on 2026-08-03: a Codex account renewed on the second
/// attempt, its quota came back at full Team allowance, and the red chip stayed on the card.
///
/// This is the whole decision, pure, so all three can be asserted without a CLI, a store or a clock.
enum LoginProbeGate {
    /// What a login attempt buys an account: rounds it may force past the interval while it still
    /// reads signed out, and whether one of them should come back almost immediately.
    struct Forcing: Equatable {
        /// How many more rounds this account may force while it still reads signed out. A renewal
        /// that reported success needs one (its short re-ask carries itself); a login handed to a
        /// Terminal window needs a few, because Tally cannot see when the user finishes it there.
        var roundsLeft: Int
        /// Whether the next round should be followed by a short re-probe rather than by the
        /// interval. Spent the first time it is used.
        var retrySoon: Bool
    }

    struct State: Equatable {
        /// Accounts whose verdict must be re-established at the next chance, throttle or not.
        var forced: [String: Forcing] = [:]

        var isForcing: Bool { !forced.isEmpty }
    }

    /// A renewal the CLI reported as successful: one forced round, and a short re-probe behind it
    /// for the seconds between "the login landed" and the credential appearing on disk.
    static let renewed = Forcing(roundsLeft: 1, retrySoon: true)

    /// A login handed to a Terminal window Tally cannot watch. No short re-probe (the user is typing
    /// in another window, not waiting on a file write), but several rounds of patience: the refresh
    /// that the new credential file triggers is the one that has to be allowed through.
    static let handedOff = Forcing(roundsLeft: 3, retrySoon: false)

    /// How long after a forced round the short re-probe runs.
    static let retryDelay: TimeInterval = 2

    enum Decision: Equatable {
        /// Run a round now.
        case run
        /// A round is already out; re-ask the moment it finishes rather than dropping this one.
        case queue
        /// Nothing here the interval does not already cover.
        case skip
    }

    static func decide(state: State, isProbing: Bool, userInitiated: Bool, lastProbeAt: Date?,
                       now: Date, interval: TimeInterval) -> Decision {
        let wanted = userInitiated || state.isForcing
        if isProbing { return wanted ? .queue : .skip }
        guard !wanted else { return .run }
        if let last = lastProbeAt, now.timeIntervalSince(last) < interval { return .skip }
        return .run
    }

    /// What a round leaves behind: the forcings that are still owed an answer, and whether a short
    /// re-probe should follow.
    ///
    /// An account the round did not probe at all keeps its forcing untouched - it was never asked.
    /// One that came back anything other than signed out is settled: the chip is gone and the
    /// interval can have it back. One still reading signed out spends a round, and is dropped when
    /// it runs out rather than forcing every refresh forever.
    static func afterRound(state: State,
                           verdicts: [String: LoginStatusCommand.Verdict]) -> (next: State,
                                                                               retrySoon: Bool) {
        var next = state
        var retrySoon = false
        for (id, forcing) in state.forced {
            guard let verdict = verdicts[id] else { continue }
            guard verdict == .signedOut else { next.forced[id] = nil; continue }
            retrySoon = retrySoon || forcing.retrySoon
            let left = forcing.roundsLeft - 1
            next.forced[id] = left > 0 ? Forcing(roundsLeft: left, retrySoon: false) : nil
        }
        return (next, retrySoon)
    }
}
