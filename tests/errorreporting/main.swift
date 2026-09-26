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

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
