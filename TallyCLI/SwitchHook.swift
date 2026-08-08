import Foundation

// `tally hook-switch` - what makes `/tally-account` cost NOTHING, in either shape.
//
// Claude Code fires a `UserPromptExpansion` hook when a slash command is typed, BEFORE any model is
// woken: the hook reads the invocation as JSON on stdin, and exiting 2 stops the expansion there,
// showing its stderr to the user. So the whole feature is: read what was typed, answer it here, and
// exit 2. No turn runs, no tokens are spent.
//
// IT ALWAYS ANSWERS. There is no pass-through, and that is the design rather than an optimisation:
// this command is an escape hatch, and an escape hatch may not depend on the thing it exists to
// escape. A bare `/tally-account` used to let the expansion run so a model could list the accounts
// and offer a picker - which works right up until the moment it is needed, because the reason to
// move accounts is usually that this one has no model left to answer with. Observed in the field
// (2026-08-06): "You've reached your Fable 5 limit", and the one command that could have moved the
// session needed a turn that could not be sent.
//
// So both shapes are answered from the snapshot on disk:
//
//   /tally-account <account>   queue the move (or say why it could not be queued)
//   /tally-account             print the fleet: who is available, how much is left, what to type
//
// and everything unrecognisable - stdin that is not JSON, a payload without the field, a shape from
// a future Claude Code - takes the LISTING branch rather than a model turn. A list is useful under
// every one of those, and it is free.
//
// The command file installed beside the skill is still the fallback for a machine where the hook
// itself is not registered (IntegrationsSwitchCommand.swift); it is no longer part of this path.

/// What the hook does with the payload it was handed.
enum HookSwitchAction: Equatable {
    /// An account (or `--auto`) was named: queue it and stop the expansion.
    case queue(String)
    /// Nothing usable was named: answer with the fleet, here, and stop the expansion.
    case list
}

/// The rest of the typed line, as Claude Code hands it to a prompt hook: one JSON object on stdin,
/// with `command_args` holding everything after the command, already past its own quote handling.
/// nil for anything else - stdin that is not JSON, a payload without the field, a shape from a
/// future Claude Code - which every hook here reads as "nothing was named".
///
/// Named for the HOOK CONTRACT rather than for the switch, because the contract is Claude Code's and
/// not this command's: `/tally-model` is handed the same object by the same event (ModelHook.swift),
/// and a second copy of the reading would be a second answer to what an unparseable payload means.
func hookCommandArguments(_ raw: String) -> String? {
    promptHookPayload(raw)?["command_args"] as? String
}

/// The payload itself, or nil for anything that is not one. One parse, one answer to "was this
/// readable", shared by the three field readings around it.
func promptHookPayload(_ raw: String) -> [String: Any]? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// The directory the prompt was typed in, as the same payload reports it (measured against Claude
/// Code 2.1.224: the `UserPromptExpansion` object carries `cwd`, `session_id`, `transcript_path`
/// and the command fields).
///
/// A HOOK MAY NOT ASK ITS OWN PROCESS. It is a child of Claude Code, and its working directory is
/// whatever Claude Code's is - usually the same thing, and not always: the point of reading it here
/// is that this field describes the PROMPT while the process describes the server. nil for a
/// payload without it (an older Claude Code, a shape nobody here has measured), which the callers
/// read as "fall back to this process's own" - the behaviour every version has had until now.
func hookCommandCwd(_ raw: String) -> String? {
    guard let cwd = promptHookPayload(raw)?["cwd"] as? String, !cwd.isEmpty else { return nil }
    return cwd
}

/// Claude Code's own id for the conversation the prompt came from, off the same payload.
///
/// THE WITNESS THAT SEPARATES NESTED SESSIONS. A `claude` launched from inside another supervised
/// session in the same directory inherits a marker the directory confirms, so nothing else in the
/// payload can tell the two apart - and the inner session's `/tally-model` acted on the outer
/// conversation (codex review of 512303b). This is compared against what each candidate supervisor
/// publishes it is watching (SessionContext.swift).
func hookCommandSessionID(_ raw: String) -> String? {
    guard let id = promptHookPayload(raw)?["session_id"] as? String, !id.isEmpty else { return nil }
    return id
}

