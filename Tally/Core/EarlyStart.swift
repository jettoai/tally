import Foundation

/// Early start: opening each Claude account's 5-hour window in the morning, so the window resets
/// earlier in the day rather than whenever the first prompt happens to be typed.
///
/// Claude's 5-hour window begins at the FIRST message of a stretch, not at a fixed hour, so a day
/// that begins at 10am carries its reset until 3pm and the one after that until 8pm. One short
/// message sent at 7am moves the whole ladder into working hours. That is the entire feature: it
/// starts a window the user was going to start anyway, a few hours earlier.
///
/// Everything in this file is a pure function of values, Foundation only (no AppKit, no timers, no
/// Process), so `tests/earlystart` compiles it standalone. The scheduling and the spawn live in
/// `Tally/Stores/EarlyStartStore.swift`; what a spawn actually IS lives in `EarlyStartCommand.swift`.

/// One account as the morning run sees it: everything the decision needs, and nothing it does not.
///
/// Assembled from two sources the store holds separately (usage rows carry the window, discovery
/// carries the home), which is exactly why it exists: the rule below reads one value type and can
/// be asserted without either of them.
struct EarlyStartCandidate: Equatable {
    var accountID: String
    var providerID: String
    /// The home a launch may use (`ProviderAccount.launchableHome`). Nil = there is no credential
    /// to run on, so there is nothing to start.
    var home: String?
    /// Whether the user has this account (and its provider) switched on.
    var isEnabled: Bool
    /// Whether the latest poll for this account SUCCEEDED (`EarlyStartLogic.readingIsUsable`). A
    /// held-over reading cannot answer the window question, and a wrong answer here spends a
    /// message rather than saving one.
    var readingIsUsable: Bool
    /// Whether the 5-hour window is already counting down (`EarlyStartLogic.windowIsOpen`).
    var windowIsOpen: Bool
}

/// Why one account was passed over. A value rather than a bare Bool because the Settings line
/// counts only the passes a user would recognise as skips, and the two kinds that mean "there was
/// no work this morning at all" must not be counted or the record would be overwritten by every
/// later wake (see `EarlyStartPlan.isReportable`).
enum EarlyStartSkip: String, Equatable {
    /// Not a Claude account. v1 acts on Claude alone: Codex's own limits do not work this way.
    case otherProvider
    /// The user switched this account, or its whole provider, off.
    case accountOff
    /// Signed out, or otherwise with no home to launch with.
    case notLaunchable
    /// The latest poll failed, so whether the window is open is not known this morning.
    case unreadable
    /// The window is already counting down. The commonest pass, and the one the feature is for:
    /// somebody who was already working gets nothing sent on their behalf.
    case windowOpen
    /// This account already had its message today.
    case alreadyStarted
    /// The schedule was armed after today's trigger had gone by, so today is not its day.
    case daySuppressed

    /// Whether this pass belongs in the "N skipped" the Settings row reports.
    ///
    /// The three that do not are the three that are not about this morning: two of them say the
    /// account was never in scope, and `alreadyStarted` says the morning already happened. Counting
    /// that last one would let a wake at 9am record "0 started, 2 skipped" over the 7am run's
    /// "2 started", which is the true sentence about the wrong event.
    var countsAsSkip: Bool {
        switch self {
        case .otherProvider, .accountOff, .daySuppressed, .alreadyStarted: return false
        case .notLaunchable, .unreadable, .windowOpen: return true
        }
    }

    /// Whether this pass FINISHED the account's morning, so no later refresh may start it today.
    ///
    /// A DIFFERENT AXIS FROM `countsAsSkip`, and the two disagree about every case they share:
    /// that one asks whether the user would recognise the pass as a skip, this one asks whether
    /// anything is still owed. `windowOpen` is both - it is reported, and it is done.
    ///
    /// Only `windowOpen` finishes anything. The feature promises one decision per account per
    /// morning ("Each morning at 07:00"), and an account that was already working at 07:00 has had
    /// its decision: without a stamp the window it was running closes at 09:00 and the next refresh
    /// starts a fresh one on its behalf, hours after the morning it was for.
    ///
    /// The two passes that must NOT finish the day are the two the catch-up exists for: an account
    /// signed out at 07:00 and signed back in at 08:00 (`notLaunchable`), and one whose poll failed
    /// at 07:00 and succeeded at 08:00 (`unreadable`). Both are "not known yet", not "not today".
    /// The remaining four are already terminal through some other part of the state, or were never
    /// in scope, so a stamp would say nothing and only enlarge the payload.
    var completesDay: Bool {
        switch self {
        case .windowOpen: return true
        case .otherProvider, .accountOff, .notLaunchable, .unreadable, .alreadyStarted,
             .daySuppressed: return false
        }
    }
}

