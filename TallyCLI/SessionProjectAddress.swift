import Foundation

// WHICH SESSION A DIRECTORY NAMES, and the whole of what `--project` adds to `tally session send`.
//
// ADDRESSING, NOT A SECOND SEND PATH. What this file produces is a pid, handed straight back to the
// `--session` route in SessionInputCommand.swift: the same roster question, the same refusals, the
// same Codex capability check. A caller that says `--project <dir>` is saying "look the pid up for
// me", and anything it would have been told about that pid it is still told.
//
// WHY A CALLER WOULD RATHER NOT TYPE THE PID. A pid is what an agent has least of: it is minted at
// spawn, changes on every restart and handoff, and the thing a script actually holds is the
// directory it is working in. `tally status --json` publishes both, so the lookup was always
// possible and was always written out by hand, once per caller, each with its own idea of what
// counts as a match.
//
// THE CHECKOUT IS THE ADDRESS, not the repository. Two parallel lines of one repo are two
// conversations with two inboxes (StatusReport.Session says so where `directory` and `project` are
// declared), so a worktree's directory does not name the trunk's session and the trunk's does not
// name a worktree's. That is the deliberate half of this: matching at repository grain would let a
// line meant for one line of work be typed into another, and no caller could tell from the exit
// code that it had happened.
//
// AMBIGUITY IS REFUSED RATHER THAN RESOLVED. Several sessions in one directory is the ordinary case
// here (a Claude and a Codex side by side, or two agents in one checkout), and there is no rule for
// picking between them that a caller would agree with in advance. So the refusal lists what is
// there, with the pid to name and the provider to narrow by, which is the answer the caller needs
// rather than a guess that lands somebody's text in the wrong conversation.

/// The provider names `--provider` may take, which are the names `tally status --json` publishes
/// under `sessions[].provider`. One list rather than a literal at each site, so a value the filter
/// accepts is a value the roster can actually carry.
let sessionProviderNames = ["claude", "codex"]

// MARK: - The address on the command line

/// How one `tally session send` command line says which session it means.
///
/// ONE TYPE FOR THREE FLAGS, because what they express is one thing with alternatives in it, and
/// the rules that make them coherent are rules ABOUT the set: `--session` and `--project` are two
/// answers to one question, and `--provider` is not an answer at all but a narrowing of the second.
/// Parsed apart, those rules would live in the grammar loop as three conditions nobody could test
/// without a command line.
struct SessionSendAddress: Equatable {
    /// A session named by pid, which is the oldest and most direct form.
    var session: String?
    /// A directory whose one supervised session is meant.
    var project: String?
    /// Which provider's session, when a directory holds more than one kind.
    var provider: String?

    /// Take `word` when it is one of the address flags, moving `index` past its value.
    ///
    /// THREE ANSWERS RATHER THAN TWO: nil means "this word is not mine", which is what lets the
    /// caller's loop go on to treat it as text or refuse it; false means it IS mine and is
    /// malformed (no value, said twice, or a provider name that is not one), which is a usage
    /// error rather than content; true means it was taken.
    mutating func take(_ word: String, _ args: [String], _ index: inout Int) -> Bool? {
        let value = index < args.endIndex ? args[index] : nil
        switch word {
        case "--session":
            guard let value, session == nil else { return false }
            session = value
        case "--project":
            // An empty directory is refused here rather than resolved: every reading of it is a
            // guess (the current directory? the root?) and a caller that wrote one meant something
            // it did not manage to expand.
            guard let value, project == nil, !value.isEmpty else { return false }
            project = value
        case "--provider":
            guard let value, provider == nil, sessionProviderNames.contains(value) else {
                return false
            }
            provider = value
        default:
            return nil
        }
        index += 1
        return true
    }

    /// Whether these name ONE session, which is what the grammar requires of them.
    ///
    /// TWO ADDRESSES ARE NOT AN ADDRESS. `--session` beside `--project` is refused rather than
    /// ranked, because the two can disagree and the caller that wrote both has already told us it
    /// is unsure which one it meant; silently preferring either is how text lands in a conversation
    /// nobody aimed at. `--provider` without `--project` is refused for a different reason: there
    /// is nothing for it to narrow, so honouring it would be accepting a filter that does nothing,
    /// and a caller that believed it had restricted the target never had.
    var namesOneSession: Bool {
        if session != nil, project != nil { return false }
        if provider != nil, project == nil { return false }
        return true
    }
}

// MARK: - The roster, as the lookup needs to see it

/// One supervised session, reduced to the four fields this lookup reads.
///
/// A VALUE OF ITS OWN rather than `StatusReport.Session`, so the rule can be asserted against a
/// roster written by hand. The report's own type is an encoding contract with a dozen fields, and a
/// test that had to fill every one of them to ask "which session is in this directory" would be
/// asserting the contract rather than the rule.
struct SessionProjectCandidate: Equatable {
    /// The provider process, which is the pid `--session` is given. Absent when the supervisor
    /// cannot prove one, which is the one case a matching session still cannot be addressed.
    var pid: Int?
    /// The checkout it was launched in, fully resolved (`StatusReport.Session.directory`).
    var directory: String?
    /// `claude` or `codex`, as the report publishes it.
    var provider: String?
    /// What it is doing, for the refusal to quote. Absent from a supervisor too old to publish one.
    var state: String?
}

