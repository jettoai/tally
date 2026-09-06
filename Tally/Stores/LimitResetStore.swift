import Foundation
import Observation

/// The app's half of Claude's once-a-week session-limit reset: what each account's record says, and
/// the one place the panel's button spends one.
///
/// A READER AND A SENDER, never a decider. The record is written by whichever SUPERVISOR saw Claude
/// Code print a sentence about the reset (TallyCLI/CapLimitReset.swift), because a transcript is
/// the only place that answer exists; this store reads those files, and when the user presses the
/// button it asks a supervised session to type the command. It never types anything itself and
/// never talks to Anthropic - there is no API for this, and NORTH_STAR rules out inventing one.
///
/// SO THE OUTCOME ARRIVES BY THE SAME ROUTE AS EVERY OTHER OBSERVATION. The button does not read
/// the CLI's stdout for the answer: `tally session send` reports that the LINE was queued or typed,
/// which says nothing about what the command then did. What settles it is the account's record
/// changing, written by the supervisor watching that conversation, and this store waits for exactly
/// that. One reading of "what happened", whoever asked for it.
@MainActor
@Observable
final class LimitResetStore {
    static let shared = LimitResetStore()

    /// What each account's record says, refreshed on the usage cycle rather than read per redraw:
    /// a card asks this several times per frame, and these are files on disk.
    private(set) var records: [String: LimitResetRecord] = [:]
    /// Accounts with a request in flight, which is what greys the button and spins it.
    private(set) var pending: Set<String> = []
    /// What the last press came to, per account, for the few seconds a card shows it.
    private(set) var lastOutcome: [String: LimitResetSpend] = [:]
    /// The one preference, shared with the supervisor through `~/.tally/limit-reset/settings.json`.
    private(set) var settings: LimitResetSettings

    private init() {
        settings = readLimitResetSettings()
        refresh()
    }

    /// What one press came to, in the app's own vocabulary rather than the vendor's.
    ///
    /// `noSession` and `noAnswer` are this store's own, and neither is a failure of the command:
    /// the first is a press on an account with nothing running to type into (the button is
    /// normally disabled for it, and this is the race where the last session ended between the
    /// draw and the click), and the second is a line that WAS typed while nothing came back inside
    /// the wait. Reported as itself rather than as a failure, because a slow answer still lands in
    /// the record a moment later and the card will show it.
    enum LimitResetSpend: Equatable {
        case reset
        case alreadyUsed
        case notAvailable
        case notEnabled
        case noSession
        case noAnswer
        case failed(String)
    }

    // MARK: Reading

    /// Re-read every account's record. Called at launch, on the usage refresh and after a press.
    ///
    /// BY ACCOUNT ID RATHER THAN BY LISTING THE DIRECTORY, because the filename is a
    /// filesystem-safe derivative of an id (`limitResetFile`) and cannot be turned back into one.
    /// A fleet is a handful of accounts, so this is a handful of small reads on the refresh cycle.
    func refresh() {
        settings = readLimitResetSettings()
        guard !DemoUsage.isActive else { return }
        var found: [String: LimitResetRecord] = [:]
        for account in UsageStore.shared.accounts {
            if let record = readLimitReset(accountID: account.id) { found[account.id] = record }
        }
        records = found
    }

    /// What this account's reset state MEANS right now (`limitResetEffective` owns the ageing
    /// rules). Demo fixtures answer from the fixture table, so a marketing capture shows both
    /// states without a file on this machine.
    func state(accountID: String, now: Date = Date()) -> LimitResetState {
        if DemoUsage.isActive { return DemoUsage.limitReset(accountID: accountID)?.state ?? .unknown }
        return limitResetEffective(records[accountID], now: now)
    }

    /// When this account's reset comes back, where a sentence named a date.
    func nextAvailableAt(accountID: String) -> Date? {
        if DemoUsage.isActive { return DemoUsage.limitReset(accountID: accountID)?.nextAvailableAt }
        return records[accountID]?.nextAvailableAt
    }

