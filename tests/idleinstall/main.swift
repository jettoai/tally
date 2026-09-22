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
expect(!install(idleFor: 180, waiting: grace * 10),
       "nothing on screen at all, but the last keystroke was three minutes ago - somebody is there")
expect(!install(idleFor: bar - 1), "one second short of the bar is still not idle")
expect(install(idleFor: bar), "the bar itself counts as idle")
expect(install(idleFor: bar + 1), "past the bar")
expect(!install(idleFor: 0, waiting: grace * 10),
       "the grace expiring never waives the human-presence bar")

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

// The body of taskWindowOnScreen alone, so a mention of a modal anywhere else in the file (the call
// site legitimately has one) cannot stand in for the thing being asserted.
let windowBody: String = {
    guard let start = controller.range(of: "private static var taskWindowOnScreen: Bool {"),
          let end = controller.range(of: "\n    }", range: start.upperBound ..< controller.endIndex)
    else { return "" }
    return String(controller[start.upperBound ..< end.lowerBound])
}()

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

// The body of that reader alone, for the same reason windowBody is read alone.
let decisionBody: String = {
    guard let start = controller.range(of: "private static var decisionPending: Bool {"),
          let end = controller.range(of: "\n    }", range: start.upperBound ..< controller.endIndex)
    else { return "" }
    return String(controller[start.upperBound ..< end.lowerBound])
}()
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

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("all passed")