/// One account passed over, with the reason.
struct EarlyStartPass: Equatable {
    var accountID: String
    var reason: EarlyStartSkip
}

/// What one morning evaluation decided.
struct EarlyStartPlan: Equatable {
    var start: [EarlyStartCandidate] = []
    var passed: [EarlyStartPass] = []

    /// Whether this evaluation is worth writing down as a run. A morning that started nothing and
    /// passed over nothing IN SCOPE did not happen, and must not replace the record of the one that
    /// did (see `EarlyStartSkip.countsAsSkip`).
    var isReportable: Bool { !start.isEmpty || passed.contains { $0.reason.countsAsSkip } }

    var skippedCount: Int { passed.filter { $0.reason.countsAsSkip }.count }
}

/// What the Settings row reports about the last morning.
struct EarlyStartRun: Codable, Equatable {
    var at: Date
    var started: Int
    var skipped: Int
    /// Accounts whose message was attempted and did not go through (the CLI exited non-zero, or
    /// never ran). Reported rather than retried: a feature that fails every morning has to SAY so
    /// on the row somebody would look at, or it is a switch that reads "on" and does nothing.
    var failed: Int = 0
}

/// Decoded key by key for the reason `EarlyStartState` gives about its own payload: a record
/// written by a build without one of these fields has to read rather than throw, because the
/// state around it is what stops a morning from happening twice.
extension EarlyStartRun {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = try container.decode(Date.self, forKey: .at)
        started = try container.decodeIfPresent(Int.self, forKey: .started) ?? 0
        skipped = try container.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        failed = try container.decodeIfPresent(Int.self, forKey: .failed) ?? 0
    }
}

/// Persisted bookkeeping (UserDefaults), so a restart, a sleep or an auto-update cannot turn one
/// morning into several.
struct EarlyStartState: Codable, Equatable {
    /// Account id to the day key of the morning it was last started on. Per account rather than
    /// per run: an account that was signed out at 7am and signed back in at 8am should still get
    /// its window opened when the machine next wakes.
    var startedDays: [String: String] = [:]
    /// A day the schedule may not act on, because it was armed after that day's trigger had passed.
    var suppressedDay: String?
    var lastRun: EarlyStartRun?
}

/// Decoded key by key so a payload written by a build without one of these fields still reads.
/// Synthesized `Decodable` throws on a missing key rather than falling back to the property
/// default, and the store reads a decode failure as "no state at all", which would re-send every
/// message already sent today. Declared in an extension so the memberwise init survives.
extension EarlyStartState {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startedDays = try container.decodeIfPresent([String: String].self, forKey: .startedDays) ?? [:]
        suppressedDay = try container.decodeIfPresent(String.self, forKey: .suppressedDay)
        lastRun = try container.decodeIfPresent(EarlyStartRun.self, forKey: .lastRun)
    }
}

/// The trigger, window-reading and dedup rules. Pure.
enum EarlyStartLogic {
    /// The one provider v1 acts on.
    static let providerID = "claude"
    /// 7am local: before a working day starts, late enough that the second window of the day lands
    /// inside it. Editable in Settings.
    static let defaultHour = 7
    static let defaultMinute = 0

    /// THE FIRST-RUN GATE. The feature ships on, so the very first message it would ever send is
    /// one nobody asked for; it waits until the one-time notice has been read (dismissed on the
    /// panel, or answered by opening the Settings row, which says the same thing at more length).
    ///
    /// A function rather than a pair of Bools read at the call site, so "on" and "may act" can
    /// never quietly become the same question again: the switch says what the user wants, this
    /// says whether they have been told.
    static func isArmed(enabled: Bool, noticeAcknowledged: Bool) -> Bool {
        enabled && noticeAcknowledged
    }

