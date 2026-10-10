import Foundation

// Assertion harness for IdleInstall (compiled with Tally/Core/IdleInstall.swift alone - it is
// Foundation-only on purpose). The Sparkle handshake around it is not testable here and is not
// tried; what IS testable is the rule that decides the moment, which is the whole reason a
// downloaded update either lands quietly or nags.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let bar = IdleInstall.idleBar
let grace = IdleInstall.pinnedPanelGrace
let windowGrace = IdleInstall.taskWindowGrace
let cap = IdleInstall.idleBarCap

func install(modal: Bool = false, taskWindow: Bool = false, pinned: Bool = false,
             idleFor: TimeInterval = 1_000, waiting: TimeInterval = 60) -> Bool {
    IdleInstall.shouldInstall(modalOpen: modal, taskWindowOpen: taskWindow, pinnedPanelOpen: pinned,
                              secondsSinceUserInput: idleFor, waiting: waiting)
}

// MARK: the constants themselves - a bar of zero would make every rule below vacuous

expect(bar > 0, "the idle bar is a real wait")
expect(grace > bar, "the pinned grace outlasts the idle bar, or it would never be the binding rule")
expect(windowGrace > bar,
       "the window grace outlasts the idle bar, or it would never be the binding rule")
expect(windowGrace < grace,
       "an ordinary window is discounted sooner than a pinned panel, which is built to sit there")
expect(cap > grace,
       "the idle bar cap outlasts the pinned grace, so both graces have expired by the time it lifts")

// MARK: a modal is an absolute veto - a decision is sitting in front of the user

expect(!install(modal: true),
       "a modal is up - the machine being idle does not make it ok to answer it by restarting")
expect(!install(modal: true, waiting: grace * 10),
       "no amount of waiting overrides an open modal")
expect(!install(modal: true, taskWindow: true, pinned: true, idleFor: 86_400, waiting: grace * 10),
       "every other condition met, one open modal still wins")

// MARK: an ordinary window holds the install off, but only for a while
//
// The regression this section exists for: an open window used to veto with no expiry, so a main
// window parked on a second display meant the app never updated itself at all (0.76.6 and 0.77.0,
// live reports 2026-09-21 and 2026-09-22).

expect(!install(taskWindow: true, waiting: 0), "window open, just queued - wait")
expect(!install(taskWindow: true, waiting: windowGrace - 1),
       "window open, one second short of the grace")
expect(install(taskWindow: true, waiting: windowGrace),
       "window open past the grace, machine idle - install (the window reopens the way it opened)")
expect(install(taskWindow: true, idleFor: bar, waiting: windowGrace * 10),
       "a window parked for hours does not veto forever")
expect(!install(taskWindow: true, idleFor: bar - 1, waiting: windowGrace * 10),
       "the grace expiring on a window never waives the human-presence bar either")

// MARK: the machine must be quiet

expect(!install(idleFor: 0), "someone is typing right now")
expect(!install(idleFor: 180, waiting: grace),
       "nothing on screen at all, but the last keystroke was three minutes ago - somebody is there")
expect(!install(idleFor: bar - 1), "one second short of the bar is still not idle")
expect(install(idleFor: bar), "the bar itself counts as idle")
expect(install(idleFor: bar + 1), "past the bar")
expect(!install(idleFor: 0, waiting: grace),
       "the grace expiring never waives the human-presence bar")

// MARK: after a day of waiting the idle bar is lifted
//
// The regression this section exists for: an agent driving the machine (or a VM forwarding input)
// keeps machine-wide input from ever going quiet, so the idle bar alone meant a downloaded update
// never installed at all (live report 2026-09-27, idle readings of 0 to 2 seconds for hours).

expect(!install(idleFor: 0, waiting: cap - 1), "someone typing, one second short of the cap - wait")
expect(install(idleFor: 0, waiting: cap), "someone typing, waiting reached the cap - install")
expect(install(idleFor: 180, waiting: grace * 10),
       "last keystroke three minutes ago, but the update has waited 60 hours - install")
expect(install(taskWindow: true, pinned: true, idleFor: 0, waiting: cap),
       "at the cap both graces have long expired, so a window and a pinned panel do not hold it")
expect(!install(modal: true, idleFor: 0, waiting: cap * 10),
       "the cap never lifts the modal veto - a question the user has not answered never expires")

// MARK: the pinned panel holds the install off, but only for a while

expect(!install(pinned: true, waiting: 0), "pinned panel up, just queued - wait")
expect(!install(pinned: true, waiting: grace - 1), "pinned panel up, one second short of the grace")
expect(install(pinned: true, waiting: grace),
       "pinned panel up past the grace, machine idle - install (the panel restores itself)")
