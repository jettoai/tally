import Foundation

// WAKING A SESSION WHOSE BACKGROUND WORK A TALLY RELAUNCH KILLED.
//
// A resumed Claude Code files a `<task-notification>` saying its Monitors and shells were stopped
// and does not start a turn, so an idle session waiting on that work sleeps until somebody types
// (2026-09-27: two sessions, 54 and 59 minutes). This types one line into it.
//
// Only a child this supervisor restarted itself (`spawnedByTally`) is armed: a child that exits on
// its own ends the supervisor. A person's `tally claude --resume` is a first spawn, armed only
// through the note `firstLaunchRestartNote` gives it.
// Either signal arms: the stopped notice in the new child's transcript, or the old child's roster
// at the handoff. Delivery is the cap resume door with all its gates, under words of its own and
// with a state of its own, so it never spends the cap station's latch.
//
// A restart that stopped nothing is owed a line only when the child it replaced had work the
// restart took (`restartOwed`, RestartLiveWork.swift; 2026-10-02's 26 minutes were a Monitor the
// roster missed, 2026-10-07's waste was idle sessions woken by every self-update), worded without
// the stopped count. A fresh or second-head relaunch leaves no note, so a new empty window is never
// typed into.

/// The note an exec's first child starts with when the old image carried none (a build before
/// `--restart-note`): it cannot say, so it owes the line.
let execRestartNote = RestartNote(reason: "self-update", background: 0, owed: true)

/// The note a supervisor's first child starts with. An exec is a self-update. A new supervisor
/// whose launch resumes a conversation (`--resume <id>`, `--continue`) is a person bringing a
/// session back after its old supervisor died, a reboot most often (2026-10-04: an idle session
/// resumed by hand sat at an empty prompt), so it is owed the line too. A fresh launch, a fork, and
/// a cleared conversation the start mode declined to resume are new windows and get nothing.
func firstLaunchRestartNote(launchArgs: [String], exec: Bool,
                            carried: RestartNote? = nil) -> RestartNote? {
    if exec { return carried ?? execRestartNote }
    let options = optionsOnly(launchArgs)
    guard !options.contains("--fork-session"),
          (flagValue(launchArgs, "--resume") ?? flagValue(launchArgs, "-r")) != nil
              || options.contains(where: continueFlags.contains) else { return nil }
    return RestartNote(reason: "resume", background: 0, owed: true)
}

let restartWakeOutcomes = CapResumeOutcomes(typed: "restart-wake", failed: "restart-wake-failed",
                                            dropped: "restart-wake-dropped")

/// How long a roster-only arm waits for the notice, which landed 2s and 9s after the relaunch.
let restartWakeSettle: TimeInterval = 15

/// What a handoff tells the next child: why it was restarted, what the roster counted, and
/// whether the child it replaces had work the restart took (`restartOwed`). A note that cannot
/// say (an exec from a build that carried none, a resume by hand) owes the line.
struct RestartNote: Equatable {
    let reason: String
    let background: Int
    let owed: Bool
}

/// The note a handoff leaves, or nil for a relaunch that resumes nothing (fresh, second head).
func restartNoteForHandoff(reason: String, fresh: Bool, roster: SessionAgentsRecord?,
                           owed: Bool) -> RestartNote? {
    fresh ? nil : RestartNote(reason: reason, background: rosterBackgroundCount(roster), owed: owed)
}

/// Why a handoff owes, or does not owe, the next child a line. `owed` is what the gates read; the
/// word is what `handoff.log` records, so a restart says which reading decided it.
struct RestartOwedReading: Equatable {
    let owed: Bool
    let why: String
}

/// THE ONE DECISION the restart wake and the cap resume share (B-5730). In order: a transcript not
/// read to the end cannot say (owed); a live task or session-only cron in it is owed; a child that
/// never ran a turn cannot have started anything (not owed); a roster that cannot be read cannot
/// say (owed); otherwise the roster's count decides.
func restartOwed(roster: SessionAgentsRecord?, ranTurn: Bool, caughtUp: Bool,
                 live: RestartLiveWork, now: Date) -> RestartOwedReading {
    guard caughtUp else { return RestartOwedReading(owed: true, why: "catching-up") }
    if !live.tasks.isEmpty { return RestartOwedReading(owed: true, why: "live-task") }
    if live.liveCron(now: now) { return RestartOwedReading(owed: true, why: "live-cron") }
    // Every task is started by a tool call, so a child with no turn started none.
    guard ranTurn else { return RestartOwedReading(owed: false, why: "no-turn") }
    guard let roster else { return RestartOwedReading(owed: true, why: "unknown-roster") }
    return rosterBackgroundCount(roster) > 0
        ? RestartOwedReading(owed: true, why: "roster")
        : RestartOwedReading(owed: false, why: "none")
}

