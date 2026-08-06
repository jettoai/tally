import Foundation

// `tally hook-model` - what makes `/tally-model` cost NOTHING, in either shape, and the three-layer
// reading every surface of this command prints before it says anything else.
//
// Claude Code fires a `UserPromptExpansion` hook when a slash command is typed, BEFORE any model is
// woken: the hook reads the invocation as JSON on stdin, and exiting 2 stops the expansion there,
// showing its stderr to the user. So the whole feature is: read what was typed, answer it here, and
// exit 2. No turn runs, no tokens are spent.
//
// IT ALWAYS ANSWERS. There is no pass-through, and that is the design rather than an optimisation,
// for the reason SwitchHook.swift states about its own command: an escape hatch may not depend on
// the thing it exists to escape. The reason to reach for `/tally-model` is usually that the model
// this session runs is the problem - out of quota, or too shallow for what just came up - and a bare
// `/tally-model` that woke a model to list the options would need the very turn that cannot be sent.
//
//   /tally-model opus xhigh   queue the change (or say why it could not be queued)
//   /tally-model auto         hand the session back to the layers underneath
//   /tally-model              print what this session runs, where each axis of it came from, and
//                             what may be typed instead
//
// and everything unrecognisable - stdin that is not JSON, a payload without the field, a shape from
// a future Claude Code - takes the LISTING branch rather than a model turn.

// MARK: - The three layers, read once

/// The name of each layer that can decide an axis, as the listing prints it. Constants because the
/// resolution and the rendering both name them and a drifted pair would report the wrong source.
let modelLayerSession = "this session"
let modelLayerProject = "this project"
let modelLayerFleet = "the fleet default"
let modelLayerNone = "nothing"

/// What every `tally model` surface reads before it says anything: the pair in force, where each of
/// its two axes came from, and the layers underneath it.
///
/// PER AXIS, not per layer, because the axes really can come from different places: `tally model
/// opus` pins the model and deliberately leaves the effort where it was, so a session can run this
/// session's model at the fleet's effort. A single "the session decides" answer would be wrong about
/// one of them.
struct ModelStatus: Equatable {
    var pair = SessionModelPin()
    var modelSource = modelLayerNone
    var effortSource = modelLayerNone
    /// The layers themselves, for the listing: what this session pinned, what the project declares,
    /// what the app defaults to.
    var session = SessionModelPin()
    var project = SessionModelPin()
    var projectKey = ""
    var fleet = SessionModelPin()
    /// A request written but not yet served, so a listing read moments after a change does not
    /// report the old pair as though nothing had happened.
    var pending: SessionModelPin?
    /// True when that pending request is a release rather than a pin.
    var pendingRelease = false
}

/// The resolution, pure: session over project over fleet, one axis at a time.
func modelStatus(session: SessionModelPin, project: ProjectPolicy, projectKey: String,
                 fleet: LaunchPolicy, pending: ModelRequest? = nil) -> ModelStatus {
    var status = ModelStatus()
    status.session = session
    status.project = SessionModelPin(model: project.model, effort: project.effort)
    status.projectKey = projectKey
    status.fleet = SessionModelPin(model: fleet.model, effort: fleet.effort)
    status.pending = pending.map(\.pin)
    status.pendingRelease = pending?.isRelease == true
    /// One axis, resolved through the layers in order. The FIRST layer that names it wins, which is
    /// the same precedence `effectivePolicy` applies to a launch - stated again here because this
    /// answers for a RUNNING session, where a fourth layer (the session's own pin) sits on top.
    func resolve(_ axis: KeyPath<SessionModelPin, String?>) -> (String?, String) {
        if let value = session[keyPath: axis] { return (value, modelLayerSession) }
        if let value = status.project[keyPath: axis] { return (value, modelLayerProject) }
        if let value = status.fleet[keyPath: axis] { return (value, modelLayerFleet) }
        return (nil, modelLayerNone)
    }
    (status.pair.model, status.modelSource) = resolve(\.model)
    (status.pair.effort, status.effortSource) = resolve(\.effort)
    return status
}