    /// The supervised session this account's reset would be typed into, or nil when there is none.
    ///
    /// THE BUTTON'S ENABLED STATE IS THIS QUESTION, which is why it is here rather than inside the
    /// press: a `/limit-reset` is interactive-only, so an account with no session running has
    /// nowhere for the command to go, and a button that opened a confirmation and then reported
    /// "nothing to send to" would be asking a question it already knew the answer to.
    func target(accountID: String) -> LimitResetTarget? {
        limitResetTarget(SessionRosterStore.shared.rows.compactMap { row in
            guard let id = row.accountID else { return nil }
            return LimitResetTarget(sessionKey: row.id, accountID: id,
                                    isReporting: row.isReporting,
                                    waitingOnPerson: Self.waitingOnPerson(row),
                                    updatedAt: row.record?.updatedAt)
        }, accountID: accountID)
    }

    /// Whether this row is sitting on a question only a person can answer, from the two halves its
    /// supervisor publishes.
    ///
    /// NEVER `state == .blocked` ON ITS OWN, which is the distinction memory
    /// `tally-blocked-vs-dialog` records and the reason this is spelled out rather than read off
    /// the state word: a soft `idle_prompt` is folded into `blocked` too, and a session that is
    /// merely idle is exactly the one this feature wants to type into. The hard reading is the
    /// notice TYPE (`userWait`, shared with the supervisor so there is one vocabulary).
    ///
    /// FAIL-OPEN TO "YES" for a blocked session that published no type, on the same rule
    /// `notificationWaitsForUser` keeps: the cost of excluding a session that could have been typed
    /// into is that a sibling gets the line, and the cost of the opposite is a slash command
    /// answering somebody's permission dialog.
    private static func waitingOnPerson(_ row: SessionRosterStore.SessionRow) -> Bool {
        guard let record = row.record else { return false }
        if let type = record.noticeType { return userWait(notificationType: type) == .hard }
        return record.supervised == .blocked
    }

    // MARK: The preference

    func setAutoReset(_ on: Bool) {
        guard on != settings.autoReset else { return }
        // A screenshot run may show this row; it may not write into the document the real app and
        // every supervisor on this machine read (the rule `EarlyStartStore.acknowledgeNotice`
        // keeps for its own defaults).
        guard !DemoUsage.isActive else { return }
        var next = settings
        next.autoReset = on
        writeLimitResetSettings(next)
        settings = next
    }

    // MARK: Spending