/// What a prompt hook knows about which session it is answering for: the directory the prompt came
/// from, and a marker that is only worth anything where that directory confirms it.
///
/// BOTH HALVES ARE THE FIX FOR ONE DEFECT, and it is not the picker's alone: a `claude` launched
/// from a shell that was itself inside a supervised session inherits that session's marker, so
/// `/tally-model` in the new session has always described and acted on the OLD one. Shipped
/// behaviour until now, found by QA on the backstop (2026-08-07) and true of the plain command hook
/// since it was written.
func promptHookSession(_ raw: String) -> (cwd: String, marker: SessionMarkerTrust) {
    // `getppid()` IS the Claude Code that ran this hook, measured 2026-08-07 and asserted by the
    // backstop's own process-table checks. A short-lived child can read it at the moment it needs
    // it; the MCP server cannot, and records it at start-up instead (MCPServe.swift).
    (hookCommandCwd(raw) ?? FileManager.default.currentDirectoryPath,
     .corroborated(PromptOrigin(marker: liveSessionMarker(),
                                promptSession: hookCommandSessionID(raw),
                                claudeCodePID: getppid())))
}

/// The decision, pure: everything about the payload, nothing about the world. The value IS the
/// account name and is passed on as written (an account label may contain spaces, and re-parsing it
/// here would be a second, different, quoting rule).
func hookSwitchAction(_ raw: String) -> HookSwitchAction {
    guard let arguments = hookCommandArguments(raw) else { return .list }
    let name = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? .list : .queue(name)
}

// The two tags a row can carry are spelled once, in the file BOTH TARGETS compile
// (PickContract.swift): they are read by code on both sides now - the arrow-key menu opens on the
// recommended row (`switchMenuStart`, SwitchMenu.swift) and the native panel draws them apart from
// the label - and a literal repeated across a process boundary is a highlight that would silently
// stop landing on the right line.

/// One account as a manual pick shows it, independent of the surface drawing it: the hook's stderr
/// list and the arrow-key menu behind a bare `tally switch` (SwitchMenu.swift) are the same reading
/// of the same fleet, in the same order, with the same recommendation. Two surfaces that ranked the
/// fleet separately would eventually recommend different accounts for the same machine.
struct SwitchFleetRow: Equatable {
    let id: String
    let label: String
    /// "session 84% · weekly 61% · fable 12%", in the vocabulary `tally status` already uses.
    let windows: String
    /// "this session" / "most headroom", in that order when both apply.
    let tags: [String]
}

/// The accounts a session could be moved onto, best first. Pure, so the ordering and the
/// recommendation are testable without a snapshot on disk.
///
/// `current` is the account this session is already on, when anything can say. It is excluded from
/// the recommendation because the point of the list is to go somewhere ELSE; the fallback covers the
/// fleet of one, where there is nowhere else and saying so is the list itself.
func switchFleetRows(accounts: [Snapshot.Account], provider: String,
                     current: String?) -> [SwitchFleetRow] {
    // Only accounts a session could be moved ONTO: a listed account with no launch home is Tally
    // saying that login is gone, and naming it would queue a move that can never happen.
    let usable = accounts.filter { $0.provider == provider && $0.launchHome != nil }
    guard !usable.isEmpty else { return [] }
    let ranked = usable.sorted { headroom($0) > headroom($1) }
    let recommended = (ranked.first { $0.id != current } ?? ranked[0]).id
    return ranked.map { account in
        var tags: [String] = []
        if account.id == current { tags.append(switchCurrentSessionTag) }
        if account.id == recommended { tags.append(switchRecommendedTag) }
        let flagship = account.modelWindowName?.lowercased() ?? "model"
        // One element per window, so the separator is written once and cannot drift between them.
        return SwitchFleetRow(
            id: account.id, label: account.label,
            windows: ["session \(fmt(account.sessionRemaining))",
                      "weekly \(fmt(account.weeklyRemaining))",
                      "\(flagship) \(fmt(account.modelRemaining))"].joined(separator: " · "),
            tags: tags)
    }
}

