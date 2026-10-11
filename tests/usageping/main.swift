import Foundation

// argv: <ping URL> <expected product>. Sends exactly one ping with the switch on (the default), then
// asserts the switch off sends nothing; tests/usageping/server.py checks the one request it saw.
let url = URL(string: CommandLine.arguments[1])!
let expected = CommandLine.arguments[2]
let suite = "tally-usageping-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
var failed = false
func check(_ ok: Bool, _ name: String) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failed = true } }

final class Outcome: @unchecked Sendable { var ok = false; let done = DispatchSemaphore(value: 0) }

check(UsagePing.product == expected, "product is \(expected)")
check(UsagePing.isEnabled(defaults), "on by default")
check(defaults.string(forKey: UsagePing.deviceKey) == nil, "no device id before the first send")

let on = Outcome()
check(UsagePing.send(to: url, defaults: defaults, version: "9.9.9") { on.ok = $0; on.done.signal() },
      "send with switch on")
check(on.done.wait(timeout: .now() + 10) == .success && on.ok, "204 counts as success")
let id = defaults.string(forKey: UsagePing.deviceKey) ?? ""
print("DEVICE \(id)")
check(UsagePing.deviceID(defaults) == id, "device id is stable")

UsagePing.setEnabled(false, defaults)
let off = Outcome()
check(!UsagePing.send(to: url, defaults: defaults, version: "9.9.9") { _ in off.done.signal() },
      "switch off sends nothing")
check(off.done.wait(timeout: .now() + 2) == .timedOut, "switch off: no request completed")

let t0 = Date()
check(UsagePing.isDue(lastSent: nil, now: t0), "first tick is due")
check(!UsagePing.isDue(lastSent: t0, now: t0.addingTimeInterval(23 * 3600)), "not due inside a day")
check(UsagePing.isDue(lastSent: t0, now: t0.addingTimeInterval(24 * 3600)), "due after a day")
check(UsagePing.isDue(lastSent: t0, now: t0.addingTimeInterval(72 * 3600)), "due once after a long sleep")

defaults.removePersistentDomain(forName: suite)
exit(failed ? 1 : 0)
