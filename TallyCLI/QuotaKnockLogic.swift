import Foundation

// THE ADVISORY KNOCK, decided: when a session is told that the account under it is running out, and
// what that sentence says. The tick that acts on this decision is next door (QuotaKnock.swift), the
// same split `ResetHintLogic` keeps from its notifier and for the same reason: everything here is
// pure, so the whole table is assertable without a snapshot, a terminal or a supervisor.
//
// WHY A SENTENCE RATHER THAN A MOVE. The idle rebalance (Rebalance.swift) already carries a session
// off a dying account, and the window repick takes that move at the cheapest moment a session has.
// Both of them need the session to be IDLE, which is the one thing a session in the middle of a
// work package is not, so the sessions that ride an account into the wall are precisely the ones
// those movers leave alone. What such a session needs is not a restart mid-package, it is the fact:
// so this says the fact into its own composer and lets the conversation decide what to do with it -
// finish the package and switch accounts, or wait the reset out.
//
// WHY 15% RATHER THAN THE 5% EVERY MOVER DRAWS. A move is still worth taking at 5% because nothing
// is lost by taking it late; advice at 5% is worth nothing, because there is no runway left to act
// on. This line is the runway rather than the wall, and it is deliberately EARLIER than the movers'
// line rather than a second opinion about when an account is dry: at 15% no mover has fired yet, and
// by the time one does the session has already been told why it is about to be moved.
//
// WHAT THE SENTENCE HAS TO CARRY for the reader to decide anything: which window is binding and how
// long until it refills (waiting is only a plan when the reset is close), how many sessions are on
// that account (three conversations sharing one window drain it three times as fast, so "wait for
// the reset" stops being a plan), and where else there is room. Everything in it is quoted from the
// same functions the account picks quote (`windowReason`, `pickReason`), so the advice and the move
// can never describe the fleet differently.

/// The line an account's binding window has to fall to before its sessions are told.
///
/// Effective remaining rather than the raw percentage (`effectiveRemaining`), the reading every
/// other gate here weighs: a window resetting in five minutes is a full window, and telling a
/// session to wrap up over one would be advice against the user's own interest.
let quotaKnockPercent = 15.0

/// Back above this inside the same cycle and the whole ladder below re-arms.
///
/// The shape `ResetHintLogic` uses (5 to fire, 30 to re-arm) rather than a second hysteresis of its
/// own. A window that has climbed back over 30% is not the drought that was announced, and the next
/// time it drains is a fresh piece of news rather than a repeat of the old one. Between the two
/// lines nothing changes, which is the whole point of the gap: an account hovering at 14% and 16%
/// says its sentence once.
let quotaKnockRearmPercent = 30.0

/// THE LADDER: the three readings worth a sentence of their own, descending.
///
/// One sentence per DROUGHT was the shape until 2026-08-21, and the incident that day is what it
/// costs. An account crossed 15% at 18:04 and was announced; it crossed 5% three hours later and
/// hit zero nine hours after that, and because all three readings belong to one window cycle the
/// arm stayed spent through every one of them. Eleven hours and seventeen minutes after the only
/// thing anybody was told, a session rode that account into a 429. The re-arm was written for an
/// account HOVERING at the line, which is a real thing to protect against; it also silenced the one
/// direction that is always news.
///
/// So a step is announced once and a LOWER one is announced again. The three are the lines this
/// repo already draws rather than three new numbers: 15% is the runway (`quotaKnockPercent`), 5% is
/// the line every mover treats as dying (`nearlyDryPercent`, AccountComfort.swift), and 0 is the
/// wall itself - which is worth a sentence of its own precisely because it is the reading that says
/// "your next turn is the one that fails".
///
/// Going back UP never says anything: only crossing a lower line does, and the 30% re-arm above is
/// what starts the ladder over. An account that drifts between 6% and 4% says its second sentence
/// once, on the same reasoning the gap was written for.
let quotaKnockSteps: [Double] = [quotaKnockPercent, nearlyDryPercent, 0]

/// Which rung a reading has reached: the LOWEST line it is at or under, or nil above all of them.
///
/// At or under, the rule every threshold in this repo follows, which is what makes zero a rung
/// rather than an unreachable one: a spent window reports exactly 0.
func quotaKnockStep(_ remaining: Double) -> Double? {
    quotaKnockSteps.last { remaining <= $0 }
}

