import Foundation

// The exec contract: the argv one supervisor writes so that the supervisor REPLACING it comes back
// holding everything the session was promised. Split out of SelfUpdate.swift, which keeps the
// decision (when to replace itself, and with what) while this keeps the spelling. The split is at
// the size cap, and it is also the honest seam: this file is the only part of a self-update that a
// DIFFERENT BUILD has to agree with, so what belongs in it is exactly what crosses the exec.
//
// LOAD-BEARING ACROSS VERSIONS. `__resupervise` and its flags are a contract between two different
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
//
// WHAT RIDES ACROSS, and why each one has to. In-memory state resets at the exec, which is
// acceptable for anything the new image re-derives within a tick or two, and NOT acceptable for a
// promise about the user's SESSION - the recovery fuse's spent budget, the account a `tally switch`
// pinned, the cap the session is still waiting out, the model and effort a `tally model` pinned.
// Every one of those is a flag below, optional by construction, with its own note on what an absent
// one has to mean.

/// The internal subcommand a self-update re-enters through. Not a user-facing command (it is absent
/// from the usage text on purpose): it carries the account and the conversation across the exec so
/// the new supervisor resumes exactly what the old one was watching, with no re-picking.
let resuperviseCommand = "__resupervise"

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

/// The flag carrying the model and effort a `tally model` pinned this session to (SessionModel.swift).
///
/// ONE flag for the pair, not one per axis, and that is a decision about this family rather than
/// about this feature. `--fuse`, `--session-pin`, `--pin-override` and `--pending-cap` were each
/// added the same way ("something else has to survive the exec"), and a fifth and sixth would make
/// the shape of the argv the thing to reason about. The pair is also indivisible in meaning: a
/// session pinned to opus/xhigh that arrived holding only the model would run the fleet's effort on
/// a model the user chose, which is neither of the two states this feature has.
///
/// JSON like the pending cap, for the same reason it is one token per flag and for one it does not
/// have: a model name is open text (`us.anthropic.claude-opus-4:1`), so a delimiter would need
/// escaping the moment a provider used one. Optional by construction, like every flag here: an
/// unpinned session writes nothing, which is what every build predating this one wrote, and an
/// absent flag means the session follows its project profile and the fleet default - the behaviour
/// those builds had.
let resuperviseSessionModelFlag = "--session-model"

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
    return encodeResuperviseFields(fields)
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
    guard let object = decodeResuperviseFields(raw),
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

/// The pinned pair as a flag value: one JSON object naming only the axes that are pinned, so a pin
/// on the model alone spells `{"model":"opus"}` rather than claiming an effort nobody chose. nil for
/// a pin that says nothing, which writes no flag - the same thing an unpinned session writes.
func encodeSessionModel(_ pin: SessionModelPin) -> String? {
    guard !pin.isEmpty else { return nil }
    var fields: [String: Any] = [:]
    if let model = pin.model { fields["model"] = model }
    if let effort = pin.effort { fields["effort"] = effort }
    return encodeResuperviseFields(fields)
}

/// The pinned pair a previous build wrote, or none. Same standard of proof as the pending cap: a key
/// that is PRESENT but not a usable axis value discards the whole pin rather than half of it, since
/// half a pin is a session running one axis the user chose and one they did not. `isLaunchAxisValue`
/// is asked here as well as at the command, because this value crossed a process boundary and the
/// entrance check that refused it belongs to a build we cannot see (ProjectPolicy.swift). An empty
/// object, or one naming only keys this build has never heard of, is no pin at all.
func decodeSessionModel(_ raw: String) -> SessionModelPin? {
    guard let object = decodeResuperviseFields(raw) else { return nil }
    func axis(_ key: String) -> String?? {
        guard let value = object[key] else { return .some(nil) }
        guard let text = value as? String, isLaunchAxisValue(text) else { return nil }
        return .some(text)
    }
    guard let model = axis("model"), let effort = axis("effort") else { return nil }
    let pin = SessionModelPin(model: model, effort: effort)
    return pin.isEmpty ? nil : pin
}

/// One JSON object as a single argv token. Keys sorted so a given state always spells the same argv,
/// which is what makes the round-trip tests assert a format rather than a dictionary ordering.
/// Shared by the two flags that carry structured state, so neither can drift into a different
/// spelling of the same idea.
private func encodeResuperviseFields(_ fields: [String: Any]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return nil }
    return text
}

