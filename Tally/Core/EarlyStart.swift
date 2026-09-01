import Foundation

/// Early start: keeping each Claude account's 5-hour window turning over, so a reset lands as early
/// in the day as it can rather than whenever the first prompt happens to be typed.
///
/// Claude's 5-hour window begins at the FIRST message of a stretch, not at a fixed hour, so a day
/// that begins at 10am carries its reset until 3pm and the one after that until 8pm. One short
/// message sent the moment a window closes moves the whole ladder earlier and keeps it there. That
/// is the entire feature: it starts a window the user was going to start anyway, sooner.
///
/// IT USED TO BE A MORNING ALARM (one message per account per day, at 07:00) and became a relay on
/// 2026-08-25. The reasoning is arithmetic: the message costs a haiku turn, and the window it opens
/// always resets earlier than the one the user would have opened themselves, so there is no hour of
/// the day where waiting is the better answer. What replaces the clock is `EarlyStartQuietHours`,
/// which is off by default and exists for the preference the arithmetic cannot speak to.
///
/// BEING SWITCHED ON IS ALREADY BEING TOLD, so nothing waits after it. The schedule goes live only
/// once the one-time notice has been answered, and both ways of answering it are the user reading
/// what this does: pressing the button on the panel, or opening the Settings row that says the same
/// thing at more length (`EarlyStartLogic.isArmed`). There is therefore no moment at which the
/// feature is armed and the user has not heard of it, and no surprise left for a waiting period to
/// prevent. It used to hold every account's closed stretch for up to five hours after the switch
/// moved; that was the same waiting the arithmetic above rules out, wearing politeness. An account
/// whose window is closed when the schedule goes live is started by the very next evaluation.
///
/// WHAT BOUNDS THE COST IS `EarlyStartLogic.retryInterval`, ALONE. One attempt per account per five
/// hours, whatever else is true, and it is the only suppression in this file.
///
/// Everything in this file is a pure function of values, Foundation only (no AppKit, no timers, no
/// Process), so `tests/earlystart` compiles it standalone. The persisted shapes live in
/// `EarlyStartState.swift`, the silence window in `EarlyStartQuietHours.swift`; the scheduling and
/// the spawn live in `Tally/Stores/EarlyStartStore.swift`, and what a spawn IS in
/// `EarlyStartCommand.swift`.

/// One account as an evaluation sees it: everything the decision needs, and nothing it does not.
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
    /// Whether those failures have been SUSTAINED rather than a single missed round
    /// (`EarlyStartLogic.readingKeepsFailing`). It decides only what the day's row reports, never
    /// whether a message goes out: an unusable reading blocks the send either way.
    var readingKeepsFailing: Bool
    /// Whether the 5-hour window is already counting down (`EarlyStartLogic.windowIsOpen`).
    var windowIsOpen: Bool
}

/// Why one account was passed over. A value rather than a bare Bool because two different questions
/// are asked of it afterwards, and they disagree about most of these cases.
enum EarlyStartSkip: String, Equatable {
    /// Not a Claude account. v1 acts on Claude alone: Codex's own limits do not work this way.
    case otherProvider
    /// The user switched this account, or its whole provider, off.
    case accountOff
    /// Signed out, or otherwise with no home to launch with.
    case notLaunchable
    /// The latest poll failed, so whether the window is open is not known right now, and this is the
    /// first miss or two. One-minute polling produces these routinely: the brief window while a CLI
    /// rotates an OAuth token is exactly the kind it catches (`foldLastGood`).
    case pollMissed
    /// …and the polls have gone on failing over the whole debounce window
    /// (`AccountUsage.pollsKeepFailing`), which is the version of that news worth showing somebody.
    case unreadable
    /// The window is already counting down. The commonest pass by far, and the one the feature is
    /// for: somebody who is working gets nothing sent on their behalf.
    case windowOpen
    /// This account has had its message inside the last `EarlyStartLogic.retryInterval`.
    case alreadyStarted
    /// The user asked for silence at this hour.
    case quietHours