/// The same reading as text, which is all a hook has: one line per account, and the two commands
/// that act on it. `rows` is nil when there was no readable snapshot to rank, which is NOT an empty
/// fleet: it means Tally is not publishing, and saying so is the actionable answer.
///
/// `problem` is what the snapshot read itself had to say (`loadSnapshot`), and it LEADS the listing
/// rather than being dropped. The whole claim of this path is that it answers from the file on disk
/// without waking a model, which carries the obligation to say how old that file is: with Tally.app
/// stopped for an hour, every percentage below is an hour old and the recommendation drawn from
/// them is an hour old too. The terminal menu has always warned (`pickSwitchTarget`); this surface
/// silently did not.
func hookSwitchListing(rows: [SwitchFleetRow]?, provider: String,
                       problem: String? = nil) -> [String] {
    // With no rows at all the problem IS the answer, and it is the more specific one: "snapshot is
    // 74m old" says what to do about it, where the generic line only guesses at the cause.
    guard let rows else {
        return [problem ?? "no fleet snapshot to read, so there is nothing to choose from - is "
            + "Tally.app running? (`tally status` says what it can see)"]
    }
    // Everything below it is a reading of a file this old, so it leads.
    let heading = [problem].compactMap { $0 }
    guard !rows.isEmpty else {
        return heading
            + ["no \(provider) account is signed in right now, so there is nowhere to move this "
                + "session - `tally add \(provider)` logs one in"]
    }
    return heading + ["accounts you can move this session to:"]
        + rows.map {
            "  \($0.label)  \($0.windows)"
                + ($0.tags.isEmpty ? "" : "  (\($0.tags.joined(separator: ", ")))")
        }
        + ["pick one with `/tally-account <name>`, or `/tally-account --auto` to follow "
            + "automatic selection"]
}

/// The account this session is running on, or nil when nothing can say - which both manual-pick
/// surfaces need and neither should ask for differently (SwitchRequest.swift requires the
/// environment and the published context to agree before it answers at all).
///
/// Through `currentSessionLookup`, the same rule the request-writing half uses, so the directory
/// fallback reaches here too: from a second terminal in the project directory there is no
/// environment marker, and reading only that marker made this answer nil while `attemptSwitch` went
/// on to move the single session running there. The row for the account it was already on then
/// carried no "this session" mark and could be recommended as somewhere to go.
func currentSessionAccount(_ accounts: [Snapshot.Account],
                           cwd: String = FileManager.default.currentDirectoryPath,
                           marker: SessionMarkerTrust = .trusted(liveSessionMarker())) -> String? {
    guard let session = currentSessionLookup(cwd: cwd, marker: marker) else { return nil }
    return sessionAccountID(sessionKey: session.key, isThisSession: session.isThisSession,
                            provider: providers[0], accounts: accounts)
}

/// The fleet this machine can offer a manual pick right now, read ONCE for both surfaces: the
/// snapshot on disk, ranked for the one provider they speak for, with the account this session
/// already sits on marked. Nil rows is no readable snapshot, which is not an empty fleet.
///
/// Both go through here rather than each reading for itself, because "which provider" and "which
/// account is this session on" are the two answers they must never come to differ on.
///
/// `cwd` names the session the "this session" mark belongs to, and defaults to this process's own
/// directory. The MCP server behind the native picker passes the directory its hook reported
/// (MCPServe.swift): it is a long-lived child of Claude Code, so its own directory says nothing
/// about which session is asking.
func liveSwitchFleetRows(cwd: String = FileManager.default.currentDirectoryPath,
                         marker: SessionMarkerTrust = .trusted(liveSessionMarker()))
    -> (rows: [SwitchFleetRow]?, problem: String?) {
    let fleet = liveSwitchFleet(cwd: cwd, marker: marker)
    return (fleet.rows, fleet.problem)
}

