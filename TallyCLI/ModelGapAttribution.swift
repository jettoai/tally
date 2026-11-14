import Foundation

// WHY THE MODEL A SESSION RUNS IS NOT THE MODEL IT WAS MEANT TO RUN, answered in ONE place (B-4551).
//
// Five consumers used to answer that question each with its own signal: the launch-default follow,
// the two degradation movers, the adoption of a person's `/model`, and the switch back after a
// capacity fallback. Every new cause (a safeguard fallback, a person's `/model`, a capacity
// fallback, our own `/model`) was added as a stand-down flag on SOME of them, and whatever no flag
// named fell into the residual that the movers treat as quota. This file is the single answer: one
// pure function turns what the watcher saw and what the supervisor remembers into one cause, one
// owner, and the evidence key, and `ModelGapLedger` remembers which signals have been spent.
//
// STATE OF THE MIGRATION. The attribution is computed every tick and every change of cause is
// written to the handoff log (`model-gap=`), so a later step can be judged against real ticks. Only
// the command tier is read by a consumer so far (`modelCommandCause`: the adoption of a person's
// `/model`, SessionModel.swift), and it is the only writer of the served-command stamp. The follow
// reads the declaration tier too: `restatedAt` is the ONLY record that the project profile was written
// again (written by `noteRestated`, spent by `spendDeclaration`), and the follow reads the cause this
// file attributed from it. The ledger fields `rewrite` and `handledCapacityKeys` are still mirrors of
// state that is authoritative elsewhere.

/// Where the declared model came from. The declaration never reads the arguments of the current
/// child: those are what we executed, which a fallback profile or a safeguard restore rewrites.
enum DeclarationSource: String, Equatable {
    case pin, typed, project, app
}

enum GapCause: Equatable {
    /// Observed agrees with declared, or nothing has been observed since the child was spawned.
    case none
    /// A `/model` WE typed is in flight, or its record is in and its answer has not settled.
    case ownCommand(since: Date)
    /// A `/model` a person ran that nobody has acted on yet; `settled` is the model that answered it.
    case personCommand(at: Date, settled: String?)
    /// The declaration moved since this child was spawned for it (a restated profile, a new default).
    case declarationMoved(source: DeclarationSource)
    /// A safeguard fallback episode is active (SafeguardDrift.swift).
    case safeguard(eventKey: String)
    /// A `model_fallback` event whose answer is still the one it moved to.
    case capacity(eventKey: String, at: Date)
    /// WE spawned this child on a model other than the declared one (fallback profile, safeguard restore).
    case executionRewrite(reason: String, model: String, at: Date)
    /// Nothing above explains it.
    case unexplained(quotaEvidence: Bool)

    /// The word the log line carries.
    var name: String {
        switch self {
        case .none: return "none"
        case .ownCommand: return "own-command"
        case .personCommand: return "person-command"
        case .declarationMoved: return "declaration-moved"
        case .safeguard: return "safeguard"
        case .capacity: return "capacity"
        case .executionRewrite: return "execution-rewrite"
        case .unexplained: return "unexplained"
        }
    }

    /// The key the cause hangs on, for the log and for "did the cause change".
    var evidence: String? {
        switch self {
        case .none, .declarationMoved, .unexplained: return nil
        case let .ownCommand(since): return String(Int(since.timeIntervalSince1970))
        case let .personCommand(at, _): return String(Int(at.timeIntervalSince1970))
        case let .safeguard(key): return key
        case let .capacity(key, _): return key
        case let .executionRewrite(reason, _, at): return "\(reason)@\(Int(at.timeIntervalSince1970))"
        }
    }

    var since: Date? {
        switch self {
        case let .ownCommand(since): return since
        case let .personCommand(at, _): return at
        case let .capacity(_, at): return at
        case let .executionRewrite(_, _, at): return at
        default: return nil
        }
    }
}

/// The only consumer that may act on this tick for this cause.
enum GapOwner: String, Equatable {
    case nobody, adoption, follow, safeguardRestore, overloadRevert, degradationMovers
}

