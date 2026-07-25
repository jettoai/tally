import Darwin
import Foundation

// Supervisor self-update: after Sparkle swaps the app bundle, a supervisor that is already running
// still executes the OLD binary's logic and keeps stamping the old version into its child, which is
// what the status line reports as "supervisor outdated, restart after update". Restarting the child
// cannot fix that (the stamp is decided by the supervisor), so the supervisor replaces ITSELF.
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
// untouched. In-memory state (the recovery fuse, the session-local quarantine) resets, which is
// acceptable directly after an upgrade.
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
/// previous exec already tried; no other relaunch is planned this tick; there is no pending cap
/// recovery (a session waiting for a sibling account to free up must not lose that state across an
/// exec, and waiting for the cap to resolve is simpler than serialising it); the session is idle by
/// the same rule a reload uses; and the child has been up past the loop-safety floor. Anything else
/// simply returns nil and the next tick asks again.
///
/// Newer, not merely different, because the exec is one-way: the child is already gone when the new
/// image starts, so a build that does not understand the `__resupervise` subcommand prints the usage
/// text and exits, and the session dies with it. Every older build is such a build. Downgrades happen
/// (an older DMG installed over the top, a Release rebuilt from an earlier checkout), and a bundle
/// that alternates between two versions would otherwise exec on every single tick that clears.
func selfUpdateTarget(captured: String?, installed: String?, isQuiet: Bool, relaunchPlanned: Bool,
                      capPending: Bool, uptime: TimeInterval, attempted: String?) -> String? {
    guard let captured, let installed, isNewerBuild(installed, than: captured) else { return nil }
    guard installed != attempted else { return nil }
    guard !relaunchPlanned, !capPending, isQuiet, uptime >= selfUpdateMinUptime else { return nil }
    return installed
}

/// The argv an upgrade execs. Continuity is spelled out rather than re-derived: the account is named
/// explicitly so the new supervisor cannot re-pick a different one, and `args` already carries the
/// `--resume <session>` the relaunch path produced, so the conversation is pinned by id. Passing the
/// original launch argv instead would let the new process pick another account and then follow a
/// bare `--continue` into whatever conversation happens to be newest there.
func selfUpdateArgv(binary: String, id: String, label: String, home: String, follow: Bool,
                    args: [String]) -> [String] {
    [binary, resuperviseCommand, "--id", id, "--label", label, "--home", home,
     follow ? "--follow" : "--no-follow", "--"] + args
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
                    args: [String], binary: String? = Bundle.main.executableURL?.path) {
    guard let binary else { return }
    warn("tally updated to \(target), restarting this session on the new build")
    setenv(selfUpdateTargetEnvKey, target, 1)
    let argv = selfUpdateArgv(binary: binary, id: id, label: label, home: home,
                              follow: follow, args: args)
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
                   capPending: Bool, uptime: TimeInterval, home: String?,
                   installed: String? = supervisorBuildVersion(),
                   binary: String? = selfUpdateBinary())
    -> (target: String, binary: String, home: String)? {
    guard let home, let binary,
          let target = selfUpdateTarget(captured: captured, installed: installed, isQuiet: isQuiet,
                                        relaunchPlanned: relaunchPlanned, capPending: capPending,
                                        uptime: uptime, attempted: attempted)
    else { return nil }
    return (target, binary, home)
}

/// Parse the exec contract's flags. Pure, and round-trip tested against `selfUpdateArgv`: the two
/// halves are written by different BUILDS of this program, so a silent disagreement between them
/// would strand exactly the sessions that were mid-upgrade. Values are taken positionally, so a
/// label that looks like a flag (`--label --home`) is still a label; a missing or trailing `--`
/// yields no child args rather than an error, because the supervisor can still resume without them.
func parseResuperviseArgs(_ args: [String]) -> (id: String, label: String, home: String,
                                                follow: Bool, childArgs: [String]) {
    var id = "", label = "", home = ""
    var follow = true
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
        case "--follow": follow = true; index += 1
        case "--no-follow": follow = false; index += 1
        case "--":
            childArgs = Array(args[(index + 1)...])
            index = args.count
        default: index += 1
        }
    }
    return (id, label, home, follow, childArgs)
}

/// `tally __resupervise --id <id> --label <label> --home <path> --follow|--no-follow -- <args...>`:
/// the other side of the exec. Rebuilds the account from what the previous supervisor passed rather
/// than from the snapshot (which may be stale, or missing the account entirely at that instant) and
/// resumes supervision. Only the id, label, and home are ever read from an account by the loop; the
/// quota fields are always re-read from the live snapshot, so leaving them empty here is safe.
func runResupervise(args: [String]) -> Never {
    let (id, label, home, follow, childArgs) = parseResuperviseArgs(args)
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
    runSupervised(provider, account: account, args: childArgs, follow: follow)
}
