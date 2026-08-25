import Foundation

/// What early start remembers between evaluations: enough to keep "at most one message per account
/// per closed-window episode" true across a restart, a sleep or an auto-update relaunch, and enough
/// for the Settings row to say what today has actually done.
///
/// EVERY TYPE HERE DECODES KEY BY KEY. The synthesized `Decodable` throws on a missing key rather
/// than falling back to the property default, and the store reads a decode failure as "no state at
/// all" - which, for this feature, means sending every message it already sent today a second time.
/// So a payload written by an older build has to READ, and the way that stays true as fields are
/// added is that fields are only ever added. Declared in extensions so the memberwise inits survive.

/// One account's suppression: when it was last acted on, and whether its window has been seen open
/// since.
///
/// THE TWO HALVES ANSWER DIFFERENT QUESTIONS and both are needed. `attemptedAt` bounds the cost, and
/// bounds it absolutely: whatever else is true, an account gets at most one message per
/// `EarlyStartLogic.retryInterval`. `sawWindowOpen` releases the suppression that has no cost behind
/// it - the one the arming stamp puts on an account no message was ever sent for
/// (`EarlyStartState.armedAt`) - because a window seen open and then closed is the provider's own
/// numbers saying that episode is over, and waiting out five hours for a message nobody sent buys
/// nothing.
///
/// IT IS RECORDED ON ATTEMPTED ACCOUNTS TOO, where it is a record rather than a release, and saying
/// otherwise was wrong for as long as this comment did: a window one of these messages opens is
/// itself `retryInterval` long, so it closes at the moment the floor lifts, and the floor is the one
/// that answers. A window that closes EARLIER than that was somebody else's, joined rather than
/// opened, and acting on it is how "at most one per five hours" would have stopped being true.
struct EarlyStartMark: Codable, Equatable {
    /// When a message was last attempted for this account, or nil when the suppression comes from
    /// the schedule being armed mid-episode rather than from an attempt (`EarlyStartState.armedAt`).
    var attemptedAt: Date?
    /// Whether this account's 5-hour window has been observed OPEN since `attemptedAt` (or since
    /// arming, when there was no attempt). Set from the pass list rather than from the spawn's exit
    /// code: what proves a window opened is the provider's own numbers saying so.
    var sawWindowOpen: Bool = false
}

extension EarlyStartMark {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attemptedAt = try container.decodeIfPresent(Date.self, forKey: .attemptedAt)
        sawWindowOpen = try container.decodeIfPresent(Bool.self, forKey: .sawWindowOpen) ?? false
    }
}

/// What the Settings row reports: today's running total, in the user's own calendar day.
///
/// A DAY'S TALLY RATHER THAN A LAST-RUN RECORD, because there is no longer a run. The schedule used
/// to make one decision each morning and the row named it; it now decides at every refresh, and a
/// row naming the latest of those would read "0 started, 0 skipped" all day - true of the last five
/// minutes and useless as an answer to "is this thing working?".
struct EarlyStartToday: Codable, Equatable {
    /// The local day this tally belongs to (`EarlyStartLogic.dayKey`). Held rather than inferred so
    /// a tally from yesterday is recognised and replaced instead of being added to.
    var day: String = ""
    /// Messages that went through.
    var started: Int = 0
    /// Attempts that were made and did not go through.
    var failed: Int = 0
    /// Accounts no attempt could be made for AT ALL, because there is no `claude` on the machine,
    /// deduplicated.
    ///
    /// A SET RATHER THAN A COUNT, for the reason `skipped` gives below and a sharper version of it.
    /// Nothing is marked when there is no CLI, deliberately, so that an install landing later is
    /// served by the very next evaluation - which means the same accounts are chosen again at every
    /// refresh, forever. As a counter this read "1,440 could not start" by the end of a day on which
    /// two accounts were never once tried.
    var couldNotStart: [String] = []
    /// Accounts passed over today for a reason that BLOCKED work (`EarlyStartSkip.countsAsSkip`),
    /// deduplicated.
    ///
    /// A SET OF ACCOUNTS, NOT A COUNT OF PASSES, and only the blocking reasons. The evaluation runs
    /// at every refresh, so a counter would climb into the hundreds by lunchtime, and an account
    /// that is simply working is not being skipped - that is the feature succeeding. What is left
    /// is the thing worth surfacing: an account signed out, or one whose polls are failing, which
    /// is a nonzero number here and nothing else on the row would say.
    var skipped: [String] = []
    /// When the most recent message was attempted today, or nil if none was.
    var lastAttemptAt: Date?

    var skippedCount: Int { skipped.count }
    /// Everything the row reports as "could not start": the attempts that were made and failed, plus
    /// the accounts no attempt could be made for. One number because the two are the same news to a
    /// reader (this account got nothing and it was not on purpose); two fields underneath because
    /// only one of them is bounded by the number of attempts.
    var couldNotStartTotal: Int { failed + couldNotStart.count }
}

extension EarlyStartToday {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decodeIfPresent(String.self, forKey: .day) ?? ""
        started = try container.decodeIfPresent(Int.self, forKey: .started) ?? 0
        failed = try container.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        couldNotStart = try container.decodeIfPresent([String].self, forKey: .couldNotStart) ?? []
        skipped = try container.decodeIfPresent([String].self, forKey: .skipped) ?? []
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
    }
}

/// Persisted bookkeeping (UserDefaults), so a restart, a sleep or an auto-update cannot turn one
/// episode into several.
struct EarlyStartState: Codable, Equatable {
    /// Account id to its suppression. Per account rather than per evaluation: an account signed out
    /// at noon and signed back in at one still gets its window opened, and its sibling's message
    /// says nothing about it.
    var marks: [String: EarlyStartMark] = [:]
    /// When the schedule was last armed, which suppresses every account's CURRENT episode without
    /// naming them (`EarlyStartLogic.arming` says why, and why it cannot name them).
    var armedAt: Date?
    /// Today's tally for the Settings row.
    var today: EarlyStartToday?
}

extension EarlyStartState {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        marks = try container.decodeIfPresent([String: EarlyStartMark].self, forKey: .marks) ?? [:]
        armedAt = try container.decodeIfPresent(Date.self, forKey: .armedAt)
        today = try container.decodeIfPresent(EarlyStartToday.self, forKey: .today)
    }
}