/// How often the reading behind this is taken at all.
///
/// The poll loop runs every 2 seconds and the app republishes the snapshot every minute or two, so
/// asking on every tick would read and decode the same file thirty times for one new number. Thirty
/// seconds is far below the rate the numbers move at and far above the rate the tick runs at, and
/// what it bounds is the only cost this feature has on an ordinary tick.
let quotaKnockInterval: TimeInterval = 30

/// How much of an account name the sentence carries, in UTF-8 BYTES.
///
/// Bytes rather than characters because bytes are the thing being bounded: the channel's limit is
/// 200 of them and each one is 30ms of the poll loop's own time (`sessionInputByteGap`), so a
/// character budget lets one emoji cost four times what a Latin letter does and one CJK label
/// spend the whole line. Measured against the fleet this is written for, whose labels are "Claude"
/// and "Claude 2" (8 bytes), 32 leaves room for a name in any script while keeping two of them
/// well inside the sentence.
let quotaKnockLabelBytes = 32

/// Whether this supervisor was asked to knock once on its next eligible tick, whatever the quota
/// says (`TALLY_QUOTA_KNOCK_FORCE=1`).
///
/// A DEVELOPMENT FLAG IN THE SHAPE THIS CLI ALREADY USES for the others it has (`TALLY_AUTO_HANDOFF`,
/// `TALLY_AUTO_FOLLOW`): an environment variable read once, at start-up, by the process it steers.
/// It exists because the alternative way to see this feature work is to burn an account down to 15%,
/// and what it fires is the REAL sentence built from the REAL snapshot - it forces the moment, never
/// the content, so what a reader sees is what a drought would have sent them.
func quotaKnockForceRequested() -> Bool {
    guard let raw = getenv("TALLY_QUOTA_KNOCK_FORCE") else { return false }
    return String(cString: raw) == "1"
}

/// Whether two cycle keys name the same drought, including the case neither names one.
///
/// nil is a legitimate key here and it means "this account publishes no reset time", which is a
/// state an account can sit in for as long as the app has not read one. Two nils are therefore the
/// same drought - one sentence, not one per tick - and a nil beside a real key is not, because a
/// window that has started reporting a reset is news the account did not have before. Anything else
/// is the CLI's one same-drought rule (`namesSameDrought`, Rebalance.swift), tolerance included: a
/// reported reset drifts by a minute between polls without the window having moved at all.
func quotaKnockSameCycle(_ one: String?, _ other: String?) -> Bool {
    switch (one, other) {
    case (nil, nil): return true
    case (let a?, let b?): return namesSameDrought(a, b)
    default: return false
    }
}

/// What one supervised session remembers about the knock between ticks. In memory and per session,
/// like `SessionInputState` and `ManualMoveState` beside it: every session on the account is meant
/// to hear this, so there is nothing to serialize across supervisors and no claim to take. A
/// supervisor restarted mid-drought says it once more, which is the honest cost of holding this in
/// memory and is stated rather than defended against.
///
/// Held per SESSION rather than per child, so a relaunch does not re-announce a drought the
/// conversation has already been told about. A relaunch that MOVES accounts is a different matter
/// and is handled explicitly below: it re-arms because the ACCOUNT changed, never because the cycle
/// key happened to.
struct QuotaKnockState: Equatable {
    /// The account the flag below belongs to.
    ///
    /// IT IS NOT ENOUGH TO REMEMBER THE CYCLE. A cycle key is a reset time, and two accounts can
    /// report the same one: the fleet this is written for has accounts whose weekly windows turn
    /// over within the five-minute tolerance of each other, and an account that publishes no reset
    /// at all keys on nil, which matches every other nil (`quotaKnockSameCycle`). So a session
    /// handed from a spent account to a sibling could arrive carrying a `fired` flag that named
    /// nobody, and the new account's warning would be swallowed for the life of its drought - the
    /// one moment this feature exists for (codex review of c12a1df).
    private(set) var accountID: String?
    /// The drought the flag below belongs to, keyed as the rebalance keys its claim.
    private(set) var cycleKey: String?
    /// The lowest rung of the ladder this drought has been told about, or nil when nothing has been
    /// said yet (`quotaKnockSteps`). It replaced a Bool on 2026-08-21: what the Bool could not
    /// express is that the same drought has three things worth saying at three different depths.
    private(set) var announced: Double?
    /// The rung the last reading says is owed, spent by `spend()`. Held rather than returned so the
    /// sending side can tell the sentence WHICH reading it is for without taking a second one.
    private(set) var owed: Double?
    /// When the reading was last taken, which is what `quotaKnockInterval` is measured from.
    private(set) var checkedAt: Date?
    /// The one forced knock a development flag asks for, spent by the first one that is sent.
    private(set) var forced: Bool