struct ModelGapAttribution: Equatable {
    let declared: String?
    let declaredSource: DeclarationSource
    /// The `--model` the current child was spawned with.
    let executing: String?
    /// `watcher.lastModel`.
    let observed: String?
    let cause: GapCause
    let owner: GapOwner
    var since: Date? { cause.since }
}

/// What the attribution reads off the transcript watcher and the drift monitor, so the function
/// below can be driven cell by cell without building a watcher.
struct ModelGapFacts: Equatable {
    var observed: String?
    /// `watcher.lastModelCommandAt`.
    var commandAt: Date?
    /// The model of the reply that answered that command (`watcher.modelConfirmation`).
    var confirmation: String?
    var overload: OverloadFallbackEvent?
    var safeguardActive = false
    var safeguardKey: String?

    init(observed: String? = nil, commandAt: Date? = nil, confirmation: String? = nil,
         overload: OverloadFallbackEvent? = nil, safeguardActive: Bool = false,
         safeguardKey: String? = nil) {
        self.observed = observed
        self.commandAt = commandAt
        self.confirmation = confirmation
        self.overload = overload
        self.safeguardActive = safeguardActive
        self.safeguardKey = safeguardKey
    }

    init(watcher: TranscriptWatcher, driftActive: Bool) {
        self.init(observed: watcher.lastModel, commandAt: watcher.lastModelCommandAt,
                  confirmation: watcher.modelConfirmation?.model, overload: watcher.lastOverloadFallback,
                  safeguardActive: driftActive,
                  safeguardKey: watcher.lastFlag.map { $0.uuid ?? ISO8601DateFormatter().string(from: $0.at) })
    }
}

/// How long after typing a `/model` record is still taken for ours. Past it a record is a person's.
let modelGapOwnRecordWindow: TimeInterval = 300

/// What the supervisor remembers about which signals have been spent, held for the session.
///
/// `servedCommandAt` has ONE writer, this struct (`consumeCommand`, `claimOwnCommand`,
/// `observeOverloadRevert`): the adoption of a person's `/model` and the claim of our own both spend
/// the same stamp, and two writers in two files is how the 6aad49a4 case got through.
struct ModelGapLedger: Equatable {
    /// The newest `/model` record somebody has acted on (or we claimed as ours). Read by the adoption
    /// as `SessionModelState.servedModelCommandAt`; written here and nowhere else.
    private(set) var servedCommandAt: Date?
    /// When our own `/model` was typed, until its record is claimed or the window passes.
    private(set) var ownCommandSince: Date?
    /// The model that line named: only a record naming it can be ours.
    private(set) var ownCommandModel: String?
    /// The record of our own `/model` that was claimed, until its answer settles.
    private(set) var ownClaimedAt: Date?
    /// The last typed-at read off the revert state, so a stale copy is never taken twice.
    private(set) var typedSeen: Date?
    /// Mirror: we spawned the child on `model` for `reason` (fallback profile, safeguard restore).
    private(set) var rewrite: Rewrite?
    /// The project profile was written again for this session, even to the value it had (#623). The
    /// one record of that: `FollowState` keeps none, which is what 35a6de18 was about (two copies
    /// parted when the follow was off). Only the follow can spend it (`spendDeclaration`), so the
    /// attribution reads it as `declarationMoved` only while the follow is live, and a session that
    /// is not following keeps it unread until it does.
    private(set) var restatedAt: Date?
    /// The cause the last tick attributed, for consumers that run later in the tick or deeper in the
    /// call stack than `tickModelGap` (the follow). Never decided here: set from the attribution.
    private(set) var attributed: GapCause = .none
    /// Mirror: the capacity-event keys the switch back has handled.
    private(set) var handledCapacityKeys: [String] = []
    /// What was declared when the current child started.
    private(set) var baseline: Baseline?
    /// The cause key last written to the log.
    private(set) var lastLogged: String?

