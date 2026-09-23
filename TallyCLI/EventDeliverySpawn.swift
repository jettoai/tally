import Foundation

// THE DETACHED DELIVERY SPAWNER (plan §5.3, narrowed by §14 revision 2). All a tick does about
// delivery is decide whether one is overdue and, if so, hand it to a `sh -c "... &"` that outlives
// this process's wait on it by milliseconds: `sh` backgrounds the real `tally events
// --deliver-once` and exits, so the grandchild is orphaned straight to launchd with no zombie and
// no `ChildReaper` involvement. Nothing here does network I/O; that is `EventDelivery.swift`'s own
// job (a separate package, P4), reached only through this spawn.

/// How long between spawns, at most: a tick is 2s and firing on every one would spawn `sh` far more
/// often than the deliverer itself needs. `deliver.lock` (§5.3, `EventDelivery.swift`) already makes
/// an overlapping spawn a no-op, but there is no reason to pay the `Process()` cost for it.
private let eventDeliverySpawnInterval: TimeInterval = 10

/// True when `~/.tally/events` holds an undelivered event AND a sink is configured to receive it.
/// Both reads are best-effort: a directory that has never been written to (nothing has ever been
/// spooled, or delivery has never run) reads as "nothing to deliver" rather than an error, which is
/// the same silent-failure rule every other file in this feature keeps.
private func eventDeliveryOverdue(dir: URL = tallyEventsDir) -> Bool {
    guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("sink.json").path)
    else { return false }
    func counter(_ name: String) -> Int {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    }
    return counter("seq") > counter("cursor") + 1
}

/// This build's own absolute path, the repo's existing convention for a spawn that has to re-invoke
/// itself (`CodexInputRelay.swift:125`'s trampoline uses the same fallback chain): `Bundle.main`
/// resolves a CLI binary's own path even outside an app bundle, and `CommandLine.arguments.first`
/// covers the one case it does not (a build not yet linked into a bundle at all).
private func ownExecutablePath() -> String? {
    let path = Bundle.main.executablePath ?? CommandLine.arguments.first
    guard let path, !path.isEmpty else { return nil }
    return path
}

/// Called once per tick by both supervisors (`Supervisor.swift`, `CodexSupervisor.swift`), and once
/// more with `force` on each one's way out. Spawns at most once per `eventDeliverySpawnInterval`,
/// and only when `eventDeliveryOverdue()` says there is something worth sending; `last` is the
/// caller's own throttle clock, held across ticks and updated here only on an actual spawn.
///
/// `force` SKIPS THE THROTTLE, not the overdue check: a supervisor ending has just spooled its
/// `wait.resolved`/`session.ended`, and no tick of its own will ever come back to send them, so a
/// spawn ten seconds ago must not be the reason they wait for some other session to start.
///
/// `spawn` is the side effect, injectable so a test can count calls without starting a process.
func maybeSpawnEventDeliverer(now: Date, last: inout Date?, force: Bool = false,
                              dir: URL = tallyEventsDir,
                              spawn: () -> Void = spawnDetachedEventDeliverer) {
    if !force, let last, now.timeIntervalSince(last) < eventDeliverySpawnInterval { return }
    guard eventDeliveryOverdue(dir: dir) else { return }
    last = now
    spawn()
}

/// §14 revision 2, verbatim: `Process()` through `/bin/sh -c "... &"` rather than `posix_spawn`, so
/// this needs nothing beyond what `Foundation` already gives the rest of this file.
func spawnDetachedEventDeliverer() {
    spawnDetachedEventDeliverer(executable: ownExecutablePath())
}

/// The same spawn with the binary named by the caller, so a test can hand it a slow stand-in and
/// measure that the call returns while the stand-in is still running.
func spawnDetachedEventDeliverer(executable: String?) {
    guard let exe = executable else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "\"$0\" events --deliver-once </dev/null >/dev/null 2>&1 &", exe]
    p.standardInput = nil
    p.standardOutput = nil
    p.standardError = nil
    try? p.run()
    p.waitUntilExit()   // sh itself exits in milliseconds; the grandchild it backgrounded does not
}
