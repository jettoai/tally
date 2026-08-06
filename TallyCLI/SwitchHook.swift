import Foundation

// `tally hook-switch` - what makes `/tally-switch` cost NOTHING, in either shape.
//
// Claude Code fires a `UserPromptExpansion` hook when a slash command is typed, BEFORE any model is
// woken: the hook reads the invocation as JSON on stdin, and exiting 2 stops the expansion there,
// showing its stderr to the user. So the whole feature is: read what was typed, answer it here, and
// exit 2. No turn runs, no tokens are spent.
//
// IT ALWAYS ANSWERS. There is no pass-through, and that is the design rather than an optimisation:
// this command is an escape hatch, and an escape hatch may not depend on the thing it exists to
// escape. A bare `/tally-switch` used to let the expansion run so a model could list the accounts
// and offer a picker - which works right up until the moment it is needed, because the reason to
// move accounts is usually that this one has no model left to answer with. Observed in the field
// (2026-08-06): "You've reached your Fable 5 limit", and the one command that could have moved the
// session needed a turn that could not be sent.
//
// So both shapes are answered from the snapshot on disk:
//
//   /tally-switch <account>   queue the move (or say why it could not be queued)
//   /tally-switch             print the fleet: who is available, how much is left, what to type
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

/// The decision, pure: everything about the payload, nothing about the world. `command_args` is what
/// Claude Code puts the rest of the typed line in, already past its own quote handling, so the value
/// IS the account name and is passed on as written (an account label may contain spaces, and
/// re-parsing it here would be a second, different, quoting rule).
func hookSwitchAction(_ raw: String) -> HookSwitchAction {
    guard let data = raw.data(using: .utf8),
          let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let arguments = payload["command_args"] as? String else { return .list }
    let name = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? .list : .queue(name)
}

/// The two tags a row can carry, spelled once because the second is read by CODE: the menu opens
/// on the recommended row (`switchMenuStart`, SwitchMenu.swift), and a literal repeated in two files
/// is a highlight that would silently stop landing on the right line. The first is named beside it
/// so the pair reads as one vocabulary rather than as one constant and one loose string.
let switchCurrentSessionTag = "this session"
let switchRecommendedTag = "most headroom"

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
        + ["pick one with `/tally-switch <name>`, or `/tally-switch --auto` to follow "
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
func currentSessionAccount(_ accounts: [Snapshot.Account]) -> String? {
    guard let session = currentSessionLookup() else { return nil }
    return sessionAccountID(sessionKey: session.key, isThisSession: session.isThisSession,
                            provider: providers[0], accounts: accounts)
}

/// The fleet this machine can offer a manual pick right now, read ONCE for both surfaces: the
/// snapshot on disk, ranked for the one provider they speak for, with the account this session
/// already sits on marked. Nil rows is no readable snapshot, which is not an empty fleet.
///
/// Both go through here rather than each reading for itself, because "which provider" and "which
/// account is this session on" are the two answers they must never come to differ on.
func liveSwitchFleetRows() -> (rows: [SwitchFleetRow]?, problem: String?) {
    let (snapshot, problem) = loadSnapshot()
    guard let accounts = snapshot?.accounts else { return (nil, problem) }
    return (switchFleetRows(accounts: accounts, provider: providers[0].id,
                            current: currentSessionAccount(accounts)), problem)
}

/// The same listing, read off this machine, with whatever the snapshot read had to say about
/// itself carried into it rather than discarded.
func switchFleetListing() -> [String] {
    let (rows, problem) = liveSwitchFleetRows()
    return hookSwitchListing(rows: rows, provider: providers[0].id, problem: problem)
}

/// `tally hook-switch`: the hook entry. Registered by the app with the skill (IntegrationsStore),
/// never typed by hand, so it is absent from the usage text.
///
/// Always exit 2: the answer is already on stderr, and letting the expansion run would spend a turn
/// re-saying it. Stderr for all of it, because that is the only channel a blocked expansion shows
/// the user, and stdout is discarded on exit 2.
func runHookSwitch() -> Int32 {
    let raw = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    switch hookSwitchAction(raw) {
    case .queue(let name):
        let attempt = attemptSwitch(name: name)
        warn(attempt.message)
        for note in attempt.notes { warn(note) }
    case .list:
        // One call, so the rows print as a block under a single tag rather than one tag per line.
        warn(switchFleetListing().joined(separator: "\n"))
    }
    return 2
}
