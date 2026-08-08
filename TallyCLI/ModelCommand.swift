import Foundation

// Asking for the change: the CLI half of `tally model`, split from SessionModel.swift (which keeps
// the supervisor-side decision) exactly as SwitchCommand.swift is split from SessionSwitch.swift.
// This side decides WHAT WAS ASKED and writes the request; that side decides what a poll tick does
// about one; ModelRequest.swift addresses it to a session.
//
// Three surfaces come through here and must get the same answer: `tally model` typed (or run as a
// tool call) inside the session, the `/tally-model` prompt hook (ModelHook.swift), and the arrow-key
// picker behind a bare `tally model` in a terminal (ModelMenu.swift).

/// What asking to change this session's pair came to, decided but not yet said: one decision, one
/// wording, three printers.
struct ModelAttempt: Equatable {
    enum Result: Equatable {
        /// A request is on disk; the supervisor applies it at the end of the current turn.
        ///
        /// There is no "already there" here, unlike `tally switch`: pinning the pair a session is
        /// already running is still a pin, and the supervisor settles that one without a restart
        /// (SessionModel.swift). Nothing about it is worth a different word to the person who typed
        /// it - the instruction is now in force either way.
        case queued
        /// Nothing was queued, and `message` says why.
        case refused
    }

    let result: Result
    /// The one sentence answering "what happened", written to stand ALONE: a surface with a single
    /// line to spend (the hook's stderr) shows this and nothing else.
    let message: String
    /// Worth saying alongside it, never instead of it: a snapshot problem, a supervisor that has to
    /// replace itself first.
    var notes: [String] = []

    var exitCode: Int32 { result == .refused ? 1 : 0 }

    static func refusal(_ message: String, notes: [String] = []) -> ModelAttempt {
        ModelAttempt(result: .refused, message: message, notes: notes)
    }
}

/// What one invocation asks for. Two shapes, because the command has two: run this conversation on
/// that pair, or hand it back to the layers underneath.
enum ModelIntent: Equatable {
    /// `effort` is nil when only a model was named, which leaves the effort axis exactly as it is.
    /// That is a real third state and not a missing value: `tally model opus` in a session launched
    /// at xhigh must not quietly drop the depth its user chose.
    case pin(model: String, effort: String?)
    case auto
}

/// What a command line asks for, or nil when it asks for something this command cannot act on.
/// Pure, so the grammar is testable: at most two words, the first a model, the second an effort.
///
/// `auto` is accepted both bare and as `--auto`. The flag spelling is what the request file carries
/// and what `tally switch` uses; the bare word is what a person types after `/tally-model`, where a
/// leading dash is awkward and every other argument is a bare word. One extra spelling of one token
/// is cheaper than the support question.
func modelIntent(_ args: [String]) -> ModelIntent? {
    let words = args.filter { !$0.isEmpty }
    /// Either spelling of the release, in either position.
    func isRelease(_ word: String) -> Bool {
        word == modelAutoRequest || word.lowercased() == "auto"
    }
    // Both together is refused rather than resolved, the rule `switchIntent` states for its own two
    // intents: `tally model auto opus` is one instruction under either reading, the two readings are
    // opposites (run opus here / follow whatever the layers below decide), and there is no answer
    // that is safe to guess at.
    guard !words.contains(where: isRelease) else {
        return words.count == 1 ? .auto : nil
    }
    switch words.count {
    case 1: return .pin(model: words[0], effort: nil)
    case 2: return .pin(model: words[0], effort: words[1])
    default: return nil
    }
}

