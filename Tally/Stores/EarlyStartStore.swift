import AppKit
import Observation

/// The early-start relay: the preferences, the persisted bookkeeping, and the one place a message
/// is actually sent. The rules it runs on are pure and live next door (`Core/EarlyStart.swift`,
/// `Core/EarlyStartState.swift`, `Core/EarlyStartQuietHours.swift`); what a spawn is lives in
/// `Core/EarlyStartCommand.swift`.
///
/// THE EVALUATION RIDES THE REFRESH LOOP rather than a timer, the same way the two notifiers do.
/// Deciding whether a window is open means reading this moment's usage, and the refresh is what
/// produces it; a timer that fired and then read whatever numbers happened to be in memory would be
/// deciding on a reading from before the machine went to sleep. So `evaluate` is called at the tail
/// of every refresh, is idempotent (a comparison and a dictionary lookup), and the two nudges below
/// do nothing but ask for a refresh.
///
/// THAT IS ALSO WHY THE TIMER SHRANK when this became a relay. A morning schedule needs a clock; a
/// relay reacts to windows closing, and the refresh that reads them is already running on the user's
/// own interval. The one thing left that happens on the clock alone is the end of quiet hours, so
/// that is the only thing the timer is ever set for.
@MainActor
@Observable
final class EarlyStartStore {
    static let shared = EarlyStartStore()

    private enum Key {
        static let enabled = "ai.jetto.tally.earlyStart.enabled"
        static let quietEnabled = "ai.jetto.tally.earlyStart.quiet.enabled"
        static let quietStartHour = "ai.jetto.tally.earlyStart.quiet.startHour"
        static let quietStartMinute = "ai.jetto.tally.earlyStart.quiet.startMinute"
        static let quietEndHour = "ai.jetto.tally.earlyStart.quiet.endHour"
        static let quietEndMinute = "ai.jetto.tally.earlyStart.quiet.endMinute"
        /// WHICH telling of the feature has been acknowledged, not whether one has. The behaviour
        /// changed after the first notice shipped, so a stored `true` from that version is consent
        /// to a schedule that no longer exists (`EarlyStartLogic.noticeVersion`). A new key rather
        /// than a reinterpreted old one: an integer read out of a Bool-shaped default is 0, which
        /// happens to be the right answer, but only by luck.
        static let noticeVersion = "ai.jetto.tally.earlyStart.noticeVersion"
        static let state = "ai.jetto.tally.earlyStart.state"
    }

    /// Dev-build launch flag pointing the spawn at a stand-in CLI (`ProviderCLI.executable`), so the
    /// whole chain can be exercised without spending a real subscription's window. Dev only and
    /// volatile (the argument domain), and it is ALSO what lets a dev build run at all: without it
    /// an unshipped build never sends anything (`mayRun`).
    private static let devOverrideKey = "TallyEarlyStartCLI"

    /// ON by default. The feature costs one haiku message per window and buys back a reset that
    /// lands earlier in the day, every time; a switch nobody finds is a switch nobody benefits from.
    /// What keeps that from being a surprise is the notice: nothing is sent until it has been read
    /// (`isArmed`).
    private(set) var isEnabled: Bool
    /// The hours the user asked for silence in. Off by default: see `EarlyStartQuietHours`.
    private(set) var quietHours: EarlyStartQuietHours
    /// Whether the CURRENT one-time notice has been shown and acknowledged. The gate in front of
    /// the first message this feature ever sends, and in front of the first one it sends under a
    /// changed promise.
    private(set) var noticeAcknowledged: Bool
    /// What today has done, for the Settings row. Nil until something has.
    private(set) var today: EarlyStartToday?

    private var timer: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?
    /// Whether `start()` has run, which is the app saying the launch-time Keychain repair is done
    /// with (AppDelegate orders the two). Nothing this store does that reaches a credential may
    /// happen before it: the repair rewrites the very keychain items the `claude` CLI reads, and
    /// both a refresh and a spawn go straight at them.
    ///
    /// THE ORDERING IN AppDelegate ONLY COVERS THE LAUNCH PATH, and this flag is the rest of it.
    /// The schedule has three other entrances that all reach `scheduleTimer`, and every one of them
    /// is a thing the user can do in the seconds an ACL dialog holds the repair open: pressing "Got
    /// it" on the notice, moving the Settings switch, changing the quiet hours. `evaluate` carries
    /// it too, because a refresh asked for by anything at all (the panel opening, the menu's
    /// Refresh) ends by asking this store whether to send.
    ///
    /// The preference writes themselves are NOT gated: they persist immediately, and `start()`
    /// schedules from the values it finds, so an early change is honoured rather than lost.
    private var started = false
    /// True while spawns are in flight. A run can outlast several refreshes (the CLI gets two
    /// minutes), and every one of those refreshes would otherwise evaluate a state that has not been
    /// written yet and send the same message again.
    private var isRunning = false

