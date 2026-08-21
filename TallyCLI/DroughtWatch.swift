import Foundation

// WHAT A PIN IS STILL WORTH ONCE THE ACCOUNT UNDER IT HAS NOTHING LEFT, and the one audit line a
// drought nobody could move a session out of leaves behind. Both come off one reading of the fleet,
// which is why they share a file: the question "is this account spent" is asked once per session
// per interval, and two stations asking it separately would be two answers to one file.
//
// THE INCIDENT (2026-08-21). A session that had been put on an account by hand sat on one whose
// flagship window had read 0% for eighty-one minutes. Every preventive mover refuses a pinned
// session on its FIRST gate (`mode != "manual"`: Rebalance.swift, WindowRepick.swift,
// TurnBoundaryMove.swift, ModelDegradation.swift), so all four declined for the whole of it, and
// the only mechanism left was the cap handoff, whose trigger is a turn that has ALREADY hit the
// wall. The session therefore lost a turn to a 429 and was moved 1.4 seconds later. Nothing
// misfired: the pin was read as "never move this conversation", when what a person naming an
// account says is "this account is my choice".
//
// THE RULE THIS ADDS, and the whole of it: a pin protects an account that still has something in
// it. Once the account's binding window has no effective remaining at all (`accountIsSpent`,
// AccountBinding.swift) the preventive movers may act on it, and the move that acts CLEARS a
// session pin and says so, exactly as the cap handoff has always done (`pinCleared(by:)`,
// ManualMoveState.swift). Everything else the pin does is untouched: a nearly dry account is not a
// spent one, and 1% is a pin honoured to the letter.
//
// WHAT IT DOES NOT REACH, deliberately. The APP's own pin (`mode == "manual"` in Settings) is the
// fleet saying Tally does not re-pick for it, one scope above any single session, so
// `pinYieldsToSpentAccount` refuses to release it and `capRecoveryAction` answers `.waitPinned` for
// such a session exactly as before. Observe-only is untouched for the same reason and by a
// different gate (AutoSteering.swift). What IS released is the session's own pin (`tally account`)
// and the project profile's (`tally project set --account`), which is the layer the incident's
// sibling case sits in: three projects on this machine pin an account, and until now a cap on one
// of them could not move the session at all.
//
// AND THE RELEASE HAS TO REACH THE PIN SWITCH TOO, which is the half that would otherwise make this
// a restart loop rather than a fix. `applyPinSwitch` drags a running session onto the pinned
// account whenever the two disagree, asking only whether that account is launchable and never
// whether it has quota (SessionSwitch.swift). So the release is applied to the policy the whole
// tick is judged by, not to the movers one at a time: with the pin released, the mover moves the
// session off the spent account AND the pin switch stands down instead of dragging it back. When
// the account refills the release lapses on its own and the standing instruction takes the session
// home again.
//
// WHY IT IS A STATION WITH A CLOCK RATHER THAN A TERM INSIDE EACH MOVER. Those movers refuse on
// `mode` BEFORE they read the snapshot, which is not an accident of ordering but the thing that
// keeps a 2 second poll affordable: `rebalanceMove` says so at length about its own `@autoclosure`.
// Teaching each of them to look past a pin would mean reading and decoding `~/.tally/snapshot.json`
// every two seconds for every pinned session. So the reading is taken here, at the rate the
// advisory knock already reads at (`droughtWatchInterval`), and the release is at most one interval
// late for a condition that lasts the rest of a window.
//
// THE SECOND CONSUMER IS OBSERVABILITY, and it is the reason this file is not called PinYield: the
// incident left NO trace anywhere. `handoff.log` and `input.log` say nothing about a session
// sitting on a 0% account, so the eighty-one minutes had to be reconstructed from window values in
// `history.jsonl` after the fact. One line per drought, naming the gates that refused, is what
// makes "a mover wanted to act and something stopped it" answerable from the record instead.

