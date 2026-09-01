import Foundation

/// What early start remembers between evaluations: enough to keep "at most one message per account
/// every 5 hours" true across a restart, a sleep or an auto-update relaunch, and enough for the
/// Settings row to say what today has actually done.
///
/// EVERY TYPE HERE DECODES KEY BY KEY. The synthesized `Decodable` throws on a missing key rather
/// than falling back to the property default, and the store reads a decode failure as "no state at
/// all" - which, for this feature, means sending every message it already sent today a second time.
/// So a payload written by an older build has to READ, and the way that stays true as fields are
/// added is that fields are only ever added. Declared in extensions so the memberwise inits survive.
///
/// A FIELD THAT IS REMOVED HAS TO GO ON READING TOO, and does, because a decoder that names its keys
/// ignores the ones it is not asking about. Two went that way when the arming suppression did
/// (`EarlyStart.swift` says why): a mark's `sawWindowOpen`, and the state's `armedAt`. Whatever is
/// on disk keeps decoding; those two keys are simply not read, which is the same answer as their
/// having been nil.

/// One account's suppression: when a message was last sent for it.
///
/// A STRUCT FOR ONE DATE, deliberately. It carried a second field while the relay inferred anything
/// from a pass, and the shape is what the payload on disk is written in, so collapsing it to a bare
/// date would make every state written before this build fail to decode - which the store reads as
/// "nothing was ever sent" and answers by sending it all again.
///
/// WHAT IT BOUNDS IS COST, ABSOLUTELY: an account gets at most one message per
/// `EarlyStartLogic.retryInterval`, and this is the only thing in the feature that holds an account
/// back. It answers WITHOUT asking whose window closed, which is the only form of the rule that
/// holds: a window one of these messages opens is at most `retryInterval` long and routinely less
/// (Anthropic resets sessions on a ten-minute grid), so "it closed early, therefore it was somebody
/// else's" is false on ordinary days. The relay simply hands over a few minutes late.
///
/// NOTHING CLEARS THESE MARKS EARLY, the switch included. Turning the feature off and on again is
/// not a reason to spend a second message inside the interval, and it is the one path that could:
/// the marks used to be wiped there, which was safe only because a stamp took over the suppression
/// in the same breath. With that stamp gone, wiping them would hand back exactly the guarantee the
/// panel notice and the Settings row both state in words.
struct EarlyStartMark: Codable, Equatable {
    /// When a message was last attempted for this account. Optional only so that a payload written
    /// before this field was always set still decodes; an evaluation writes one on every attempt and
    /// prunes the ones it finds without it (`EarlyStartLogic.recording`).
    var attemptedAt: Date?
}

extension EarlyStartMark {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attemptedAt = try container.decodeIfPresent(Date.self, forKey: .attemptedAt)
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
    /// Attempts that were made and did not go through. A COUNT, and it stays one: it is the partner
    /// of `started`, the pair describes MESSAGES, and one account really can cost two failed
    /// messages in a day. What the row shows is a different question, answered by the two sets
    /// below (`couldNotStartTotal`).
    var failed: Int = 0
    /// WHICH accounts those failures belong to, deduplicated.
    ///
    /// Beside the count rather than instead of it, because the row and the arithmetic ask different
    /// questions of the same event: `started` has to have exactly as many messages taken back off
    /// it as were optimistically added, while the row is answering "how many accounts have got
    /// nothing today" and must not count one account twice. An account leaves this list the moment
    /// a later round is ANSWERED with a message through for it (`EarlyStartLogic.correcting`, where
    /// the answers are: the write before a spawn knows only that one is about to be tried), which
    /// the count beside it cannot do. A payload written by the build before this
    /// field simply reports fewer accounts for the rest of that day, which is the only window in
    /// which the two can disagree: the tally is replaced at midnight.
    var attemptFailed: [String] = []
    /// Accounts no attempt could be made for AT ALL, because there is no `claude` on the machine,
    /// deduplicated.
    ///
    /// A SET RATHER THAN A COUNT, for the reason `skipped` gives below and a sharper version of it.
    /// Nothing is marked when there is no CLI, deliberately, so that an install landing later is
    /// served by the very next evaluation - which means the same accounts are chosen again at every
    /// refresh, forever. As a counter this read "1,440 could not start" by the end of a day on which
    /// two accounts were never once tried. And when that install does land, the account whose
    /// message is ANSWERED comes back off this list rather than sitting on it until midnight.
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
    /// Everything the row reports as "could not start": ACCOUNTS that have got nothing today and
    /// not on purpose, whether the attempt failed or none could be made.
    ///
    /// AS THINGS STAND, not as they ever stood today. Both lists drop an account the moment a spawn
    /// ANSWERS that it went through (`EarlyStartLogic.correcting`), so a fleet that recovered by
    /// lunchtime reads zero here rather than reporting its morning back at itself all afternoon.
    /// Answered rather than merely attempted, because an app that dies mid-batch must leave the
    /// safe reading behind, and the safe reading is that nobody was served.
    ///
    /// A UNION, NOT A SUM. Adding `failed` to `couldNotStart.count` let one account be counted on
    /// both sides of the day - blocked all morning with no CLI, then attempted and failed once one
    /// arrived - and print "4 could not start" on a machine holding two accounts. Every quantity a
    /// reader compares against their own fleet has to be a set of accounts; the same mistake in
    /// counter form is what put 1,440 on this row.
    var couldNotStartTotal: Int { Set(attemptFailed).union(couldNotStart).count }
}

extension EarlyStartToday {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decodeIfPresent(String.self, forKey: .day) ?? ""
        started = try container.decodeIfPresent(Int.self, forKey: .started) ?? 0
        failed = try container.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        attemptFailed = try container.decodeIfPresent([String].self, forKey: .attemptFailed) ?? []
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
    /// Today's tally for the Settings row.
    var today: EarlyStartToday?
}

extension EarlyStartState {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        marks = try container.decodeIfPresent([String: EarlyStartMark].self, forKey: .marks) ?? [:]
        today = try container.decodeIfPresent(EarlyStartToday.self, forKey: .today)
    }
}
