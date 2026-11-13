import Foundation

// The typing half of the capacity-fallback net: one tick of it, through the same composer door as
// every other automatic writer. The decision and its brake are OverloadFallback.swift.

struct OverloadRevertState {
    var brake = OverloadRevertBrake()
    var typedAt: Date?
    var typedKey: String?
    /// The `/model` record our typed line produced, for the supervisor to mark served so the
    /// adoption of a person's `/model` (adoptNativeModelChoice) does not pin our own switch.
    var confirmedCommandAt: Date?
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
func applyOverloadRevert(_ state: inout OverloadRevertState, pid: String,
                         event: OverloadFallbackEvent?, actualModel: String?,
                         primaryModel: String?, providerID: String, driftActive: Bool,
                         modelCommandAt: Date?, mode: OverloadRevertMode, hookInstalled: Bool,
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
        if let command = modelCommandAt, command > typedAt {
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
    if let event { state.brake = overloadRevertBrakeOnEvent(state.brake, event: event) }
    let idle = !typedAlready
        && automaticSessionInputHold(state: session, quiet: quiet, turnEnded: turnEnded(),
                                     keyboardIdle: keyboardIdle, relaunchPlanned: relaunchPlanned,
                                     dialogPossible: waitingOnPerson) == nil
    guard case let .revert(model, key) = overloadRevertDecision(
        OverloadRevertInput(event: event, actualModel: actualModel, primaryModel: primaryModel,
                            providerID: providerID, safeguardDriftActive: driftActive,
                            modelCommandAt: modelCommandAt, quiet: idle),
        brake: state.brake, now: now) else { return nil }
    // Spent BEFORE the write: a failure that repeats every tick must not type twice.
    state.brake.handled = Array((state.brake.handled + [key]).suffix(16))
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
        appendSessionInputLine(overloadRevertLine(pid: pid, outcome: "typed", eventKey: key,
                                                  model: model, now: now), to: log)
    case .held:
        // Nothing reached the terminal: offer it again next tick.
        state.brake.handled.removeAll { $0 == key }
    case .uncertain, .failed:
        appendSessionInputLine(overloadRevertLine(pid: pid, outcome: "unconfirmed", eventKey: key,
                                                  model: model, now: now), to: log)
    }
    return written.sent ? text : nil
}
