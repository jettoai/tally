import Foundation

// WHAT A PIN IS STILL WORTH ONCE THE ACCOUNT UNDER IT HAS NOTHING LEFT, and the one audit line a
// drought nobody could move a session out of leaves behind. Both come off one reading of the fleet,
// which is why they share a file: the snapshot is read once per session per interval and answered
// twice from, and two stations reading it separately would be two answers to one file.
//
// THE TWO QUESTIONS ARE ABOUT DIFFERENT ACCOUNTS, which is the single most important thing here and
// the one this file first got wrong (`pinnedSpent` carries the whole account of it). The RELEASE is
// about the account the pin NAMES; the AUDIT is about the account the session is SITTING ON. They
// are the same row until the moment a mover acts, and from that moment until the pinned account
// refills they are different rows, which is exactly the window in which everything below matters.
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
// it. Once the binding window of THE ACCOUNT THE PIN NAMES has no effective remaining at all
// (`accountIsSpent`, AccountBinding.swift) the preventive movers may act on the session, and the
// move that acts CLEARS a session pin and says so, exactly as the cap handoff has always done
// (`pinCleared(by:)`, ManualMoveState.swift). Everything else the pin does is untouched: a nearly
// dry account is not a spent one, and 1% is a pin honoured to the letter.
//
// THE ACCOUNT THE PIN NAMES, NOT THE ACCOUNT THE SESSION IS ON, and the first version of this file
// said the second (codex review of 7404128, raised to Critical on independent verification;
// `capgap-rootcause.md:140` had specified the first all along). What that costs is a restart loop,
// and it lands exactly on the case this feature was written to rescue:
//
//   1. a project profile pins D, D is spent, so the release stands and a preventive mover carries
//      the session to healthy S;
//   2. the next reading is taken against S, which is not spent, so the release lapses;
//   3. `applyPinSwitch` asks only whether D is LAUNCHABLE, never whether it has quota, and drags
//      the session back to D;
//   4. and D is still spent, so step 1 happens again.
//
// It ends when the RecoveryFuse runs out, three moves per ten minutes, and that fuse is SHARED with
// the cap handoff (`applyCapHandoff(fuseAllows:)`): for the rest of that window the one mechanism
// that worked before this feature existed is refused too. A session pin does not loop, because the
// move that carries it off clears it; a project profile is not cleared by anything, and three repos
// on this machine set one.
//
// KEYING IT ON THE PINNED ROW IS ALSO WHAT MAKES THE RELEASE LAST. There is no separate latch and
// no expiry: each interval re-reads the row the pin names, so the release holds for as long as that
// account is empty and lapses by itself the moment it refills, which is when the standing
// instruction should take the session home again.
//
// THE ONE CELL THE OLD KEYING COVERED AND THIS ONE DOES NOT, named here rather than left to be
// discovered: a pin naming an account THIS FLEET NO LONGER HAS, over a session sitting on a spent
// one. Judged on the session's own account that released and a mover carried it off; judged on the
// pinned row there is no row to judge, so nothing is released and the preventive movers go on
// refusing. It is a narrowing of the rescue rather than a new break - it is exactly where a pinned
// session stood before this feature existed - and it is deliberately not widened with a `?? spent`
// fallback, because that is the old defect written as a default and it would make "this fleet has
// no such account" indistinguishable from "the account the pin names is empty". A session pin
// cannot reach this state (`tally account` cancels a pin whose account leaves the fleet,
// SessionSwitch.swift); a project profile naming a removed account can, and nothing validates one
// today.
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

