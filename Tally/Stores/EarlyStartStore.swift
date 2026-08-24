import AppKit
import Observation

/// The early-start schedule: the preference, the persisted bookkeeping, and the one place a morning
/// message is actually sent. The rules it runs on are pure and live next door (`Core/EarlyStart.swift`);
/// what a spawn is lives in `Core/EarlyStartCommand.swift`.
///
/// THE EVALUATION RIDES THE REFRESH LOOP rather than the timer, the same way the two notifiers do.
/// Deciding whether a window is open means reading this morning's usage, and the refresh is what
/// produces it; a timer that fired and then read whatever numbers happened to be in memory would be
/// deciding on a reading from before the machine went to sleep. So `evaluate` is called at the tail
/// of every refresh, is idempotent (a date comparison and a dictionary lookup), and the timer and
/// the wake observer below exist only to make the morning PUNCTUAL: both of them do nothing but ask
/// for a refresh, and the decision happens where it always happens.
///
/// That also covers the case no timer can: an app that was closed at 7am and opened at 8am has no
/// fire to catch up on, and its first refresh is the one that notices.
@MainActor
@Observable
final class EarlyStartStore {
    static let shared = EarlyStartStore()

    private enum Key {
        static let enabled = "ai.jetto.tally.earlyStart.enabled"
        static let hour = "ai.jetto.tally.earlyStart.hour"
        static let minute = "ai.jetto.tally.earlyStart.minute"
        static let noticeSeen = "ai.jetto.tally.earlyStart.noticeSeen"
        static let state = "ai.jetto.tally.earlyStart.state"
    }

    /// Dev-build launch flag pointing the spawn at a stand-in CLI (`ProviderCLI.executable`), so the
    /// whole chain can be exercised without spending a real subscription's window. Dev only and
    /// volatile (the argument domain), and it is ALSO what lets a dev build run at all: without it
    /// an unshipped build never sends anything (`mayRun`).
    private static let devOverrideKey = "TallyEarlyStartCLI"

    /// ON by default. The feature costs one short message per account per morning and buys back a
    /// reset that lands inside the working day; a switch nobody finds is a switch nobody benefits
    /// from. What keeps that from being a surprise is the notice: nothing is sent until it has been
    /// read (`isArmed`).
    private(set) var isEnabled: Bool
    private(set) var hour: Int
    private(set) var minute: Int
    /// Whether the one-time notice has been shown and acknowledged. The gate in front of the very
    /// first message this feature ever sends.
    private(set) var noticeAcknowledged: Bool
    /// What the last morning did, for the Settings row. Nil until there has been one.
    private(set) var lastRun: EarlyStartRun?

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
    /// it" on the notice, moving the Settings switch, changing the time. An app opened at 06:59:40
    /// and acknowledged at 06:59:45 would otherwise arm a timer that fires at 07:00 into the middle
    /// of the repair. `evaluate` carries it too, because a refresh asked for by anything at all
    /// (the panel opening, the menu's Refresh) ends by asking this store whether to send.
    ///
    /// The preference writes themselves are NOT gated: they persist immediately, and `start()`
    /// schedules from the values it finds, so an early change is honoured rather than lost.
    private var started = false
    /// True while a morning's spawns are in flight. A run can outlast several refreshes (the CLI
    /// gets two minutes), and every one of those refreshes would otherwise evaluate a state that
    /// has not been written yet and send the same message again.
    private var isRunning = false

    private init() {
        let defaults = UserDefaults.standard
        // `nil` here is "never chosen", not "chose off": the key is written only by the Settings
        // switch, and property observers do not run during init.
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        noticeAcknowledged = defaults.bool(forKey: Key.noticeSeen)
        let storedHour = defaults.object(forKey: Key.hour) as? Int
        let storedMinute = defaults.object(forKey: Key.minute) as? Int
        hour = Self.clampedHour(storedHour ?? EarlyStartLogic.defaultHour)
        minute = Self.clampedMinute(storedMinute ?? EarlyStartLogic.defaultMinute)
        lastRun = Self.loadState().lastRun
    }

    // MARK: Lifetime