/// The same reading with the ACCOUNTS it was ranked from, in the order the snapshot lists them.
///
/// Two orders out of one read, because two surfaces want different ones and neither may re-read the
/// disk for itself. The text listing and the arrow-key menu are RANKED, best first, which is what
/// someone reading a list of percentages wants. The native dialog is not: it sits beside Tally's own
/// panel, and a person looking at both expects row three to be row three (`mcpAccountOptions`,
/// MCPPicker.swift). The recommendation still comes from the ranking, carried as a tag, so the two
/// surfaces never disagree about WHICH account has the most headroom - only about where it sits.
func liveSwitchFleet(cwd: String = FileManager.default.currentDirectoryPath,
                     marker: SessionMarkerTrust = .trusted(liveSessionMarker()))
    -> (accounts: [Snapshot.Account], rows: [SwitchFleetRow]?, problem: String?) {
    let (snapshot, problem) = loadSnapshot()
    guard let accounts = snapshot?.accounts else { return ([], nil, problem) }
    return (accountsInPanelOrder(accounts, order: snapshot?.accountOrder),
            switchFleetRows(accounts: accounts, provider: providers[0].id,
                            current: currentSessionAccount(accounts, cwd: cwd, marker: marker)),
            problem)
}

/// The accounts as the app's PANEL lists them: the published drag order first, then anything that
/// order does not mention, in the order the snapshot wrote it.
///
/// The order is published beside the accounts rather than applied to them, because that array's own
/// order decides near-ties for the launcher's account pick (UsageSnapshot.swift states the trade).
/// So applying it is the reading surface's job, and this is the one place it is done.
///
/// An absent order is a snapshot from an older app, and reads as "no preference": everything keeps
/// the order it arrived in, which is what every surface did before this existed.
func accountsInPanelOrder(_ accounts: [Snapshot.Account],
                          order: [String]?) -> [Snapshot.Account] {
    guard let order else { return accounts }
    // An EMPTY order needs no special case: nothing ranks, so every account ties and the stable
    // fallback below leaves them exactly where they were (asserted, and the early return that used
    // to be here was found to change nothing by mutating it away).
    let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    return accounts.enumerated().sorted { lhs, rhs in
        let left = rank[lhs.element.id] ?? Int.max
        let right = rank[rhs.element.id] ?? Int.max
        return left == right ? lhs.offset < rhs.offset : left < right
    }.map(\.element)
}

/// The same listing, read off this machine, with whatever the snapshot read had to say about
/// itself carried into it rather than discarded.
func switchFleetListing(cwd: String = FileManager.default.currentDirectoryPath,
                        marker: SessionMarkerTrust = .trusted(liveSessionMarker())) -> [String] {
    let (rows, problem) = liveSwitchFleetRows(cwd: cwd, marker: marker)
    return hookSwitchListing(rows: rows, provider: providers[0].id, problem: problem)
}

/// `tally hook-switch`: the hook entry. Registered by the app with the skill (IntegrationsStore),
/// never typed by hand, so it is absent from the usage text.
///
/// Always exit 2: the answer is already on stderr, and letting the expansion run would spend a turn
/// re-saying it. Stderr for all of it, because that is the only channel a blocked expansion shows
/// the user, and stdout is discarded on exit 2.
///
/// `--backstop` is the same work under a condition: it is registered BESIDE an `mcp_tool` hook that
/// raises the native picker, and it answers only when that picker is not there to
/// (PromptHookBackstop.swift states why it may not simply always answer).
func runHookSwitch(args: [String] = []) -> Int32 {
    let backstop = promptHookIsBackstop(args)
    if backstop, promptHookBackstopAction(pickerIsServing: nativePickerIsServing()) == .standDown {
        return 0
    }
    let raw = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    // Which session this prompt belongs to, read off the payload rather than off this process
    // (`promptHookSession` states why the two differ).
    let (cwd, marker) = promptHookSession(raw)
    let lines: [String]
    switch hookSwitchAction(raw) {
    case .queue(let name):
        let attempt = attemptSwitch(name: name, cwd: cwd, marker: marker)
        lines = [attempt.message] + attempt.notes
    case .list:
        // One element, so the rows print as a block under a single tag rather than one tag per
        // line - and as one `reason` rather than a decision per line on the other channel.
        lines = [switchFleetListing(cwd: cwd, marker: marker).joined(separator: "\n")]
    }
    return emitPromptHookOutput(promptHookOutput(lines, backstop: backstop))
}
