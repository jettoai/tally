import Darwin
import Foundation

// Supervisor self-update: after Sparkle swaps the app bundle, a supervisor that is already running
// still executes the OLD binary's logic and keeps stamping the old version into its child, which is
// what the status line reports as "supervisor updating at next idle". Restarting the child cannot
// fix that (the stamp is decided by the supervisor), so the supervisor replaces ITSELF - at the
// next idle moment, or straight away on a restart another reason is already making (`selfUpdateFold`
// below, which is why the status line promises the next idle rather than a manual restart).
//
// Detection needs no new machinery: `supervisorBuildVersion()` resolves the running executable's
// path and reads the enclosing bundle's Info.plist on every call, so once the bundle is replaced a
// fresh call returns the new version while the value captured at startup still holds the old one.
// Verified live (2026-07-25): a process launched through a symlink into a bundle reported 0.25.0,
// the bundle was replaced under it the way an installer does (move aside, move the new one in), and
// the very next call in the SAME process returned 0.26.0. While the path is momentarily absent
// mid-install the call returns nil, which reads as "nothing to do".
//
// The replacement is an execv of the same path: the pid and the terminal's foreground process group
// survive, so the supervisor-state registration, the status line, and the user's terminal are all
// untouched. In-memory state resets, which is acceptable for the session-local quarantine (the
// shared per-account files outlive the exec anyway) but NOT for the recovery fuse: "at most 3
// automatic recoveries in 10 minutes" is a promise about the user's session, and every restart it
// permits is a conversation visibly interrupted. Two recoveries spent, the account not capped at
// that instant, the app updates, and a reset fuse would let the same session be restarted three
// more times. So the fuse's recorded recoveries ride across in the argv below, as absolute times.
//
// Everything else that is a promise about the SESSION rather than about this process rides the same
// way, and for the same reason: the pins a `tally switch` left, and the cap recovery the session is
// still waiting out. Each is a flag below with its own note on what an absent one has to mean.
//
// LOAD-BEARING ACROSS VERSIONS: `__resupervise` and its flags are a contract between two DIFFERENT
// builds, not an internal detail. The old build writes the argv; the NEW build's parser reads it.
// Rename the subcommand, remove a flag, or change what one means, and every session that upgrades
// into that release dies at the exec: its child has already been terminated, the new image does not
// recognise the command, prints the usage text, exits 2, and the user is left staring at a shell
// prompt where their conversation was. The upgrade-only gate cannot protect against this, because
// the build they land on is by definition the newer one. Adding a new OPTIONAL flag is safe (an old
// build simply never writes it, and the parser must keep defaulting sensibly when it is absent);
// renaming or removing anything here is not. If it ever has to change, ship a release that accepts
// both spellings first, and drop the old one only once no supervisor predating that release can
// still be running. `parseResuperviseArgs` is round-trip tested against `selfUpdateArgv` for the
// same reason: the two halves are one contract.

/// How long this supervisor must have been running its current child before it may replace itself.
/// The brake on a pathological environment (a half-installed bundle whose plist reads differently
/// on consecutive calls): with it, a self-update can happen at most once a minute per session.
let selfUpdateMinUptime: TimeInterval = 60

/// The version an exec was aiming for, handed to the new process through its environment so it can
/// recognise "I am the upgrade that was already attempted for this exact target" and refuse to go
/// again. Without it, a bundle that keeps reporting the old version after the swap would have every
/// generation exec once more, forever.
let selfUpdateTargetEnvKey = "TALLY_SELF_UPDATE_TARGET"

/// The internal subcommand a self-update re-enters through. Not a user-facing command (it is absent
/// from the usage text on purpose): it carries the account and the conversation across the exec so
/// the new supervisor resumes exactly what the old one was watching, with no re-picking.
let resuperviseCommand = "__resupervise"

/// Whether `installed` is a LATER release than `captured`, compared component by component so 0.10.0
/// beats 0.9.0 (a string compare has that backwards). A version that is not plain dotted integers
/// answers false: staying on a build that works beats exec'ing into one we cannot reason about.
func isNewerBuild(_ installed: String, than captured: String) -> Bool {
    func components(_ version: String) -> [Int]? {
        let fields = version.split(separator: ".").map { Int($0) }
        guard !fields.isEmpty, !fields.contains(nil) else { return nil }
        return fields.compactMap { $0 }
    }
    guard let new = components(installed), let old = components(captured) else { return false }
    for index in 0 ..< max(new.count, old.count) {
        let left = index < new.count ? new[index] : 0
        let right = index < old.count ? old[index] : 0
        if left != right { return left > right }
    }
    return false
}

