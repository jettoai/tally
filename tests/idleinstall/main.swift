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

func install(taskSurface: Bool = false, pinned: Bool = false,
             idleFor: TimeInterval = 1_000, waiting: TimeInterval = 60) -> Bool {
    IdleInstall.shouldInstall(taskSurfaceOpen: taskSurface, pinnedPanelOpen: pinned,
                              secondsSinceUserInput: idleFor, waiting: waiting)
}

// MARK: the constants themselves - a bar of zero would make every rule below vacuous

expect(bar > 0, "the idle bar is a real wait")
expect(grace > bar, "the pinned grace outlasts the idle bar, or it would never be the binding rule")

// MARK: a Tally window the user opened is an absolute veto

expect(!install(taskSurface: true),
       "a task surface is open - the machine being idle does not make it ok to take it away")
expect(!install(taskSurface: true, waiting: grace * 10),
       "no amount of waiting overrides an open task surface")
expect(!install(taskSurface: true, pinned: true, idleFor: 86_400, waiting: grace * 10),
       "every other condition met, one open task surface still wins")

// MARK: the machine must be quiet

expect(!install(idleFor: 0), "someone is typing right now")
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

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("all passed")
