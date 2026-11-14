import Foundation

// The typing half of the capacity-fallback net: one tick of it, through the same composer door as
// every other automatic writer. The decision is here (it reads the model gap attribution, which the
// status line and worktree suites do not compile); the brake and the event are OverloadFallback.swift.

let overloadRevertHourCap = 3

struct OverloadRevertInput: Equatable {
    /// This tick's attribution (ModelGapAttribution.swift). It alone says whether this is a capacity
    /// fallback that is still the one answering, whether the declared model is the one it moved off,
    /// and whether a safeguard fallback, a person's `/model` or ours owns the gap instead. Nothing is
    /// read off the transcript watcher here.
    let gap: ModelGapAttribution
    let providerID: String
    /// Nothing is writing, nobody is typing, no dialog is possible, no relaunch is planned.
    let quiet: Bool
}

/// The model name is typed into a terminal, so only a plain alias or id may go.
private func overloadRevertTypable(_ model: String) -> Bool {
    !model.isEmpty && model.allSatisfy { $0.isLetter || $0.isNumber || "-._[]".contains($0) }
}

func overloadRevertDecision(_ input: OverloadRevertInput, brake: OverloadRevertBrake,
                            now: Date) -> OverloadRevertDecision {
    guard input.providerID == "claude" else { return .none("codex") }
    // A safeguard drift, a `/model` after the event, a declared model other than the one the event
    // moved off, or the original model answering again all show up as another cause or owner.
    guard case let .capacity(key, _) = input.gap.cause else { return .none(input.gap.cause.name) }
    guard input.gap.owner == .overloadRevert else { return .none("handled") }
    if let until = brake.notBefore, until > now { return .wait(until: until) }
    let hour = brake.reverts.filter { now.timeIntervalSince($0) < 3600 }
    guard hour.count < overloadRevertHourCap else { return .none("hour-cap") }
    guard input.quiet else { return .none("not-quiet") }
    guard let model = input.gap.declared, overloadRevertTypable(model) else { return .none("model-name") }
    return .revert(model: model, eventKey: key)
}

struct OverloadRevertState {
    var brake = OverloadRevertBrake()
    var typedAt: Date?
    var typedKey: String?
    /// The `/model` record our typed line produced. The ledger spends it
    /// (`ModelGapLedger.observeOverloadRevert`) so the adoption of a person's `/model`
    /// (adoptNativeModelChoice) does not pin our own switch.
    var confirmedCommandAt: Date?
    /// When our line was typed, kept past `done` and past `stuck-confirm`: the ledger copies it and
    /// claims the record when it arrives (`ModelGapLedger.claimOwnCommand`). `typedAt` cannot do this
    /// job: it is cleared on a stuck-confirm, and the record of a line that landed late would then
    /// belong to nobody.
    var ownCommandSince: Date?
    /// What that line asked for, so a `/model` record is ours only when it names the same model.
    var ownCommandModel: String?
}

/// grep `overload-revert=` in the input log. Session pid, event key prefix and model only.
func overloadRevertLine(pid: String, outcome: String, eventKey: String, model: String? = nil,
                        reason: String? = nil, now: Date = Date()) -> String {
    "\(ISO8601DateFormatter().string(from: now)) pid=\(pid) overload-revert=\(outcome) "
        + "event=\(eventKey.prefix(8))" + (model.map { " model=\($0)" } ?? "")
        + (reason.map { " reason=\($0)" } ?? "") + "\n"
}

/// One tick of the net. Returns the line typed, or nil. Same gates as every other writer into the
/// composer (`automaticSessionInputHold`); the caller treats a non-nil as a composer write.
@discardableResult
func applyOverloadRevert(_ state: inout OverloadRevertState, ledger: inout ModelGapLedger,
                         pid: String, gap: ModelGapAttribution, providerID: String,
                         mode: OverloadRevertMode, hookInstalled: Bool,
                         typedAlready: Bool, session: SupervisedState, quiet: SessionQuiet,
                         turnEnded: () -> Bool, keyboardIdle: Bool, relaunchPlanned: Bool,
                         draftSuspected: Bool, waitingOnPerson: Bool,
                         seen: SessionInputSeen? = nil, now: Date = Date(),
                         log: URL = sessionInputLog,
                         inject: (String, SessionInputDraftGuard) -> SessionInputInjection = {
                             injectSessionInput($0, draft: $1)
                         }) -> String? {
    guard mode != .off else { return nil }
    // Did the line we typed land? A `/model` record after it says yes. No record within the window,
    // or a dialog possible, says Claude Code is asking something: leave it for a person, no Esc and
    // no digit key (a keystroke nobody asked for is the thing this net must never be).
    if let typedAt = state.typedAt, let key = state.typedKey {
        // A record is OURS only when it names the model we typed: a person's `/model` inside the
        // window is a different choice, and spending it as ours would drop it for good. The ledger
        // already judged that (`claimOwnCommand`, run before this in the tick), so it is read there.
        if let command = ledger.ownClaimedAt, command > typedAt {
            state.confirmedCommandAt = command
            appendSessionInputLine(overloadRevertLine(pid: pid, outcome: "done", eventKey: key,
                                                      now: now), to: log)
        } else if waitingOnPerson || now.timeIntervalSince(typedAt) >= overloadRevertConfirmWindow {
            appendSessionInputLine(overloadRevertLine(pid: pid, outcome: "stuck-confirm",
                                                      eventKey: key, now: now), to: log)
        } else {
            return nil
        }
        state.typedAt = nil
        state.typedKey = nil
    }
    if case let .capacity(_, at) = gap.cause { state.brake = overloadRevertBrakeOnEvent(state.brake, at: at) }
    let idle = !typedAlready
        && automaticSessionInputHold(state: session, quiet: quiet, turnEnded: turnEnded(),
                                     keyboardIdle: keyboardIdle, relaunchPlanned: relaunchPlanned,
                                     dialogPossible: waitingOnPerson) == nil
    guard case let .revert(model, key) = overloadRevertDecision(
        OverloadRevertInput(gap: gap, providerID: providerID, quiet: idle),
        brake: state.brake, now: now) else { return nil }
    // Spent BEFORE the write: a failure that repeats every tick must not type twice. The ledger holds
    // the key, so the next tick's attribution hands the gap to nobody.
    ledger.handleCapacity(key)
    guard mode == .act || (mode == .auto && hookInstalled) else {
        appendSessionInputLine(overloadRevertLine(pid: pid, outcome: "would-revert", eventKey: key,
                                                  model: model, now: now), to: log)
        return nil
    }
    let text = "/model \(model)"
    let written = inject(text, sessionInputDraftGuard(dialog: waitingOnPerson,
                                                      suspected: draftSuspected))
    switch written {
    case .done:
        state.brake.reverts = state.brake.reverts.filter { now.timeIntervalSince($0) < 3600 } + [now]
        state.typedAt = now
        state.typedKey = key
        state.ownCommandSince = now
        state.ownCommandModel = model
        appendSessionInputLine(overloadRevertLine(pid: pid, outcome: "typed", eventKey: key,
                                                  model: model, now: now), to: log)
    case .held:
        // Nothing reached the terminal: offer it again next tick.
        ledger.releaseCapacity(key)
    case .uncertain, .failed:
        appendSessionInputLine(overloadRevertLine(pid: pid, outcome: "unconfirmed", eventKey: key,
                                                  model: model, now: now), to: log)
    }
    return written.sent ? text : nil
}