/// The other half: an argv token back to an object, or nil for anything that is not one (a value
/// truncated by a shell, a JSON array, a shape from a build we do not know).
private func decodeResuperviseFields(_ raw: String) -> [String: Any]? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// The argv an upgrade execs. Continuity is spelled out rather than re-derived: the account is named
/// explicitly so the new supervisor cannot re-pick a different one, and `args` already carries the
/// `--resume <session>` the relaunch path produced, so the conversation is pinned by id. Passing the
/// original launch argv instead would let the new process pick another account and then follow a
/// bare `--continue` into whatever conversation happens to be newest there. `recoveries` is the
/// recovery fuse's live record (already pruned by `RecoveryFuse.carried`), `pendingCap` the cap
/// state the relaunch this exec rides on decided to hand over (`capCarriedAcrossRelaunch`), and
/// `sessionModel` the pair a `tally model` pinned, so the new image inherits exactly what the next
/// CHILD would have inherited had there been no upgrade.
func selfUpdateArgv(binary: String, id: String, label: String, home: String, follow: Bool,
                    recoveries: [Date] = [], sessionPin: String? = nil,
                    pinOverride: String? = nil, pendingCap: PendingCapRecovery? = nil,
                    sessionModel: SessionModelPin? = nil,
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
    if let sessionModel, let encoded = encodeSessionModel(sessionModel) {
        argv += [resuperviseSessionModelFlag, encoded]
    }
    return argv + ["--"] + args
}

/// Everything one side of the exec hands the other. A value type rather than a tuple because the
/// list only ever grows (each entry is one more promise about the session that must survive), and a
/// tuple of eight named fields is a signature nobody can read at the call site.
struct ResuperviseArgs {
    var id = ""
    var label = ""
    var home = ""
    var follow = true
    var recoveries: [Date] = []
    var sessionPin: String?
    var pinOverride: String?
    var pendingCap: PendingCapRecovery?
    var sessionModel: SessionModelPin?
    var childArgs: [String] = []
}

/// Parse the exec contract's flags. Pure, and round-trip tested against `selfUpdateArgv`: the two
/// halves are written by different BUILDS of this program, so a silent disagreement between them
/// would strand exactly the sessions that were mid-upgrade. Values are taken positionally, so a
/// label that looks like a flag (`--label --home`) is still a label; a missing or trailing `--`
/// yields no child args rather than an error, because the supervisor can still resume without them.
/// An absent `--fuse` (every build before it, and any supervisor whose fuse was empty) means no
/// recoveries, which is the fresh-fuse behaviour this contract had all along; an absent
/// `--session-pin` means the session was never pinned by hand, an absent `--pin-override` means it
/// never overrode a pin, an absent `--pending-cap` means the session was not waiting on a cap, and
/// an absent `--session-model` means it pinned no model or effort of its own - which is what every
/// build before each flag effectively said too.
func parseResuperviseArgs(_ args: [String]) -> ResuperviseArgs {
    var parsed = ResuperviseArgs()
    var index = 0
    while index < args.count {
        let argument = args[index]
        func value() -> String {
            index + 1 < args.count ? args[index + 1] : ""
        }
        switch argument {
        case "--id": parsed.id = value(); index += 2
        case "--label": parsed.label = value(); index += 2
        case "--home": parsed.home = value(); index += 2
        case resuperviseFuseFlag: parsed.recoveries = decodeRecoveryFuse(value()); index += 2
        // An empty value is no pin rather than a pin on "": these flags are only written with a
        // real account id, so an empty one is a disagreement about the format, and the safe reading
        // of it is the behaviour of every build that never wrote the flag at all.
        case resuperviseSessionPinFlag:
            parsed.sessionPin = value().isEmpty ? nil : value()
            index += 2
        case resupervisePinOverrideFlag:
            parsed.pinOverride = value().isEmpty ? nil : value()
            index += 2
        case resupervisePendingCapFlag: parsed.pendingCap = decodePendingCap(value()); index += 2
        case resuperviseSessionModelFlag: parsed.sessionModel = decodeSessionModel(value()); index += 2
        case "--follow": parsed.follow = true; index += 1
        case "--no-follow": parsed.follow = false; index += 1
        case "--":
            parsed.childArgs = Array(args[(index + 1)...])
            index = args.count
        default: index += 1
        }
    }
    return parsed
}
