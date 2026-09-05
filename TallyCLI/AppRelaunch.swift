import Darwin
import Foundation

// Opening the app again when a silent Sparkle update took it away and never brought it back.
//
// THE INCIDENT (2026-09-05 19:23, v0.71.0). Sparkle installed the update in the background, the app
// quit for the swap as it always does, and nothing started it again: the menu bar icon was simply
// gone, and the user's first sign of an update was its absence. Two other automatic updates the
// same day relaunched normally, so the app itself is not at fault and nothing it could do would
// help. The relaunch is decided inside Sparkle's installer, in
// `InstallerProgressAppController.m registerApplicationBundlePath:reply:`: the moment the progress
// agent registers, it asks `runningApplicationsWithBundleIdentifier:` whether the app is still
// there, and an empty answer is recorded as `targetDead = YES`. `AppInstaller.m` then finishes the
// install and returns without launching anything. The app is already on its way out at that point
// and never learns the verdict, and 2.9.5 and 2.9.6 carry the same code.
//
// SO THE SUPERVISOR WATCHES FROM OUTSIDE. Every `tally claude` session has one, each already
// re-reads its own bundle's Info.plist on every tick (`supervisorBuildVersion`), and SelfUpdate.swift
// already turns "the installed version is newer than the one I captured" into a decision. This adds
// one more reading over the same fact: the app was running before the bundle was swapped, the swap
// happened, and the app has stayed away since. That triple only occurs when a relaunch was owed and
// did not happen, which is why it needs no cooperation from Sparkle and no new signal from the app.
//
// "STAYED AWAY SINCE" IS JUDGED AFTER THE SWAP, NEVER AT IT. The install finished at .751 the day of
// the incident and the app died at .775, so for those 24 milliseconds the bundle already carried the
// new version while the app was still running, and this station's reading of the process table can
// be five seconds older again. A rule that asked "is the app gone at the tick where the version
// changed" would therefore answer "no" in the very case it was written for. What the swap does is
// ARM; the two things that can happen next are the app returning (Sparkle's own relaunch, so there
// is nothing to do) and the app never leaving for a whole minute (this update was not what would
// have taken it away, so a quit hours later is the user's own).
//
// WHICH APP COUNTS AS ALIVE is the bundle THIS supervisor lives inside, matched on the executable
// path a process actually runs (`Contents/MacOS/<name>`), not on a process name: a second copy
// elsewhere on the machine, or the separately named Debug build, must not stand in for the one that
// just vanished. Both ways the reading can be wrong are safe. A false "dead" (a path we compare
// literally, a process we may not inspect) costs one `open -g` against an app that is already
// running, which macOS answers by doing nothing. A false "alive" costs nothing at all: the station
// stays quiet and the user opens the app by hand, which is exactly today's behaviour.
//
// ONE OPEN PER UPDATE, ACROSS EVERY SUPERVISOR ON THE MACHINE. Nine of them were resident the day
// of the incident, all watching the same bundle and all reaching the same conclusion within a few
// seconds of each other. The version being opened for is claimed as a filename under the supervisor
// state directory with `O_CREAT | O_EXCL`, so the create IS the decision and exactly one process
// wins it; the losers record the version as handled and stop asking.
//
// KNOWN BLIND SPOT. A supervisor that self-updates (`selfUpdateFold`, SelfUpdate.swift) inside the
// grace window below replaces itself with `execv`, and this station's observations are in memory
// only: the new image starts with no record that the app was alive under the previous version, so
// it will not open the app. Accepted rather than carried across: `ResuperviseContract.swift` is the
// argv contract two different BUILDS have to agree on, and the recovery is one `open` of an app the
// user can also open themselves. The other supervisors on the machine do not exec in step with this
// one, so in the multi-session case that is what covers it.

/// How long the app may stay away after the swap before this supervisor opens it. A normal Sparkle
/// relaunch has the app back within a second or two (measured on the two updates that worked the
/// same day), so this waits well past that: the cost of being early is a second app launch racing
/// Sparkle's own, and the cost of being late is fifteen quiet seconds nobody sees.
let appRelaunchGrace: TimeInterval = 15

/// How long after the swap the app may still be running before this station concludes the update
/// did not take it away. A Sparkle install sends the app its quit within a second of finishing, and
/// the incident's own timing had them 24 milliseconds apart, so an app still running a minute later
/// was never going anywhere: somebody dropped a new build over the top while the old code kept
/// running, and whenever they quit it after that is their business, not an owed relaunch.
let appRelaunchArmWindow: TimeInterval = 60

/// The shortest gap between two walks of the process table. The poll tick is far faster than this
/// and there can be nine supervisors on one machine, so the scan is throttled rather than run per
/// tick; the app's absence is a state that lasts, so a reading up to this old changes nothing.
let appRelaunchScanInterval: TimeInterval = 5

/// One file per version some supervisor has already opened the app for. A directory inside the
/// supervisor state directory rather than beside its per-pid files: the sweeps there read a
/// filename as a pid (`supervisorStatePid`), and this is not one.
let appRelaunchClaimDir = supervisorStateDir.appendingPathComponent("app-relaunch")