/// Every live session, as this lookup sees it.
///
/// THROUGH THE ONE SCAN the report itself is folded from (`sessionReadings`), rather than a second
/// walk of the state directory or a subprocess reading our own JSON back: a second notion of which
/// sessions exist would be free to disagree with the one `tally status --json` publishes, and the
/// caller that reads that JSON to pick a directory would then be told there is nothing there.
func liveSessionProjectCandidates() -> [SessionProjectCandidate] {
    sessionReadings().sessions.map {
        SessionProjectCandidate(pid: $0.pid, directory: $0.directory, provider: $0.provider,
                                state: $0.state)
    }
}

// MARK: - The lookup

/// What a directory turns out to name.
enum SessionProjectMatch: Equatable {
    /// Exactly one, by the pid `--session` would have been given.
    case one(String)
    /// Nothing supervised was launched there at all.
    case noSession
    /// Sessions are there, and none is the provider that was asked for. Carries what IS there, so
    /// the refusal can show the caller the filter it should drop or change.
    case noneOfProvider([SessionProjectCandidate])
    /// Matching sessions are there and none of them publishes a pid to type into.
    case unaddressable([SessionProjectCandidate])
    /// More than one, which is refused rather than picked between.
    case ambiguous([SessionProjectCandidate])
}

/// The one spelling of a directory, so a caller's typing and the roster's publication can be
/// compared at all.
///
/// The roster's `directory` is the fully resolved checkout (`pickProject` puts it through
/// `realpathString`, GitRepoRoot.swift's POSIX `realpath` wrapper), and what a caller types is
/// whatever its shell handed it: a relative path, a `~`, a trailing slash, a symlinked parent. All
/// four compare unequal to a resolved path as strings, so each is undone here before the comparison
/// rather than guessed at afterwards - through `realpathString` itself, and not Foundation's
/// `resolvingSymlinksInPath()`: the two disagree under `/tmp`, `/var` and `/etc`, which macOS mounts
/// as symlinks into `/private`. `resolvingSymlinksInPath()` documents stripping a leading `/private`
/// back off when the result names the same file without it; `realpath` does not. A checkout under
/// any of those roots, compared the Foundation way, never matched the roster entry for it, which is
/// compared the `realpathString` way.
///
/// Returns nil only for an empty path, which the grammar has already refused; the guard is here so
/// the rule cannot be reached from a future caller that has not.
func sessionProjectDirectory(_ path: String,
                             cwd: String = FileManager.default.currentDirectoryPath) -> String? {
    guard !path.isEmpty else { return nil }
    let expanded = (path as NSString).expandingTildeInPath
    let absolute = expanded.hasPrefix("/")
        ? expanded
        : (cwd as NSString).appendingPathComponent(expanded)
    let resolved = realpathString(absolute)
    // `realpath` itself canonicalizes a trailing slash away once the path exists, so this only
    // still does anything on the path realpath could NOT resolve (nothing there to canonicalize):
    // `realpathString` hands that one back unchanged, trailing slash included, and without this a
    // caller's unresolvable `--project foo/` would compare unequal to the very same `--project foo`.
    guard resolved.count > 1, resolved.hasSuffix("/") else { return resolved }
    return String(resolved.dropLast())
}

/// Which session that directory names, if one does.
///
/// Pure, and the whole of the decision: the live caller differs from a test only in where the
/// roster came from.
func sessionProjectMatch(_ sessions: [SessionProjectCandidate], directory: String,
                         provider: String?) -> SessionProjectMatch {
    let here = sessions.filter { $0.directory == directory }
    guard !here.isEmpty else { return .noSession }
    let wanted = provider.map { name in here.filter { $0.provider == name } } ?? here
    guard !wanted.isEmpty else { return .noneOfProvider(here) }
    // TWO QUESTIONS, ASKED IN THE ORDER THAT MAKES EACH ONE MEAN SOMETHING. "Can anything here be
    // named at all?" comes first: when nothing in `wanted` publishes a pid, how many of them there
    // are does not matter, because none can be typed into either way. Only once that is settled is
    // "is there more than one?" asked, and it is asked over ALL of `wanted`, not just the ones that
    // publish a pid - filtering the pidless one out before counting used to let it vanish, so two
    // matching sessions quietly narrowed to "exactly one" and a caller's ambiguous --project was
    // sent to whichever one happened to publish a pid, while it was never told the other was there.
    guard wanted.contains(where: { $0.pid != nil }) else { return .unaddressable(wanted) }
    guard wanted.count == 1, let pid = wanted[0].pid else {
        return .ambiguous(wanted)
    }
    return .one(String(pid))
}

// MARK: - What the caller is told

/// One candidate as a refusal names it: the pid to type, and enough about it to tell it from its
/// neighbour.
private func describe(_ candidate: SessionProjectCandidate) -> String {
    let pid = candidate.pid.map(String.init) ?? "no pid published"
    // Absence is not `unknown`: that word is a session saying it cannot tell, while a missing field
    // is this Tally saying so (StatusReport.Session states the distinction).
    return "\(pid) (\(candidate.provider ?? "provider unpublished"), "
        + "\(candidate.state ?? "state unpublished"))"
}

