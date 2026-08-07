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
    /// The model seen serving this session's most recently READ assistant event
    /// (SessionContext.swift). nil until one has been read, which is a real state and not a zero.
    ///
    /// A READING OF THE PAST, and every sentence built on it has to say so. Nothing here observes
    /// the future: a user who types Claude Code's own `/model` and has not sent a turn since has
    /// changed what will answer next while this still holds what answered last, so reporting it in
    /// the present tense makes this command wrong in exactly the case the previous round added it
    /// for (caught in review of 1c39846). The fix is the tense, not a cleverer reading - detecting
    /// that command would mean guessing at an event shape nobody here has measured.
    ///
    /// The only measurement of the three readings this type holds, and it outranks the other two
    /// wherever they disagree. `pair` is what the LAYERS resolve to and `declared` is what the
    /// command line ASKS FOR; both are intents, and the paths that make them wrong are ordinary -
    /// a safeguard fallback, a quota degradation, Claude Code's own `/model`, none of which move an
    /// argv word. That is also the exact moment someone asks this command what they are running.
    var observedModel: String?
    /// The pair the child's command line asks for, published by its supervisor. nil when nothing
    /// has been published at all - a conversation that has not had a turn has no reading, and the
    /// layers below are NOT a substitute for one.
    var declared: SessionModelPin?

    /// What to report: the model that was SEEN when there is one, else the one that was asked for,
    /// beside the effort - which nothing ever observes, so it is always the request. nil only when
    /// neither reading exists.
    var running: SessionModelPin? {
        guard observedModel != nil || declared != nil else { return nil }
        return SessionModelPin(model: observedModel ?? declared?.model, effort: declared?.effort)
    }

    /// Whether the model above is a reading rather than a request. What keeps the two out of one
    /// indicative sentence.
    var modelObserved: Bool { observedModel != nil }
    /// A request written but not yet served, so a listing read moments after a change does not
    /// report the old pair as though nothing had happened.
    ///
    /// Filled from the RUNNING pair on the axis a model-only request leaves alone, because that is
    /// what the relaunch will actually do (`sessionModelPair`, SessionModel.swift). Reading the
    /// request's own pin here printed `queued: opus/default` for `tally model opus` in a session
    /// running `--effort xhigh` - promising a reset the mechanism was never going to perform
    /// (raised in review, 2026-08-07). nil on that axis means it is genuinely unknown, and the
    /// rendering says so rather than filling it in.
    var pending: SessionModelPin?
    /// True when that pending request is a release rather than a pin.
    var pendingRelease = false
}