/// What one tick sees: the version installed in this supervisor's bundle right now, whether the app
/// from that bundle is running, and when the reading was taken.
struct AppPresence: Equatable {
    var installedVersion: String?
    var appAlive: Bool
    var at: Date
}

/// The process table, asked at most every `appRelaunchScanInterval` and answered from the last walk
/// in between.
struct AppPresenceScan: Equatable {
    private var lastAt: Date?
    private var lastAlive = false

    mutating func alive(now: Date, interval: TimeInterval = appRelaunchScanInterval,
                        probe: () -> Bool) -> Bool {
        if let lastAt, now.timeIntervalSince(lastAt) < interval { return lastAlive }
        lastAt = now
        lastAlive = probe()
        return lastAlive
    }
}

/// Everything this station remembers between ticks. All of it in memory, for the reason the header
/// gives: nothing here outlives the process, and nothing here is worth an exec contract.
struct AppRelaunchState: Equatable {
    /// The most recent version observed, and whether the app was running the last time it was seen
    /// under it. The pair is what tells "the user quit the app and an update landed later" (nothing
    /// to do) from "the update took the app away" (the case this station exists for).
    var seenVersion: String?
    var seenAlive = false
    /// The version a swap moved to while the app was running, when that arming happened, and when
    /// the app was first seen missing under that version. Cleared the moment the app comes back,
    /// which is what a Sparkle relaunch that worked looks like from here.
    var pendingVersion: String?
    var armedAt: Date?
    var missingSince: Date?
    /// The versions this process has already settled: opened the app for, or lost the claim on.
    var openedVersions: Set<String> = []
    var scan = AppPresenceScan()
}

/// Fold `observation` into `state` and answer with the version this supervisor should open the app
/// for, or nil to do nothing. Pure apart from `claim`, so every gate is testable without a bundle,
/// a process table, or a filesystem.
///
/// The order of the gates is the order of the facts they rest on: a version must be readable at all
/// (a dev or standalone build reports nil and is never in this game), the version must have moved
/// FORWARD (`isNewerBuild`, shared with the self-update so a downgrade or an unparseable version
/// reads the same way in both places), the app must have been running immediately before that move,
/// and it must still be missing once the grace has passed.
///
/// ARMING ON THE SWAP, NOT ON THE APP BEING GONE AT THAT INSTANT. The tick that notices the swap
/// very often still reads the app as alive: the installer finished 24 milliseconds before the app
/// died the day of the incident, and the reading itself can be `appRelaunchScanInterval` older than
/// that again. So the swap arms, and what happens afterwards decides. The app coming back after an
/// absence is Sparkle's own relaunch and disarms; the app never going away at all for
/// `appRelaunchArmWindow` means this update was not what would have taken it, which disarms too.
func appRelaunchDue(_ state: inout AppRelaunchState, observation: AppPresence,
                    grace: TimeInterval = appRelaunchGrace,
                    claim: (String) -> Bool) -> String? {
    guard let installed = observation.installedVersion else { return nil }
    defer {
        state.seenVersion = installed
        state.seenAlive = observation.appAlive
    }
    if let previous = state.seenVersion, previous != installed,
       isNewerBuild(installed, than: previous), state.seenAlive {
        state.pendingVersion = installed
        state.armedAt = observation.at
        state.missingSince = nil
    }
    guard let pending = state.pendingVersion, pending == installed else { return nil }
    func disarm() -> String? {
        state.pendingVersion = nil
        state.armedAt = nil
        state.missingSince = nil
        return nil
    }
    if observation.appAlive {
        // The app was here a moment ago and is here now. Which of the two that means depends on
        // whether it has been away in between: if it has, Sparkle brought it back on its own, which
        // is what happens every other time. If it has not, the app simply has not gone yet - the
        // reading can be `appRelaunchScanInterval` old and the incident's app outlived its own
        // installer by 24 milliseconds - so keep waiting, up to the arming window.
        guard state.missingSince == nil else { return disarm() }
        guard let armedAt = state.armedAt,
              observation.at.timeIntervalSince(armedAt) < appRelaunchArmWindow else {
            return disarm()
        }
        return nil
    }
    guard let since = state.missingSince else {
        state.missingSince = observation.at
        return nil
    }
    guard observation.at.timeIntervalSince(since) >= grace,
          !state.openedVersions.contains(pending) else { return nil }
    // Settled either way: this supervisor opens the app, or another one already has.
    state.openedVersions.insert(pending)
    _ = disarm()
    return claim(pending) ? pending : nil
}