/// How often the reading behind both consumers is taken.
///
/// The knock's interval (`quotaKnockInterval`), and the same argument: the poll loop runs every two
/// seconds, the app republishes the snapshot every minute or two, and reading it thirty times for
/// one new number is the cost this bounds. What it costs to be a whole interval late is bounded on
/// the other side by what the reading is ABOUT - an account with nothing left stays that way until
/// its window resets, which is hours rather than seconds.
let droughtWatchInterval: TimeInterval = quotaKnockInterval

/// Whether the pins standing over a session yield to the account under it being spent.
///
/// `appMode` is the APP's own mode, read before either overlay (`launchPolicy`, never
/// `effectivePolicy`): a project profile and a session pin both present themselves to the rest of
/// the loop AS a manual pin, so the folded policy cannot tell which scope pinned it, and this is
/// the one question where the scopes differ. The fleet's own pin is never released; the two below
/// it are, once there is nothing left to protect.
func pinYieldsToSpentAccount(appMode: String, spent: Bool) -> Bool {
    spent && appMode != "manual"
}

/// The same policy as every mover on this tick judges it: with a released pin reading as automatic
/// selection.
///
/// ONLY `mode` MOVES. `pinnedAccountID` is left standing because it is a record of what the user
/// asked for rather than an instruction on its own - every reader of it is behind a
/// `mode == "manual"` guard (`capReading`, `applyPinSwitch`, `pinnedAccount`) - and because the
/// release is meant to lapse: when the account refills, the unreleased policy is the same document
/// it always was.
func pinReleasedPolicy(_ policy: LaunchPolicy, yielding: Bool) -> LaunchPolicy {
    guard yielding, policy.mode == "manual" else { return policy }
    var released = policy
    released.mode = "auto"
    return released
}

/// Which of the preventive movers' gates are refusing this session, named for the audit line.
///
/// The terms are `rebalanceAllowedForSession`'s, in the order they bite there, plus the two the
/// turn-boundary mover adds (`draftSuspected`, and the same keyboard bar under `isQuiet`) and the
/// one question that needs the fleet (`hasTarget`, which is `capHandoffTarget` answering nothing).
/// One list rather than a sentence per mover: what a reader of this log wants is "what stopped
/// anything from happening", and the three movers refuse on the same facts.
func droughtBlockers(steering: Bool, mode: String, blocked: Bool, agentsWorking: Bool,
                     isQuiet: Bool, draftSuspected: Bool, carryable: Bool, fuseAllows: Bool,
                     hasTarget: Bool) -> [String] {
    var named: [String] = []
    if !steering { named.append("steering-off") }
    if mode == "manual" { named.append("mode-manual") }
    if blocked { named.append("waiting-on-person") }
    if agentsWorking { named.append("agents-working") }
    if !isQuiet { named.append("session-busy") }
    if draftSuspected { named.append("draft-suspected") }
    if !carryable { named.append("not-carryable") }
    if !fuseAllows { named.append("fuse-spent") }
    if !hasTarget { named.append("no-target") }
    return named
}

/// The line a blocked drought leaves in the handoff log (grep `drought=blocked`).
///
/// Pure, and formatted like every other line in that file (SupervisorRuntime.swift): the stamp, the
/// session, the pid, a marker naming what kind of record this is, and `cwd` LAST because it is the
/// field that can contain a space.
///
/// IT NAMES THE BINDING WINDOW RATHER THAN "the model window", which the incident report's sketch
/// called it: what makes an account spent is its emptiest counted window (`bindingWindow`), and on
/// this fleet that is as often the weekly one as the flagship. A field that said `model-window` for
/// a spent weekly would be the log telling its reader something untrue about which wall they hit.
///
/// The percentage is the EFFECTIVE remaining, the reading the gates weigh, so the number here and
/// the decision it describes cannot disagree: a window minutes from resetting reads as full to
/// both.
func droughtAuditLine(sessionID: String?, pid: String, account: String, window: String?,
                      remaining: Double?, blockers: [String], cwd: String,
                      now: Date = Date()) -> String {
    let stamp = ISO8601DateFormatter().string(from: now)
    let sid = sessionID.map { String($0.prefix(8)) } ?? "unknown"
    let left = remaining.map { "\(Int($0.rounded()))%" } ?? "unknown"
    return "\(stamp) session=\(sid) pid=\(pid) drought=blocked account=\(account) "
        + "window=\(window ?? "unknown") remaining=\(left) "
        + "movers-blocked=\(blockers.joined(separator: ",")) cwd=\(cwd)\n"
}