/// The version this supervisor should upgrade itself to, or nil to stay put. Pure so every gate is
/// testable without a bundle or a child.
///
/// Every condition must hold: the installed version is NEWER than the one captured at startup (both
/// present - a dev or standalone build reports nil and never self-updates); this is not the target a
/// previous exec already tried; no other relaunch is planned this tick; the session is idle by the
/// same rule a reload uses; and the child has been up past the loop-safety floor. Anything else
/// simply returns nil and the next tick asks again.
///
/// A PENDING CAP RECOVERY used to be one of those conditions, and retiring it is what the
/// `--pending-cap` flag below exists for. The gate rested on "waiting for the cap to resolve is
/// simpler than serialising it", which assumed the wait is short. It is not: that wait is for a
/// sibling account to free up, which is hours, so the gate did not defer the upgrade - it CANCELLED
/// it, and a capped session could never take one at all. Live, 2026-08-06: pid 67853 hit a cap at
/// 20:44, was manually moved to another account, and hours later was still running 0.38.0 while the
/// nine other supervisors on the machine had all moved to 0.38.1 - which is the release that fixes
/// the bug leaving its pending cap uncleared. The one session that needed the new build was the only
/// one this rule kept from having it. The state the gate protected rides across the exec in the argv
/// now, so there is nothing left to wait for.
///
/// Newer, not merely different, because the exec is one-way: the child is already gone when the new
/// image starts, so a build that does not understand the `__resupervise` subcommand prints the usage
/// text and exits, and the session dies with it. Every older build is such a build. Downgrades happen
/// (an older DMG installed over the top, a Release rebuilt from an earlier checkout), and a bundle
/// that alternates between two versions would otherwise exec on every single tick that clears.
func selfUpdateTarget(captured: String?, installed: String?, isQuiet: Bool, relaunchPlanned: Bool,
                      uptime: TimeInterval, attempted: String?) -> String? {
    guard let captured, let installed, isNewerBuild(installed, than: captured) else { return nil }
    guard installed != attempted else { return nil }
    guard !relaunchPlanned, isQuiet, uptime >= selfUpdateMinUptime else { return nil }
    return installed
}

/// The flag carrying the recovery fuse's recorded recoveries across the exec, so the limit holds
/// for the SESSION rather than for the process. Optional by construction: a supervisor with an
/// empty fuse writes no flag at all, which is also what every build predating it wrote.
let resuperviseFuseFlag = "--fuse"

/// The flag carrying the account a `tally switch` pinned this session to (SessionSwitch.swift), for
/// the same reason the fuse rides along: the pin is a promise about the user's SESSION, and it lives
/// in memory only. Without it, the first quiet tick after an upgrade would hand the session back to
/// automatic selection - a nearly dry account rebalances it away, and the account the user named
/// silently stops being the one they are on.
///
/// A NEW optional flag rather than a new meaning for `--pin-override` below, because the two halves
/// of this argv are written by different BUILDS: an old supervisor writes the pin it moved the
/// session OFF, and reading that as the pin it was moved ONTO would name the wrong account. Optional
/// by construction, like the fuse - an unpinned session writes no flag, and so does every build
/// predating this one, which is exactly the behaviour those builds had.
let resuperviseSessionPinFlag = "--session-pin"

/// The flag carrying the pin a `tally switch` took this session OFF (SessionSwitch.swift), for the
/// same reason the fuse rides along: it is a promise about the user's session, not about this
/// process. Without it the new image starts with no override, and the first quiet tick after an
/// upgrade hands the session straight back to the pin it was deliberately moved away from - undoing
/// an instruction the user gave by hand, minutes later, for no reason they can see.
///
/// Optional by construction, like the fuse: a session that never overrode a pin writes no flag, and
/// so does every build predating this one. An absent flag means "no override", which is exactly the
/// behaviour those builds had.
///
/// Nothing in this build WRITES it any more (a switch records a session pin instead, which outranks
/// every pin rather than only the one it overrode), and it is still parsed and still forwarded: a
/// session that upgrades out of a build that wrote one arrives holding it, and dropping it there
/// would undo that session's switch on its first quiet tick.
let resupervisePinOverrideFlag = "--pin-override"

