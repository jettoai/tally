import Foundation

// A pending cap recovery riding across the self-update exec, and the gate that retirement removes.
//
// The behaviour under test, from the incident that motivated it (2026-08-06): `selfUpdateTarget`
// refused to upgrade while a cap recovery was pending, on the grounds that an exec would drop that
// state. The wait it deferred to is for a sibling account to free up, which is hours, so the gate
// did not defer the upgrade, it cancelled it: pid 67853 hit a cap at 20:44 and was still running
// 0.38.0 hours later while the nine other supervisors on the machine had all moved to 0.38.1 - the
// build whose fix is that a pending cap gets cleared. The one session that needed the new build was
// the only one that could not have it.
//
// So the state is serialised into the exec's argv instead (`--pending-cap`), and everything here is
// about the two halves of that being one contract: what the old image writes, the new image reads
// back field for field, and decides the same thing with.

func runCapSelfUpdateChecks() {
    // MARK: - 32. A pending cap across the self-update exec

    let capT0 = Date(timeIntervalSince1970: 1_800_000_000)
    let resetsAt = capT0.addingTimeInterval(3600)
    let waitingNote = CapAction.waitNoTarget.waitingNote ?? ""
    /// The record as `applyCapHandoff` leaves it after a tick that could not hand off: a retry
    /// backoff in the future and the note the status line is showing.
    let pending = PendingCapRecovery(cappedAccountID: "claude:/Users/x/.claude5", cappedAt: capT0,
                                     primaryModel: "fable", recoveryResetsAt: resetsAt,
                                     nextRetry: capT0.addingTimeInterval(15), reason: waitingNote)

    // MARK: 32a. The codec

    // Every field the decision reads has to survive, so they are asserted one by one rather than as
    // a whole: a record that comes back missing one is not a smaller record, it is a session that
    // decides DIFFERENTLY from the one that was upgraded (no reset boundary is a badge that never
    // clears; no model scores every handoff candidate against the wrong quota window).
    guard let encoded = encodePendingCap(pending) else {
        check("a pending cap can be spelled as a flag value", false)
        return
    }
    guard let round = decodePendingCap(encoded) else {
        check("and read back again", false)
        return
    }
    check("the account that capped survives", round.cappedAccountID == pending.cappedAccountID)
    check("the instant it capped survives", round.cappedAt == pending.cappedAt)
    check("the model this session runs survives", round.primaryModel == pending.primaryModel)
    check("the reset the recovery is waiting for survives",
          round.recoveryResetsAt == pending.recoveryResetsAt)
    check("the retry backoff survives, so the new image does not re-attempt immediately",
          round.nextRetry == pending.nextRetry)
    check("and the note the status line is showing survives", round.reason == pending.reason)
    // A comma and parentheses live inside the real waiting notes, which is why this is JSON and not
    // the fuse's delimited list.
    check("the note under test is the real one, punctuation and all",
          waitingNote.contains(",") && !waitingNote.isEmpty)

    // Same state, same argv: keys are sorted so an assertion about what an upgrade produces is not
    // a coin flip on dictionary order.
    check("the same record always spells the same value", encodePendingCap(pending) == encoded)
    check("and no parser can mistake it for a flag", !encoded.hasPrefix("-"))
    // One argv ELEMENT, not a shell string: execv hands the vector over as it is, so the spaces
    // inside the waiting note cost nothing and need no quoting.
    let spelled = selfUpdateArgv(binary: "/usr/local/bin/tally", id: "a", label: "A", home: "/h",
                                 follow: true, pendingCap: pending, args: [])
    check("the whole record occupies exactly one argv slot, spaces and all",
          spelled.filter { $0 == encoded }.count == 1 && encoded.contains(" "))

    // The optional halves are genuinely optional: a cap whose snapshot could name no reset, on a
    // session with no model of its own, is the state a single-account user hits.
    let bare = PendingCapRecovery(cappedAccountID: "A", cappedAt: capT0, primaryModel: nil,
                                  recoveryResetsAt: nil, nextRetry: .distantPast, reason: "")
    let bareRound = encodePendingCap(bare).flatMap(decodePendingCap)
    check("a record with no reset boundary and no model round-trips as one",
          bareRound?.recoveryResetsAt == nil && bareRound?.primaryModel == nil)
    check("and keeps the rest", bareRound?.cappedAccountID == "A" && bareRound?.reason == ""
          && bareRound?.nextRetry == Date.distantPast && bareRound?.cappedAt == capT0)

    // Written by a DIFFERENT build, so a shape we cannot fully parse is a disagreement about the
    // format, not something to half-believe (the rule `decodeRecoveryFuse` set). Dropping the whole
    // value degrades to "no pending cap", which is exactly what every build before this one had.
    check("a value that is not JSON at all is no pending cap", decodePendingCap("not-json") == nil)
    check("an empty value is no pending cap", decodePendingCap("") == nil)
    check("a JSON array is not a record either", decodePendingCap("[1,2]") == nil)
    check("a record with no account names nothing to wait for",
          decodePendingCap(#"{"cappedAt":1,"nextRetry":1,"reason":""}"# ) == nil)
    check("an empty account is the same as none",
          decodePendingCap(#"{"account":"","cappedAt":1,"nextRetry":1,"reason":""}"#) == nil)
    check("a missing timestamp discards the whole record",
          decodePendingCap(#"{"account":"A","nextRetry":1,"reason":""}"#) == nil)
    check("a missing retry does too",
          decodePendingCap(#"{"account":"A","cappedAt":1,"reason":""}"#) == nil)
    check("a missing note does too",
          decodePendingCap(#"{"account":"A","cappedAt":1,"nextRetry":1}"#) == nil)
    check("a time that is not a number discards it",
          decodePendingCap(#"{"account":"A","cappedAt":"soon","nextRetry":1,"reason":""}"#) == nil)
    // Present but unreadable is the dangerous shape: read as "absent" it would silently become a
    // session that can never clear its own badge, so it discards instead.
    check("a reset boundary that is present and unreadable discards the record",
          decodePendingCap(
              #"{"account":"A","cappedAt":1,"nextRetry":1,"reason":"","resets":"later"}"#) == nil)
    check("so does a model that is present and unreadable",
          decodePendingCap(#"{"account":"A","cappedAt":1,"nextRetry":1,"reason":"","model":7}"#)
              == nil)
    // A later build may add fields; this one has no business refusing an otherwise complete record.
    check("keys a newer build adds are ignored, not fatal",
          decodePendingCap(
              #"{"account":"A","cappedAt":1,"nextRetry":1,"reason":"","future":"x"}"#)?
              .cappedAccountID == "A")

    // MARK: 32b. The exec contract

    let trip = { (state: PendingCapRecovery?, recoveries: [Date], sessionPin: String?) in
        parseResuperviseArgs(Array(selfUpdateArgv(
            binary: "/usr/local/bin/tally", id: "acct-1", label: "Claude 5",
            home: "/Users/x/.claude5", follow: true, recoveries: recoveries,
            sessionPin: sessionPin, pendingCap: state, args: ["--resume", "abc"]).dropFirst(2)))
    }
    let carried = trip(pending, [], nil)
    check("the pending cap survives the argv round trip",
          carried.pendingCap?.cappedAccountID == pending.cappedAccountID
              && carried.pendingCap?.cappedAt == pending.cappedAt
              && carried.pendingCap?.primaryModel == pending.primaryModel
              && carried.pendingCap?.recoveryResetsAt == pending.recoveryResetsAt
              && carried.pendingCap?.nextRetry == pending.nextRetry
              && carried.pendingCap?.reason == pending.reason)
    check("and does not disturb what rides beside it",
          carried.home == "/Users/x/.claude5" && carried.id == "acct-1" && carried.follow
              && carried.childArgs == ["--resume", "abc"])
    // Written in sequence with the other optional flags, so a run-on would eat one.
    let crowded = trip(pending, [capT0], "acct-2")
    check("the fuse, the pin and the cap all ride together",
          crowded.recoveries == [capT0] && crowded.sessionPin == "acct-2"
              && crowded.pendingCap?.cappedAccountID == pending.cappedAccountID
              && crowded.childArgs == ["--resume", "abc"])
    // WHAT THIS SUPERVISOR HAS ALREADY PUBLISHED AS THE LAST CONVERSATION WATCHED HERE rides along
    // for the same reason the fuse does: it is memory about this session's own history, it lives
    // nowhere but in the writer, and the new image that cannot re-derive it re-announces an
    // unchanged conversation on its first tick - over whatever a SIBLING session in the directory
    // published in the meantime (LastConversation.swift).
    let withRecord = parseResuperviseArgs(Array(selfUpdateArgv(
        binary: "/usr/local/bin/tally", id: "a", label: "A", home: "/h", follow: true,
        recoveries: [capT0], sessionPin: "acct-2", pendingCap: pending,
        lastConversation: "conv-abc", args: ["--resume", "abc"]).dropFirst(2)))
    check("the published conversation survives the argv round trip",
          withRecord.lastConversation == "conv-abc")
    check("…alongside everything else that rides",
          withRecord.recoveries == [capT0] && withRecord.sessionPin == "acct-2"
              && withRecord.pendingCap?.cappedAccountID == pending.cappedAccountID
              && withRecord.childArgs == ["--resume", "abc"])
    check("a supervisor that has published nothing writes no flag at all",
          !selfUpdateArgv(binary: "/usr/local/bin/tally", id: "a", label: "A", home: "/h",
                          follow: true, args: []).contains(resuperviseLastConversationFlag))
    // Re-validated on the way in: the value crossed a process boundary from a build we cannot see,
    // and it is about to name a file. Anything that is not an id is no memory, which is the
    // behaviour of every build that never wrote the flag.
    check("a value that cannot be a transcript id is no memory",
          parseResuperviseArgs([resuperviseLastConversationFlag, "../../etc/passwd"])
              .lastConversation == nil)
    check("an argv from a build predating the flag parses as no memory",
          parseResuperviseArgs(["--id", "a", "--home", "/h", "--follow"]).lastConversation == nil)
    // BOTH ENDS ARE ACTUALLY WIRED, asserted from the source the way the transcript identity's two
    // ends are: the loop needs a live child to run, so nothing here can call it. A flag that rides
    // an argv nobody fills in and nobody reads back would round-trip perfectly and fix nothing.
    let supervisorLoop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift",
                                      encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the self-update checks", !supervisorLoop.isEmpty)
    check("an upgrading supervisor hands on what it has published",
          supervisorLoop.contains("lastConversation: lastConversation.published"))
    check("…and the image it hands to starts holding it",
          supervisorLoop.contains("LastConversationWriter(current: lastConversation)"))
    let entry = (try? String(contentsOfFile: "TallyCLI/SelfUpdate.swift", encoding: .utf8)) ?? ""
    check("…which the resupervise entry point takes off the argv",
          entry.contains("lastConversation: parsed.lastConversation"))

    // Optional by construction: nothing pending writes no flag, which is what every build before
    // this one wrote, and an absent flag has to keep meaning "nothing pending".
    check("a session with no pending cap writes no flag at all",
          !selfUpdateArgv(binary: "/usr/local/bin/tally", id: "a", label: "A", home: "/h",
                          follow: true, args: []).contains(resupervisePendingCapFlag))
    check("and reads back as nothing pending", trip(nil, [], nil).pendingCap == nil)
    check("an argv from a build predating the flag parses as nothing pending",
          parseResuperviseArgs(["--id", "a", "--label", "A", "--home", "/h", "--follow",
                                "--", "--resume", "abc"]).pendingCap == nil)
    check("an unreadable value is nothing pending, not a crash",
          parseResuperviseArgs(["--home", "/h", resupervisePendingCapFlag, "{"]).pendingCap == nil)
    check("a dangling flag is nothing pending either",
          parseResuperviseArgs(["--home", "/h", resupervisePendingCapFlag]).pendingCap == nil)
    check("and neither swallows the home",
          parseResuperviseArgs([resupervisePendingCapFlag, "{", "--home", "/h"]).home == "/h")
    // The other direction of the contract, which cannot be run here because it needs the OTHER
    // build: what does a parser that predates a flag do with it? The `default: index += 1` arm has
    // been in this parser unchanged since the subcommand shipped (2c2a6d8), and it steps over an
    // unknown word one at a time - so the flag and its value are skipped as two unknown words, and
    // everything around them still arrives. Asserted with a flag THIS build does not know either,
    // which is the same code path an older build takes through `--pending-cap`.
    let future = parseResuperviseArgs(["--id", "a", "--home", "/h", "--not-a-flag-we-know",
                                       encoded, "--follow", "--", "--resume", "abc"])
    check("a flag this build does not know is stepped over, along with its value",
          future.home == "/h" && future.id == "a" && future.follow
              && future.childArgs == ["--resume", "abc"])

    // MARK: 32c. The gate that is gone

    // The tick that used to be impossible: a capped session, waiting because no sibling has quota
    // to spare, is quiet by definition and has no relaunch planned - and now it upgrades.
    check("a session waiting out a cap takes the update",
          selfUpdateDue(captured: "0.38.0", attempted: nil, isQuiet: true, relaunchPlanned: false,
                        uptime: 300, home: "/Users/x/.claude5",
                        installed: "0.38.1", binary: "/bin/ls")?.target == "0.38.1")
    // Neither end of that is reachable without a child, so the source carries the rest (the
    // technique the fold, the rebalance and the cap reset all use): the gate is not merely unused
    // here, it is absent from both halves, and the tick hands the state to the exec instead.
    let helper = (try? String(contentsOfFile: "TallyCLI/SelfUpdate.swift", encoding: .utf8)) ?? ""
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the self-update and supervisor sources are readable from the cap checks",
          !helper.isEmpty && !loop.isEmpty)
    if let opens = helper.range(of: "func selfUpdateTarget("),
       let ends = helper.range(of: "\n}\n", options: [], range: opens.upperBound ..< helper.endIndex) {
        let body = String(helper[opens.lowerBound ..< ends.lowerBound])
        check("the decision reads the whole function", body.contains("return installed"))
        // A cap gate cannot be spelled without a cap to gate on, and nothing else in this function
        // is one - so the absence of the word covers the signature and every guard under it.
        check("and it takes no pending-cap gate any more", !body.contains("capPending"))
    } else {
        check("the self-update decision was found", false)
    }
    // Bounded at both ends, the way the keyboard checks bound the same block: a span that ran on
    // would reach `syncPendingNotice`, which reads the pending cap for the badge quite legitimately,
    // and the assertion would stop meaning anything. Inside these two lines the ONLY thing the
    // pending cap could be doing is gating the upgrade, whatever it is spelled.
    if let opens = loop.range(of: "let childAge = Date().timeIntervalSince(launchedAt)"),
       let closes = loop.range(of: "RelaunchPlan(target: account, reason: \"self-update\"") {
        let tick = String(loop[opens.lowerBound ..< closes.lowerBound])
        check("the tick asks for the upgrade in that span", tick.contains("selfUpdateDue("))
        check("and nothing about a pending cap stands between the two",
              !tick.contains("pendingCap") && !tick.contains("capPending"))
    } else {
        check("the self-update block boundaries were found", false)
    }

    // MARK: 32d. The new image decides what the old one was deciding

    // Equivalence where it is actually spent: each field the record carries feeds a decision, so
    // the restored record is run through the same deciders and has to answer identically. Anything
    // dropped in transit shows up here as a session that behaves differently after an upgrade than
    // it would have without one, which is worse than not upgrading at all.
    guard let restored = carried.pendingCap else {
        check("the restored record is there to decide with", false)
        return
    }
    func badge(_ state: PendingCapRecovery?) -> PendingBadge? {
        supervisorPendingBadges(reload: nil, followDeadEnd: false, followQueued: false,
                                policy: LaunchPolicy(), capReason: state?.reason).chosen
    }
    check("the status line says the same thing on the new build", badge(restored) == badge(pending))
    check("and it is the wait the session was actually in",
          badge(restored)?.badge.contains("no account with quota") == true)
    // The reset boundary: the clear path for a session nobody types into. Asked either side of the
    // boundary, so a record that lost it (or landed with a different one) cannot pass.
    for offset in [-60.0, 60.0] {
        let now = resetsAt.addingTimeInterval(offset)
        check("the reset clear answers the same \(offset < 0 ? "before" : "after") the boundary",
              capRecoveredByReset(restored, now: now) == capRecoveredByReset(pending, now: now))
    }
    check("and the boundary is the one that matters, not a constant answer",
          capRecoveredByReset(restored, now: resetsAt.addingTimeInterval(60))
              != capRecoveredByReset(restored, now: resetsAt.addingTimeInterval(-60)))
    // The account arm: a pending cap belongs to the account it named, and the new image has to keep
    // waiting on the same one (and stop waiting on the same move). Run over an empty transcript, so
    // the account under the session is the only thing that can decide it.
    func afterTick(_ state: PendingCapRecovery?, on accountID: String) -> PendingCapRecovery? {
        var carriedState = state
        var quarantine: [String: (model: String?, until: Date)] = [:]
        var watcher = watcherAfterScanning([])
        let account = Snapshot.Account(id: accountID, provider: "claude", label: accountID,
                                       launchHome: "/Users/x/.claude5", sessionRemaining: nil,
                                       weeklyRemaining: nil, modelRemaining: nil,
                                       sessionResetsAt: nil, weeklyResetsAt: nil,
                                       modelResetsAt: nil, modelWindowName: nil,
                                       resetCreditsAvailable: nil, isStale: false, error: nil)
        observeCapHit(pendingCap: &carriedState, quarantine: &quarantine, watcher: &watcher,
                      account: account, primaryModel: "fable",
                      now: capT0.addingTimeInterval(200), snapshotAccounts: { [] })
        return carriedState
    }
    check("the new image is still waiting on the account that capped",
          afterTick(restored, on: pending.cappedAccountID)?.cappedAccountID
              == afterTick(pending, on: pending.cappedAccountID)?.cappedAccountID)
    check("and that is a wait, not a clear",
          afterTick(restored, on: pending.cappedAccountID) != nil)
    check("a session that has moved elsewhere clears on both builds alike",
          afterTick(restored, on: "acct-elsewhere") == nil
              && afterTick(pending, on: "acct-elsewhere") == nil)
    // The handoff's own inputs: the model the candidates are scored against, and the backoff that
    // decides whether this tick attempts one at all.
    check("the handoff on the new build scores against the same model",
          restored.primaryModel == pending.primaryModel)
    check("and does not attempt before the backoff the old build set",
          restored.nextRetry == pending.nextRetry && restored.nextRetry > capT0)
}