    init(forced: Bool = quotaKnockForceRequested()) { self.forced = forced }

    /// Whether this tick takes a reading at all. A forced knock does not wait out the interval:
    /// what it is for is somebody watching a terminal for it.
    func due(now: Date) -> Bool {
        guard !forced, let checkedAt else { return true }
        return now.timeIntervalSince(checkedAt) >= quotaKnockInterval
    }

    /// A reading was taken at `now`, whatever came of it.
    ///
    /// Its own entry point because the reading can end before there is anything to fold in: a
    /// snapshot too old to trust, or one that does not name this account, answers nothing, and the
    /// tick that asked still ASKED. Left unrecorded, `due` said yes on the very next tick and the
    /// station re-read `~/.tally/snapshot.json` every two seconds for as long as Tally.app was not
    /// running - which is exactly when nothing can come of it (codex review of c12a1df).
    mutating func noteChecked(now: Date) { checkedAt = now }

    /// Fold one reading in, and answer whether this session is owed the sentence.
    ///
    /// IT DOES NOT MARK THE SENTENCE SENT, which is the whole reason this is not one function with
    /// the send. The composer may be busy at the moment the account crosses the line, and a flag
    /// raised there would spend the announcement on a tick that typed nothing: the sending side
    /// calls `spend()` when the bytes are actually on their way, and until then this keeps
    /// answering yes.
    ///
    /// The re-arm is applied before the answer rather than after, so an account that refilled past
    /// `quotaKnockRearmPercent` and drained again inside one cycle (a weekly window under a
    /// session window that reset) is a fresh drought to this.
    ///
    /// A DIFFERENT ACCOUNT IS ALWAYS A FRESH START, asked before the cycle and independently of it:
    /// the account is what the sentence is ABOUT, so a flag raised for one account says nothing
    /// about another whatever their reset times happen to look like (see `accountID`).
    ///
    /// WHAT IS OWED IS A RUNG BEING CROSSED, not a line being under: a reading owes a sentence when
    /// it has reached a step of the ladder LOWER than the deepest one this drought has already been
    /// told about (`quotaKnockSteps`). One reading of the same rung says nothing however many times
    /// it is taken, which is the "advisory rather than nag" property the Bool had; a reading a rung
    /// deeper says something, which is the property it did not.
    mutating func observe(account: String, cycle: String?, remaining: Double, now: Date) -> Bool {
        noteChecked(now: now)
        if account != accountID || !quotaKnockSameCycle(cycleKey, cycle) { announced = nil }
        accountID = account
        cycleKey = cycle
        if remaining > quotaKnockRearmPercent { announced = nil }
        guard let step = quotaKnockStep(remaining), announced.map({ step < $0 }) ?? true else {
            owed = nil
            return false
        }
        owed = step
        return true
    }

    /// The sentence is on its way: this rung is spoken for, and a forced knock is spent.
    ///
    /// Called when the injection is ATTEMPTED rather than when it succeeds, the rule
    /// `applySessionInput` states about its own served stamp: by then the bytes are on the terminal
    /// or the write has failed, and the failure that repeats every tick is the one that would
    /// re-type the line into the conversation that already has it.
    ///
    /// A FORCED knock with nothing owed leaves the ladder exactly where it was, which is what that
    /// development flag promises: it forces the MOMENT, never the content, so it must not consume a
    /// rung the account has not reached.
    mutating func spend() {
        if let owed { announced = owed }
        owed = nil
        forced = false
    }
}