/// The fuse's recoveries as a flag value: absolute epoch seconds, comma separated. Absolute, not
/// "N seconds ago", because the exec takes real time (and can be delayed by a slow disk mid-install)
/// and durations re-based on arrival would silently stretch the window they are measured in.
func encodeRecoveryFuse(_ recoveries: [Date]) -> String {
    recoveries.map { String($0.timeIntervalSince1970) }.joined(separator: ",")
}

/// The recoveries a previous build wrote, or none. Anything unreadable answers empty rather than a
/// partial list: the value comes from a DIFFERENT build, so a shape we cannot fully parse is a
/// disagreement about the format, and half-believing it would put an arbitrary number of recoveries
/// into the new fuse. Empty degrades to exactly today's behaviour (a fresh fuse), never to a crash.
func decodeRecoveryFuse(_ raw: String) -> [Date] {
    guard !raw.isEmpty else { return [] }
    var recoveries: [Date] = []
    for field in raw.split(separator: ",", omittingEmptySubsequences: false) {
        guard let epoch = Double(field), epoch.isFinite else { return [] }
        recoveries.append(Date(timeIntervalSince1970: epoch))
    }
    return recoveries
}

/// The flag carrying the cap recovery this session is still waiting on, for the same reason the fuse
/// rides along: it is a promise about the SESSION - which account capped, when, when the window it
/// capped on refills, when to retry the handoff, and what the status line is currently saying about
/// the wait - and it lives in memory only. Without it the new image comes back with nothing left to
/// notice a sibling freeing up, and the session waits on a dead account until its user hits the wall
/// a second time: the same failure `capCarriedAcrossRelaunch` (SupervisorRuntime.swift) exists to
/// prevent one child later. That function decides WHETHER the state survives a given relaunch; this
/// flag is only how it gets across an exec, and a self-update relaunch is one it carries.
///
/// JSON, where the fuse uses a delimited list, because these fields are not all numbers: the waiting
/// note is a sentence containing commas and parentheses, and an account id can be a path. One argv
/// token either way. Optional by construction, like every flag here - a session with no pending cap
/// writes nothing, which is also what every build predating this one wrote, and an old parser
/// reading an argv it does not recognise skips the flag and its value as two unknown words.
let resupervisePendingCapFlag = "--pending-cap"

/// A pending cap recovery as a flag value: one JSON object, with absolute epoch seconds for the
/// times for the reason the fuse uses them - the exec takes real time, and a duration re-based on
/// arrival would silently move the boundary it names. Keys are sorted so a given state always spells
/// the same argv. nil when the value cannot be serialised at all, which writes no flag: a state we
/// cannot spell in full is one the new image must not receive in part.
func encodePendingCap(_ pending: PendingCapRecovery) -> String? {
    var fields: [String: Any] = [
        "account": pending.cappedAccountID,
        "cappedAt": pending.cappedAt.timeIntervalSince1970,
        "nextRetry": pending.nextRetry.timeIntervalSince1970,
        "reason": pending.reason,
    ]
    if let model = pending.primaryModel { fields["model"] = model }
    if let resets = pending.recoveryResetsAt { fields["resets"] = resets.timeIntervalSince1970 }
    guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return nil }
    return text
}

/// The pending cap a previous build wrote, or none. Anything unreadable answers nil rather than a
/// partial record, for the reason `decodeRecoveryFuse` gives: the value comes from a DIFFERENT
/// build, so a shape we cannot fully parse is a disagreement about the format. Half-believing one is
/// worse here than dropping it - a record that lost `resets` is a session whose badge can never
/// clear itself, and one that lost `model` scores every handoff candidate against the wrong quota
/// window - so a key that is present but unreadable discards the whole value. Keys a later build
/// adds are ignored; keys genuinely absent are genuinely absent (no reset boundary the snapshot
/// could name, no model this session pinned).
func decodePendingCap(_ raw: String) -> PendingCapRecovery? {
    func seconds(_ value: Any?) -> Date? {
        guard let epoch = value as? Double, epoch.isFinite else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }
    guard let data = raw.data(using: .utf8),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let account = object["account"] as? String, !account.isEmpty,
          let cappedAt = seconds(object["cappedAt"]), let nextRetry = seconds(object["nextRetry"]),
          let reason = object["reason"] as? String
    else { return nil }
    var model: String?
    if let value = object["model"] {
        guard let text = value as? String, !text.isEmpty else { return nil }
        model = text
    }
    var resets: Date?
    if let value = object["resets"] {
        guard let date = seconds(value) else { return nil }
        resets = date
    }
    return PendingCapRecovery(cappedAccountID: account, cappedAt: cappedAt, primaryModel: model,
                              recoveryResetsAt: resets, nextRetry: nextRetry, reason: reason)
}

