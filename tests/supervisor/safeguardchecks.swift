import Foundation

// The safeguard-fallback restore, split out for file size. Top-level statements can only live in
// main.swift, so these run as one function it calls; the harness (`check`, `failures`), the fixed
// `launch` date, `stamp` and `watcherAfterScanning` are shared from there.
//
// The behaviour under test: the API's safeguards move a session onto a fallback model and leave it
// there, running at whatever depth its LAUNCH flags carry - a depth chosen for the model it is no
// longer on. The supervisor restarts it at the depth the home declares, at the next idle moment, on
// the fallback model and never back on the model that tripped the safeguard.
//
// With one exception since 2026-07-29 (section 29b): when the landed model is one the declaration
// already NAMES, the safeguard has produced the state the user asked for and the restart is dropped.
// That is why the `target` helper below declares no fallback model by default: the shapes that still
// restore are the ones whose declaration does not name where the session landed.

func runSafeguardChecks() {
    // MARK: - 27. The real event shape
    //
    // Trimmed from a live transcript (2026-07-26, one conversation that took nine of these): the
    // human-readable `content` is the "safeguards flagged" sentence, but every field the supervisor
    // reads is structured, which is what keeps this apart from a quota cap. The refusal explanation
    // is dropped here (it is a fixed policy sentence, and nothing reads it).
    let realFlag = #"""
    {"parentUuid":"9d6adcb0-5e76-43a1-86d0-670f833372d0","isSidechain":false,"type":"system","subtype":"model_refusal_fallback","content":"Fable 5's safeguards flagged this message.","level":"warning","trigger":"refusal","direction":"retry","originalModel":"claude-fable-5","fallbackModel":"claude-opus-4-8","requestId":"req_011CdQgdDb6q8xv3NkE5HmcN","apiRefusalCategory":"cyber","apiRefusalExplanation":null,"retractedMessageUuids":["2efe5e93-14ed-47c0-b5e5-319c7d8fc52a"],"refusedUserMessageUuid":null,"isMeta":false,"uuid":"df0888ed-a87a-43eb-ab22-eb1bb5d32171","timestamp":"\#(stamp(60))","userType":"external","entrypoint":"cli","cwd":"/w","sessionId":"49d098c0","version":"2.1.220"}
    """#
    let real = watcherAfterScanning([realFlag])
    check("the real fallback event parses", real.lastFlag?.to == "claude-opus-4-8")
    check("and carries its own event uuid as the restore pointer",
          real.lastFlag?.uuid == "df0888ed-a87a-43eb-ab22-eb1bb5d32171")
    check("a null refusedUserMessageUuid is tolerated", real.lastFlag?.refusedUUID == nil)
    check("the event key is that uuid",
          real.lastFlag.map(safeguardEventKey) == "df0888ed-a87a-43eb-ab22-eb1bb5d32171")
    // A transcript with no uuid still yields a usable pointer: the timestamp names the same line.
    let keyless = SafeguardFlag(at: launch, from: "claude-fable-5", to: "claude-opus-4-8",
                                category: "cyber", refusedUUID: nil, uuid: nil)
    check("a flag with no uuid falls back to its timestamp",
          safeguardEventKey(keyless) == ISO8601DateFormatter().string(from: launch))

    // The false positive this feature must never fire on: the fallback to a weaker model that a
    // spent QUOTA window causes. It arrives as an api-error message plus synthetic turns, carries no
    // `model_refusal_fallback` anywhere, and so raises no flag - and with no flag there is nothing
    // for a restore to act on.
    let quotaLimit = watcherAfterScanning([
        #"{"timestamp":"\#(stamp(30))","isApiErrorMessage":true,"message":{"content":"You've reached your Fable 5 limit for this week"}}"#,
        #"{"timestamp":"\#(stamp(40))","message":{"model":"<synthetic>"}}"#,
        #"{"timestamp":"\#(stamp(50))","message":{"model":"claude-opus-4-8"}}"#,
    ])
    check("a quota limit raises no safeguard flag", quotaLimit.lastFlag == nil)

    // MARK: - 28. The declaration a restore is decided against
    //
    // The launch policy's fallback pair, NOT Claude Code's own settings.json: the launcher already
    // overrides `effortLevel` with `--effort` on every launch, so reading it here would apply the
    // depth declared for the primary model to the fallback one. The quota fallback profile reads
    // this same pair, so a dry window and a safeguard read the same declaration.
    check("the entry naming the landed model is found",
          declaredFallbackModel("opus", landedOn: "claude-opus-4-8") == "opus")
    // The field is a comma-separated list, so the entry naming the model the safeguard chose is the
    // one that answers. Taking the first entry blindly would answer about a model nobody landed on,
    // and testing the raw string would compare against a model called "opus,sonnet" and never match.
    check("the list entry matching the landed model wins, not the first",
          declaredFallbackModel("sonnet, opus", landedOn: "claude-opus-4-8") == "opus")
    check("surrounding whitespace is trimmed",
          declaredFallbackModel("  opus  ,sonnet", landedOn: "claude-opus-4-8") == "opus")
    check("a list naming none of the landed models declares no name",
          declaredFallbackModel("sonnet,haiku", landedOn: "claude-opus-4-8") == nil)
    check("no declared list declares no name", declaredFallbackModel(nil, landedOn: "claude-opus-4-8") == nil)
    check("an empty list declares no name", declaredFallbackModel("", landedOn: "claude-opus-4-8") == nil)
    check("a list of separators declares no name",
          declaredFallbackModel(" , ", landedOn: "claude-opus-4-8") == nil)

    // The launcher injects aliases, the transcript carries full ids, and the two have to compare
    // equal or a session already on the fallback would be restarted onto it again.
    check("an alias and a full id are the same model", modelsAgree("opus", "claude-opus-4-8"))
    check("and it reads both ways", modelsAgree("claude-opus-4-8", "opus"))
    check("different families are not the same model", modelsAgree("fable", "claude-opus-4-8") == false)
    check("nil is never a match", modelsAgree(nil, "claude-opus-4-8") == false)
    check("empty is never a match", modelsAgree("", "claude-opus-4-8") == false)

    // MARK: - 29. What a restore targets

    let flag = SafeguardFlag(at: launch.addingTimeInterval(60), from: "claude-fable-5",
                             to: "claude-opus-4-8", category: "cyber", refusedUUID: nil,
                             uuid: "e-1")
    // The live configuration this was measured against: fable at high to make the flagship window
    // last, opus at xhigh because that quota is not the scarce one. The pairing is deliberate,
    // which is exactly why the restore reads it rather than raising everything to one level.
    func target(actual: String? = "claude-opus-4-8", declaredModel: String? = nil,
                declaredEffort: String? = "xhigh", declaredArgs: String? = nil,
                model: String? = "fable", effort: String? = "high",
                handled: Bool = false) -> SafeguardRestore? {
        safeguardRestoreTarget(flag: flag, actualModel: actual, fallbackModel: declaredModel,
                               fallbackEffort: declaredEffort, fallbackArgs: declaredArgs,
                               currentModel: model, currentEffort: effort, alreadyHandled: handled)
    }

    // The case this feature exists for: launched fable/high, the safeguard moved it to opus, and the
    // declaration says nothing about opus - so the depth declared for the fallback is the only
    // answer available, applied on the model the event itself names.
    check("a drifted session onto an unnamed model is restored",
          target()?.model == "claude-opus-4-8")
    check("and at the depth declared for the fallback", target()?.effort == "xhigh")
    // A declaration naming only other models is never a reason to move the session to one of them.
    check("a declaration naming other models does not redirect the session",
          target(declaredModel: "sonnet,haiku")?.model == "claude-opus-4-8")
    // Never back to the model that tripped it: standing against the safeguard only re-trips it.
    check("the restore never steers back to the model that was flagged",
          target()?.model != "claude-fable-5")

    // MARK: - 29b. A landing place the user already named is left alone
    //
    // WAS (until 2026-07-29): a declaration naming the landed model supplied the NAME to relaunch
    // under, and the session was restarted onto it at the declared depth. The restart settled
    // nothing a user could see: the safeguard had already put the session on the model they wrote
    // down as their fallback, so it was being interrupted to become what it already was. The
    // declared depth going unapplied in this case is the price knowingly paid. The drift itself is
    // untouched, warning and status-line badge still report the switch.
    check("a landed model the declaration already names is left alone",
          target(declaredModel: "opus") == nil)
    // The alias/full-id pair is the everyday form of this: the user writes `opus`, the transcript
    // says `claude-opus-4-8`, and the running depth is not the declared one. Still no restart.
    check("even when the declared depth differs from the running one",
          target(declaredModel: "opus", declaredEffort: "xhigh", effort: "high") == nil)
    check("a multi-entry declaration naming it counts the same",
          target(declaredModel: "opus,sonnet") == nil)
    check("and so does one where it is not the first entry",
          target(declaredModel: "sonnet,opus") == nil)
    check("declared extra flags do not buy the restart back",
          target(declaredModel: "opus", declaredEffort: nil, declaredArgs: "--a") == nil)
    check("nor does a session sitting at a depth nobody declared",
          target(declaredModel: "opus", effort: nil) == nil)
    // The two shapes the gate must NOT swallow, kept beside it because that is where a later reader
    // will look: both still restore exactly as they did before.
    check("a declaration naming none of the landed model still restores",
          target(declaredModel: "sonnet")
          == SafeguardRestore(model: "claude-opus-4-8", effort: "xhigh", extraArgs: []))
    check("and no declared model at all still restores, as it always did",
          target(declaredModel: nil)
          == SafeguardRestore(model: "claude-opus-4-8", effort: "xhigh", extraArgs: []))

    // The declaration has two independent halves and EITHER is enough, the same test the quota
    // fallback profile applies. Gating on the depth alone meant a user who declared only extra
    // flags never got this feature at all (codex review P2-1).
    check("no declaration at all means no restore",
          target(declaredEffort: nil, declaredArgs: nil) == nil)
    check("an empty fallbackEffort is no declaration", target(declaredEffort: "") == nil)
    check("a declared model without a depth or flags means no restore",
          target(declaredModel: "opus", declaredEffort: nil, declaredArgs: nil) == nil)
    check("declared extra flags alone are enough to restore",
          target(declaredEffort: nil, declaredArgs: "--append-system-prompt hi") != nil)
    check("and that restore carries no depth it was never given",
          target(declaredEffort: nil, declaredArgs: "--append-system-prompt hi")?.effort == nil)
    check("the extra flags reach the restore split into arguments",
          target(declaredArgs: "--append-system-prompt hi")?.extraArgs
          == ["--append-system-prompt", "hi"])
    check("repeated spaces do not become empty arguments",
          target(declaredArgs: "--a   --b")?.extraArgs == ["--a", "--b"])
    check("no declared flags is an empty list, not a phantom argument",
          target()?.extraArgs == [])
    // With no depth declared, being on the model is the whole of "already there" - there is no
    // depth left to disagree about, and the flags are not compared on either path.
    check("with flags only, a session already on the model is left alone",
          target(declaredEffort: nil, declaredArgs: "--a", model: "opus") == nil)

    // The user ran `/model` themselves after the switch. A restore would overwrite a deliberate,
    // newer choice with an older one, so it does not happen.
    check("a session the user moved elsewhere is left alone",
          target(actual: "claude-sonnet-5") == nil)
    check("a session with no known serving model is left alone", target(actual: nil) == nil)

    // Already there: a resume that carries the fallback model at the declared depth has nothing to
    // gain from a restart, and restarting it anyway would loop.
    check("a session already on the restored pairing is left alone",
          target(model: "claude-opus-4-8", effort: "xhigh") == nil)
    check("the alias form counts as already there too",
          target(model: "opus", effort: "xhigh") == nil)
    check("the same model at the wrong depth is still restored",
          target(model: "opus", effort: "high")?.effort == "xhigh")
    check("depth matching ignores case", target(model: "opus", effort: "XHigh") == nil)
    // A session launched with no model or effort flags of its own has nothing to compare against, so
    // the restore proceeds and gives it the declared pairing.
    check("a session with no launch flags is restored",
          target(model: nil, effort: nil)?.effort == "xhigh")

    // MARK: - 30. One correction per event

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-safeguard-records-\(UUID().uuidString)")
    check("an unknown conversation has handled nothing",
          safeguardRestoreHandled(session: "s-1", event: "e-1", dir: dir) == false)
    recordSafeguardRestore(session: "s-1", event: "e-1", dir: dir)
    check("a recorded event reads as handled",
          safeguardRestoreHandled(session: "s-1", event: "e-1", dir: dir))
    // This is the guard that survives a supervisor replacing itself: the new process re-reads the
    // transcript from scratch, and the record is what stops it correcting the same event twice.
    check("a handled event is not restored again", target(handled: true) == nil)
    // A LATER switch in the same conversation is a different event with a pointer of its own, so it
    // is corrected on its own merits rather than being swallowed by the record of the first.
    check("a later event in the same conversation is not pre-handled",
          safeguardRestoreHandled(session: "s-1", event: "e-2", dir: dir) == false)
    check("another conversation is unaffected",
          safeguardRestoreHandled(session: "s-2", event: "e-1", dir: dir) == false)
    check("a conversation with no id records nothing",
          safeguardRestoreHandled(session: nil, event: "e-1", dir: dir) == false)
    // An id with a slash has to reach the same file through the writer and the reader alike.
    recordSafeguardRestore(session: "a/b", event: "e-3", dir: dir)
    check("an id with a slash round-trips",
          safeguardRestoreHandled(session: "a/b", event: "e-3", dir: dir))

    // Records are bounded: a conversation gone for longer than the TTL leaves nothing behind.
    let stale = dir.appendingPathComponent("s-old")
    try! "e-old".write(to: stale, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-safeguardRecordTTL - 60)],
        ofItemAtPath: stale.path)
    pruneSafeguardRecords(dir: dir)
    check("a record past its TTL is pruned", !FileManager.default.fileExists(atPath: stale.path))
    check("live records survive the prune",
          safeguardRestoreHandled(session: "s-1", event: "e-1", dir: dir))

    // MARK: - 31. The relaunch the plan produces

    // The pairing reaches the child as flags, replacing whatever the session was launched with. The
    // conversation itself rides along in the args the resume path already built.
    let plan = RelaunchPlan(target: Snapshot.Account(
        id: "A", provider: "claude", label: "A", launchHome: "/tmp/A",
        sessionRemaining: 90, weeklyRemaining: 90, modelRemaining: 90,
        sessionResetsAt: nil, weeklyResetsAt: nil, modelResetsAt: nil,
        modelWindowName: "fable", resetCreditsAvailable: nil, isStale: false, error: nil),
        reason: "safeguard", countsFuse: true, model: "opus", effort: "xhigh",
        extraArgs: ["--append-system-prompt", "hi"])
    check("the restore relaunch carries the declared profile, replacing what was launched",
          planLaunchArgs(["--resume", "abc", "--model", "fable", "--effort", "high"], plan: plan)
          == ["--resume", "abc", "--model", "opus", "--effort", "xhigh",
              "--append-system-prompt", "hi"])
    check("the restore is a same-account relaunch", plan.target.id == "A")
    check("and it is audited as a safeguard restore", plan.reason == "safeguard")
    // Flags-only: nothing declared a depth, so the relaunch must not invent one.
    let argsOnly = RelaunchPlan(target: plan.target, reason: "safeguard", countsFuse: true,
                                model: "opus", effort: nil, extraArgs: ["--a"])
    check("a restore with no declared depth passes no --effort",
          planLaunchArgs(["--resume", "abc", "--model", "fable", "--effort", "high"],
                         plan: argsOnly) == ["--resume", "abc", "--model", "opus", "--a"])

    // MARK: - 32. Episode bookkeeping and the badge

    var monitor = DriftMonitor()
    check("a fresh episode has nothing queued", !monitor.restoreQueued)
    _ = monitor.tick(flag: flag, actualModel: "claude-opus-4-8", primary: "fable", now: launch)
    monitor.markRestoreQueued()
    check("the announcement is made once", monitor.restoreQueued)
    // A newer switch is a new event with a pointer of its own, so it gets its own announcement.
    let later = SafeguardFlag(at: launch.addingTimeInterval(600), from: "claude-fable-5",
                              to: "claude-opus-4-8", category: "cyber", refusedUUID: nil,
                              uuid: "e-2")
    _ = monitor.tick(flag: later, actualModel: "claude-opus-4-8", primary: "fable",
                     now: launch.addingTimeInterval(600))
    check("a newer flag re-arms the announcement", !monitor.restoreQueued)
    monitor.markRestoreQueued()
    _ = monitor.tick(flag: later, actualModel: "claude-fable-5", primary: "fable",
                     now: launch.addingTimeInterval(700))
    check("a cleared episode leaves nothing queued", !monitor.restoreQueued)
    // An announcement has to be retractable by hand too: the episode can stay active while the
    // restore it promised stops applying.
    monitor.markRestoreQueued()
    monitor.clearRestoreQueued()
    check("a queued announcement can be withdrawn", !monitor.restoreQueued)

    // MARK: - 32b. Queued state follows the target, in both directions
    //
    // The defect this closes (codex review P2-2): a restore queued while the session was busy, then
    // losing its target mid-wait - the user runs `/model` to a third model, or clears the
    // declaration - used to leave `restoring at idle` on the status line for the rest of the
    // session while no idle tick would ever restart anything. Announced state must be retractable
    // by the same path that announced it.
    check("a target with nothing said yet is announced",
          safeguardPendingTransition(hasTarget: true, queued: false) == .announce)
    check("a target already announced just waits",
          safeguardPendingTransition(hasTarget: true, queued: true) == .hold)
    check("a target that went away after being announced is cancelled",
          safeguardPendingTransition(hasTarget: false, queued: true) == .cancel)
    check("no target and nothing announced says nothing",
          safeguardPendingTransition(hasTarget: false, queued: false) == .idle)
    // The two ways a queued restore loses its target, both while the episode stays active.
    check("switching to a third model drops the target",
          target(actual: "claude-sonnet-5") == nil)
    check("clearing the declaration drops the target",
          target(declaredEffort: nil, declaredArgs: nil) == nil)
    // And coming back re-queues: the record is only written when a restore actually happens, so
    // nothing has been spent and the session is owed the same restart it was owed before.
    check("returning to the landed model makes it a target again", target() != nil)
    check("which re-announces rather than staying silent",
          safeguardPendingTransition(hasTarget: true, queued: false) == .announce)

    // The badge the status line renders while the restore waits for the session to be left alone.
    let sDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-safeguard-state-\(UUID().uuidString)")
    writeDriftState(flag, pid: "1", dir: sDir)
    check("a drift with no restore queued says so", readDriftState(pid: "1", dir: sDir)
          == DriftState(from: "claude-fable-5", to: "claude-opus-4-8", category: "cyber"))
    writeDriftState(flag, pid: "1", restorePending: true, dir: sDir)
    check("a queued restore round-trips through the state file",
          readDriftState(pid: "1", dir: sDir)?.restorePending == true)
    check("and the rest of the badge is untouched",
          readDriftState(pid: "1", dir: sDir)
          == DriftState(from: "claude-fable-5", to: "claude-opus-4-8", category: "cyber",
                        restorePending: true))
    // A file written by a supervisor from before this feature still reads, which is the state of
    // every running session while an app update rolls out.
    try! "claude-fable-5\tclaude-opus-4-8\tcyber\t1800000060.0"
        .write(to: sDir.appendingPathComponent("2"), atomically: true, encoding: .utf8)
    check("an older four-field state file still reads as a drift",
          readDriftState(pid: "2", dir: sDir)
          == DriftState(from: "claude-fable-5", to: "claude-opus-4-8", category: "cyber"))
    check("and reads as having no restore queued",
          readDriftState(pid: "2", dir: sDir)?.restorePending == false)

    // MARK: - 33. The audit line carries a pointer, never the content

    // What triggers a safeguard here is auth and token work, and handoff.log is a plain file, so the
    // line names WHERE to look rather than quoting what was said (the drift line next door is what
    // carries a sanitized excerpt, and only that one).
    let transcript = URL(fileURLWithPath: "/tmp/projects/-w/49d098c0-490b-413f.jsonl")
    let triggered = SafeguardFlag(at: launch, from: "claude-fable-5", to: "claude-opus-4-8",
                                  category: "cyber", refusedUUID: "u-trigger", uuid: "e-1")
    let restored = SafeguardRestore(model: "opus", effort: "xhigh",
                                    extraArgs: ["--append-system-prompt", "secret guidance"])
    let line = safeguardRestoreLine(sessionID: "49d098c0-490b-413f", flag: triggered,
                                    restore: restored, transcript: transcript, now: launch)
    check("the audit line names the switch", line.contains("claude-fable-5->claude-opus-4-8"))
    check("and the model being restored to", line.contains("model=opus"))
    check("and the depth being restored", line.contains("effort=xhigh"))
    // The extra flags are counted, never quoted: fallbackArgs is free text the user configured and
    // --append-system-prompt lives there, so copying it in would duplicate exactly the kind of
    // content this line exists to keep out of a plain file.
    check("the extra flags are counted", line.contains("extra-args=2"))
    check("but never quoted", !line.contains("secret guidance")
          && !line.contains("--append-system-prompt"))
    let plainLine = safeguardRestoreLine(
        sessionID: "s", flag: triggered,
        restore: SafeguardRestore(model: "opus", effort: nil, extraArgs: []),
        transcript: nil, now: launch)
    check("a restore with no depth names none", !plainLine.contains("effort="))
    check("and a restore with no extra flags counts none", !plainLine.contains("extra-args="))
    check("and the session, trimmed to its prefix like every other line",
          line.contains("session=49d098c0") && !line.contains("session=49d098c0-490b"))
    check("and points at the event rather than quoting it",
          line.contains("event=e-1") && line.contains("transcript=\(transcript.path)"))
    // The guarantee that has to hold forever: no trigger text reaches the log. The uuid of the
    // refused message is deliberately absent too - it is a handle on the prompt, and the event uuid
    // already locates the episode.
    check("the audit line carries no excerpt of what triggered the safeguard",
          !line.contains("u-trigger") && !line.contains("excerpt"))
    check("a transcript that could not be located is simply omitted",
          !plainLine.contains("transcript="))
}