    struct Rewrite: Equatable {
        let reason: String
        let model: String
        let at: Date
    }

    /// A ledger resumed across a self-update exec starts from the rewrite the old image held.
    init(rewrite: Rewrite? = nil) { self.rewrite = rewrite }

    struct Baseline: Equatable {
        let spawnedAt: Date
        let model: String?
    }

    // MARK: Commands

    /// Our revert state, mirrored: the time our `/model` was typed, and the record its typing
    /// produced. A confirmed record of ours is spent here so the adoption never reads it as a person's
    /// (the second half of the claim; the first is `claimOwnCommand`).
    mutating func observeOverloadRevert(typedAt: Date?, typedModel: String?, confirmedAt: Date?) {
        if let typedAt, typedAt != typedSeen {
            typedSeen = typedAt
            ownCommandSince = typedAt
            ownCommandModel = typedModel
        }
        if let confirmedAt, confirmedAt > (servedCommandAt ?? .distantPast) {
            servedCommandAt = confirmedAt
            ownClaimedAt = confirmedAt
        }
    }

    /// Our own `/model`, settled for this tick: what the revert state says we typed or confirmed, then
    /// the claim of its record. Runs BEFORE anything reads the commands (see `claimOwnCommand`).
    mutating func settleOwnCommand(typedAt: Date?, typedModel: String?, confirmedAt: Date?,
                                   commandAt: Date?, args: String?, now: Date) {
        observeOverloadRevert(typedAt: typedAt, typedModel: typedModel, confirmedAt: confirmedAt)
        claimOwnCommand(commandAt: commandAt, args: args, now: now)
    }

    /// The `/model` record of OUR typed line, claimed once it is on disk and BEFORE the adoption of
    /// a person's choice runs. The order is the whole point: the adoption reads the first answer after
    /// the command, and when a capacity fallback served that answer it pins the fallback model, which
    /// turns the temporary state we exist to undo into a standing pin.
    ///
    /// A record is ours only when its argument is the model we typed. Time alone was the defect
    /// (B-4551, third round): a stuck-confirm keeps the claim open for the window, and a person's own
    /// `/model` inside it was spent as ours and never adopted. A record with no argument (the
    /// picker) is never ours, because everything we type carries one.
    @discardableResult
    mutating func claimOwnCommand(commandAt: Date?, args: String?, now: Date) -> Date? {
        guard let since = ownCommandSince else { return nil }
        if now.timeIntervalSince(since) >= modelGapOwnRecordWindow {
            ownCommandSince = nil
            return nil
        }
        guard let commandAt, commandAt > since,
              modelCommandArgsMatch(args, typed: ownCommandModel) else { return nil }
        ownCommandSince = nil
        if commandAt > (servedCommandAt ?? .distantPast) {
            servedCommandAt = commandAt
            ownClaimedAt = commandAt
        }
        return commandAt
    }

    /// A person's `/model` has been judged: spent whether or not it changed anything, so the next
    /// one has to be newer.
    mutating func consumeCommand(at commandAt: Date) {
        servedCommandAt = commandAt
    }

    // MARK: Mirrors (shadow; the state they copy is still the authority)

    /// A relaunch we execute. The two reasons that put the child on a model other than the declared
    /// one WRITE the rewrite; the two that restate the declaration spend it; every other relaunch
    /// (an account move, a cap handoff, a switch) says nothing about the model and leaves it alone.
    mutating func noteRelaunch(reason: String, model: String?, at: Date) {
        switch reason {
        case "fallback", "safeguard":
            if let model, !model.isEmpty { rewrite = Rewrite(reason: reason, model: model, at: at) }
        case "follow", "model":
            rewrite = nil
        default:
            break
        }
    }

    /// The declaration moved without a relaunch (a person's `/model` adopted as the pin): what we
    /// rewrote the child to is no longer what a gap should be read against.
    mutating func noteDeclarationAdopted() { rewrite = nil }

    mutating func mirror(handled: [String]) { handledCapacityKeys = handled }