/// The argv an upgrade execs. Continuity is spelled out rather than re-derived: the account is named
/// explicitly so the new supervisor cannot re-pick a different one, and `args` already carries the
/// `--resume <session>` the relaunch path produced, so the conversation is pinned by id. Passing the
/// original launch argv instead would let the new process pick another account and then follow a
/// bare `--continue` into whatever conversation happens to be newest there. `recoveries` is the
/// recovery fuse's live record (already pruned by `RecoveryFuse.carried`), and `pendingCap` the cap
/// state the relaunch this exec rides on decided to hand over (`capCarriedAcrossRelaunch`), so the
/// new image inherits exactly what the next CHILD would have inherited had there been no upgrade.
func selfUpdateArgv(binary: String, id: String, label: String, home: String, follow: Bool,
                    recoveries: [Date] = [], sessionPin: String? = nil,
                    pinOverride: String? = nil, pendingCap: PendingCapRecovery? = nil,
                    args: [String]) -> [String] {
    var argv = [binary, resuperviseCommand, "--id", id, "--label", label, "--home", home,
                follow ? "--follow" : "--no-follow"]
    if !recoveries.isEmpty { argv += [resuperviseFuseFlag, encodeRecoveryFuse(recoveries)] }
    if let sessionPin, !sessionPin.isEmpty {
        argv += [resuperviseSessionPinFlag, sessionPin]
    }
    if let pinOverride, !pinOverride.isEmpty {
        argv += [resupervisePinOverrideFlag, pinOverride]
    }
    if let pendingCap, let encoded = encodePendingCap(pendingCap) {
        argv += [resupervisePendingCapFlag, encoded]
    }
    return argv + ["--"] + args
}

/// The path this process would exec, but only when something runnable is actually there right now.
/// Checked BEFORE the child is terminated: an installer swapping the bundle makes the path vanish
/// for a moment, and paying for that with the session's child (killed for an exec that was never
/// going to work) is the one failure worth spending a filesystem check to avoid. A tick that finds
/// nothing simply does nothing and the next one asks again.
func selfUpdateBinary(_ candidate: String? = Bundle.main.executableURL?.path) -> String? {
    guard let candidate, FileManager.default.isExecutableFile(atPath: candidate) else { return nil }
    return candidate
}

/// The target a previous exec was aiming for, consumed from the environment so it neither leaks into
/// the child nor outlives the check it exists for.
func consumeSelfUpdateAttempt() -> String? {
    guard let raw = getenv(selfUpdateTargetEnvKey) else { return nil }
    let value = String(cString: raw)
    unsetenv(selfUpdateTargetEnvKey)
    return value
}

/// Replace this process with the new build. Returns ONLY when the exec failed (the bundle vanished
/// mid-install, say), leaving the caller to relaunch the child and stay on the build it has - the
/// caller records the attempt first, so an unreachable target is tried once, not every minute for
/// the life of the session; on success nothing after the execv runs. Announced first: an app update
/// silently restarting a session is exactly the surprise the dialogs elsewhere exist to avoid.
func execSelfUpdate(to target: String, id: String, label: String, home: String, follow: Bool,
                    recoveries: [Date] = [], sessionPin: String? = nil, pinOverride: String? = nil,
                    pendingCap: PendingCapRecovery? = nil,
                    args: [String], binary: String? = Bundle.main.executableURL?.path) {
    guard let binary else { return }
    warn("tally updated to \(target), restarting this session on the new build")
    setenv(selfUpdateTargetEnvKey, target, 1)
    let argv = selfUpdateArgv(binary: binary, id: id, label: label, home: home, follow: follow,
                              recoveries: recoveries, sessionPin: sessionPin,
                              pinOverride: pinOverride, pendingCap: pendingCap, args: args)
    var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cargs.append(nil)
    execv(binary, &cargs)
    // Only reached when the exec failed. Drop the marker again so it does not ride into the child
    // this supervisor is about to relaunch; the caller's in-memory record is what keeps this target
    // from being chased a second time.
    let failure = String(cString: strerror(errno))
    unsetenv(selfUpdateTargetEnvKey)
    for pointer in cargs { free(pointer) }
    warn("could not start the new build (\(failure)), staying on this one")
}