    /// Whether this pass belongs in the "N skipped" the Settings row reports.
    ///
    /// ONLY THE TWO THAT MEAN SOMETHING IS WRONG. This narrowed when the feature became a relay:
    /// under the old one-decision-per-morning schedule, "the window was already open at 07:00" was
    /// news, and it was reported. Under a relay it is the steady state - every account this feature
    /// successfully starts reads that way for the next five hours - so counting it would put the
    /// whole fleet in the skipped column on a day when everything worked.
    ///
    /// What is left is the pair a user would want to see a number for and could not learn any other
    /// way: an account with no credential to launch with, and one whose polls keep failing. Both
    /// mean the switch reads "on" while that account gets nothing.
    ///
    /// KEEP FAILING, NOT FAILED ONCE, which is why the unreadable reason is two cases. The day's
    /// list is a set that only clears at midnight, so one missed poll would pin an account there
    /// until then and leave the row saying something is wrong hours after it stopped being. That is
    /// `pollMissed`, and it reports nothing.
    var countsAsSkip: Bool {
        switch self {
        case .otherProvider, .accountOff, .pollMissed, .windowOpen, .alreadyStarted,
             .quietHours: return false
        case .notLaunchable, .unreadable: return true
        }
    }
}

/// One account passed over, with the reason.
struct EarlyStartPass: Equatable {
    var accountID: String
    var reason: EarlyStartSkip
}

/// What one evaluation decided.
struct EarlyStartPlan: Equatable {
    var start: [EarlyStartCandidate] = []
    var passed: [EarlyStartPass] = []

    /// Whether this evaluation belongs in the day's tally, and the same question as whether it has
    /// anything to write down at all. An evaluation that started nothing and blocked on nothing is
    /// the ordinary quiet case, hundreds of times a day, and must not touch the record (see
    /// `EarlyStartSkip.countsAsSkip`).
    ///
    /// IT WAS TWO QUESTIONS while the relay carried an observation forward: an evaluation whose only
    /// content was "these three accounts are working now" reported nothing and still had to be
    /// written, because that fact ended their suppression. Nothing is inferred from a pass any more
    /// - the only suppression left is the attempt's own floor, which ages out on the clock - so the
    /// two questions have one answer and are one property.
    var isReportable: Bool { !start.isEmpty || passed.contains { $0.reason.countsAsSkip } }

    var skippedCount: Int { passed.filter { $0.reason.countsAsSkip }.count }
}

/// The window-reading, silence and dedup rules. Pure.
enum EarlyStartLogic {
    /// The one provider v1 acts on.
    static let providerID = "claude"

    /// How long an attempt suppresses its account when nothing else has happened.
    ///
    /// EXACTLY THE LENGTH OF THE WINDOW THE MESSAGE WOULD HAVE OPENED, which is what makes it the
    /// right number rather than a tuning knob. If the attempt worked, the window it opened has
    /// itself expired by now and the account is owed another message anyway; if it did not work,
    /// five hours is the longest a retry can be withheld without the feature falling behind the
    /// schedule it replaced. It is also the guarantee anybody worried about cost is owed: whatever
    /// goes wrong, and however often the app refreshes, one account cannot be sent more than one
    /// message per five hours.
    ///
    /// NOTHING OVERRIDES IT, which is what makes it a guarantee rather than a default, and it is a
    /// FLOOR ON COST rather than a guess about windows: no observation lifts it, whoever opened the
    /// window that was observed.
    ///
    /// The window one of these messages opens is AT MOST this long, not exactly. Anthropic resets a
    /// session on a ten-minute grid point, so the window a 09:03 message opens closes at 14:00
    /// rather than 14:03 (592 distinct session resets in `~/.tally/history.jsonl`, every one of them
    /// on a ten-minute mark or the minute before it). The relay therefore hands over up to ten
    /// minutes after its own window shut, which is the price of the promise and is not worth an
    /// exception: an exception is the bug this floor was rewritten to close.
    ///
    /// IT IS ALSO THE ONLY SUPPRESSION LEFT. Everything else that used to hold an account back was
    /// about the moment somebody moved a switch (see the top of this file), and none of it bounded a
    /// cost, so this one carries the promise by itself.
    static let retryInterval: TimeInterval = 5 * 60 * 60

    /// Which telling of this feature the one-time notice has to have delivered. Bumped when the
    /// behaviour it describes changes, which is what re-shows it to somebody who already answered
    /// the previous one.
    ///
    /// 1 was "each morning at 07:00". 2 is the relay, which sends at hours the first notice
    /// promised it would not, so consent given to 1 is not consent to 2.
    static let noticeVersion = 2