expect(install(waiting: 0),
       "nothing on screen and the machine is idle - install immediately, no waiting required")

// MARK: shouldHandleShowingScheduledUpdate - who gets to speak about a scheduled update

expect(!IdleInstall.standardAlertShouldShowScheduledUpdate(automaticInstallsEnabled: true),
       "automatic installs on - the app owns it, the header chip is the reminder, no alert")
expect(IdleInstall.standardAlertShouldShowScheduledUpdate(automaticInstallsEnabled: false),
       "automatic installs off - nothing else would mention it, so the standard alert stays")

// MARK: which real surface feeds which input
//
// The rules above take the modal and the windows as two booleans; WHICH windows are behind them is
// decided in UpdaterController.swift, and that wiring is where the distinction can silently go back
// to what it was (put the modal back into the window list and every window vetoes forever again;
// drop a window out of it and that window stops holding the install off at all). The rules cannot
// see it, so it is read out of the source. Run from the repo root by tests/run-idleinstall-tests.sh.

let controllerPath = "Tally/App/UpdaterController.swift"
guard let controller = try? String(contentsOfFile: controllerPath, encoding: .utf8) else {
    print("FAIL could not read \(controllerPath) - run this from the repo root")
    exit(1)
}

// One declaration's body alone, so a mention of a modal anywhere else in the file (the call site
// legitimately has one) cannot stand in for the thing being asserted. Both readers below want the
// same extraction, which is why it is a function rather than two closures that must stay alike.
func body(of declaration: String, in source: String) -> String {
    guard let start = source.range(of: declaration),
          let end = source.range(of: "\n    }", range: start.upperBound ..< source.endIndex)
    else { return "" }
    return String(source[start.upperBound ..< end.lowerBound])
}

let windowBody = body(of: "private static var taskWindowOnScreen: Bool {", in: controller)
expect(!windowBody.isEmpty, "UpdaterController still has a taskWindowOnScreen to read")
for surface in ["isPopoverShown", "SettingsWindowController.shared.isWindowVisible",
                "MainWindowController.shared.isWindowVisible"] {
    expect(windowBody.contains(surface),
           "\(surface) is one of the windows that holds the install off for the grace")
}
expect(!windowBody.contains("modalWindow"),
       "the modal is NOT in the window list - it would inherit the grace and expire, and a "
           + "question the user has not answered must never expire")
expect(controller.contains("modalOpen: Self.decisionPending"),
       "the no-expiry veto reaches the rule through its own input, and by way of the rule above "
           + "rather than a question asked straight at AppKit")

let decisionBody = body(of: "private static var decisionPending: Bool {", in: controller)
expect(!decisionBody.isEmpty, "UpdaterController has a decisionPending to read")
expect(decisionBody.contains("attachedSheet"),
       "it asks each window whether a sheet is attached to it - NSApp.modalWindow cannot see one, "
           + "which is the whole of this defect")
expect(decisionBody.contains("NSApp.modalWindow"),
       "and it still asks about an application-modal window, which it always did catch")
expect(controller.contains("taskWindowOpen: Self.taskWindowOnScreen"),
       "the windows reach the rule through the input that does have one")

// MARK: what "a decision is sitting in front of the user" is actually read from
//
// `modalOpen` above is a boolean; the defect this section exists for was in how the app ARRIVES at
// it. It asked `NSApp.modalWindow != nil`, a question about AppKit's modal session, and that answers
// nil for a sheet attached to a window - which is what SwiftUI's `.sheet` is. So "Add account", a
// half-filled form with an OAuth round trip in the middle of it, was invisible to this veto. It only
// ever survived because the sheet hangs off Settings and an open window used to veto forever; the
// hour-long taskWindowGrace took that cover away.

func window(modal: Bool = false, sheet: Bool = false) -> IdleInstall.WindowState {
    IdleInstall.WindowState(isApplicationModal: modal, hasAttachedSheet: sheet)
}

expect(!IdleInstall.decisionPending(windows: []), "no windows at all - nothing is being decided")
expect(!IdleInstall.decisionPending(windows: [window(), window()]),
       "two plain windows on screen - furniture, which is what taskWindowOpen is for")
expect(IdleInstall.decisionPending(windows: [window(modal: true)]),
       "an application-modal window counts, as it always did")
expect(IdleInstall.decisionPending(windows: [window(sheet: true)]),
       "a window with a sheet attached counts too - NSApp.modalWindow answers nil for one")