/// What one supervised session knows about the account under it running out.
///
/// In memory and per SESSION rather than per child, like the knock's arm beside it: a relaunch does
/// not change what the fleet says, and a relaunch that MOVES accounts re-keys this by the account
/// rather than by the cycle (see `observe`).
struct DroughtWatch {
    /// The account every field below is about. A move makes all of them meaningless at once, which
    /// is why they are re-taken rather than aged out when it changes.
    private(set) var accountID: String?
    /// Whether that account had no effective remaining at all when it was last read.
    private(set) var spent = false
    /// Its binding window's name and effective remaining, for the audit line.
    private(set) var window: String?
    private(set) var remaining: Double?
    /// Whether anything comfortable exists to move to, by the gate every mover picks through.
    private(set) var hasTarget = false
    /// The drought that reading belongs to, keyed as the rebalance keys its claim
    /// (`rebalanceCycleKey`), so one audit line covers one window cycle however long it lasts.
    private(set) var cycle: String?
    /// When the reading was taken, which is what `droughtWatchInterval` is measured from.
    private var checkedAt: Date?
    /// Whether this drought has already left a line, and which drought that was.
    private var audited = false
    private var auditedCycle: String?

    /// Whether this tick reads the fleet at all. A session that has just MOVED reads immediately:
    /// the interval bounds how often one account is re-read, and the account under this session is
    /// not the one the last reading was about.
    func due(on account: String, now: Date) -> Bool {
        guard account == accountID, let checkedAt else { return true }
        return now.timeIntervalSince(checkedAt) >= droughtWatchInterval
    }

    /// Take the reading, at most once per interval.
    ///
    /// `loaded` is the snapshot read, `@autoclosure` for the reason `rebalanceMove` states in full:
    /// nearly every tick reaches this station and one in fifteen of them takes a reading, so a plain
    /// default argument would be evaluated at the call site on every 2 second poll.
    ///
    /// A SNAPSHOT THAT CANNOT ANSWER RELEASES NOTHING. Too old to trust, unreadable, or not naming
    /// this account are all `liveMoveField` answering nil, and every one of them leaves `spent`
    /// false: releasing a pin is an act taken against what the user asked for, and an exemption
    /// invented out of missing data is exactly the mistake `accountIsSpent` refuses to make with a
    /// held-over zero.
    mutating func observe(provider: String, account: Snapshot.Account, primaryModel: String?,
                          quarantine: [String: (model: String?, until: Date)] = [:],
                          reserves: AccountReserves = .none,
                          loaded: @autoclosure () -> (Snapshot?, String?) = loadSnapshot(),
                          now: Date = Date()) {
        guard due(on: account.id, now: now) else { return }
        if accountID != account.id {
            // A different account is a different drought, and nothing recorded about the last one
            // describes this one - including whether it has been written down.
            audited = false
            auditedCycle = nil
            accountID = account.id
        }
        checkedAt = now
        guard let field = liveMoveField(provider: provider, account: account,
                                        primaryModel: primaryModel, quarantine: quarantine,
                                        loaded: loaded(), now: now) else {
            spent = false
            window = nil
            remaining = nil
            hasTarget = false
            cycle = nil
            return
        }
        let binding = bindingWindow(field.current, primaryModel: primaryModel, reserves: reserves,
                                    now: now)
        spent = accountIsSpent(field.current, primaryModel: primaryModel, reserves: reserves,
                               now: now)
        window = binding?.name
        remaining = binding.map { effectiveRemaining(comfortWindow($0), now: now) }
        hasTarget = capHandoffTarget(field.candidates, primaryModel: primaryModel,
                                     reserves: reserves, now: now) != nil
        cycle = rebalanceCycleKey(field.current, primaryModel: primaryModel, now: now)
    }