/// Whether a name can go on a terminal's input queue as it stands.
///
/// A LABEL IS FREE TEXT AND THIS IS A KEYSTROKE CHANNEL, which is the whole of the danger: the
/// rename popover trims the ends and accepts everything else, so a label can carry a newline, and
/// `injectSessionInput` pushes each byte in as though it had been typed. A newline in the middle of
/// this sentence is a Return: the first half is submitted as a prompt and the rest is typed into
/// whatever comes up next. ESC and the other control bytes are the same class of accident one step
/// further, since a TUI reads them as commands rather than as text.
/// Asked THROUGH the strip below rather than beside it: two spellings of "what a terminal reads as
/// a keystroke" is one refusal and one repair that can come to disagree, and the disagreement is
/// silent - a name judged usable by one and rewritten by the other.
private func quotaKnockTypeable(_ name: String) -> Bool {
    !name.isEmpty && quotaKnockStripped(name) == name
}

/// The same string with those scalars dropped, for the last resort below.
private func quotaKnockStripped(_ name: String) -> String {
    String(String.UnicodeScalarView(name.unicodeScalars.filter {
        !CharacterSet.controlCharacters.contains($0) && !$0.properties.isDefaultIgnorableCodePoint
    }))
}

/// `text` cut to at most `limit` UTF-8 BYTES, never through a character.
///
/// Bytes because bytes are what is being bounded (the channel's limit, and 30ms of the poll loop
/// per one), and characters because a cut inside a multi-byte scalar is not a shorter string, it is
/// a broken one. Whole Characters rather than scalars so an emoji built from several does not lose
/// half of itself either.
func quotaKnockClipped(_ text: String, bytes limit: Int) -> String {
    guard text.utf8.count > limit else { return text }
    var out = ""
    var used = 0
    for character in text {
        let size = String(character).utf8.count
        guard used + size <= limit else { break }
        out.append(character)
        used += size
    }
    return out
}

/// The name the sentence calls an account, safe to type and inside `quotaKnockLabelBytes`.
///
/// THE LABEL IS PREFERRED AND THE CONFIG-DIR NAME IS THE FALLBACK, which is `completionAccountNames`
/// (CompletionData.swift) exactly: a label carrying something that cannot go on this channel is
/// REFUSED rather than repaired, because the repaired string is a name that no longer resolves -
/// "Claude\n2" with the newline dropped is "Claude2", which `tally account` matches against nothing,
/// and this sentence exists to be acted on. The directory name is what a person can type instead.
///
/// The strip is only the last resort, for an account whose every name is unusable: something has to
/// be printed, and by then a name that merely READS right is the best there is.
func quotaKnockName(_ account: Snapshot.Account, bytes limit: Int = quotaKnockLabelBytes) -> String {
    let directory = account.launchHome.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
    let candidates = [account.label, directory]
    let name = candidates.first(where: quotaKnockTypeable)
        ?? candidates.map(quotaKnockStripped).first { !$0.isEmpty }
        ?? quotaKnockStripped(account.id)
    // The ellipsis is one character and THREE BYTES, so the room for it is taken out of the budget
    // before the cut rather than added after it: a name clipped to the budget and then marked would
    // be three bytes over the thing that was being bounded.
    let clipped = quotaKnockClipped(name, bytes: limit - 3)
    return clipped.utf8.count == name.utf8.count ? name : clipped + "\u{2026}"
}

/// How many conversations are sharing this window, or nothing at all when the count is zero.
///
/// ZERO IS NOT PRINTED, because it cannot be true: the session being typed into is on that account
/// by construction, so a zero is a reading that failed (a supervisor whose sidecar could not be
/// read) rather than an empty account. Saying "0 sessions on it" to the one session on it is the
/// kind of sentence that makes a reader distrust the rest of the line.
private func quotaKnockSessionsClause(_ sessions: Int) -> String {
    guard sessions > 0 else { return "" }
    return ", \(sessions) session\(sessions == 1 ? "" : "s") on it"
}