expect(IdleInstall.decisionPending(windows: [window(), window(sheet: true), window()]),
       "one sheet among ordinary windows is enough")

// And why it is routed into modalOpen rather than taskWindowOpen: this one does not expire.
expect(!install(modal: IdleInstall.decisionPending(windows: [window(sheet: true)]),
                taskWindow: true, idleFor: 86_400, waiting: windowGrace * 10),
       "Add account open, the machine idle for a day, hours past every grace - still no restart")

// MARK: B-5730 - at most one unattended install a day, and only with every session idle

func spaced(since: TimeInterval?, busy: Int?, waiting: TimeInterval = 60) -> Bool {
    IdleInstall.shouldInstall(modalOpen: false, taskWindowOpen: false, pinnedPanelOpen: false,
                              secondsSinceUserInput: 1_000, waiting: waiting,
                              sinceLastInstall: since, busySessions: busy)
}
let hour: TimeInterval = 3600
expect(!spaced(since: 23 * hour, busy: 0), "T-F1 23 hours after the last install: not yet")
expect(spaced(since: 25 * hour, busy: 0), "T-F1 25 hours after it, every session idle: install")
expect(!spaced(since: 23 * hour, busy: 0, waiting: 100 * hour),
       "T-F1 the spacing is not lifted by waiting")
expect(!spaced(since: nil, busy: 1, waiting: hour), "T-F2 a busy session holds it")
expect(!spaced(since: nil, busy: 1, waiting: 5 * hour), "T-F2 …still at 5 hours")
expect(spaced(since: nil, busy: 1, waiting: 7 * hour), "T-F2 …until 6 hours have passed")
expect(!spaced(since: nil, busy: nil, waiting: hour), "T-F2 sessions that cannot be read hold it too")
expect(spaced(since: nil, busy: nil, waiting: 7 * hour), "T-F2 …on the same cap")
expect(IdleInstall.busySessionsCap == 6 * 3600, "B-1395 the busy hold is six hours, not three days")

// MARK: B-1395 - a session sitting at its composer is idle, not busy

expect(IdleInstall.busyCount([.waitingSoft, .idle]) == 0,
       "B-1395-1 a soft idle_prompt wait and an idle session hold nothing")
expect(IdleInstall.busyCount([.waitingHard]) == 1, "B-1395-2 a permission dialog still holds it")
expect(IdleInstall.busyCount([.working, .waitingSoft]) == 1,
       "B-1395-3 a working session still holds it beside a soft wait")
expect(IdleInstall.busyCount([.unknown]) == 1, "B-1395-4 a session with no reading still holds it")
let updaterDelegate = (try? String(contentsOfFile: "Tally/App/UpdaterDelegate.swift", encoding: .utf8)) ?? ""
expect(updaterDelegate.contains("IdleInstall.busyCount(")
        && !updaterDelegate.contains("$0.state != .idle }.count"),
       "B-1395-5 the app counts busy sessions through busyCount, not the state word")
let blockedArm = updaterDelegate.components(separatedBy: "case .blocked:").dropFirst().first ?? ""
expect(blockedArm.prefix(300).contains("userWait(notificationType:"),
       "B-1395-6 a blocked row is split on its notice type")
expect(spaced(since: nil, busy: 0), "T-F3 never installed and nothing busy: the old rules decide")
expect(!IdleInstall.shouldInstall(modalOpen: true, taskWindowOpen: false, pinnedPanelOpen: false,
                                  secondsSinceUserInput: 1_000, waiting: 60,
                                  sinceLastInstall: nil, busySessions: 0),
       "T-F3 …a modal still vetoes")
// T-F4: a person's own check never meets these rules. The reducer runs a requested install on the
// spot (UpdateState.swift `.installHandlerArrived`), so the only caller is the unattended moment.
let appSources = (FileManager.default.enumerator(atPath: "Tally")?.allObjects as? [String] ?? [])
    .filter { $0.hasSuffix(".swift") && $0 != "Core/IdleInstall.swift" }
let callers = appSources.filter {
    ((try? String(contentsOfFile: "Tally/\($0)", encoding: .utf8)) ?? "").contains("IdleInstall.shouldInstall(")
}
expect(callers == ["App/UpdaterController.swift"], "T-F4 shouldInstall has one caller: \(callers)")
let reducer = (try? String(contentsOfFile: "Tally/Core/UpdateState.swift", encoding: .utf8)) ?? ""
expect(reducer.contains("guard state.requestedByUser else { return [] }\n            return state.dispatch(userAsked: true)"),
       "T-F4 a requested install is dispatched by the reducer, never through the idle moment")

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("all passed")