    /// Install the punctuality nudges. Called once at launch, behind the Keychain repair.
    ///
    /// Opening the gate is the FIRST thing it does, because everything below it is gated on it.
    /// Scheduling here rather than arming: `EarlyStartLogic.arming` marks today as spent when the
    /// trigger has gone by, which is right for somebody changing their mind and wrong for a launch.
    /// An app opened at 8am is the case this feature is most obviously for, so the catch-up has to
    /// survive the gate, and it does because a preference changed before this point has already
    /// written its own arming through `rearm`.
    func start() {
        started = true
        scheduleTimer()
        guard wakeObserver == nil else { return }
        // A machine asleep through 7am has no fire to catch: the schedule below is set on the wall
        // clock so a deadline that passed during sleep fires on the way back, and this is the
        // second path to the same place for the sleep that outlasts it.
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

    func setTime(hour newHour: Int, minute newMinute: Int) {
        let clamped = (Self.clampedHour(newHour), Self.clampedMinute(newMinute))
        guard clamped != (hour, minute) else { return }
        hour = clamped.0
        minute = clamped.1
        UserDefaults.standard.set(hour, forKey: Key.hour)
        UserDefaults.standard.set(minute, forKey: Key.minute)
        rearm()
    }

    /// The notice has been read. The gate opens here and nowhere else.
    func acknowledgeNotice() {
        // A screenshot run may show the notice and press its button; it may not write that press
        // into the defaults the real app reads (the same rule `AppLocale.override` follows).
        guard !DemoUsage.isActive, !noticeAcknowledged else { return }
        noticeAcknowledged = true
        UserDefaults.standard.set(true, forKey: Key.noticeSeen)
        rearm()
    }

    /// Whether the panel should be carrying the one-time notice. The caller adds the question this
    /// store cannot answer: whether there is a Claude account for it to be about.
    var showsNotice: Bool { isEnabled && !noticeAcknowledged }

    /// The schedule is live: switched on AND the notice has been read. The rule itself is pure
    /// (`EarlyStartLogic.isArmed`) so the gate in front of the first message is asserted rather
    /// than described.
    var isArmed: Bool {
        EarlyStartLogic.isArmed(enabled: isEnabled, noticeAcknowledged: noticeAcknowledged)
    }

    /// Today's trigger instant, for the notice's own sentence and the Settings row's caption.
    var triggerToday: Date? {
        EarlyStartLogic.trigger(onDayOf: Date(), hour: hour, minute: minute,
                                calendar: Calendar.current)
    }

    // MARK: The morning

    /// Fold one refresh's accounts into the schedule, and send this morning's messages if this is
    /// the refresh that finds the trigger passed. Called at the tail of every refresh.
    func evaluate(accounts: [AccountUsage], launchHomes: [String: String]) {
        guard started, Self.mayRun, isArmed, !isRunning else { return }
        let now = Date()
        let calendar = Calendar.current
        guard EarlyStartLogic.triggerHasPassed(now: now, hour: hour, minute: minute,
                                               calendar: calendar) else { return }
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
                windowIsOpen: EarlyStartLogic.windowIsOpen(usage, now: now))
        }