/// The line typed into the session, or nil when there is nothing to say (an account reporting no
/// windows at all, which is a reading rather than a drought).
///
/// `limit` is the byte budget the caller keeps, handed in rather than read here so this file stays
/// free of the session-input channel: the caller is the one that pays for those bytes
/// (`sessionInputMaxBytes` is 200 of them, at 30ms each).
///
/// THE INVARIANT IS THAT WHAT COMES BACK IS NEVER LONGER THAN `limit`, and it is held by three
/// layers rather than by one, because the earlier version held it by hope: it checked the long form
/// only, so the two returns that skipped the check ("no account has headroom", and the short form
/// itself) went over the budget on any label of 24 emoji or 24 CJK characters, which a character
/// budget counted as inside it (codex review of c12a1df, measured at 230 and 206 bytes).
///
///  - names are clipped to a byte budget of their own, so the ordinary sentence keeps its detail;
///  - the forms are tried longest first and the first that FITS is the answer, so an over-long line
///    costs the alternative account rather than the news (that clause is the one thing a reader can
///    get for themselves, from `tally status`);
///  - and whatever is left is cut to the budget, which is what makes this a guarantee: a window
///    name is published by the provider and nothing here bounds it, so a form built out of one is
///    not something to reason about, only something to measure.
func quotaKnockMessage(account: Snapshot.Account, alternative: Snapshot.Account?, sessions: Int,
                       primaryModel: String?, limit: Int, step: Double? = nil,
                       now: Date = Date()) -> String? {
    guard let binding = bindingWindow(account, primaryModel: primaryModel, now: now) else {
        return nil
    }
    // THE BOTTOM RUNG IS DIFFERENT NEWS AND SAYS SO. "Running low" is a description of a window
    // with runway left in it; at zero there is none, the next turn is the one that hits the wall,
    // and a reader who has already been told this account is running low would read a second copy
    // of that sentence as the same news repeated (2026-08-21).
    let atTheWall = (step ?? quotaKnockPercent) <= 0
    let head = "[tally] account \(quotaKnockName(account)) is "
        + (atTheWall ? "out of quota: " : "running low: ")
        + windowReason(binding, now: now) + quotaKnockSessionsClause(sessions) + "."
    // Nothing comfortable anywhere is a different instruction, and it is the honest one: moving to
    // an equally spent account buys minutes and costs a restart, which is the same answer
    // `capHandoffTarget` gives by returning nothing.
    //
    // AND AT THE WALL THE ADVICE IS A COMMAND RATHER THAN A SUGGESTION. The session reading this is
    // the one thing on the machine that can still act - every mover has already declined or it
    // would not be here - so the sentence hands it the exact line to run instead of a direction to
    // work out for itself. It replaces the "best alternative" clause rather than joining it: that
    // clause names the same account, and the reason behind the pick is detail a session about to
    // hit a wall cannot spend bytes on.
    let advice: String
    if let alternative, atTheWall {
        advice = " Run `tally account \(quotaKnockCommandName(quotaKnockName(alternative)))`"
            + " to move this session."
    } else if alternative == nil {
        advice = " No account has headroom; consider pausing until the reset."
    } else {
        advice = " Wrap up and switch accounts, or wait for the reset."
    }
    let short = head + advice
    let full = atTheWall ? nil : alternative.map {
        head + " Best alternative: \(quotaKnockName($0)) "
            + "(\(pickReason($0, primaryModel: primaryModel, now: now)))." + advice
    }
    return [full, short].compactMap { $0 }.first { $0.utf8.count <= limit }
        ?? quotaKnockClipped(short, bytes: limit)
}

/// An account name as a shell ARGUMENT rather than as prose: quoted when it carries a space, which
/// the labels on this fleet do ("Claude 2").
///
/// The one place the sentence asks to be executed rather than read, so it is the one place the
/// difference matters: `tally account Claude 2` is two arguments and resolves nothing.
///
/// THE RESIDUAL, which this shares with the "best alternative" clause it replaces: a label longer
/// than `quotaKnockLabelBytes` arrives here already clipped, and a clipped name is not one
/// `tally account` matches. Nothing here can undo that - the budget is what keeps the line inside
/// the channel - and the reader is left with a name that reads right and a command that says which
/// verb they want.
private func quotaKnockCommandName(_ name: String) -> String {
    name.contains(" ") ? "\"\(name)\"" : name
}