    /// Whether the notice the user has answered is the current one.
    static func noticeIsCurrent(seen: Int) -> Bool { seen >= noticeVersion }

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

    /// The day a moment belongs to, in the user's own calendar. The key the Settings row's tally is
    /// kept under, so a machine carried across a time zone gets the new zone's day.
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
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
    /// trusting a reset stamp alone, costs an episode where nothing is opened at all.
    static func windowIsOpen(_ usage: AccountUsage, now: Date) -> Bool {
        guard let session = usage.metrics.first(where: { $0.kind == .session }),
              let resetsAt = session.resetsAt else { return false }
        return resetsAt > now && session.usedPercent > 0
    }

    /// Whether this account's latest reading may be used to decide anything.
    ///
    /// BOTH HALVES, because a failed round does not announce itself as an error straight away. The
    /// fold that runs after every poll keeps the last good numbers on a failure and leaves `error`
    /// nil until a streak of them makes the account stale, publishing the failure on the first
    /// round through `lastRefreshFailed` instead (`foldLastGood`, Core/LastGoodFold.swift, which
    /// spells out why the badge and the machine need opposite answers). Reading `error` alone would
    /// hand this evaluation a set of numbers from an earlier poll wearing the face of a fresh one: a
    /// window that has since closed still reads as open, and a window that has since opened still
    /// reads as closed, and the second of those spends a message on somebody already working.
    ///
    /// This is the same question `AccountPick` asks before believing a zero, for the same reason.
    static func readingIsUsable(_ usage: AccountUsage) -> Bool {
        usage.error == nil && !usage.lastRefreshFailed
    }

    /// Whether this account's polls have been failing long enough to be worth a line on the day's
    /// row, rather than having missed a single round.
    ///
    /// THE DEBOUNCED HALF OF THE FOLD `readingIsUsable` READS THE UNDEBOUNCED HALF OF, and the two
    /// readers need opposite answers for the reason `foldLastGood` spells out. The decision needs
    /// the first failure, because a held-over reading cannot answer the window question. A person
    /// reading "N skipped" needs the second, because that list is a set that stands until midnight:
    /// on the first failure it would name every account that ever lost a poll to a token rotation
    /// and go on naming it all day.
    ///
    /// NOT `isStale`, WHICH IS THE BADGE: it is never raised for an account that has never loaded
    /// (`foldLastGood` says why it must not be), and that account - signed in, failing every poll
    /// since launch - is precisely the one this row exists to name. Asking the badge made it the
    /// one account the row could never report (codex review of 60a4fe7).
    static func readingKeepsFailing(_ usage: AccountUsage) -> Bool { usage.pollsKeepFailing }

    /// Why this account is not being started, or nil to start it.
    ///
    /// ONE ORDERING IS LOAD-BEARING: `notLaunchable` comes before the reading check, because a
    /// signed-out account also reports an unusable reading and "there is no credential here" is the
    /// more useful of the two answers. The rest of the order decides only which reason a passed-over
    /// account is reported with, since none of these questions changes another's answer.
    static func pass(_ candidate: EarlyStartCandidate, state: EarlyStartState,
                     quietHours: EarlyStartQuietHours, now: Date, calendar: Calendar)
        -> EarlyStartSkip? {
        if candidate.providerID != providerID { return .otherProvider }
        if !candidate.isEnabled { return .accountOff }
        if candidate.home == nil { return .notLaunchable }
        if !candidate.readingIsUsable {
            return candidate.readingKeepsFailing ? .unreadable : .pollMissed
        }
        if candidate.windowIsOpen { return .windowOpen }
        if quietHours.contains(now, calendar: calendar) { return .quietHours }

        // THE ATTEMPT'S FLOOR, AND NOTHING GETS PAST IT: an account that has had a message owes the
        // five hours whatever is observed during them, which is the promise three places in this app
        // make in those words. The rule is deliberately blind to WHOSE window closed, because that
        // question cannot be answered from here and the promise does not depend on it: our own
        // window closes inside the interval routinely (resets land on a ten-minute grid, so it shuts
        // up to ten minutes early), and somebody else's does too whenever the reading that sent the
        // message read a live window as closed (`windowIsOpen` names the 0%-rounding edge).
        // Releasing on either would be a second message inside the interval.
        //
        // AND NO MARK MEANS GO. An account this schedule has not written down inside the interval is
        // one nothing has been spent on, so there is nothing to bound and nothing to wait for: the
        // window in front of it is closed and can be moved earlier now.
        if let attemptedAt = state.marks[candidate.accountID]?.attemptedAt {
            return now.timeIntervalSince(attemptedAt) >= retryInterval ? nil : .alreadyStarted
        }
        return nil
    }

