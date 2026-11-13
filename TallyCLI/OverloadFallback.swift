import Foundation

// A CAPACITY fallback: the serving side was overloaded, so Claude Code moved ONE request from the
// session's model to a stronger one (`model_fallback`, trigger=server_error) and, by its own
// design, tries the original again on the next turn. It is not a quota problem and not a safeguard
// one (SafeguardDrift.swift), and two things in this file follow from that.
//
//  1. THE DEGRADATION MOVERS MUST NOT READ IT AS QUOTA (the `capacity` cause of
//     ModelGapAttribution.swift, which they read through `degradationMoversMayAct`). On 2026-11-13 they did: 8 `reason=fallback` relaunches (6 of them
//     onto `--model opus`, after which Claude Code's own "back to the original next turn" could no
//     longer happen) and 12 `reason=degraded` account moves, each within seconds of the event.
//
//  2. A SAFETY NET for a window that stays on the fallback model anyway: once it is quiet and its
//     newest answer still came from the fallback model, type `/model <declared model>` once per
//     event (`overloadRevertDecision`). After (1) the expected number of firings is close to zero,
//     so this is deliberately cautious: one switch per event, three per hour, backoff when the
//     original model falls over again right after a switch, and it types only when the account has
//     a `PreModelSwitch` hook (`OverloadRevertMode.auto`), because without one Claude Code asks
//     for a confirmation that nobody requested.
//
// State is per session and in memory. A relaunch or self-update exec starts a child whose `since`
// is later than every earlier event, so the watcher never replays one into a fresh brake.

/// The literal `LineNeedle.overloadFallback` looks for. Quoted so it cannot match
/// `model_refusal_fallback` (a different subtype, handled by SafeguardDrift.swift).
let overloadFallbackSubtypeLiteral = "\"subtype\":\"model_fallback\""

/// The only trigger value observed (31 of 31 events, 2026-11-13).
let overloadFallbackTrigger = "server_error"

struct OverloadFallbackEvent: Equatable {
    let at: Date
    /// The model the session was running (`originalModel`).
    let from: String
    /// The model this request was moved to (`fallbackModel`).
    let to: String
    let trigger: String
    let uuid: String?
}

/// One `model_fallback` transcript line. nil for anything else, a sidechain event, or a line
/// missing a field the decision needs.
func overloadFallbackEvent(inLine line: Substring) -> OverloadFallbackEvent? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          (object["isSidechain"] as? Bool) != true,
          (object["subtype"] as? String) == "model_fallback",
          let from = object["originalModel"] as? String,
          let to = object["fallbackModel"] as? String,
          let trigger = object["trigger"] as? String,
          let at = (object["timestamp"] as? String).flatMap(parseISO) else { return nil }
    return OverloadFallbackEvent(at: at, from: from, to: to, trigger: trigger,
                                 uuid: object["uuid"] as? String)
}

// MARK: - The switch back

enum OverloadRevertMode {
    /// Nothing is decided or logged.
    case off
    /// A revert is decided and logged (`would-revert`), never typed.
    case observe
    /// A revert is typed whether or not the account has the hook (a bare account gets the dialog).
    case act
    /// Typed only where the account's settings.json registers a `PreModelSwitch` hook, observed
    /// everywhere else.
    case auto
}

/// THE ONE SWITCH for (b). (c), the fix above, is not behind it: it is a bug fix whose failure
/// direction is safe.
let overloadRevertMode: OverloadRevertMode = .auto

let overloadRevertHourCap = 3
let overloadRevertBackoffWindow: TimeInterval = 10 * 60
let overloadRevertBackoff: TimeInterval = 15 * 60
/// How long a typed `/model` has to show up in the transcript before it is called stuck.
let overloadRevertConfirmWindow: TimeInterval = 90

