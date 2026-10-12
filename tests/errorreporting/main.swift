import Foundation
import Sentry

// ErrorReporting.scrub against a crash-shaped event: the app run from ~/Downloads puts the home
// directory into debug images and stack frames. After scrub, the serialized event must not carry it.
// Offline: nothing here starts the SDK.

let home = "/Users/tallyfixture"
let appBinary = "\(home)/Downloads/Tally.app/Contents/MacOS/Tally"
var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "PASS \(what)" : "FAIL \(what)")
    if !ok { failures += 1 }
}

func frame() -> Frame {
    let f = Frame()
    f.package = appBinary
    f.fileName = "\(home)/src/tally/Tally/App/AppDelegate.swift"
    f.module = appBinary
    f.function = "main"
    return f
}

let event = Event(level: .fatal)
let image = DebugMeta()
image.codeFile = appBinary
image.type = "macho"
event.debugMeta = [image]
let thread = SentryThread(threadId: 0)
thread.stacktrace = SentryStacktrace(frames: [frame()], registers: [:])
event.threads = [thread]
let exception = Exception(value: "crashed in \(appBinary)", type: "EXC_BAD_ACCESS")
exception.stacktrace = SentryStacktrace(frames: [frame()], registers: [:])
event.exceptions = [exception]
event.stacktrace = SentryStacktrace(frames: [frame()], registers: [:])

func serialized(_ e: Event) -> String {
    let data = try! JSONSerialization.data(withJSONObject: e.serialize(), options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
}

check(serialized(event).contains(home), "fixture carries the home directory before scrub")
let out = serialized(ErrorReporting.scrub(event, home: home))
check(!out.contains(home), "serialized event carries no home directory after scrub")
check(!out.contains("tallyfixture"), "serialized event carries no login name after scrub")
check(out.contains("~/Downloads/Tally.app/Contents/MacOS/Tally"), "paths are folded to ~, not dropped")
check(image.codeFile == "~/Downloads/Tally.app/Contents/MacOS/Tally", "debugMeta codeFile folded")
check(thread.stacktrace?.frames.first?.package == "~/Downloads/Tally.app/Contents/MacOS/Tally",
      "thread frame package folded")
check(exception.stacktrace?.frames.first?.package == "~/Downloads/Tally.app/Contents/MacOS/Tally",
      "exception frame package folded")

// App Hang context (Sentry TALLY-6, TALLY-59): dropped whenever the display sleeps, tagged
// otherwise; anything that is not an App Hang passes untouched.
func hang() -> Event {
    let e = Event(level: .error)
    let x = Exception(value: "App hanging for at least 2000 ms.", type: "App Hanging")
    x.mechanism = Mechanism(type: "AppHang")
    e.exceptions = [x]
    return e
}
check(ErrorReporting.contextualizeHang(hang(), displayAsleep: true, hostAlarmed: true) == nil,
      "hang with display asleep on an alarmed host is dropped")
check(ErrorReporting.contextualizeHang(hang(), displayAsleep: true, hostAlarmed: false) == nil,
      "hang with display asleep below the host alarm is dropped")
for (asleep, alarmed) in [(false, true), (false, false)] {
    let tags = ErrorReporting.contextualizeHang(hang(), displayAsleep: asleep, hostAlarmed: alarmed)?.tags
    check(tags?["display_asleep"] == String(asleep) && tags?["host_alarmed"] == String(alarmed),
          "hang kept and tagged (asleep \(asleep), alarmed \(alarmed))")
}
check(ErrorReporting.contextualizeHang(hang(), displayAsleep: false, hostAlarmed: false,
                                       surfaceTab: "sessions")?.tags?["surface_tab"] == "sessions",
      "hang tagged with the page the surface last showed")
check(ErrorReporting.contextualizeHang(hang(), displayAsleep: false, hostAlarmed: false)?
          .tags?["surface_tab"] == "none",
      "hang before any surface appeared says so")
// App Nap (Sentry TALLY-2): a main thread below priority 31 is throttled, so the hang is dropped.
check(ErrorReporting.contextualizeHang(hang(), displayAsleep: false, hostAlarmed: false,
                                       mainPriority: 4) == nil,
      "hang with the main thread throttled to priority 4 is dropped")
check(ErrorReporting.contextualizeHang(hang(), displayAsleep: false, hostAlarmed: false,
                                       mainPriority: 46)?.tags?["main_pri"] == "46",
      "hang at normal priority 46 is kept and tagged main_pri=46")
check(ErrorReporting.contextualizeHang(hang(), displayAsleep: false, hostAlarmed: false,
                                       mainPriority: nil)?.tags?["main_pri"] == "unknown",
      "hang with an unreadable priority is kept and tagged main_pri=unknown")
var offMain: Int32?
let read = DispatchSemaphore(value: 0)
let mainPort = pthread_mach_thread_np(pthread_self())
DispatchQueue.global().async { offMain = ErrorReporting.threadPriority(mainPort); read.signal() }
read.wait()
check((offMain ?? 0) > 0, "main thread priority read from a background queue: \(String(describing: offMain))")

let crash = Event(level: .fatal)
let crashException = Exception(value: "boom", type: "EXC_BAD_ACCESS")
crashException.mechanism = Mechanism(type: "mach")
crash.exceptions = [crashException]
let passed = ErrorReporting.contextualizeHang(crash, displayAsleep: true, hostAlarmed: true)
check(passed === crash && passed?.tags == nil, "non-hang event passes untouched while asleep and alarmed")
let crash2 = Event(level: .fatal)
crash2.exceptions = [crashException]
let passed2 = ErrorReporting.contextualizeHang(crash2, displayAsleep: false, hostAlarmed: false,
                                               mainPriority: 4)
check(passed2 === crash2 && passed2?.tags == nil, "non-hang event passes untouched at priority 4")

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