    /// One evaluation's whole decision.
    static func plan(candidates: [EarlyStartCandidate], state: EarlyStartState,
                     quietHours: EarlyStartQuietHours, now: Date,
                     calendar: Calendar) -> EarlyStartPlan {
        var plan = EarlyStartPlan()
        for candidate in candidates {
            if let reason = pass(candidate, state: state, quietHours: quietHours, now: now,
                                 calendar: calendar) {
                plan.passed.append(EarlyStartPass(accountID: candidate.accountID, reason: reason))
            } else {
                plan.start.append(candidate)
            }
        }
        return plan
    }

    /// Fold a finished evaluation into the state: what was attempted, and what today's row should
    /// say.
    ///
    /// STAMPED ON THE ATTEMPT, not on the success, because the promise is "at most one message per
    /// account per five hours" and a retry ladder cannot keep it: a refresh loop running every few
    /// minutes on a day when something is wrong would be dozens of attempts per account. The cost is
    /// an episode lost to a transient failure; what is bought is that the count on the row is the
    /// number of times Tally spoke on somebody's behalf, whatever the answers were.
    ///
    /// - Parameters:
    ///   - attempted: account ids a spawn was made for, whatever its outcome.
    ///   - failed: WHICH of those did not go through, not how many. The day's row reports accounts
    ///     rather than events (`EarlyStartToday.couldNotStartTotal`), and it cannot fold a count
    ///     into that answer without risking counting one account twice.
    ///   - couldNotStart: account ids no spawn could be made for at all, because there is no CLI on
    ///     the machine. NAMED RATHER THAN COUNTED, like `skipped` and for a sharper version of the
    ///     same reason: no attempt is made, so nothing is marked, so the very same accounts are
    ///     chosen again at the next refresh and every one after it. A counter would describe the
    ///     refresh loop (a thousand a day at the shipping interval) rather than the fleet. Being
    ///     named is also what lets an account LEAVE the list, which `correcting` does.
    ///
    /// NOTHING IS TAKEN OFF EITHER LIST HERE, and that is the point of the split. This fold runs
    /// BEFORE the spawn, so what it knows is that a message is about to be tried, not that one
    /// arrived; an app replaced mid-run (an auto-update relaunch is the ordinary way it happens)
    /// leaves whatever this wrote as the day's last word. Clearing the lists here made that word
    /// "both accounts have their message" for a batch that may have sent nothing at all. The lists
    /// are cleared where the answers are (`correcting`), so the crash window degrades towards the
    /// safe reading - an account stays on the row until something says it was served.
    static func recording(_ state: EarlyStartState, plan: EarlyStartPlan, attempted: [String],
                          failed: [String], couldNotStart: [String] = [], now: Date,
                          calendar: Calendar) -> EarlyStartState {
        var next = state
        for accountID in attempted {
            next.marks[accountID] = EarlyStartMark(attemptedAt: now)
        }

        if plan.isReportable {
            let today = dayKey(now, calendar: calendar)
            // Yesterday's tally is replaced rather than added to: the row says "today".
            var report = EarlyStartToday(day: today)
            if let running = next.today, running.day == today { report = running }
            report.started += max(0, attempted.count - failed.count)
            report.failed += failed.count
            var skipped = Set(report.skipped)
            for entry in plan.passed where entry.reason.countsAsSkip {
                skipped.insert(entry.accountID)
            }
            report.skipped = skipped.sorted()
            report.attemptFailed = Set(report.attemptFailed).union(failed).sorted()
            report.couldNotStart = Set(report.couldNotStart).union(couldNotStart).sorted()
            if !attempted.isEmpty { report.lastAttemptAt = now }
            next.today = report
        }

        // A mark that can no longer change an answer is dropped, so the payload does not grow by one
        // entry per account per day for the life of the install. A mark whose floor has aged past
        // the retry interval suppresses nothing, and one with no floor at all (which only a payload
        // from an older build can hold) never did.
        next.marks = next.marks.filter { _, mark in
            guard let floor = mark.attemptedAt else { return false }
            return now.timeIntervalSince(floor) < retryInterval
        }
        return next
    }

