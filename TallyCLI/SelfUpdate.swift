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
// way, and for the same reason: the pins a `tally switch` left, the pair a `tally model` pinned, and
// the cap recovery the session is still waiting out. How each of those is SPELLED in the argv is
// next door in ResuperviseContract.swift, which is the half a different BUILD has to agree with;
// what is here is only the decision to replace this process at all.

/// How long this supervisor must have been running its current child before it may replace itself.
/// The brake on a pathological environment (a half-installed bundle whose plist reads differently
/// on consecutive calls): with it, a self-update can happen at most once a minute per session.
let selfUpdateMinUptime: TimeInterval = 60

/// The version an exec was aiming for, handed to the new process through its environment so it can
/// recognise "I am the upgrade that was already attempted for this exact target" and refuse to go
/// again. Without it, a bundle that keeps reporting the old version after the swap would have every
/// generation exec once more, forever.
let selfUpdateTargetEnvKey = "TALLY_SELF_UPDATE_TARGET"

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
                    pendingCap: PendingCapRecovery? = nil, sessionModel: SessionModelPin? = nil,
                    lastConversation: String? = nil,
                    args: [String], binary: String? = Bundle.main.executableURL?.path) {
    guard let binary else { return }
    warn("tally updated to \(target), restarting this session on the new build")
    setenv(selfUpdateTargetEnvKey, target, 1)
    let argv = selfUpdateArgv(binary: binary, id: id, label: label, home: home, follow: follow,
                              recoveries: recoveries, sessionPin: sessionPin,
                              pinOverride: pinOverride, pendingCap: pendingCap,
                              sessionModel: sessionModel, lastConversation: lastConversation,
                              args: args)
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
/// respawn the caller falls through to reads that same variable. `sessionModel` is the pair a
/// `tally model` pinned, on the same terms as the account pin: an upgrade that dropped it would put
/// the session back on the fleet default a minute after the user chose otherwise. `lastConversation`
/// is what this supervisor has already published as the last conversation watched in its directory,
/// on the same terms again: an upgrade that dropped it would have the new image re-announce an
/// unchanged conversation over a sibling's newer one (LastConversation.swift). Returns normally only
/// when there was nothing to do or the exec failed, leaving the caller to respawn.
func execPlannedSelfUpdate(_ upgrade: (target: String, binary: String, home: String)?,
                           attempted: inout String?, target: Snapshot.Account,
                           follow: Bool, recoveries: [Date], sessionPin: String? = nil,
                           pinOverride: String? = nil, pendingCap: PendingCapRecovery? = nil,
                           sessionModel: SessionModelPin? = nil, lastConversation: String? = nil,
                           args: [String]) {
    guard let upgrade else { return }
    attempted = upgrade.target
    execSelfUpdate(to: upgrade.target, id: target.id, label: target.label, home: upgrade.home,
                   follow: follow, recoveries: recoveries, sessionPin: sessionPin,
                   pinOverride: pinOverride, pendingCap: pendingCap, sessionModel: sessionModel,
                   lastConversation: lastConversation, args: args, binary: upgrade.binary)
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

/// `tally __resupervise --id <id> --label <label> --home <path> --follow|--no-follow
/// [--fuse <epochs>] [--session-pin <accountID>] [--pin-override <accountID>]
/// [--pending-cap <json>] [--session-model <json>] [--last-conversation <id>] -- <args...>`: the
/// other side of the exec.
/// Rebuilds the account from what the previous supervisor passed rather than from the snapshot
/// (which may be stale, or missing the account entirely at that instant) and resumes supervision,
/// with the recovery fuse, the pins, and any cap this session is still waiting out continuing where
/// that supervisor left off. Only the id, label, and home are ever read from an account by the loop;
/// the quota fields are always re-read from the live snapshot, so leaving them empty here is safe.
/// The flags themselves are spelled in ResuperviseContract.swift.
func runResupervise(args: [String]) -> Never {
    let parsed = parseResuperviseArgs(args)
    let (id, label, home) = (parsed.id, parsed.label, parsed.home)
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
    runSupervised(provider, account: account, args: parsed.childArgs, follow: parsed.follow,
                  recoveries: parsed.recoveries, resumed: true, sessionPin: parsed.sessionPin,
                  pinOverride: parsed.pinOverride, pendingCap: parsed.pendingCap,
                  sessionModel: parsed.sessionModel, lastConversation: parsed.lastConversation)
}