    /// Ask a supervised session on this account to type `/limit-reset`, then wait for the record to
    /// say what it did.
    ///
    /// THE CONFIRMATION IS NOT HERE. It belongs to `RedeemAction`, which is the one place any write
    /// Tally performs is confirmed, so the notification and the card cannot come to word the cost
    /// differently (RedeemAction.swift states that rule for the Codex credit and now for this).
    func spend(accountID: String) async -> LimitResetSpend {
        guard !DemoUsage.isActive else { return .noAnswer }
        guard let target = target(accountID: accountID) else {
            record(.noSession, for: accountID)
            return .noSession
        }
        pending.insert(accountID)
        defer { pending.remove(accountID) }
        let before = records[accountID]?.observedAt ?? .distantPast
        guard let cli = Self.cliPath() else {
            let outcome = LimitResetSpend.failed(L("This build does not bundle the CLI"))
            record(outcome, for: accountID)
            return outcome
        }
        let sent = await CLIRunner.run(cli,
                                       arguments: ["session", "send", limitResetCommand,
                                                   "--session", target.sessionKey],
                                       timeout: limitResetSendTimeout)
        guard let sent, sent.exitCode == 0 else {
            // The CLI's own sentence is the useful half here: it names WHY nothing was queued (a
            // session that has gone, one this machine does not supervise, one already holding a
            // send). It reaches a tooltip rather than a row, on the rule `AccountUsage.errorDetail`
            // states: a vendor's or a tool's own wording must not set a card's width.
            let detail = (sent?.stderr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let outcome = LimitResetSpend.failed(detail.isEmpty ? L("Could not reach that session")
                                                               : detail)
            record(outcome, for: accountID)
            return outcome
        }
        let outcome = await waitForAnswer(accountID: accountID, newerThan: before)
        record(outcome, for: accountID)
        return outcome
    }

    /// The `tally` this press speaks through: the CLI inside this bundle, then the one on the PATH.
    ///
    /// BUNDLED FIRST, which is the rule the hook registrations already keep (`bundledCLIURL`): a
    /// release build carries its own and must use it whether or not `/usr/local/bin/tally` was ever
    /// installed. THE FALLBACK IS FOR A DEV BUILD, and it is not a dev build "owning a shared
    /// surface" - what this writes is a request the user just asked for, addressed to one session,
    /// through a channel that already handles two builds disagreeing about its shape
    /// (`liveRequestHonourability` refuses a supervisor too old to read it). Without it, the one
    /// build Albert can be handed for a look at this feature is the one build whose button cannot
    /// be pressed.
    private static func cliPath() -> String? {
        let bundled = IntegrationsStore.bundledCLIURL.path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return CLIRunner.resolve("tally")
    }

    /// Poll this account's record until it moves, or until the wait runs out.
    ///
    /// POLLING RATHER THAN WATCHING, and the interval is what makes that cheap: the file is written
    /// by another process on a 2s poll of its own, so anything faster than that is asking a
    /// question whose answer cannot have changed. The whole wait is a handful of reads of one small
    /// file.
    private func waitForAnswer(accountID: String, newerThan: Date) async -> LimitResetSpend {
        let deadline = Date().addingTimeInterval(limitResetAnswerWait)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(limitResetPollInterval))
            guard let record = readLimitReset(accountID: accountID),
                  record.observedAt > newerThan else { continue }
            records[accountID] = record
            // WHICH SENTENCE THE SUPERVISOR SAW, not which state it folded to. The success line and
            // the "already used" one BOTH fold to `used` and BOTH carry a date ("Session limit
            // reset · next reset available {date}" and "Weekly reset used · available again
            // {date}"), so the state and the date cannot tell a press that worked from one that
            // found the week's credit already gone - this reported the second as a green "Session
            // limit reset" until the record started remembering the sentence itself.
            switch record.lastSignal {
            case LimitResetSignalName.reset: return .reset
            case LimitResetSignalName.alreadyUsed: return .alreadyUsed
            case LimitResetSignalName.notEnabled: return .notEnabled
            case LimitResetSignalName.unavailable, LimitResetSignalName.loginRequired:
                return .notAvailable
            case LimitResetSignalName.noticeAvailable:
                // The wall notice, folded by the watcher while this press was in flight. It says
                // the account HAS a reset to spend, which is not an answer to the command that was
                // just sent, so the wait goes on rather than reporting a refusal that nobody made.
                continue
            default:
                // A record written by a supervisor too old to name the sentence. The date rule is
                // all such a record has: wrong for the "already used" line, and the only reading
                // available for it.
                return legacySpend(record)
            }
        }
        return .noAnswer
    }

    /// The reading for a record whose writer did not name the sentence (`lastSignal` nil): a build
    /// old enough to predate the field, running as this account's supervisor while a newer app
    /// presses the button. Deliberately the OLD rule, ambiguity and all, because it is the only
    /// information such a record carries.
    private func legacySpend(_ record: LimitResetRecord) -> LimitResetSpend {
        switch record.state {
        case .used: return record.nextAvailableAt != nil ? .reset : .alreadyUsed
        case .notEnabled: return .notEnabled
        case .unknown, .available: return .notAvailable
        }
    }

    /// Hold one outcome for the few seconds a card shows it, then take it down.
    private func record(_ outcome: LimitResetSpend, for accountID: String) {
        lastOutcome[accountID] = outcome
        refresh()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(limitResetOutcomeLinger))
            guard let self, self.lastOutcome[accountID] == outcome else { return }
            self.lastOutcome[accountID] = nil
        }
    }
}

/// How long the app waits for `tally session send` to queue or type the line. The CLI has its own
/// grace and returns having queued (SessionSendWait.swift), so this only has to be longer than
/// that, not longer than a turn.
let limitResetSendTimeout: TimeInterval = 30

/// How long the record is given to say what the command did, from the moment the line was queued.
///
/// A LITTLE LONGER THAN THE SUPERVISOR'S OWN WAIT (`capLimitResetAnswerWait`, 20s), because this
/// wait starts EARLIER: the line may still be queued behind a turn when this begins. Running out is
/// not a failure and is not reported as one - the answer lands in the record a moment later either
/// way, and the card shows it on the next refresh.
let limitResetAnswerWait: TimeInterval = 30

/// How often that record is re-read while waiting. The supervisor that writes it polls every 2s, so
/// anything faster asks a question whose answer cannot have changed.
let limitResetPollInterval: TimeInterval = 2

/// How long a card keeps showing what the press came to, matching the banked-reset outcome line
/// beside it (`AccountCardView.startRedeem`).
let limitResetOutcomeLinger: TimeInterval = 8