/// The same reading as text, which is all a hook has. Pure, so the wording is testable without a
/// session or a config file.
///
/// It leads with the pair and its sources because that is the question ("what am I running, and who
/// decided"), lists the layers underneath so a release is predictable rather than a surprise, and
/// closes with what may be typed - including the effort levels, since that axis is a closed set and
/// guessing at it is the one way to get a session that will not start.
func modelStatusLines(_ status: ModelStatus, efforts: [String] = claudeEffortNames()) -> [String] {
    var lines = ["this session runs \(sessionModelDescription(status.pair))",
                 "  model   \(status.pair.model ?? "not set")   (\(status.modelSource))",
                 "  effort  \(status.pair.effort ?? "not set")   (\(status.effortSource))"]
    if let pending = status.pending {
        lines.append(status.pendingRelease
            ? "  queued: going back to the layers below at the end of this turn"
            : "  queued: \(sessionModelDescription(pending)) at the end of this turn")
    }
    if !status.project.isEmpty {
        lines.append("\(modelLayerProject) (\(status.projectKey)): "
            + "\(sessionModelDescription(status.project))")
    }
    lines.append("\(modelLayerFleet): \(sessionModelDescription(status.fleet))")
    return lines + ["pin this conversation with `/tally-model <model> [effort]`, or "
        + "`/tally-model auto` to follow the layers below again",
                    "efforts: \(efforts.joined(separator: ", "))"]
}

/// The same reading, off this machine. The session layer comes from what the supervisor publishes
/// (SessionContext.swift) rather than from this shell's environment, so it describes the SESSION
/// being asked about rather than the process doing the asking - and a request this shell wrote a
/// moment ago is shown as queued rather than being invisible until the turn ends.
func liveModelStatus() -> ModelStatus {
    let provider = providers[0]
    let session = currentSessionLookup()
    let published = session.flatMap { readSessionContext(pid: $0.key) }
    return modelStatus(
        session: SessionModelPin(model: published?.sessionModel, effort: published?.sessionEffort),
        project: projectPolicy(provider.id), projectKey: projectPolicyKey(),
        fleet: launchPolicy(provider.id),
        pending: session.flatMap { readModelRequest(sessionKey: $0.key) })
}

// MARK: - The hook

/// What the hook does with the payload it was handed.
enum HookModelAction: Equatable {
    /// A pair (or `auto`) was named: queue it and stop the expansion.
    case queue([String])
    /// Nothing usable was named: answer with the three layers, here, and stop the expansion.
    case list
}

/// The decision, pure: everything about the payload, nothing about the world. The typed line arrives
/// through the shared reading of the hook contract (`hookCommandArguments`, SwitchHook.swift); unlike
/// an account label, the two values here cannot contain spaces (both are launch-axis names), so it
/// splits on whitespace into at most a model and an effort.
func hookModelAction(_ raw: String) -> HookModelAction {
    guard let arguments = hookCommandArguments(raw) else { return .list }
    let words = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
    return words.isEmpty ? .list : .queue(words)
}

/// `tally hook-model`: the hook entry. Registered by the app with the skill (IntegrationsStore),
/// never typed by hand, so it is absent from the usage text.
///
/// Always exit 2: the answer is already on stderr, and letting the expansion run would spend a turn
/// re-saying it. Stderr for all of it, because that is the only channel a blocked expansion shows
/// the user, and stdout is discarded on exit 2.
///
/// NEVER A MENU on this path, whatever the terminal looks like. The hook runs as a child of Claude
/// Code, whose TUI owns the screen; a raw-mode picker drawn under it would fight the thing already
/// drawing there (the same rule SwitchMenu.swift states for its own four ways in).
func runHookModel() -> Int32 {
    let raw = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    switch hookModelAction(raw) {
    case .queue(let words):
        guard let intent = modelIntent(words) else {
            warn("`/tally-model` takes a model and an optional effort, or `auto`; "
                + "\"\(words.joined(separator: " "))\" is neither")
            warn(modelStatusLines(liveModelStatus()).joined(separator: "\n"))
            return 2
        }
        let attempt = attemptModel(intent)
        warn(attempt.message)
        for note in attempt.notes { warn(note) }
    case .list:
        // One call, so the lines print as a block under a single tag rather than one tag per line.
        warn(modelStatusLines(liveModelStatus()).joined(separator: "\n"))
    }
    return 2
}