/// Whether the pins standing over a session yield, given that the account they NAME is spent.
///
/// `appMode` is the APP's own mode, read before either overlay (`launchPolicy`, never
/// `effectivePolicy`): a project profile and a session pin both present themselves to the rest of
/// the loop AS a manual pin, so the folded policy cannot tell which scope pinned it, and this is
/// the one question where the scopes differ. The fleet's own pin is never released; the two below
/// it are, once there is nothing left to protect.
///
/// `pinnedSpent` IS SPELLED OUT AT EVERY CALL SITE, and the label is the fix rather than a
/// decoration: this argument used to be called `spent`, every caller handed it the reading for the
/// account the session was sitting on, and nothing in the sentence `pinYieldsToSpentAccount(appMode:
/// spent:)` asked WHICH account (see the header for what that cost).
func pinYieldsToSpentAccount(appMode: String, pinnedSpent: Bool) -> Bool {
    pinnedSpent && appMode != "manual"
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

/// The row the RELEASE is about: the account the pins over this session name, as this reading of
/// the fleet reports it.
///
/// nil for three different situations that are one answer, on the rule `observe` states in full: no
/// pin at all (there is nothing to release, so nothing to judge), a snapshot that could not be read,
/// and a pin naming an account this fleet no longer has. Releasing a pin acts against what the user
/// asked for, and an exemption invented out of missing data is the mistake this repo refuses to make
/// everywhere else it reads this file.
///
/// A pin naming the account the session is ON resolves to that same row, which is why the ordinary
/// case needs no branch: until a mover acts, the release and the audit are two readings of one row.
func droughtPinnedRow(_ pinned: String?, in snapshot: Snapshot?) -> Snapshot.Account? {
    guard let pinned, let snapshot else { return nil }
    return snapshot.accounts.first { $0.id == pinned }
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
///
/// `burstAge` IS HOW OLD THE DRAFT EVIDENCE IS, in whole seconds, and it is here because the one
/// blocker that turned out to matter is the one this line could say nothing about (2026-09-02).
/// `draft-suspected` named 21 of the first 25 blocked droughts on this machine and stood alone in
/// ten of them, and reconstructing WHY took the burst's age to be inferred from the absence of
/// `session-busy` in the same field. A keyboard stamp nothing has refreshed for eleven minutes and
/// a person mid-sentence are the same word in `movers-blocked` and different situations entirely;
/// this is the number that separates them without anybody having to infer it. `none` where the
/// terminal carries no burst at all, which is what a session nobody has typed in looks like.
func droughtAuditLine(sessionID: String?, pid: String, account: String, window: String?,
                      remaining: Double?, blockers: [String], burstAge: TimeInterval?, cwd: String,
                      now: Date = Date()) -> String {
    let stamp = ISO8601DateFormatter().string(from: now)
    let sid = sessionID.map { String($0.prefix(8)) } ?? "unknown"
    let left = remaining.map { "\(Int($0.rounded()))%" } ?? "unknown"
    let age = burstAge.map { "\(Int($0.rounded()))" } ?? "none"
    return "\(stamp) session=\(sid) pid=\(pid) drought=blocked account=\(account) "
        + "window=\(window ?? "unknown") remaining=\(left) "
        + "movers-blocked=\(blockers.joined(separator: ",")) burst-age=\(age) cwd=\(cwd)\n"
}

/// What one supervised session knows about the account under it running out.
///
/// In memory and per SESSION rather than per child, like the knock's arm beside it: a relaunch does
/// not change what the fleet says, and a relaunch that MOVES accounts re-keys this by the account
/// rather than by the cycle (see `observe`).
struct DroughtWatch {
    /// The account the session is SITTING ON, which is what the audit fields below are about. A move
    /// makes all of them meaningless at once, which is why they are re-taken rather than aged out
    /// when it changes.
    private(set) var accountID: String?
    /// The account the pins over this session NAME, which is what `pinnedSpent` is about. Held
    /// beside the one above rather than assumed equal to it: they are the same until a mover acts
    /// and different from then until the pinned account refills.
    private(set) var pinnedID: String?
    /// Whether the account the session is sitting on had no effective remaining at all when it was
    /// last read. THE AUDIT'S input, never the release's: a session that has been carried onto a
    /// healthy account is not in a drought, and a line saying it was would be untrue.
    private(set) var spent = false
    /// Whether the account the PIN names had none. THE RELEASE's input, and the whole of the
    /// difference between a pin that yields for as long as its account is empty and a restart loop
    /// (see the header).
    private(set) var pinnedSpent = false
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
    /// the interval bounds how often one PAIR of accounts is re-read, and neither of these is the
    /// one the last reading was about.
    ///
    /// BOTH HALVES OF THE KEY, because either one changing makes the last reading describe
    /// something else: the session was carried somewhere (the audit's row moved) or the pin was
    /// changed or served (the release's row moved). A `tally switch` consumed later in this same
    /// tick is the second case, and it is answered on the next tick rather than this one, which is
    /// two seconds rather than the interval.
    func due(on account: String, pinned: String?, now: Date) -> Bool {
        guard account == accountID, pinned == pinnedID, let checkedAt else { return true }
        return now.timeIntervalSince(checkedAt) >= droughtWatchInterval
    }

    /// Take the reading, at most once per interval.
    ///
    /// `loaded` is the snapshot read, `@autoclosure` for the reason `rebalanceMove` states in full:
    /// nearly every tick reaches this station and one in fifteen of them takes a reading, so a plain
    /// default argument would be evaluated at the call site on every 2 second poll.
    ///
    /// `pinned` is the account the pins over this session NAME, innermost scope first (a session pin
    /// over the fleet's own reading, which is the order `sessionPolicy` folds them in). nil when
    /// nothing is pinned, which leaves `pinnedSpent` false: with no pin there is nothing to release.
    ///
    /// A SNAPSHOT THAT CANNOT ANSWER RELEASES NOTHING. Too old to trust, unreadable, or not naming
    /// this account are all `liveMoveField` answering nil, and every one of them leaves both
    /// readings false: releasing a pin is an act taken against what the user asked for, and an
    /// exemption invented out of missing data is exactly the mistake `accountIsSpent` refuses to
    /// make with a held-over zero. A pin naming an account this snapshot does not carry gets the
    /// same answer for the same reason (`droughtPinnedRow`).
    mutating func observe(provider: String, account: Snapshot.Account, primaryModel: String?,
                          pinned: String? = nil,
                          quarantine: [String: (model: String?, until: Date)] = [:],
                          reserves: AccountReserves = .none,
                          loaded: @autoclosure () -> (Snapshot?, String?) = loadSnapshot(),
                          now: Date = Date()) {
        guard due(on: account.id, pinned: pinned, now: now) else { return }
        if accountID != account.id {
            // A different account is a different drought, and nothing recorded about the last one
            // describes this one - including whether it has been written down. Keyed on the account
            // the session SITS on, because that is what an audit line is about: a pin being moved
            // changes which row the release reads and says nothing about the drought this session
            // is or is not in.
            audited = false
            auditedCycle = nil
            accountID = account.id
        }
        pinnedID = pinned
        checkedAt = now
        // ONE READ, TWO ROWS. `loaded` is an autoclosure, so it is bound once here rather than
        // called twice: a second call is a second decode of `~/.tally/snapshot.json`, and worse, it
        // can return a DIFFERENT version of the file (the app rewrites it every minute or two), so
        // the release and the audit could come to describe two different moments.
        let reading = loaded()
        guard let field = liveMoveField(provider: provider, account: account,
                                        primaryModel: primaryModel, quarantine: quarantine,
                                        loaded: reading, now: now) else {
            spent = false
            pinnedSpent = false
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
        // AND THE ROW THE RELEASE IS ABOUT, which is the same one until a mover acts. Read out of
        // the snapshot rather than out of `field`, which cannot answer it: `current` is the account
        // the session is on and `candidates` has the pinned account filtered out of it whenever it
        // is quarantined or cannot serve this model, and a pin over a quarantined account is
        // precisely a pin that must go on yielding.
        pinnedSpent = droughtPinnedRow(pinned, in: reading.0).map {
            accountIsSpent($0, primaryModel: primaryModel, reserves: reserves, now: now)
        } ?? false
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
                        burstAt: Date? = nil, blockers: () -> [String],
                        now: Date = Date()) -> String? {
        let alreadyWritten = audited && quotaKnockSameCycle(auditedCycle, cycle)
        guard spent, !alreadyWritten else { return nil }
        let named = blockers()
        guard !named.isEmpty else { return nil }
        audited = true
        auditedCycle = cycle
        // The AGE rather than the stamp, measured against the clock this line is dated by: what a
        // reader wants of that field is how stale the draft evidence was at the moment these gates
        // refused, and two absolute times in one line is a subtraction the reader has to perform.
        return droughtAuditLine(sessionID: sessionID, pid: pid, account: account, window: window,
                                remaining: remaining, blockers: named,
                                burstAge: burstAt.map { now.timeIntervalSince($0) }, cwd: cwd,
                                now: now)
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
                       isQuiet: @autoclosure () -> Bool, draftSuspected: Bool, burstAt: Date?,
                       carryable: Bool,
                       fuseAllows: @autoclosure () -> Bool, now: Date = Date(), log: URL) {
    guard !relaunchPlanned else { return }
    // Read out before the call: `audit` takes the watch `inout`, so reading a property of it from
    // inside the closure would be a simultaneous access - which compiles without a word and traps
    // at runtime (measured on this track 2026-08-02, and stated beside the reload repick).
    let hasTarget = watch.hasTarget
    guard let line = watch.audit(account: account, sessionID: sessionID, pid: pid, cwd: cwd,
                                 burstAt: burstAt,
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