/// Why this pair cannot be written, or nil when it can. Pure, and asked BEFORE anything is written,
/// so a refused value never reaches a request file.
///
/// THE TWO AXES ARE CHECKED DIFFERENTLY, on purpose. A model name is open text - every provider
/// spells them differently and new ones appear between releases - so it is checked only for the
/// shape any launch axis must have (`isLaunchAxisValue`, which is also the shell-injection
/// entrance). An effort is a closed enumeration the installed CLI publishes, and a value outside it
/// is not a preference but a session that will not start: `claude --effort nonsense` exits
/// immediately, so the supervisor would kill the child and respawn it into the same failure on every
/// tick. Refusing here, naming the levels, is the difference between a typo and a broken session.
func modelIntentProblem(_ intent: ModelIntent, efforts: [String] = claudeEffortNames()) -> String? {
    guard case .pin(let model, let effort) = intent else { return nil }
    guard isLaunchAxisValue(model) else {
        // A value that is itself a flag gets its own wording, because the general sentence ends in
        // "and dash" and would read as a contradiction to the one person who most needs to act on
        // it (the same distinction `tally project set` draws).
        return model.hasPrefix("-")
            ? "\"\(model)\" is a flag, not a model name; nothing was queued"
            : "\"\(model)\" is not a model name - letters, digits, dot, underscore, colon and dash "
                + "only; nothing was queued"
    }
    guard let effort else { return nil }
    guard isLaunchAxisValue(effort), isClaudeEffortName(effort, in: efforts) else {
        return "\"\(effort)\" is not an effort level - pick one of "
            + "\(efforts.joined(separator: ", ")); nothing was queued"
    }
    return nil
}

/// Find the session, check the value, and write the request. Everything the command does except
/// print, so all three surfaces share it.
///
/// Unconfirmed, like `tally switch` and `tally reload`: asking IS the intent. It returns as soon as
/// the request is written - the supervisor acts on it - so it never blocks the turn it was run in,
/// which matters because that turn has to END before the change can happen.
///
/// `cwd` is the directory whose session is being addressed, which is this process's own for every
/// surface a person types into. It is a parameter for the one surface where the two differ: the MCP
/// server behind the native picker is a long-lived child of Claude Code (MCPServe.swift), so the
/// directory that identifies the session is the one the HOOK reported, not the one this process
/// happens to sit in.
func attemptModel(_ intent: ModelIntent, now: Date = Date(),
                  cwd: String = FileManager.default.currentDirectoryPath,
                  marker: SessionMarkerTrust = .trusted(liveSessionMarker())) -> ModelAttempt {
    if let problem = modelIntentProblem(intent) { return .refusal(problem) }
    // Claude only, exactly as the supervisor is: a codex launch is a plain exec with nothing
    // resident to act on a request.
    let sessionKey: String
    switch marker.resolve(here: supervisorsInDirectory(cwd)) {
    case .session(let key):
        sessionKey = key
    case .none:
        return .refusal(
            "this session is not supervised, so nothing here can change what it runs: it was "
                + "launched bare, with --no-handoff, or with an --account pin. Sessions started "
                + "with `tally claude` can be changed.")
    case .ambiguous(let pids):
        return .refusal(
            "\(pids.count) supervised sessions are running in this directory, so this command "
                + "cannot tell which one you mean (pids \(pids.joined(separator: ", "))). Run it "
                + "inside the session you want to change - or ask the agent in that session to run "
                + "it.")
    }
    // Whether anything will read the request, through the same answer `tally switch` gets
    // (SwitchRequest.swift states when it can be judged at all).
    var notes: [String] = []
    // Judged against a version stamped beside a marker we BELIEVED. A corroborated marker that was
    // dropped describes somebody else's supervisor, and refusing this request over its build would
    // turn away a session that is perfectly current (`liveRequestHonourability` asks only where the
    // session named itself).
    let honourability = liveRequestHonourability(marker: marker.adopted(sessionKey))
    if honourability == .tooOld {
        return .refusal(
            "this session's supervisor predates `tally model` and would never read the request, so "
                + "nothing was queued. Restart this session once (exit, then launch again with "
                + "`tally claude`) and it can be changed from then on.")
    }
    sweepDeadSessionRequests(dir: modelRequestDir)
    let requested: (model: String, effort: String?)
    switch intent {
    case .auto: requested = (modelAutoRequest, nil)
    case .pin(let model, let effort): requested = (model, effort)
    }
    do {
        // The conversation this was typed into, on the same terms as the account axis
        // (`attemptSwitch`): a hook and the native picker are told which one it is, a person's shell
        // is not, and the supervisor uses it to catch up with a `/clear` it cannot otherwise resolve.
        try writeModelRequest(model: requested.model, effort: requested.effort,
                              sessionKey: sessionKey, transcriptID: marker.promptTranscriptID,
                              now: now)
    } catch {
        return .refusal("cannot write \(modelRequestFile(sessionKey: sessionKey).path): "
            + "\(error.localizedDescription)")
    }
    if honourability == .afterSelfUpdate {
        notes.append("this session runs a supervisor from another build: it replaces itself with "
            + "the installed one at the next idle moment, and the change happens after that")
    }
    guard case .pin(let model, let effort) = intent else {
        return ModelAttempt(
            result: .queued,
            message: "this session follows the launch defaults again (this project's profile, then "
                + "the app's default model and effort). It changes at the end of this turn if that "
                + "differs from what it is running now",
            notes: notes)
    }
    // The timing, spelled out, because the caller is usually an agent that has to relay it.
    return ModelAttempt(
        result: .queued,
        message: "this session will run \(model)\(effort.map { "/\($0)" } ?? "") from the end of "
            + "this turn, and stays there for the rest of the conversation - the launch default "
            + "stops moving it. `tally model auto` hands it back"
            + (effort == nil ? " (effort left as it is: name one to change it too)" : ""),
        notes: notes)
}