    // MARK: The restatement and what the follow reads of it

    /// The project profile was written again (the first write stands until it is spent).
    mutating func noteRestated(at now: Date) { restatedAt = restatedAt ?? now }

    /// An adoption of a pair spends the restatement, and the cause read from it, together. `ifRead`
    /// is the follow's own adoption: it spends only what it read, so a restatement it was kept from
    /// reading (a command of ours in flight) is still there afterwards. The adoption of a person's
    /// `/model` and of a `tally model` spend it whatever the cause, as the follow's flag always was.
    mutating func spendDeclaration(ifRead: Bool = false) {
        if ifRead && !declarationMoved { return }
        restatedAt = nil
        if declarationMoved { attributed = .none }
    }

    /// A tick that planned a relaunch and stood it down hands the restatement back (StandDown.swift).
    mutating func restoreRestated(_ at: Date?) { restatedAt = at }

    mutating func noteAttributed(_ cause: GapCause) { attributed = cause }

    /// What the follow asks: did the declaration move since this child was spawned for it?
    var declarationMoved: Bool {
        if case .declarationMoved = attributed { return true }
        return false
    }

    /// A new child (or a pin) re-bases what "declared since spawn" is measured against.
    mutating func noteTick(spawnedAt: Date, declared: String?, source: DeclarationSource) {
        if baseline?.spawnedAt != spawnedAt || source == .pin {
            baseline = Baseline(spawnedAt: spawnedAt, model: declared)
        }
    }

    /// Whether this attribution is a change worth a log line. A session that never leaves `none`
    /// writes nothing.
    mutating func transition(to attribution: ModelGapAttribution) -> Bool {
        let key = attribution.cause.name + (attribution.cause.evidence.map { ":" + $0 } ?? "")
        defer { lastLogged = key }
        return key != (lastLogged ?? GapCause.none.name)
    }
}

/// Whether a `/model` record's argument names the model we typed. Exact, ignoring case: the record
/// carries the text as typed.
func modelCommandArgsMatch(_ args: String?, typed: String?) -> Bool {
    guard let args = args?.trimmingCharacters(in: .whitespaces).lowercased(), !args.isEmpty,
          let typed = typed?.lowercased() else { return false }
    return args == typed
}

/// The command tier, which both the tick's attribution and the adoption of a person's `/model`
/// read: ONE function, so the two cannot disagree about whose command it is.
///
/// A record nobody has served is a person's, because ours are claimed (`claimOwnCommand`) before
/// anything asks. Ours is reported while its line is in flight or its answer is unsettled, so the
/// other consumers stand down without being told twice. A person's command outranks ours only when
/// both are open at once, which is what keeps the adoption of the older one alive exactly as it was.
func modelCommandCause(commandAt: Date?, confirmation: String?, ledger: ModelGapLedger,
                       now: Date) -> GapCause? {
    if let commandAt, commandAt > (ledger.servedCommandAt ?? .distantPast) {
        return .personCommand(at: commandAt, settled: confirmation)
    }
    if let since = ledger.ownCommandSince, now.timeIntervalSince(since) < modelGapOwnRecordWindow {
        return .ownCommand(since: since)
    }
    if let claimed = ledger.ownClaimedAt, commandAt == claimed, confirmation == nil {
        return .ownCommand(since: claimed)
    }
    return nil
}

func gapOwner(of cause: GapCause, handledCapacity: [String]) -> GapOwner {
    switch cause {
    case .none, .ownCommand, .executionRewrite: return .nobody
    case .personCommand: return .adoption
    case .declarationMoved: return .follow
    case .safeguard: return .safeguardRestore
    case let .capacity(key, _): return handledCapacity.contains(key) ? .nobody : .overloadRevert
    case .unexplained: return .degradationMovers
    }
}