/// Everything one poll tick needs to know to replace this supervisor: the version to reach, the
/// executable to exec, and the home to pass on. nil on every tick but one, and nil is the answer to
/// anything unclear. The gates live here rather than inline in the supervisor loop so that file
/// keeps its headroom; the caller then performs the three steps in order (record the attempt,
/// terminate the child, exec).
///
/// Deliberately values in and values out, with no closure and no `inout`. The first shape of this
/// took the watcher `inout` and a `stopChildAndResume` closure, which meant Swift held an exclusive
/// access to the caller's watcher while the closure's handoff mutated the same variable: the process
/// died with "Fatal access conflict detected" the moment an upgrade fired (caught by an end-to-end
/// run, 2026-07-25, since no unit test and no compiler check sees it). Plain parameters cannot
/// reintroduce that.
///
/// A missing home means no `--home` to pass, and the new build refuses that argv: it could only end
/// the session. Unreachable in practice (the loop force-unwraps the same value to spawn each child),
/// and cheap to make impossible. The executable is checked for real BEFORE the caller kills anything.
func selfUpdateDue(captured: String?, attempted: String?, isQuiet: Bool, relaunchPlanned: Bool,
                   uptime: TimeInterval, home: String?,
                   installed: String? = supervisorBuildVersion(),
                   binary: String? = selfUpdateBinary())
    -> (target: String, binary: String, home: String)? {
    guard let home, let binary,
          let target = selfUpdateTarget(captured: captured, installed: installed, isQuiet: isQuiet,
                                        relaunchPlanned: relaunchPlanned,
                                        uptime: uptime, attempted: attempted)
    else { return nil }
    return (target, binary, home)
}

/// Carry out the upgrade a planned relaunch folded in, if there is one. The attempt is recorded
/// BEFORE the exec, and both live here so no caller can do one without the other: a successful exec
/// carries the record across in the environment, a failed one leaves nothing behind, and without it
/// the session would chase the same unreachable build on every relaunch for the rest of its life.
/// The account named is the one the plan MOVED TO (the exec must resume where the handoff put the
/// conversation, not on the account it left), and the fuse rides along - an upgrade spends no
/// recovery budget, but it must not refund what the session has already spent either. So do the
/// session pin and the overridden pin, for the same reason: all three are promises about the
/// session, and all three are in memory only. So does the pending cap this relaunch chose to hand on
/// (`pendingCap`, the caller's `carriedCap`): passing the CARRIED value rather than the live one is
/// what makes a failed exec and a successful one leave the session in the same place, since the
/// respawn the caller falls through to reads that same variable. Returns normally only when there
/// was nothing to do or the exec failed, leaving the caller to respawn.
func execPlannedSelfUpdate(_ upgrade: (target: String, binary: String, home: String)?,
                           attempted: inout String?, target: Snapshot.Account,
                           follow: Bool, recoveries: [Date], sessionPin: String? = nil,
                           pinOverride: String? = nil, pendingCap: PendingCapRecovery? = nil,
                           args: [String]) {
    guard let upgrade else { return }
    attempted = upgrade.target
    execSelfUpdate(to: upgrade.target, id: target.id, label: target.label, home: upgrade.home,
                   follow: follow, recoveries: recoveries, sessionPin: sessionPin,
                   pinOverride: pinOverride, pendingCap: pendingCap, args: args,
                   binary: upgrade.binary)
}

/// The upgrade a relaunch ALREADY happening this tick should carry, or nil to come back on the build
/// we have. Same target checks as `selfUpdateDue` (installed, newer, real, executable, not already
/// attempted) with the two waiting gates neutralised, because they exist to protect a restart that
/// would otherwise not happen: the child is being terminated either way, so there is no idle moment
/// left to wait for and no loop for the uptime floor to brake. Deferring instead is what charged the
/// user two visible restarts minutes apart (a cap handoff at 06:34, the self-update at 06:36,
/// 2026-07-26): after the handoff, the child's age and the quiet bar both start over.
///
/// A relaunch carrying a pending cap used to be refused here as well (`capCarried`), on the grounds
/// that the exec would drop the one piece of state the plan does not itself resolve. It no longer
/// drops it - the carried record rides in the argv (`resupervisePendingCapFlag`) - so the refusal
/// bought nothing and cost the same deferral twice over.
func selfUpdateFold(captured: String?, attempted: String?, home: String?,
                    installed: String? = supervisorBuildVersion(),
                    binary: String? = selfUpdateBinary())
    -> (target: String, binary: String, home: String)? {
    selfUpdateDue(captured: captured, attempted: attempted,
                  isQuiet: true, relaunchPlanned: false,
                  uptime: selfUpdateMinUptime, home: home,
                  installed: installed, binary: binary)
}