    /// Carry the spawns' answers into today's tally: move `failed` messages out of the "started"
    /// column, and take the ones that DID go through off the row's two account lists.
    ///
    /// CALLED WHETHER OR NOT ANYTHING FAILED, which is what makes the second half possible. An
    /// all-successful batch has nothing to move between columns and is still the only proof this
    /// feature ever gets that an account was served; skipping the call on success left accounts on
    /// "could not start" with no way off it before midnight.
    ///
    /// A SEPARATE RULE FROM `recording` BECAUSE THE TALLY ACCUMULATES. The attempt is written
    /// optimistically before the spawn (the store says why: an auto-update relaunch inside the two
    /// minutes a CLI gets would otherwise resend everything), and the answers land minutes later.
    /// Replaying `recording` with the same account ids to carry the failures - which is what the
    /// morning schedule did, harmlessly, because it overwrote a single last-run record - would add
    /// the whole batch to the day's total a second time.
    ///
    /// The marks are deliberately untouched: an attempt suppresses its account for `retryInterval`
    /// whatever the CLI answered, which is the promise this feature makes about cost.
    ///
    /// A batch that started before midnight and answered after it is left alone rather than
    /// corrected into the new day's column, where it would describe messages that day never sent.
    ///
    /// WHAT THE CRASH WINDOW LEAVES BEHIND, stated with its limits rather than papered over. An app
    /// that dies between the write before the spawn and these answers leaves the day's tally in two
    /// halves that answer differently, and only one of them is this rule's to claim:
    ///
    /// The TWO ACCOUNT LISTS are conservative, and that is what moving the clearing here bought.
    /// An account already named on one of them stays named until something confirms it was served,
    /// so the leftover reads "1 started, 1 could not start" on a one-account machine rather than
    /// announcing a success nobody saw happen.
    ///
    /// `started` IS NOT, and never was. It is added optimistically before the spawn, for the reason
    /// EarlyStartStore states where it does it (WRITTEN BEFORE THE SPAWN: an app replaced inside the
    /// two minutes a CLI gets would otherwise send the whole batch again), which is the price of the
    /// at-most-one-message promise. So the ordinary crash - a machine with a CLI, first attempt of
    /// the day, nothing on either list yet - leaves "1 started, 0 could not start" for a message
    /// that may never have gone. That is the inherited trade, not a claim this fold makes; the lists
    /// are what changed here, and the counter beside them still describes attempts.
    ///
    /// - Parameters:
    ///   - attempted: every account id the batch spawned for, failures included. What is NOT in
    ///     `failed` was served, and is taken off both lists.
    ///   - failed: the ids that did not go through.
    static func correcting(_ state: EarlyStartState, attempted: [String], failed: [String],
                           now: Date, calendar: Calendar) -> EarlyStartState {
        guard !attempted.isEmpty || !failed.isEmpty, var report = state.today,
              report.day == dayKey(now, calendar: calendar) else { return state }
        var next = state
        report.started = max(0, report.started - failed.count)
        report.failed += failed.count
        // NAMED as well as counted, and the names are what the row reads. The count still moves,
        // because it is the partner of `started` and the pair describes messages; the row describes
        // ACCOUNTS, and only a set can be merged with the other one without counting an account
        // that was blocked this morning and failed this afternoon twice.
        //
        // The served ids come off both lists in the same breath: an account blocked all morning for
        // want of a CLI and sent to at noon has its message, and a list that only ever grew said
        // "2 could not start" on a machine holding two accounts that were both working.
        let served = Set(attempted).subtracting(failed)
        report.attemptFailed = Set(report.attemptFailed).union(failed)
            .subtracting(served).sorted()
        report.couldNotStart = Set(report.couldNotStart).subtracting(served).sorted()
        next.today = report
        return next
    }
}