/// Whether the degradation movers (the rescue and the fallback profile) may act on this tick: only
/// when nothing else explains the gap. They used to be handed two flags (`driftActive`, and a
/// capacity explanation that read one trigger value) and treated every other cause as quota, which
/// is how a person's `/model` and an `overloaded` capacity fallback got a window relaunched.
///
/// ONE EXCEPTION, kept from before: with no declaration at all there is nothing to attribute a gap
/// to, and the fallback profile has always judged that case by its own fallback list.
func degradationMoversMayAct(_ gap: ModelGapAttribution) -> Bool {
    gap.owner == .degradationMovers || (gap.declared == nil && gap.cause == .none)
}

/// The one answer. Priority, first that holds:
///
///     command (ours or a person's) > declaration moved > [nothing to explain: none]
///       > safeguard > capacity > execution rewrite > unexplained
///
/// The command and the moved declaration come before "nothing to explain" because they have to be
/// consumed even when the model did not change (a `/model` that only moved the depth), or they linger
/// as signals and are spent on the next real gap. The capacity cause carries no trigger whitelist:
/// the subtype separates it from every other event, and an unseen trigger is evidence, not a reason
/// to read the event as quota.
func attributeModelGap(declared: String?, source: DeclarationSource, executing: String?,
                       facts: ModelGapFacts, ledger: ModelGapLedger, followLive: Bool = true,
                       quotaEvidence: () -> Bool, now: Date) -> ModelGapAttribution {
    func result(_ cause: GapCause) -> ModelGapAttribution {
        ModelGapAttribution(declared: declared, declaredSource: source, executing: executing,
                            observed: facts.observed, cause: cause,
                            owner: gapOwner(of: cause, handledCapacity: ledger.handledCapacityKeys))
    }
    if let command = modelCommandCause(commandAt: facts.commandAt, confirmation: facts.confirmation,
                                       ledger: ledger, now: now) {
        return result(command)
    }
    // A restatement is a signal only the follow consumes, so it counts only while the follow is
    // live: a session whose follow axes are off (a pin on either axis, `--no-follow`, both flags
    // typed) would otherwise read `declarationMoved` for the rest of the session, with an owner that
    // never acts, and the movers would stand down on a real quota gap (35a6de18).
    if (followLive && ledger.restatedAt != nil)
        || (source != .pin && ledger.baseline.map { !modelsAgree(declared, $0.model) } == true
            && !modelsAgree(declared, executing)) {
        return result(.declarationMoved(source: source))
    }
    guard let observed = facts.observed, declared != nil, !modelsAgree(declared, observed) else {
        return result(.none)
    }
    if facts.safeguardActive { return result(.safeguard(eventKey: facts.safeguardKey ?? "flag")) }
    if let event = facts.overload, modelsAgree(observed, event.to), modelsAgree(declared, event.from) {
        return result(.capacity(eventKey: overloadEventKey(event), at: event.at))
    }
    if let rewrite = ledger.rewrite, modelsAgree(observed, rewrite.model) {
        return result(.executionRewrite(reason: rewrite.reason, model: rewrite.model, at: rewrite.at))
    }
    return result(.unexplained(quotaEvidence: quotaEvidence()))
}

/// grep `model-gap=` in the handoff log. Models and a key prefix only, nothing of the conversation.
func modelGapLine(_ attribution: ModelGapAttribution, sessionID: String?, trigger: String? = nil,
                  now: Date) -> String {
    let sid = sessionID.map { String($0.prefix(8)) } ?? "unknown"
    func word(_ value: String?) -> String { value ?? "-" }
    return "\(ISO8601DateFormatter().string(from: now)) session=\(sid) "
        + "model-gap=\(attribution.cause.name) declared=\(word(attribution.declared)) "
        + "executing=\(word(attribution.executing)) observed=\(word(attribution.observed)) "
        + "evidence=\(word(attribution.cause.evidence.map { String($0.prefix(8)) })) "
        + "owner=\(attribution.owner.rawValue)"
        // The capacity event's own trigger, so a value nobody has seen is on the record.
        + (trigger.map { " trigger=\($0)" } ?? "") + "\n"
}