// MARK: - CLI entry

/// Which of the command's three surfaces an invocation lands on. Pure, so "does a script still get
/// the usage text" is a question a test can ask without a terminal.
enum ModelEntry: Equatable {
    case act(ModelIntent)
    case menu
    case usage
}

func modelEntry(_ args: [String], interactive: Bool) -> ModelEntry {
    if let intent = modelIntent(args) { return .act(intent) }
    // Only a TRULY bare invocation opens the menu: a line this command cannot act on is a refusal
    // with something to say, and answering it with a menu would hide the mistake instead of naming
    // it. Interactivity is both ends being a terminal, for the reason `menuIsAvailable` gives.
    return args.isEmpty && interactive ? .menu : .usage
}

/// `tally model <model> [effort]`: run this conversation on that pair for the rest of its life.
/// `tally model auto` releases it. Bare, in a terminal, it asks (ModelMenu.swift).
func runModel(args: [String]) -> Int32 {
    let chosen: ModelIntent?
    switch modelEntry(args, interactive: menuIsAvailable(
        stdinIsTTY: isatty(STDIN_FILENO) == 1, stdoutIsTTY: isatty(STDOUT_FILENO) == 1)) {
    case .act(let intent):
        chosen = intent
    case .menu:
        // Said before the menu, because it is the answer to "what am I running now" and the menu is
        // only the answer to "what instead".
        for line in modelStatusLines(liveModelStatus()) { warn(line) }
        switch pickSessionModel() {
        case .picked(let intent): chosen = intent
        case .cancelled: return 1        // they said no; saying it back to them adds nothing
        case .unavailable: chosen = nil  // no menu to draw: the usage text says what to type
        }
    case .usage:
        chosen = nil
    }
    guard let intent = chosen else {
        warn("""
        usage: tally model <model> [effort]
               tally model auto

        <model> pins THIS conversation to that model for the rest of its life: it takes effect when
        the current turn ends and STAYS, so the launch default in Tally's Settings stops moving it.
        Name an effort second (\(claudeEffortNames().joined(separator: ", "))) to pin the depth too;
        leave it out and the session keeps the one it has.
        auto releases the pin, handing the session back to this project's profile and then the app's
        default. Run it bare in a terminal to pick from a menu; in a pipe you get this text.
        To make every launch in this project run one model, use `tally project set --model`.
        """)
        return 2
    }
    let attempt = attemptModel(intent)
    // The one line that answers the command goes to stdout when it worked, so a script can read it;
    // a refusal is stderr, like every other failure here.
    if attempt.result == .refused { warn(attempt.message) } else { print(attempt.message) }
    for note in attempt.notes { warn(note) }
    return attempt.exitCode
}
