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
    ///
    /// These rounds are patience with the CLI, not with the user. The ladder behind a handoff re-arms
    /// them when it sees the credential land, so a slow sign-in cannot spend them before there is
    /// anything to ask about (`handoffPatience`).
    static let handedOff = Forcing(roundsLeft: 3, retrySoon: false)

    /// How long after a forced round the short re-probe runs.
    static let retryDelay: TimeInterval = 2

    /// How long between the ticks a handed-off login runs on its own (RenewLoginStore).
    ///
    /// Forcing a round only helps if a round happens, and after a handoff nothing schedules one: the
    /// renewal returned the moment the Terminal window opened, and the only other thing that would
    /// notice the login landing is the config-dir watcher, which is fail-open by design
    /// (AccountDirWatcher). So the handoff runs a ladder of its own, this far apart, and each tick
    /// asks the question below.
    static let handoffPollDelay: TimeInterval = 10

    /// How long that ladder keeps looking, and the reason it is a clock rather than a round count.
    ///
    /// `handedOff.roundsLeft` is the gate's patience with an account that keeps reading signed out.
    /// Spending one of those per tick made three of them the deadline for the PERSON as well, and
    /// thirty seconds was never a claim about how long a browser sign-in takes: a user slower than
    /// that landed their credential into a ladder that had already stopped, and with no watcher
    /// event to fall back on the red chip stayed up until the poll timer came round, which is as
    /// much as fifteen minutes (codex review, 2026-08-03).
    ///
    /// So the two clocks are separate. This one is the person's, and it is as generous as the watch
    /// the Terminal window itself gets (LoginTerminalFallback: 300 rounds a second apart).
    static let handoffPatience: TimeInterval = 5 * 60

    /// What one tick of that ladder does.
    enum HandoffTick: Equatable {
        /// Nothing has landed yet. Look again, having spent nothing but a file check.
        case wait
        /// The credential is on disk: ask for a round.
        case ask
        /// The credential is on disk and this is the last tick: ask, then close the ladder.
        case askThenStop
        /// Nothing left to wait for, or nobody left to wait for it.
        case stop
    }

    /// One tick, pure, so the ladder's shape can be asserted without a clock or a filesystem.
    ///
    /// The order is the point. A round is only asked for once the credential is actually there, so
    /// waiting costs a `stat` rather than a probe per enabled account, and the gate's rounds are
    /// spent where they were meant to be - on the seconds between a credential appearing and the
    /// CLI agreeing that it has - instead of on the minutes a person spends typing.
    ///
    /// The deadline is asked SECOND for the same reason. A credential that landed between the last
    /// tick and this one is news this tick is the first to have, and a ladder that stopped on the
    /// clock before reading it threw away a login finished at 4:55 - back to waiting on the ordinary
    /// poll, which is the very outcome the ladder exists to prevent (codex review, 2026-08-03). So
    /// the last tick still gets its question in; it just does not get another one.
    static func handoffTick(elapsed: TimeInterval, credentialLanded: Bool,
                            awaitingLogin: Bool) -> HandoffTick {
        guard credentialLanded else { return elapsed < handoffPatience ? .wait : .stop }
        guard awaitingLogin else { return .stop }
        return elapsed < handoffPatience ? .ask : .askThenStop
    }

    /// A cheap fingerprint of the credential in one config home, and the rule for reading two of
    /// them (RenewLoginStore takes them; this decides what a difference means).
    ///
    /// A fingerprint rather than a yes/no, because renewing an EXPIRED login usually starts with a
    /// credential still sitting there: an `auth.json` holding a refused token, or a Keychain item
    /// whose refresh token was revoked. "Is there one?" is already true before the user types
    /// anything, so the only usable signal is that the one on disk is no longer the one that was
    /// there when Tally handed the login over.
    struct CredentialStamp: Equatable {
        /// Whether the credential file is there at all. Separate from the attributes below because
        /// a `stat` failing and a file being absent are different answers: the first is a worse
        /// view of the machine, the second is the machine.
        var fileExists: Bool = false
        var fileModifiedAt: Date?
        var fileSize: Int?
        var keychain: Bool
        var keychainModifiedAt: Date?

        /// Whether this stamp is a NEW credential rather than the old one seen through a worse
        /// view of the same machine.
        ///
        /// Every field here can fail to be read - a locked Keychain answers with no attributes at
        /// all - and nil means "not known", never "not there". Comparing a nil against a date makes
        /// the lock itself look like a login landing, which ends the ladder's waiting on a
        /// credential that never moved (codex review, 2026-08-03). So a field only speaks when both
        /// sides of the comparison could be read, and anything unreadable simply reads as
        /// unchanged: the account falls back to the config-dir watcher and the poll, where it was
        /// before this ladder existed. Never the other way round.
        ///
        /// Existence is the one thing that cannot go unknown - a locked Keychain item still answers
        /// that it is present (KeychainReader.exists), and a file either has a directory entry or
        /// does not - so it speaks in one direction: a credential appearing is a login landing, one
        /// disappearing is not.
        ///
        /// Both existences have to be asked, not just the Keychain's. Only Claude Code keeps a
        /// login there, so a Codex account's `keychain` is false on both sides of every comparison,
        /// and a dormant one starts with no `auth.json` at all: every attribute is nil before the
        /// login and a date after it, which the rule above reads as unchanged. That is the exact
        /// account the Terminal handoff exists for, and its ladder would have waited out its five
        /// minutes without asking once (codex review, 2026-08-03).
        func landed(after previous: CredentialStamp) -> Bool {
            Self.moved(previous.fileModifiedAt, fileModifiedAt)
                || Self.moved(previous.fileSize, fileSize)
                || Self.moved(previous.keychainModifiedAt, keychainModifiedAt)
                || (fileExists && !previous.fileExists)
                || (keychain && !previous.keychain)
        }

        private static func moved<Value: Equatable>(_ before: Value?, _ after: Value?) -> Bool {
            guard let before, let after else { return false }
            return before != after
        }
    }

    /// Which of a finished round's readings may still be written.
    ///
    /// A round is several CLI spawns wide and takes seconds, and a credential can land in the middle
    /// of one. That round then answers about a machine that no longer exists: it says signed out
    /// because that was true when it asked, and writing the answer puts the red chip back on an
    /// account that is signed in, announces an outage that has ended, and spends the forcing that
    /// was waiting for a real answer (codex review, 2026-08-03). The landing is the better witness -
    /// it is credential-shaped, and the reading is a memory of the moment before it.
    ///
    /// A generation rather than a flag, because rounds overlap: what is stale is a reading asked for
    /// BEFORE the landing, not everything that arrives after it.
    struct Landings: Equatable {
        private var stamp = 0
        private var landed: [String: Int] = [:]

        /// What a round starting now carries, and what its answers are later judged against.
        var mark: Int { stamp }

        /// A credential landed for these accounts. An empty set is not news.
        mutating func land(_ accountIDs: Set<String>) {
            guard !accountIDs.isEmpty else { return }
            stamp += 1
            for id in accountIDs { landed[id] = stamp }
        }

        /// Whether a round that started at `mark` may still answer for this account.
        func isStale(_ accountID: String, since mark: Int) -> Bool {
            (landed[accountID] ?? 0) > mark
        }
    }

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
    ///
    /// `known` is every account that still EXISTS on this machine, and it is what stops "was never
    /// asked" from meaning "forever". An account removed after its login was handed to a Terminal
    /// window can never produce a verdict again, so its forcing would never be spent - and one
    /// forcing left behind makes `isForcing` true, which puts EVERY later refresh past the
    /// five-minute throttle and spawns a probe per enabled account each time (codex review,
    /// 2026-08-03). Nothing left to ask means nothing left to wait for.
    static func afterRound(state: State, verdicts: [String: LoginStatusCommand.Verdict],
                           known: Set<String>) -> (next: State, retrySoon: Bool) {
        var next = state
        var retrySoon = false
        for (id, forcing) in state.forced {
            guard known.contains(id) else { next.forced[id] = nil; continue }
            guard let verdict = verdicts[id] else { continue }
            guard verdict == .signedOut else { next.forced[id] = nil; continue }
            retrySoon = retrySoon || forcing.retrySoon
            let left = forcing.roundsLeft - 1
            next.forced[id] = left > 0 ? Forcing(roundsLeft: left, retrySoon: false) : nil
        }
        return (next, retrySoon)
    }
}