/// One tick of the shadow: attribute, and log a change of cause. Returns the attribution.
@discardableResult
func observeModelGap(ledger: inout ModelGapLedger, declared: String?, source: DeclarationSource,
                     executing: String?, facts: ModelGapFacts, followLive: Bool = true,
                     sessionID: String?, quotaEvidence: () -> Bool, now: Date = Date(),
                     writeLog: Bool = true, log: URL = handoffLog) -> ModelGapAttribution {
    let attribution = attributeModelGap(declared: declared, source: source, executing: executing,
                                        facts: facts, ledger: ledger, followLive: followLive,
                                        quotaEvidence: quotaEvidence, now: now)
    ledger.noteAttributed(attribution.cause)
    if writeLog && ledger.transition(to: attribution) {
        var trigger: String?
        if case .capacity = attribution.cause { trigger = facts.overload?.trigger }
        appendHandoffLine(modelGapLine(attribution, sessionID: sessionID, trigger: trigger, now: now),
                          to: log)
    }
    return attribution
}

/// Everything the supervisor tick hands the shadow, so Supervisor.swift (at its size cap) carries one
/// call. The attribution is computed for every provider because the degradation movers read it; the
/// log line is written for claude only (the codex provider's `lastModel` has not been checked
/// against the same rule, B6 in the design).
@discardableResult
func tickModelGap(state: inout SessionModelState, handledCapacityKeys: [String],
                  followLive: Bool, watcher: TranscriptWatcher, driftActive: Bool, typedModel: String?,
                  policyModel: String?, projectDeclares: Bool, executing: String?,
                  spawnedAt: Date, quotaEvidence: () -> Bool, writeLog: Bool, now: Date = Date(),
                  log: URL = handoffLog) -> ModelGapAttribution {
    state.gap.mirror(handled: handledCapacityKeys)
    let declared = state.pin.model ?? typedModel ?? policyModel
    let source: DeclarationSource = state.pin.model != nil ? .pin
        : typedModel != nil ? .typed : projectDeclares ? .project : .app
    state.gap.noteTick(spawnedAt: spawnedAt, declared: declared, source: source)
    return observeModelGap(ledger: &state.gap, declared: declared, source: source, executing: executing,
                           facts: ModelGapFacts(watcher: watcher, driftActive: driftActive),
                           followLive: followLive,
                           sessionID: watcher.file?.deletingPathExtension().lastPathComponent,
                           quotaEvidence: quotaEvidence, now: now, writeLog: writeLog, log: log)
}

/// `--model-rewrite` across a self-update exec (B-4551): the model this session's child was rewritten
/// onto, which the ledger holds in memory only. Without it the new image reads the rewritten child as
/// `unexplained` and the degradation movers act on a gap nobody else owns. JSON like `--session-model`
/// (a model name is open text), epoch seconds for `at`. Optional by construction: a session with no
/// rewrite writes no flag, and an absent flag is the empty ledger every earlier build started with.
let resuperviseModelRewriteFlag = "--model-rewrite"

func encodeModelRewrite(_ rewrite: ModelGapLedger.Rewrite) -> String? {
    let fields: [String: Any] = ["at": rewrite.at.timeIntervalSince1970, "model": rewrite.model,
                                 "reason": rewrite.reason]
    guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else {
        return nil
    }
    return String(data: data, encoding: .utf8)
}

/// The rewrite a previous build wrote, or nil. A key that is missing or unreadable discards the whole
/// record rather than keeping half of it: a rewrite with no model would attribute nothing, and one
/// with a wrong reason would be spent by the wrong relaunch.
func decodeModelRewrite(_ raw: String) -> ModelGapLedger.Rewrite? {
    guard let data = raw.data(using: .utf8),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let reason = object["reason"] as? String, !reason.isEmpty,
          let model = object["model"] as? String, !model.isEmpty,
          let epoch = object["at"] as? Double, epoch.isFinite else { return nil }
    return ModelGapLedger.Rewrite(reason: reason, model: model, at: Date(timeIntervalSince1970: epoch))
}