/// Parse the exec contract's flags. Pure, and round-trip tested against `selfUpdateArgv`: the two
/// halves are written by different BUILDS of this program, so a silent disagreement between them
/// would strand exactly the sessions that were mid-upgrade. Values are taken positionally, so a
/// label that looks like a flag (`--label --home`) is still a label; a missing or trailing `--`
/// yields no child args rather than an error, because the supervisor can still resume without them.
/// An absent `--fuse` (every build before it, and any supervisor whose fuse was empty) means no
/// recoveries, which is the fresh-fuse behaviour this contract had all along; an absent
/// `--session-pin` means the session was never pinned by hand, an absent `--pin-override` means it
/// never overrode a pin, and an absent `--pending-cap` means the session was not waiting on a cap,
/// which is what every build before each flag effectively said too.
func parseResuperviseArgs(_ args: [String]) -> (id: String, label: String, home: String,
                                                follow: Bool, recoveries: [Date],
                                                sessionPin: String?, pinOverride: String?,
                                                pendingCap: PendingCapRecovery?,
                                                childArgs: [String]) {
    var id = "", label = "", home = ""
    var follow = true
    var recoveries: [Date] = []
    var sessionPin: String?
    var pinOverride: String?
    var pendingCap: PendingCapRecovery?
    var childArgs: [String] = []
    var index = 0
    while index < args.count {
        let argument = args[index]
        func value() -> String {
            index + 1 < args.count ? args[index + 1] : ""
        }
        switch argument {
        case "--id": id = value(); index += 2
        case "--label": label = value(); index += 2
        case "--home": home = value(); index += 2
        case resuperviseFuseFlag: recoveries = decodeRecoveryFuse(value()); index += 2
        // An empty value is no pin rather than a pin on "": these flags are only written with a
        // real account id, so an empty one is a disagreement about the format, and the safe reading
        // of it is the behaviour of every build that never wrote the flag at all.
        case resuperviseSessionPinFlag:
            sessionPin = value().isEmpty ? nil : value()
            index += 2
        case resupervisePinOverrideFlag:
            pinOverride = value().isEmpty ? nil : value()
            index += 2
        case resupervisePendingCapFlag: pendingCap = decodePendingCap(value()); index += 2
        case "--follow": follow = true; index += 1
        case "--no-follow": follow = false; index += 1
        case "--":
            childArgs = Array(args[(index + 1)...])
            index = args.count
        default: index += 1
        }
    }
    return (id, label, home, follow, recoveries, sessionPin, pinOverride, pendingCap, childArgs)
}

/// `tally __resupervise --id <id> --label <label> --home <path> --follow|--no-follow
/// [--fuse <epochs>] [--session-pin <accountID>] [--pin-override <accountID>]
/// [--pending-cap <json>] -- <args...>`: the other side of the exec. Rebuilds the account from what
/// the previous supervisor passed rather than from the snapshot (which may be stale, or missing the
/// account entirely at that instant) and resumes supervision, with the recovery fuse, the pins, and
/// any cap this session is still waiting out continuing where that supervisor left off. Only the id,
/// label, and home are ever read from an account by the loop; the quota fields are always re-read
/// from the live snapshot, so leaving them empty here is safe.
func runResupervise(args: [String]) -> Never {
    let (id, label, home, follow, recoveries, sessionPin, pinOverride, pendingCap, childArgs) =
        parseResuperviseArgs(args)
    guard !home.isEmpty else {
        warn("\(resuperviseCommand) needs --home; this is an internal command")
        exit(2)
    }
    let provider = providers[0]   // supervision is claude-only, as everywhere else
    let account = Snapshot.Account(
        id: id.isEmpty ? home : id, provider: provider.id,
        label: label.isEmpty ? URL(fileURLWithPath: home).lastPathComponent : label,
        launchHome: home, sessionRemaining: nil, weeklyRemaining: nil, modelRemaining: nil,
        sessionResetsAt: nil, weeklyResetsAt: nil, modelResetsAt: nil, modelWindowName: nil,
        resetCreditsAvailable: nil, isStale: false, error: nil)
    // `resumed`: this process replaced a supervisor whose child was already terminated, so the very
    // first spawn below continues a running conversation rather than starting the user's session.
    runSupervised(provider, account: account, args: childArgs, follow: follow,
                  recoveries: recoveries, resumed: true, sessionPin: sessionPin,
                  pinOverride: pinOverride, pendingCap: pendingCap)
}