    /// The day a moment belongs to, in the user's own calendar. The dedup key: "one message per
    /// account per morning" is a statement about local days, so a machine carried across a time
    /// zone gets the new zone's morning rather than the old one's.
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The trigger instant on the day `date` falls in.
    ///
    /// Nil only when the calendar cannot build that instant at all. A clock hour that a daylight
    /// saving jump removed is not that case: `Calendar` resolves it to the moment the jump lands
    /// on, which is the correct reading of "7am on the day the clocks went forward".
    static func trigger(onDayOf date: Date, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        var parts = calendar.dateComponents([.year, .month, .day], from: date)
        parts.hour = hour
        parts.minute = minute
        parts.second = 0
        return calendar.date(from: parts)
    }

    /// The next trigger strictly after `now`, which is what the timer is set to.
    static func nextTrigger(after now: Date, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        calendar.nextDate(after: now,
                          matching: DateComponents(hour: hour, minute: minute, second: 0),
                          matchingPolicy: .nextTime, direction: .forward)
    }

    /// Whether today's trigger has already gone by, which is the question a wake (or a launch)
    /// asks: a machine asleep at 7am has no timer fire to catch, so the moment it comes back it
    /// checks the clock instead. What stops that from re-sending is the per-account day key, not
    /// this.
    static func triggerHasPassed(now: Date, hour: Int, minute: Int, calendar: Calendar) -> Bool {
        guard let today = trigger(onDayOf: now, hour: hour, minute: minute, calendar: calendar) else {
            return false
        }
        return now >= today
    }

    /// Whether an account's 5-hour window is already counting down, read from the usage the app
    /// already polls. Nothing here calls an API: the panel's own numbers are the answer.
    ///
    /// Open means BOTH halves: a reset in the future and something spent against it. Claude reports
    /// a session line for a window that has not started as 0% with no reset to name, and a window
    /// whose reset has passed is a window that closed. Requiring both is what keeps a stale reading
    /// (a reset time still on file from a window that has since expired) from reading as open.
    ///
    /// The honest edge: a window opened moments ago by somebody else, with too little spent to
    /// round above 0%, reads as closed here and costs one extra short message. The alternative,
    /// trusting a reset stamp alone, costs a morning where nothing is opened at all.
    static func windowIsOpen(_ usage: AccountUsage, now: Date) -> Bool {
        guard let session = usage.metrics.first(where: { $0.kind == .session }),
              let resetsAt = session.resetsAt else { return false }
        return resetsAt > now && session.usedPercent > 0
    }

    /// Whether this account's latest reading may be used to decide anything this morning.
    ///
    /// BOTH HALVES, because a failed round does not announce itself as an error straight away. The
    /// fold that runs after every poll keeps the last good numbers on a failure and leaves `error`
    /// nil until a streak of them makes the account stale, publishing the failure on the first
    /// round through `lastRefreshFailed` instead (`foldLastGood`, Core/LastGoodFold.swift, which
    /// spells out why the badge and the machine need opposite answers). Reading `error` alone would
    /// hand this morning a set of numbers from an earlier poll wearing the face of a fresh one: a
    /// window that has since closed still reads as open, and a window that has since opened still
    /// reads as closed, and the second of those spends a message on somebody already working.
    ///
    /// This is the same question `AccountPick` asks before believing a zero, for the same reason.
    static func readingIsUsable(_ usage: AccountUsage) -> Bool {
        usage.error == nil && !usage.lastRefreshFailed
    }