/// The candidates in the order a reader can scan, which is by pid rather than by whatever order the
/// state directory was listed in: a refusal printed twice about the same two sessions should read
/// the same both times.
private func listed(_ candidates: [SessionProjectCandidate]) -> String {
    candidates.sorted { ($0.pid ?? 0, $0.provider ?? "") < ($1.pid ?? 0, $1.provider ?? "") }
        .map(describe).joined(separator: ", ")
}

private func sessionCount(_ n: Int) -> String {
    "\(n) supervised session\(n == 1 ? "" : "s")"
}

/// Why that directory could not be typed into, or nil when it could.
///
/// Pure, so every wording is assertable, and worded so none of them can be mistaken for a gate
/// refusal: these all mean "nothing of yours was queued at all", and each names the next thing to
/// type rather than only what went wrong.
func sessionProjectRefusal(_ match: SessionProjectMatch, directory: String,
                           provider: String?) -> String? {
    switch match {
    case .one:
        return nil
    case .noSession:
        return "no supervised session was launched in \(directory), so nothing there could be "
            + "typed into and nothing was queued. `tally status --json` lists the sessions this "
            + "machine supervises and the directory each one is in; a parallel line of a "
            + "repository keeps its own directory, so a worktree is not addressed by the trunk's "
            + "path or the other way round"
    case .noneOfProvider(let here):
        let name = provider ?? "that provider"
        return "no supervised \(name) session was launched in \(directory), so nothing was "
            + "queued. What is running there: \(listed(here)). Drop --provider, or name the one "
            + "you mean with --session <pid>"
    case .unaddressable(let matched):
        return "\(sessionCount(matched.count)) in \(directory) publish no provider pid, so there "
            + "is no process there this command can type into and nothing was queued. That pid is "
            + "published at spawn and read back only while the process is alive and still that "
            + "supervisor's child, so a supervisor too old to publish one is reached by restarting "
            + "the session once (exit, then `tally claude`)"
    case .ambiguous(let candidates):
        // The narrowing is offered only where it would actually narrow: suggesting --provider to a
        // caller looking at two sessions of the same provider, or to one that already passed it,
        // is sending them back to a flag that will refuse them again for the same reason.
        let narrowable = provider == nil && Set(candidates.map(\.provider)).count > 1
        // A candidate can be listed here without a pid of its own (describe() already prints "no
        // pid published" for it): it still made the directory ambiguous, but "Name one with
        // --session <pid>" would read like every candidate can be named that way, so say which one
        // cannot until it publishes one.
        let unnamed = candidates.contains { $0.pid == nil }
        return "\(sessionCount(candidates.count)) are running in \(directory), so --project "
            + "cannot tell which one you mean and nothing was queued: \(listed(candidates)). Name "
            + "one with --session <pid>"
            + (unnamed ? " (one of these publishes none yet and cannot be named until it does)" : "")
            + (narrowable ? ", or narrow it with --provider claude|codex" : "")
    }
}

// MARK: - From a command line to an address

/// What `--project` resolved to for one command line.
enum SessionProjectResolution: Equatable {
    /// The same request with its session filled in, which is exactly what the caller would have
    /// written by hand.
    case addressed(SessionSendIntent)
    /// The sentence the caller is refused with. Nothing has been written at this point, by
    /// construction: this runs before `queueSessionLine` is called at all.
    case refused(String)
}

/// Turn a `--project` into a `--session`, or say why it cannot be.
///
/// The roster is a parameter rather than a call, so the resolution can be asserted against sessions
/// that do not exist on the machine running the test, and so the live path pays for the scan only
/// where a directory was actually named (`runSessionSend` asks for it only then).
func resolveSessionProject(_ intent: SessionSendIntent, sessions: [SessionProjectCandidate],
                           cwd: String = FileManager.default.currentDirectoryPath)
    -> SessionProjectResolution {
    guard let project = intent.project else { return .addressed(intent) }
    guard let directory = sessionProjectDirectory(project, cwd: cwd) else {
        return .refused("--project needs a directory to look a session up by; nothing was queued")
    }
    let match = sessionProjectMatch(sessions, directory: directory, provider: intent.provider)
    if let refusal = sessionProjectRefusal(match, directory: directory, provider: intent.provider) {
        return .refused(refusal)
    }
    guard case .one(let pid) = match else {
        // Unreachable while the refusal above covers every case but `.one`, and stated rather than
        // forced: a case added to the match without a wording for it must not fall through into a
        // send addressed to nobody.
        return .refused("could not tell which session \(directory) names; nothing was queued")
    }
    // THE PROJECT IS SPENT HERE. What travels on is a request that names a pid, so everything
    // downstream (the roster check, the Codex refusal, the one-send-at-a-time address) is asked the
    // same question about it as it is asked about a pid somebody typed.
    return .addressed(SessionSendIntent(text: intent.text, session: pid))
}