    private init() {
        let defaults = UserDefaults.standard
        // `nil` here is "never chosen", not "chose off": the key is written only by the Settings
        // switch, and property observers do not run during init.
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        noticeAcknowledged = EarlyStartLogic.noticeIsCurrent(
            seen: defaults.integer(forKey: Key.noticeVersion))
        let suggested = EarlyStartQuietHours.suggested
        quietHours = EarlyStartQuietHours(
            isEnabled: defaults.bool(forKey: Key.quietEnabled),
            startHour: defaults.object(forKey: Key.quietStartHour) as? Int ?? suggested.startHour,
            startMinute: defaults.object(forKey: Key.quietStartMinute) as? Int
                ?? suggested.startMinute,
            endHour: defaults.object(forKey: Key.quietEndHour) as? Int ?? suggested.endHour,
            endMinute: defaults.object(forKey: Key.quietEndMinute) as? Int ?? suggested.endMinute)
        today = Self.loadState().today
    }

    // MARK: Lifetime

    /// Install the punctuality nudges. Called once at launch, behind the Keychain repair.
    ///
    /// Opening the gate is the FIRST thing it does, because everything below it is gated on it.
    /// Scheduling here rather than arming: `EarlyStartLogic.arming` suppresses the episode in
    /// progress, which is right for somebody changing their mind and wrong for a launch. An app
    /// opened after a window closed is the case this feature is most obviously for, so the catch-up
    /// has to survive the gate, and it does because a preference changed before this point has
    /// already written its own arming through `rearm`.
    func start() {
        started = true
        scheduleTimer()
        guard wakeObserver == nil else { return }
        // A machine asleep while a window closed has no fire to catch, and the refresh loop it wakes
        // into is on a several-minute interval. Asking on the way out of sleep is the quick path to
        // the same decision.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in EarlyStartStore.shared.nudge() }
        }
    }

    // MARK: Preferences

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Key.enabled)
        rearm()
    }

    /// Change the silence window.
    ///
    /// IT DOES NOT RE-ARM, and that is the difference between this control and the switch above.
    /// Arming costs the user the episode in progress, which is the right price for "I have just
    /// decided to let this run" and the wrong one for "I am adjusting when it stays quiet": paying
    /// it here would mean every nudge of a picker silently withheld a window. The one visible
    /// consequence is that turning quiet hours OFF part way through the night lets the next refresh
    /// act, which is what the person who just turned it off asked for.
    func setQuietHours(_ hours: EarlyStartQuietHours) {
        guard hours != quietHours else { return }
        quietHours = hours
        let defaults = UserDefaults.standard
        defaults.set(hours.isEnabled, forKey: Key.quietEnabled)
        defaults.set(hours.startHour, forKey: Key.quietStartHour)
        defaults.set(hours.startMinute, forKey: Key.quietStartMinute)
        defaults.set(hours.endHour, forKey: Key.quietEndHour)
        defaults.set(hours.endMinute, forKey: Key.quietEndMinute)
        scheduleTimer()
    }

    /// The notice has been read. The gate opens here and nowhere else.
    func acknowledgeNotice() {
        // A screenshot run may show the notice and press its button; it may not write that press
        // into the defaults the real app reads (the same rule `AppLocale.override` follows).
        guard !DemoUsage.isActive, !noticeAcknowledged else { return }
        noticeAcknowledged = true
        UserDefaults.standard.set(EarlyStartLogic.noticeVersion, forKey: Key.noticeVersion)
        rearm()
    }

    /// Whether the panel should be carrying the one-time notice. The caller adds the question this
    /// store cannot answer: whether there is a Claude account for it to be about.
    var showsNotice: Bool { isEnabled && !noticeAcknowledged }

    /// The schedule is live: switched on AND the current notice has been read. The rule itself is
    /// pure (`EarlyStartLogic.isArmed`) so the gate in front of the first message is asserted rather
    /// than described.
    var isArmed: Bool {
        EarlyStartLogic.isArmed(enabled: isEnabled, noticeAcknowledged: noticeAcknowledged)
    }

    // MARK: The relay

    /// Fold one refresh's accounts into the schedule, and send for any account whose window has
    /// closed. Called at the tail of every refresh.
    func evaluate(accounts: [AccountUsage], launchHomes: [String: String]) {
        guard started, Self.mayRun, isArmed, !isRunning else { return }
        let now = Date()
        let calendar = Calendar.current
        let settings = SettingsStore.shared
        let candidates = accounts.map { usage in
            EarlyStartCandidate(
                accountID: usage.id,
                providerID: usage.providerID,
                home: launchHomes[usage.id],
                // Asked of the settings rather than taken from the caller's filtering, so the rule
                // is the same one wherever the list came from.
                isEnabled: settings.isEnabled(usage.providerID)
                    && settings.isAccountEnabled(usage.id),
                readingIsUsable: EarlyStartLogic.readingIsUsable(usage),
                readingKeepsFailing: EarlyStartLogic.readingKeepsFailing(usage),
                windowIsOpen: EarlyStartLogic.windowIsOpen(usage, now: now))
        }

        let state = Self.loadState()
        let plan = EarlyStartLogic.plan(candidates: candidates, state: state,
                                        quietHours: quietHours, now: now, calendar: calendar)
        // Most evaluations decide nothing and observe nothing - the fleet is working, or asleep, or
        // out of scope. `needsRecording` rather than `isReportable`: an evaluation whose only
        // content is "these accounts are working now" writes no row and still carries the fact that
        // ends their episodes (`EarlyStartPlan.needsRecording`).
        guard plan.needsRecording else { return }
        guard !plan.start.isEmpty else {
            record(state, plan: plan, attempted: [], failed: [], now: now, calendar: calendar)
            return
        }
        // Absent rather than unresolved: `ProviderCLI.executable` falls back to the bare name, which
        // would spawn nothing and report a failure per account every few minutes. Asked the way
        // `ClaudeProvider` asks it.
        guard Self.devStandIn != nil || CLIRunner.resolve("claude") != nil else {
            // Nothing is marked, so an install that arrives later gets the next evaluation; the row
            // says the accounts could not be started rather than that they were skipped.
            //
            // NAMED, NOT COUNTED, and that follows from the line above rather than being a second
            // decision: unmarked accounts are chosen again at every refresh, so a count would have
            // climbed by one per account per minute for as long as the CLI stayed missing
            // (`EarlyStartToday.couldNotStart`).
            record(state, plan: plan, attempted: [], failed: [],
                   couldNotStart: plan.start.map(\.accountID), now: now, calendar: calendar)
            return
        }
        isRunning = true
        let starting = plan.start
        let ids = starting.map(\.accountID)
        // WRITTEN BEFORE THE SPAWN, not after it. The CLIs get two minutes, and an app that quits
        // inside that window (an auto-update relaunch is the ordinary way it happens) would come
        // back to a state that never heard about this attempt and send everything again. Marking
        // first is what makes "at most one message per account per five hours" true of a process
        // that can be replaced mid-run; the counts below correct themselves when the answers land.
        record(state, plan: plan, attempted: ids, failed: [], now: now, calendar: calendar)
        Task { [weak self] in
            let failures = await Self.send(to: starting)
            guard let self else { return }
            self.isRunning = false
            guard !failures.isEmpty else { return }
            // Re-read: the refresh loop has been running while the CLIs were out, and a state
            // written from the copy captured above would discard whatever it wrote. A correction
            // rather than a replay, because the tally accumulates (`EarlyStartLogic.correcting`).
            self.correct(failed: failures, now: Date(), calendar: calendar)
        }
    }

    /// Send one short message per account, concurrently, and answer WHICH did not go through.
    ///
    /// Which rather than how many, because the day's row counts accounts and not messages: an
    /// account blocked this morning and failed this afternoon is one account with nothing to show
    /// for the day, and only a name can be merged with the other list without saying two
    /// (`EarlyStartToday.couldNotStartTotal`).
    ///
    /// The reply is discarded unread and never logged: what the run is for is the fact that a
    /// message was sent, and the body of a model's answer is not something this app has any reason
    /// to keep. Nothing about a credential passes through here either - the CLI holds its own.
    private static func send(to accounts: [EarlyStartCandidate]) async -> [String] {
        let directory = EarlyStartCommand.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = ProviderCLI.executable("claude", devOverrideKey: devOverrideKey)
        return await withTaskGroup(of: (String, Bool).self) { group in
            for account in accounts {
                group.addTask {
                    // Never nil for an account the plan chose (`EarlyStartLogic.pass` rejects one
                    // without a home); counted as a failure rather than skipped so a rule that ever
                    // stops guaranteeing it shows up in the row instead of shrinking the total.
                    guard let home = account.home else { return (account.accountID, false) }
                    let invocation = EarlyStartCommand.invocation(home: home, directory: directory)
                    let output = await CLIRunner.run(executable,
                                                     arguments: invocation.arguments,
                                                     environment: invocation.environment,
                                                     currentDirectory: invocation.currentDirectory,
                                                     timeout: invocation.timeout)
                    return (account.accountID, output?.exitCode == 0)
                }
            }
            var failures: [String] = []
            for await (accountID, ok) in group where !ok { failures.append(accountID) }
            return failures
        }
    }

    // MARK: Scheduling

    /// Ask for a refresh; the decision happens at its tail. Both nudges (the quiet-hours timer and
    /// the wake) come through here, so neither of them can grow a second copy of the rule.
    private func nudge() {
        scheduleTimer()
        guard started, Self.mayRun, isArmed else { return }
        Task { await UsageStore.shared.refresh(userInitiated: false) }
    }

    /// Set the one timer this feature still needs: the end of the quiet stretch.
    ///
    /// With quiet hours off there is no timer at all, and that is correct rather than a gap. Every
    /// other thing the relay waits for - a window closing, an attempt ageing out - is read from a
    /// refresh, and the refresh loop runs on its own interval whatever this store does.
    private func scheduleTimer() {
        timer?.cancel()
        timer = nil
        // `started` sits with the other conditions rather than above the cancel, so a schedule can
        // only ever be taken down by a path that could also put one back up.
        guard started, Self.mayRun, isArmed,
              let next = quietHours.nextEnd(after: Date(), calendar: Calendar.current) else {
            return
        }
        // WALL CLOCK, not the uptime clock every other timer in this app uses. `DispatchTime` stops
        // while the machine sleeps, so a deadline set eight hours out on a machine that sleeps for
        // seven would fire seven hours late; `DispatchWallTime` fires on the way back out of sleep
        // instead, which is the morning this timer is about.
        let delay = max(1, next.timeIntervalSinceNow)
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(wallDeadline: .now() + delay, leeway: .seconds(30))
        source.setEventHandler { Task { @MainActor in EarlyStartStore.shared.nudge() } }
        source.resume()
        timer = source
    }

    /// What every path that makes the schedule live has to do: arm without backfilling the episode
    /// in progress (`EarlyStartLogic.arming` says why), then set the timer. One function because two
    /// callers doing two things in order is two chances to do one of them.
    ///
    /// Its two halves answer to different gates. The arming is bookkeeping in the defaults and runs
    /// whenever somebody changes their mind, launch or no launch; the timer is a live thing that
    /// ends in a refresh, so it waits for `started` like every other entrance.
    private func rearm() {
        if isArmed { Self.saveState(EarlyStartLogic.arming(Self.loadState(), now: Date())) }
        scheduleTimer()
    }

    // MARK: State

    private func record(_ state: EarlyStartState, plan: EarlyStartPlan, attempted: [String],
                        failed: [String], couldNotStart: [String] = [], now: Date,
                        calendar: Calendar) {
        apply(EarlyStartLogic.recording(state, plan: plan, attempted: attempted, failed: failed,
                                        couldNotStart: couldNotStart, now: now,
                                        calendar: calendar))
    }

    /// Carry the spawns' answers into the tally that was written before they were made.
    private func correct(failed: [String], now: Date, calendar: Calendar) {
        apply(EarlyStartLogic.correcting(Self.loadState(), failed: failed, now: now,
                                         calendar: calendar))
    }

    /// Persist a new state and republish what the Settings row reads off it. The one place either
    /// happens, so a fold can never be written down without the row hearing about it.
    private func apply(_ state: EarlyStartState) {
        Self.saveState(state)
        today = state.today
    }

    private static func loadState() -> EarlyStartState {
        guard let data = UserDefaults.standard.data(forKey: Key.state),
              let state = try? JSONDecoder().decode(EarlyStartState.self, from: data) else {
            return EarlyStartState()
        }
        return state
    }

    private static func saveState(_ state: EarlyStartState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: Key.state)
    }

    // MARK: Gates

    /// The dev stand-in CLI, or nil. Dev builds only (`ProviderCLI.executable` enforces the same).
    private static var devStandIn: String? {
        guard BuildVariant.isDev,
              let path = UserDefaults.standard.string(forKey: devOverrideKey),
              !path.isEmpty else { return nil }
        return path
    }

    /// Whether this process may send anything at all.
    ///
    /// A screenshot run never does: its accounts are fixtures. A build nobody installed never does
    /// either, the same rule the two notifiers follow - one process owns the shared surfaces and it
    /// is the installed release app - with the one exception that makes the chain reviewable: a dev
    /// build pointed at a stand-in CLI spends nothing, so it is allowed to run the whole path.
    private static var mayRun: Bool {
        guard !DemoUsage.isActive else { return false }
        return !BuildVariant.isUnshipped || devStandIn != nil
    }
}