    /// Why this account is not being started, or nil to start it.
    static func pass(_ candidate: EarlyStartCandidate, state: EarlyStartState,
                     now: Date, calendar: Calendar) -> EarlyStartSkip? {
        let today = dayKey(now, calendar: calendar)
        if candidate.providerID != providerID { return .otherProvider }
        if !candidate.isEnabled { return .accountOff }
        // Ordered before the readable check on purpose: a signed-out account also reports an
        // unusable reading, and "there is no credential here" is the more useful of the two.
        if candidate.home == nil { return .notLaunchable }
        if state.suppressedDay == today { return .daySuppressed }
        if state.startedDays[candidate.accountID] == today { return .alreadyStarted }
        if !candidate.readingIsUsable { return .unreadable }
        if candidate.windowIsOpen { return .windowOpen }
        return nil
    }

    /// One morning's whole decision.
    static func plan(candidates: [EarlyStartCandidate], state: EarlyStartState,
                     now: Date, calendar: Calendar) -> EarlyStartPlan {
        var plan = EarlyStartPlan()
        for candidate in candidates {
            if let reason = pass(candidate, state: state, now: now, calendar: calendar) {
                plan.passed.append(EarlyStartPass(accountID: candidate.accountID, reason: reason))
            } else {
                plan.start.append(candidate)
            }
        }
        return plan
    }

    /// Arm the schedule, which is what the switch going on and the first notice being read both do.
    ///
    /// NOTHING IS BACKFILLED INTO THE DAY SOMEBODY CHANGED THEIR MIND ON. Turning the feature on at
    /// 10am is a statement about tomorrow: sending a message the moment the switch moves would be
    /// the surprise the notice exists to prevent, one step later. So a trigger that has already
    /// gone by today marks today as spent, and a switch flipped before 7am leaves today alone -
    /// it is still going to happen.
    ///
    /// Only the arming does this. A launch or a wake past the trigger DOES catch up, because
    /// neither is somebody changing their mind: an app that was closed at 7am and opened at 8am is
    /// the case this feature is most obviously for.
    static func arming(_ state: EarlyStartState, now: Date, hour: Int, minute: Int,
                       calendar: Calendar) -> EarlyStartState {
        guard triggerHasPassed(now: now, hour: hour, minute: minute, calendar: calendar) else {
            return state
        }
        var next = state
        next.suppressedDay = dayKey(now, calendar: calendar)
        return next
    }

    /// Fold a finished run into the state: every account whose morning is OVER is stamped with
    /// today, and the run is recorded only if it was one (`EarlyStartPlan.isReportable`).
    ///
    /// Two kinds of account are over. One is every account a message was attempted for. The other
    /// is every account passed over for a reason that finished its day (`EarlyStartSkip
    /// .completesDay`), which today means the one that was already working: stamping it is what
    /// keeps the promise on the Settings row - one decision per account per morning - when the
    /// window it was running closes at lunchtime and the next refresh would otherwise open a new
    /// one on its behalf.
    ///
    /// STAMPED ON THE ATTEMPT, not on the success, because the promise is "at most one message per
    /// account per morning" and a retry ladder cannot keep it: a lid opened twenty times on a day
    /// when something is wrong would be twenty attempts per account. The cost is a morning lost to
    /// a transient failure; what is bought is that the count in the row is the number of times
    /// Tally spoke on somebody's behalf, whatever the answers were.
    ///
    /// - Parameters:
    ///   - attempted: account ids a spawn was made for, whatever its outcome.
    ///   - failed: how many of those did not go through.
    static func recording(_ state: EarlyStartState, plan: EarlyStartPlan, attempted: [String],
                          failed: Int, now: Date, calendar: Calendar) -> EarlyStartState {
        var next = state
        let today = dayKey(now, calendar: calendar)
        for accountID in attempted { next.startedDays[accountID] = today }
        for entry in plan.passed where entry.reason.completesDay {
            next.startedDays[entry.accountID] = today
        }
        if plan.isReportable {
            next.lastRun = EarlyStartRun(at: now, started: max(0, attempted.count - failed),
                                         skipped: plan.skippedCount, failed: failed)
        }
        // Yesterday's stamps answer no question anybody can still ask, and an id is never reused
        // for a different account without being removed first. Pruning here keeps the payload from
        // growing by one entry per account per day for the life of the install.
        next.startedDays = next.startedDays.filter { $0.value == today }
        if next.suppressedDay != today { next.suppressedDay = nil }
        return next
    }
}