/// `handoff.log` (grep `restart-owed=`): one line per handoff, which reading decided it.
func restartOwedLine(pid: String, reason: String, reading: RestartOwedReading,
                     now: Date = Date()) -> String {
    "\(ISO8601DateFormatter().string(from: now)) pid=\(pid) restart-owed=\(reading.owed ? 1 : 0) "
        + "why=\(reading.why) reason=\(reason)\n"
}

/// `--restart-note` across a self-update exec: `reason,background,owed`. Absent or unreadable is
/// nil, which the new image reads as `execRestartNote` (owes the line).
let resuperviseRestartNoteFlag = "--restart-note"
func encodeRestartNote(_ note: RestartNote) -> String? {
    note.reason.contains(",") ? nil : "\(note.reason),\(note.background),\(note.owed ? 1 : 0)"
}
func decodeRestartNote(_ raw: String) -> RestartNote? {
    let f = raw.split(separator: ",", omittingEmptySubsequences: false)
    guard f.count == 3, !f[0].isEmpty, let n = Int(f[1]), n >= 0, f[2] == "0" || f[2] == "1"
    else { return nil }
    return RestartNote(reason: String(f[0]), background: n, owed: f[2] == "1")
}

/// Everything a believable roster says is running, subagents included; zero otherwise.
func rosterBackgroundCount(_ record: SessionAgentsRecord?) -> Int {
    guard let record, record.reportable != nil else { return 0 }
    return record.live.count + (record.background ?? 0)
}

func restartWakeMessage(reason: String, count: Int, limit: Int = sessionInputMaxBytes) -> String {
    let line = count > 0
        ? "[tally] Tally restarted Claude Code (\(reason)) and \(count) background task(s) were "
            + "stopped. Check which ones stopped and restart or resume them."
        : "[tally] Tally restarted Claude Code (\(reason)). Re-arm any monitors you had running and "
            + "pick up pending work; if nothing was running, no action is needed."
    return keystrokeClipped(line, bytes: limit)
}

struct RestartWakeState: Equatable {
    private(set) var offer: CapResumeState.Offer?
    /// The launch instant of the child the last arm was for: one line per relaunch.
    private(set) var armedFor: Date?
    /// The notice that raised it, so a notice read twice arms once.
    private(set) var noticeUUID: String?
    /// The hold last written to the log, so a wait is one line rather than one per tick.
    var lastHold: CapResumeHold?

    var isArmed: Bool { offer != nil }
    mutating func arm(_ offer: CapResumeState.Offer, child: Date, notice: String?) {
        self.offer = offer
        armedFor = child
        if let notice { noticeUUID = notice }
    }
    mutating func settle(_ offer: CapResumeState.Offer?) {
        self.offer = offer
        if offer == nil { lastHold = nil }
    }
}

/// The offer this child is owed now, or nil. Pure, so the whole grid is assertable.
func restartWakeOffer(state: RestartWakeState, spawnedByTally: Bool, resumesConversation: Bool,
                      note: RestartNote?, launchedAt: Date, notice: StoppedTaskNotice?,
                      answeredAt: Date?, userTurnAt: Date?, conversation: String?,
                      caughtUp: Bool, capOwnsChild: Bool, now: Date) -> CapResumeState.Offer? {
    guard spawnedByTally, resumesConversation, !state.isArmed, state.armedFor != launchedAt,
          !capOwnsChild, caughtUp, let conversation, userTurnAt == nil,
          now.timeIntervalSince(launchedAt) <= capResumeLife else { return nil }
    let roster = note?.background ?? 0
    if let notice {
        // The session answered after the notice: it is awake and has read it.
        guard notice.uuid != state.noticeUUID,
              answeredAt.map({ $0 <= notice.at }) ?? true else { return nil }
    } else {
        guard let note, note.owed, answeredAt == nil,
              now.timeIntervalSince(launchedAt) >= restartWakeSettle else { return nil }
    }
    let count = notice.map { max(roster, $0.ids.count, 1) } ?? roster
    return CapResumeState.Offer(at: notice?.at ?? now, conversation: conversation,
                                line: restartWakeMessage(reason: note?.reason ?? "self-update",
                                                         count: count))
}