        let state = Self.loadState()
        let plan = EarlyStartLogic.plan(candidates: candidates, state: state, now: now,
                                        calendar: calendar)
        // A morning with nothing to start and nothing in scope passed over is not a morning: it
        // must not overwrite the record of the one that was (`EarlyStartPlan.isReportable`).
        guard plan.isReportable else { return }
        guard !plan.start.isEmpty else {
            record(state, plan: plan, attempted: [], failed: 0, now: now, calendar: calendar)
            return
        }
        // Absent rather than unresolved: `ProviderCLI.executable` falls back to the bare name, which
        // would spawn nothing and report a failure per account every morning. Asked the way
        // `ClaudeProvider` asks it.
        guard Self.devStandIn != nil || CLIRunner.resolve("claude") != nil else {
            // Nothing is stamped, so an install that arrives later gets its morning on the next
            // refresh; the row says the accounts could not be started rather than that they were
            // skipped.
            record(state, plan: plan, attempted: [], failed: plan.start.count, now: now,
                   calendar: calendar)
            return
        }
        isRunning = true
        let starting = plan.start
        let ids = starting.map(\.accountID)
        // WRITTEN BEFORE THE SPAWN, not after it. The CLIs get two minutes, and an app that quits
        // inside that window (an auto-update relaunch is the ordinary way it happens) would come
        // back to a state that never heard about this morning and send everything again. Stamping
        // first is what makes "at most one message per account per morning" true of a process that
        // can be replaced mid-run; the counts below correct themselves when the answers land.
        record(state, plan: plan, attempted: ids, failed: 0, now: now, calendar: calendar)
        Task { [weak self] in
            let failures = await Self.send(to: starting)
            guard let self else { return }
            self.isRunning = false
            guard failures > 0 else { return }
            // Re-read: the refresh loop has been running while the CLIs were out, and a state
            // written from the copy captured above would discard whatever it wrote.
            self.record(Self.loadState(), plan: plan, attempted: ids, failed: failures, now: now,
                        calendar: calendar)
        }
    }

    /// Send one short message per account, concurrently, and answer how many did not go through.
    ///
    /// The reply is discarded unread and never logged: what the run is for is the fact that a
    /// message was sent, and the body of a model's answer is not something this app has any reason
    /// to keep. Nothing about a credential passes through here either - the CLI holds its own.
    private static func send(to accounts: [EarlyStartCandidate]) async -> Int {
        let directory = EarlyStartCommand.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = ProviderCLI.executable("claude", devOverrideKey: devOverrideKey)
        return await withTaskGroup(of: Bool.self) { group in
            for account in accounts {
                group.addTask {
                    // Never nil for an account the plan chose (`EarlyStartLogic.pass` rejects one
                    // without a home); counted as a failure rather than skipped so a rule that ever
                    // stops guaranteeing it shows up in the row instead of shrinking the total.
                    guard let home = account.home else { return false }
                    let invocation = EarlyStartCommand.invocation(home: home, directory: directory)
                    let output = await CLIRunner.run(executable,
                                                     arguments: invocation.arguments,
                                                     environment: invocation.environment,
                                                     currentDirectory: invocation.currentDirectory,
                                                     timeout: invocation.timeout)
                    return output?.exitCode == 0
                }
            }
            var failures = 0
            for await ok in group where !ok { failures += 1 }
            return failures
        }
    }

    // MARK: Scheduling

    /// Ask for a refresh; the decision happens at its tail. Both nudges (the timer and the wake)
    /// come through here, so neither of them can grow a second copy of the rule.
    private func nudge() {
        scheduleTimer()
        guard started, Self.mayRun, isArmed else { return }
        Task { await UsageStore.shared.refresh(userInitiated: false) }
    }

    private func scheduleTimer() {
        timer?.cancel()
        timer = nil
        // `started` sits with the other conditions rather than above the cancel, so a schedule can
        // only ever be taken down by a path that could also put one back up.
        guard started, Self.mayRun, isArmed,
              let next = EarlyStartLogic.nextTrigger(after: Date(), hour: hour, minute: minute,
                                                     calendar: Calendar.current) else { return }
        // WALL CLOCK, not the uptime clock every other timer in this app uses. `DispatchTime` stops
        // while the machine sleeps, so a deadline set eight hours out on a machine that sleeps for
        // seven would fire seven hours late; `DispatchWallTime` fires on the way back out of sleep
        // instead, which is the morning this feature is about.
        let delay = max(1, next.timeIntervalSinceNow)
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(wallDeadline: .now() + delay, leeway: .seconds(30))
        source.setEventHandler { Task { @MainActor in EarlyStartStore.shared.nudge() } }
        source.resume()
        timer = source
    }

    /// What every path that can make the schedule live, or move its trigger, has to do: arm without
    /// backfilling today (`EarlyStartLogic.arming` says why), then set the timer to the new next
    /// trigger. One function because three callers doing two things in order is three chances to do
    /// one of them.
    ///
    /// Its two halves answer to different gates. The arming is bookkeeping in the defaults and runs
    /// whenever somebody changes their mind, launch or no launch; the timer is a live thing that
    /// ends in a refresh, so it waits for `started` like every other entrance.
    private func rearm() {
        if isArmed {
            Self.saveState(EarlyStartLogic.arming(Self.loadState(), now: Date(), hour: hour,
                                                  minute: minute, calendar: Calendar.current))
        }
        scheduleTimer()
    }

    // MARK: State

    private func record(_ state: EarlyStartState, plan: EarlyStartPlan, attempted: [String],
                        failed: Int, now: Date, calendar: Calendar) {
        let next = EarlyStartLogic.recording(state, plan: plan, attempted: attempted,
                                             failed: failed, now: now, calendar: calendar)
        Self.saveState(next)
        lastRun = next.lastRun
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

    // MARK: Bounds

    /// Clock components, brought back into range on the way IN as well as on the way out: a
    /// defaults file edited by hand must not be able to schedule a 25th hour.
    private static func clampedHour(_ value: Int) -> Int { min(max(value, 0), 23) }
    private static func clampedMinute(_ value: Int) -> Int { min(max(value, 0), 59) }
}