struct OverloadRevertInput: Equatable {
    let event: OverloadFallbackEvent?
    /// `watcher.lastModel`.
    let actualModel: String?
    /// The model this session is meant to run: pin, then launch args, then policy.
    let primaryModel: String?
    let providerID: String
    let safeguardDriftActive: Bool
    /// `watcher.lastModelCommandAt`: did a person run `/model` after the event.
    let modelCommandAt: Date?
    /// Nothing is writing, nobody is typing, no dialog is possible, no relaunch is planned.
    let quiet: Bool
}

struct OverloadRevertBrake: Equatable {
    /// Event keys already acted on (bounded to the newest 16).
    var handled: [String] = []
    /// When `/model` was typed, pruned to the last hour.
    var reverts: [Date] = []
    /// After the original model fell over again soon after a switch, nothing before this.
    var notBefore: Date?
}

enum OverloadRevertDecision: Equatable {
    /// Why nothing is done, one word.
    case none(String)
    case wait(until: Date)
    case revert(model: String, eventKey: String)
}

func overloadEventKey(_ event: OverloadFallbackEvent) -> String {
    event.uuid ?? ISO8601DateFormatter().string(from: event.at)
}

/// A NEW event arriving soon after a switch of ours means the switch did not hold: back off.
/// Idempotent, so it can run every tick.
func overloadRevertBrakeOnEvent(_ brake: OverloadRevertBrake, event: OverloadFallbackEvent)
    -> OverloadRevertBrake {
    var next = brake
    let recent = brake.reverts.contains {
        let gap = event.at.timeIntervalSince($0)
        return gap >= 0 && gap <= overloadRevertBackoffWindow
    }
    if recent {
        let until = event.at.addingTimeInterval(overloadRevertBackoff)
        next.notBefore = max(until, brake.notBefore ?? .distantPast)
    }
    return next
}

/// The model name is typed into a terminal, so only a plain alias or id may go.
private func overloadRevertTypable(_ model: String) -> Bool {
    !model.isEmpty && model.allSatisfy { $0.isLetter || $0.isNumber || "-._[]".contains($0) }
}

func overloadRevertDecision(_ input: OverloadRevertInput, brake: OverloadRevertBrake,
                            now: Date) -> OverloadRevertDecision {
    guard let event = input.event else { return .none("no-event") }
    guard input.providerID == "claude" else { return .none("codex") }
    // A safeguard fallback is never reverted (SafeguardDrift.swift): the API chose it on purpose.
    guard !input.safeguardDriftActive else { return .none("safeguard") }
    guard event.trigger == overloadFallbackTrigger else { return .none("trigger") }
    guard let primary = input.primaryModel, modelsAgree(primary, event.from) else {
        return .none("primary-mismatch")
    }
    if let command = input.modelCommandAt, command > event.at { return .none("user-chose") }
    guard modelsAgree(input.actualModel, event.to) else { return .none("recovered") }
    let key = overloadEventKey(event)
    guard !brake.handled.contains(key) else { return .none("handled") }
    if let until = brake.notBefore, until > now { return .wait(until: until) }
    let hour = brake.reverts.filter { now.timeIntervalSince($0) < 3600 }
    guard hour.count < overloadRevertHourCap else { return .none("hour-cap") }
    guard input.quiet else { return .none("not-quiet") }
    guard overloadRevertTypable(primary) else { return .none("model-name") }
    return .revert(model: primary, eventKey: key)
}

/// `PreModelSwitch` registered in this account's settings.json: the hook that lets a typed
/// `/model` through without Claude Code's confirmation dialog. Read when a child is launched, for
/// the reason `quotaKnockFilingAvailable` gives. Unreadable means no (observe).
func preModelSwitchHookRegistered(home: String?) -> Bool {
    guard let home,
          let data = try? Data(contentsOf: URL(fileURLWithPath: home)
              .appendingPathComponent("settings.json")),
          let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let hooks = settings["hooks"] as? [String: Any],
          let entries = hooks["PreModelSwitch"] as? [Any] else { return false }
    return !entries.isEmpty
}