/// The word a hold is logged under: the shared table's own case name, or this door's.
func restartWakeHoldWord(_ hold: CapResumeHold) -> String {
    if case .input(let why) = hold { return "\(why)" }
    return "\(hold)"
}

func restartWakeLogLine(pid: String, outcome: String, fields: String, now: Date = Date()) -> String {
    "\(ISO8601DateFormatter().string(from: now)) pid=\(pid) input=\(outcome) \(fields)\n"
}

/// One tick: raise the arm this tick found, drop it if the session answered on its own, then hand
/// what stands to the cap resume door. Returns the line typed, or nil.
@discardableResult
func applyRestartWake(_ state: inout RestartWakeState, pid: String, candidate: CapResumeState.Offer?,
                      source: String, launchedAt: Date, noticeUUID: String?, answeredAt: Date?,
                      typedAlready: Bool, session: SupervisedState, quiet: SessionQuiet,
                      turnEnded: () -> Bool, keyboardIdle: Bool, relaunchPlanned: Bool,
                      draftSuspected: Bool, waitingOnPerson: Bool, seen: SessionInputSeen? = nil,
                      caughtUp: Bool, userTurnAt: Date?, conversation: String?,
                      now: Date = Date(), log: URL = sessionInputLog,
                      stamped: () -> Date = { Date() },
                      inject: (String, SessionInputDraftGuard) -> SessionInputInjection = {
                          injectSessionInput($0, draft: $1)
                      }) -> String? {
    if let candidate {
        state.arm(candidate, child: launchedAt, notice: noticeUUID)
        appendSessionInputLine(restartWakeLogLine(
            pid: pid, outcome: "restart-wake-armed",
            fields: "source=\(source) conversation=\(candidate.conversation.prefix(8)) "
                + "at=\(ISO8601DateFormatter().string(from: candidate.at))", now: now), to: log)
    }
    if let offer = state.offer, answeredAt.map({ $0 > offer.at }) == true {
        state.settle(nil)
        appendSessionInputLine(restartWakeLogLine(pid: pid, outcome: restartWakeOutcomes.dropped,
                                                  fields: "reason=answered", now: now), to: log)
        return nil
    }
    guard state.isArmed else { return nil }
    var door = CapResumeState(offer: state.offer)
    let typed = applyCapResume(&door, pid: pid, typedAlready: typedAlready, session: session,
                               quiet: quiet, turnEnded: turnEnded, keyboardIdle: keyboardIdle,
                               relaunchPlanned: relaunchPlanned, draftSuspected: draftSuspected,
                               waitingOnPerson: waitingOnPerson, seen: seen, caughtUp: caughtUp,
                               userTurnAt: userTurnAt, conversation: conversation, now: now,
                               outcomes: restartWakeOutcomes, log: log, stamped: stamped,
                               held: { why in
                                   // Said once per hold rather than once per tick: a wait with no
                                   // line is what hid the 15-minute drafting hold (B-885).
                                   guard why != state.lastHold else { return }
                                   state.lastHold = why
                                   appendSessionInputLine(restartWakeLogLine(
                                       pid: pid, outcome: "restart-wake-held",
                                       fields: "reason=\(restartWakeHoldWord(why))", now: now),
                                       to: log)
                               },
                               inject: inject)
    state.settle(door.offer)
    return typed
}

/// The self-update background hold's record in `handoff.log` (grep `self-update-hold=`): `held` on
/// the first held tick, `released` or `expired` when the restart is planned. `roster` and
/// `rosterAt` are `selfUpdateRosterState`, so a release with work running says which reading lost it.
func selfUpdateHoldLine(pid: String, event: String, background: Int, heldSince: Date?,
                        roster: String, rosterAt: Date?, now: Date = Date()) -> String {
    let stamp = ISO8601DateFormatter()
    return "\(stamp.string(from: now)) pid=\(pid) self-update-hold=\(event) "
        + "background=\(background) heldSince=\(heldSince.map { stamp.string(from: $0) } ?? "none") "
        + "roster=\(roster) rosterAt=\(rosterAt.map { stamp.string(from: $0) } ?? "none")\n"
}

/// Why `currentGenerationRoster` did or did not hand the gate a roster, for the log only: `none` (no
/// file), `untrusted` (a count this Claude Code cannot vouch for), `stale` (written before this
/// child started) or `ok`. Mirrors that function's guard, and decides nothing.
func selfUpdateRosterState(_ record: SessionAgentsRecord?, childStartedAt: Date) -> String {
    guard let record else { return "none" }
    if record.reportable == nil { return "untrusted" }
    return record.updatedAt >= childStartedAt ? "ok" : "stale"
}