/// Claim the one open this version gets across every supervisor on the machine. True means this
/// process won it. `O_CREAT | O_EXCL` on a name every supervisor derives the same way, so the create
/// is the whole decision and there is nothing else to protect; a claim that cannot be written loses,
/// on the same terms as everything else here (not opening costs the user one manual launch, opening
/// nine times costs them nine).
///
/// The claims of other versions are removed once a newer one is taken: they are debris from updates
/// already dealt with, and leaving them would grow one file per release forever.
func claimAppRelaunch(_ version: String, dir: URL = appRelaunchClaimDir) -> Bool {
    guard !version.isEmpty,
          version.allSatisfy({ $0.isNumber || $0.isLetter || $0 == "." || $0 == "-" }),
          version != ".", version != ".." else { return false }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fd = open(dir.appendingPathComponent(version).path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
    guard fd >= 0 else { return false }
    close(fd)
    let stale = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    for name in stale where name != version {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }
    return true
}

/// The app bundle this `tally` binary is embedded in: the bundle to open, and the executable a live
/// app process would be running. nil when the binary is not inside a bundle at all (a dev or
/// standalone build), which is the same answer `supervisorBuildVersion` gives about the same layout.
struct AppBundlePaths: Equatable {
    var bundle: String
    var executable: String
}

/// The CLI lives at `<App>.app/Contents/Helpers/tally`, so two directories up is `Contents` and
/// three is the bundle. The path is resolved first for the reason `supervisorBuildVersion` resolves
/// it: the installed command is a symlink from /usr/local/bin and walking up from there lands
/// nowhere. The executable's NAME comes from the same Info.plist rather than from the bundle's
/// directory name, so the Debug build ("Tally Dev") is matched as itself and a bundle somebody
/// renamed on disk is still matched correctly.
func bundledAppPaths(_ executable: URL? = Bundle.main.executableURL) -> AppBundlePaths? {
    guard let exe = executable?.resolvingSymlinksInPath() else { return nil }
    let contents = exe.deletingLastPathComponent().deletingLastPathComponent()
    guard contents.lastPathComponent == "Contents" else { return nil }
    let plistURL = contents.appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: plistURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
              as? [String: Any],
          let name = plist["CFBundleExecutable"] as? String, !name.isEmpty else { return nil }
    return AppBundlePaths(
        bundle: contents.deletingLastPathComponent().path,
        executable: contents.appendingPathComponent("MacOS").appendingPathComponent(name).path)
}

/// Whether any process on this machine is running the executable at `path`. One walk of the process
/// table with one `proc_pidpath` per pid, rather than a `pgrep` spawned on every tick of every
/// supervisor. How far the buffer may be read comes from `scannedPidCount` (ReloadRequest.swift),
/// which documents why the second `proc_listallpids` return must not be divided by the pid size.
/// Processes we cannot inspect simply drop out, which reads as "not this one" - the safe direction
/// (see the header: a false "dead" costs an `open` macOS ignores).
func appProcessAlive(_ path: String) -> Bool {
    let capacity = proc_listallpids(nil, 0)
    guard capacity > 0 else { return false }
    var pids = [pid_t](repeating: 0, count: Int(capacity))
    let returned = proc_listallpids(&pids, Int32(Int(capacity) * MemoryLayout<pid_t>.size))
    // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is not imported into Swift; use its literal value.
    var buffer = [CChar](repeating: 0, count: 4 * 1024)
    for pid in pids.prefix(scannedPidCount(returned, capacity: pids.count)) where pid > 0 {
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
        let running = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        if running == path { return true }
    }
    return false
}

/// Start the app again, in the background: `-g` so a session the user is typing into does not have
/// the app steal the foreground, and the bundle path rather than the bundle id so the copy that is
/// opened is the one this supervisor lives in. Announced first, because an app appearing on its own
/// deserves the same one line an update restarting a session gets.
///
/// A failure is reported and dropped. There is no retry by design: the caller has already recorded
/// the version as settled, so a bundle that will not open is one line on the terminal rather than
/// one line every fifteen seconds for the rest of the session.
func openAppBundle(_ path: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        warn("could not open the app (\(error.localizedDescription))")
        return
    }
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        warn("could not open the app (open exited \(process.terminationStatus))")
    }
}

/// One poll tick of this station: take the reading, ask the decision, and act on it. The whole
/// station is this one call so the supervisor loop keeps its headroom, and every input is injectable
/// so the tick can be driven from a harness.
///
/// The announcement is injectable for a reason of the harness's own: `warn` writes to the terminal
/// the assertions are printed on, and a line arriving mid-print splits one of them, which is the
/// same interleaving `run-supervisor-tests.sh` warns about where it counts them.
func applyAppRelaunch(_ state: inout AppRelaunchState, now: Date = Date(),
                      installed: String? = supervisorBuildVersion(),
                      bundle: AppBundlePaths? = bundledAppPaths(),
                      probe: ((String) -> Bool)? = nil,
                      claim: @escaping (String) -> Bool = { claimAppRelaunch($0) },
                      announce: (String) -> Void = { warn($0) },
                      launch: (String) -> Void = openAppBundle) {
    guard let bundle else { return }
    let alive = state.scan.alive(now: now) { (probe ?? appProcessAlive)(bundle.executable) }
    let seen = AppPresence(installedVersion: installed, appAlive: alive, at: now)
    guard let target = appRelaunchDue(&state, observation: seen, claim: claim) else { return }
    announce("tally updated to \(target) but the app did not come back, opening it")
    launch(bundle.bundle)
}