    /// The audit line this tick owes, or nil - which is nearly every tick.
    ///
    /// Three things have to be true. The account is SPENT, not merely nearly dry, because a session
    /// on a 4% account is one the movers are still expected to carry off in the ordinary way and a
    /// line per nearly dry window would bury the case this exists for. Something is REFUSING, since
    /// a drought with no blocker is a drought the mover is about to end and the move writes its own
    /// line. And this drought has not been written down already, keyed by the same same-drought rule
    /// the knock and the rebalance claim share (`quotaKnockSameCycle`) so a reported reset drifting
    /// by a minute does not spell a second line.
    ///
    /// `blockers` is a closure because it is only asked for on the tick a line is actually written:
    /// naming them costs the transcript read behind the 120 second bar, which no ordinary tick
    /// should pay for a record it is not going to leave.
    ///
    /// It RETURNS the line rather than writing it, so that reaching this decision in a test cannot
    /// append to the user's own audit history - the rule `appendHandoffLine` states about its sink.
    mutating func audit(account: String, sessionID: String?, pid: String, cwd: String,
                        blockers: () -> [String], now: Date = Date()) -> String? {
        let alreadyWritten = audited && quotaKnockSameCycle(auditedCycle, cycle)
        guard spent, !alreadyWritten else { return nil }
        let named = blockers()
        guard !named.isEmpty else { return nil }
        audited = true
        auditedCycle = cycle
        return droughtAuditLine(sessionID: sessionID, pid: pid, account: account, window: window,
                                remaining: remaining, blockers: named, cwd: cwd, now: now)
    }
}

// MARK: - The tick's station

/// One poll tick's audit of a drought nothing could move this session out of. Nothing happens on
/// the vast majority of ticks: the account is not spent, or this drought has already been written
/// down, or a mover is about to act.
///
/// A station rather than four lines in the poll loop, on the same terms as every other decision
/// lifted out of that file: it is at the repo's size cap, and the gates are all answerable without
/// a child.
///
/// `isQuiet` and `fuseAllows` are `@autoclosure` because both cost something the ordinary tick has
/// no reason to pay - the first reads the transcript behind the 120 second bar, the second prunes
/// the fuse - and neither is asked unless a line is actually being written.
///
/// `log` has no default, the rule `appendHandoffLine` states in full: a call site that can reach
/// the user's own audit history by saying nothing is one that eventually will.
func applyDroughtAudit(_ watch: inout DroughtWatch, relaunchPlanned: Bool, account: String,
                       sessionID: String?, pid: String, cwd: String,
                       steering: Bool, mode: String, blocked: Bool, agentsWorking: Bool,
                       isQuiet: @autoclosure () -> Bool, draftSuspected: Bool, carryable: Bool,
                       fuseAllows: @autoclosure () -> Bool, now: Date = Date(), log: URL) {
    guard !relaunchPlanned else { return }
    // Read out before the call: `audit` takes the watch `inout`, so reading a property of it from
    // inside the closure would be a simultaneous access - which compiles without a word and traps
    // at runtime (measured on this track 2026-08-02, and stated beside the reload repick).
    let hasTarget = watch.hasTarget
    guard let line = watch.audit(account: account, sessionID: sessionID, pid: pid, cwd: cwd,
                                 blockers: {
                                     droughtBlockers(steering: steering, mode: mode,
                                                     blocked: blocked, agentsWorking: agentsWorking,
                                                     isQuiet: isQuiet(),
                                                     draftSuspected: draftSuspected,
                                                     carryable: carryable, fuseAllows: fuseAllows(),
                                                     hasTarget: hasTarget)
                                 }, now: now)
    else { return }
    appendHandoffLine(line, to: log)
}