/// The resolution, pure: session over project over fleet, one axis at a time.
func modelStatus(session: SessionModelPin, project: ProjectPolicy, projectKey: String,
                 fleet: LaunchPolicy, pending: ModelRequest? = nil,
                 declared: SessionModelPin? = nil, observedModel: String? = nil) -> ModelStatus {
    var status = ModelStatus()
    status.session = session
    status.declared = declared
    status.observedModel = observedModel
    status.project = SessionModelPin(model: project.model, effort: project.effort)
    status.projectKey = projectKey
    status.fleet = SessionModelPin(model: fleet.model, effort: fleet.effort)
    status.pendingRelease = pending?.isRelease == true
    // A model-only request keeps the effort the session is RUNNING, so that is what to show; with
    // no running reading there is nothing honest to fill it with, and the rendering leaves it out.
    status.pending = pending.flatMap { request in
        request.isRelease ? nil
            : SessionModelPin(model: request.model,
                              effort: request.effort ?? declared?.effort)
    }
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

/// The half of the listing that answers "what is this session on right now", which is the half both
/// of this command's defects were in: first it reported the LAYER RESOLUTION as the answer, then the
/// COMMAND LINE. Its own function so that answer can be asserted directly, without the layer block
/// and the closing help around it.
///
/// TWO FACTS, TWO VOICES, AND ONE TENSE. The model is a reading once a turn has been served and a
/// request until then; the effort is ALWAYS a request, because nothing reports it back. And the
/// reading is of the LAST response, never of this instant, so every line drawn from it is written in
/// the past. All three defects this command has had were the same move - stating something in the
/// present indicative that was not measured at present - so the distinctions live in the wording
/// rather than being assumed away.
func modelStatusRunningLines(_ status: ModelStatus) -> [String] {
    guard let running = status.running else {
        return ["this session: nothing published yet, so what it is running cannot be read here "
            + "(a supervisor publishes it once the conversation has had a turn)"]
    }
    let named = running.model ?? "no model of its own"
    // PAST TENSE FOR THE READING, and it is load-bearing rather than fussy. The observation is of
    // the last answer that was written down; anything the user has done since - Claude Code's own
    // `/model` above all - changes what answers NEXT without touching it. Said as "is served by",
    // this line is confidently wrong in the one case worth asking about; said as "the last response
    // was", it is true at every moment, including that one.
    var lines = [status.modelObserved
        ? "this session's last response was served by \(named)"
        : "this session was launched on \(named), and nothing it has served has been read back yet"]
    lines.append("  effort \(running.effort ?? "not set"), as asked on the command line - nothing "
        + "reports effort back, so this is the request rather than a reading")
    // The sharp one: the command line has not moved and the answers have. Stated as the fact it is;
    // which of the several paths did it is not something this command can tell.
    // The sharp one: the command line has not moved and the answers had. Kept in the same tense as
    // the reading it is drawn from - it is a fact about that response, not a claim about this
    // instant - and it names no culprit, which is not something this command can tell.
    if let observed = status.observedModel, let asked = status.declared?.model,
       !modelsAgree(asked, observed) {
        lines.append("  the command line still says \(asked), so something moved this session onto "
            + "\(observed) after it started")
    }
    if !sessionModelMatchesLayers(running: running, layers: status.pair) {
        lines.append("  the layers below resolve to \(sessionModelDescription(status.pair)) "
            + "instead of that")
    }
    return lines
}

/// The same reading as text, which is all a hook has. Pure, so the wording is testable without a
/// session or a config file.
///
/// It leads with the pair and its sources because that is the question ("what am I running, and who
/// decided"), lists the layers underneath so a release is predictable rather than a surprise, and
/// closes with what may be typed - including the effort levels, since that axis is a closed set and
/// guessing at it is the one way to get a session that will not start.
func modelStatusLines(_ status: ModelStatus, efforts: [String] = claudeEffortNames()) -> [String] {
    // WHAT IS RUNNING FIRST, and only when it is known. The layers cannot stand in for it: they say
    // what SHOULD be running, and every path that moves a session off them (a quota fallback, a
    // safeguard restore, a flag typed at launch) leaves the two disagreeing precisely when someone
    // asks. Nothing published yet says so rather than guessing - a command whose whole job is to
    // report what a session runs may not answer that in the indicative when it cannot read it.
    var lines = modelStatusRunningLines(status)
    lines += ["what the layers say:",
              "  model   \(status.pair.model ?? "not set")   (\(status.modelSource))",
              "  effort  \(status.pair.effort ?? "not set")   (\(status.effortSource))"]
    if status.pendingRelease {
        lines.append("  queued: going back to the layers below at the end of this turn")
    } else if let pending = status.pending {
        // Named the way the request was made: an axis nobody named, and that nothing can be read
        // for, is reported as untouched rather than as a default it will not be reset to.
        let model = pending.model ?? "?"
        let pair = pending.effort.map { "\(model)/\($0)" } ?? "\(model), effort unchanged"
        lines.append("  queued: \(pair) at the end of this turn")
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

/// Whether the pair a session is RUNNING is the pair its layers resolve to.
///
/// Through `modelsAgree`, so the alias a Settings picker writes (`opus`) counts as the full id a
/// rewrite may have put on the command line (`claude-opus-4-8`) - the same comparison the follow
/// adoption makes, for the same reason, and a divergence note raised over a spelling difference
/// would be worse than none. Both sides naming nothing is a match; one side naming nothing is not.
func sessionModelMatchesLayers(running: SessionModelPin, layers: SessionModelPin) -> Bool {
    let sameModel = (running.model == nil && layers.model == nil)
        || modelsAgree(layers.model, running.model)
    return sameModel && running.effort?.lowercased() == layers.effort?.lowercased()
}

/// The same reading, off this machine. Both the session's pin and what it is RUNNING come from what
/// the supervisor publishes (SessionContext.swift) rather than from this shell's environment, so
/// they describe the SESSION being asked about rather than the process doing the asking - and a
/// request this shell wrote a moment ago is shown as queued rather than being invisible until the
/// turn ends.
/// `cwd` names the session being reported on, and defaults to this process's own directory - the
/// right answer everywhere a person types. The MCP server behind the native picker passes the
/// directory its hook reported instead (MCPServe.swift), because that process outlives the prompt
/// and does not sit where the prompt came from.
func liveModelStatus(cwd: String = FileManager.default.currentDirectoryPath,
                     marker: SessionMarkerTrust = .trusted(liveSessionMarker())) -> ModelStatus {
    let provider = providers[0]
    let session = currentSessionLookup(cwd: cwd, marker: marker)
    let published = session.flatMap { readSessionContext(pid: $0.key) }
    // An empty declared pair is "cannot say", not "asked for nothing": a document written by a
    // build before these fields existed decodes with them all nil, and reporting that as a fact
    // would be the same lie in a new place. A session genuinely launched with no `--model` at all
    // reads the same way, which is the conservative direction - its layers say "not set" too.
    let declared = SessionModelPin(model: published?.runningModel, effort: published?.runningEffort)
    return modelStatus(
        session: SessionModelPin(model: published?.sessionModel, effort: published?.sessionEffort),
        project: projectPolicy(provider.id), projectKey: projectPolicyKey(),
        fleet: launchPolicy(provider.id),
        pending: session.flatMap { readModelRequest(sessionKey: $0.key) },
        declared: declared.isEmpty ? nil : declared,
        observedModel: published?.observedModel)
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
///
/// `--backstop` is the same work under a condition: it is registered BESIDE an `mcp_tool` hook that
/// raises the native picker, and it answers only when that picker is not there to
/// (PromptHookBackstop.swift states why it may not simply always answer).
func runHookModel(args: [String] = []) -> Int32 {
    let backstop = promptHookIsBackstop(args)
    if backstop, promptHookBackstopAction(pickerIsServing: nativePickerIsServing()) == .standDown {
        return 0
    }
    let raw = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    // Which session this prompt belongs to, read off the payload rather than off this process
    // (`promptHookSession`, SwitchHook.swift, states why the two differ).
    let (cwd, marker) = promptHookSession(raw)
    let lines: [String]
    switch hookModelAction(raw) {
    case .queue(let words):
        guard let intent = modelIntent(words) else {
            lines = ["`/tally-model` takes a model and an optional effort, or `auto`; "
                        + "\"\(words.joined(separator: " "))\" is neither",
                     modelStatusLines(liveModelStatus(cwd: cwd, marker: marker))
                         .joined(separator: "\n")]
            break
        }
        let attempt = attemptModel(intent, cwd: cwd, marker: marker)
        lines = [attempt.message] + attempt.notes
    case .list:
        // One element, so the lines print as a block under a single tag rather than one tag per
        // line - and as one `reason` rather than a decision per line on the other channel.
        lines = [modelStatusLines(liveModelStatus(cwd: cwd, marker: marker)).joined(separator: "\n")]
    }
    return emitPromptHookOutput(promptHookOutput(lines, backstop: backstop))
}
