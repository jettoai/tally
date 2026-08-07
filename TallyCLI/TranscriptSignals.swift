import Foundation

// Reading ONE transcript line: the field extractions the scan needs, and the turn bookkeeping that
// says which exchange a line belongs to.
//
// Split from TranscriptWatcher.swift, which was over the repo's size cap before this package added
// to it. The seam is the one the scan already has: everything here answers a question about a line
// or about the shape of a conversation, and nothing here knows about files, offsets, forks, or what
// the supervisor does with the answer. The watcher keeps the IO and the state.
//
// WHY A TURN IS WORTH TRACKING AT ALL. Claude Code writes no field saying "this user event will
// produce a model request", and the shapes cannot be told apart: a local command (`/effort`), a
// skill command (`/commit`) and a hook-intercepted command (`/tally-model`) write an IDENTICAL
// invocation record, differing only in what comes after it (a stdout echo, a meta expansion that
// reaches the model, a `<synthetic>` reply that never does). Every rule this feature has tried to
// write on the user side has been refuted by that (four times, 2026-08-07), because it is asking an
// undecidable question of a single record.
//
// The assistant side is a closed world instead: a main-chain event carrying a real model id IS a
// request that was served. So "was this request made after the command" is answered by the TURN it
// belongs to - the user event its parent chain leads back to - and a turn that started before the
// command can never answer for one that came after it, however late its tail arrives.

/// How many events' turn roots are remembered. A turn is a chain: one prompt, then any number of
/// tool_result / assistant pairs hanging off it, and a long agentic turn runs to hundreds of events
/// (measured: hop depth 6 on plain turns, tool chains into the hundreds). This is the ceiling on
/// "how far back a still-open turn's root can be", not on the conversation: an event whose root has
/// been evicted resolves to nothing, which the caller treats as "cannot tell" and therefore waits.
let turnRootCapacity = 512

/// The `parentUuid` a transcript line hangs off, or nil for a root (or for a line without the
/// field).
///
/// Read by direct key match rather than by parsing the line: this runs on every line of every scan,
/// and the quoted key cannot collide with `"uuid":"` the way a suffix match would.
func lineParentUUID(_ line: Substring) -> String? {
    guard let key = line.range(of: "\"parentUuid\":\"") else { return nil }
    let rest = line[key.upperBound...]
    guard let quote = rest.firstIndex(of: "\"") else { return nil }
    let value = String(rest[..<quote])
    return value.isEmpty ? nil : value
}

/// Which exchange each event belongs to, kept as "event uuid -> the timestamp of the user event its
/// chain starts at". Bounded and insertion-ordered, exactly like the excerpt map next door.
struct TurnRoots {
    private(set) var roots: [String: Date] = [:]
    private var order: [String] = []

    /// Record where `uuid` sits, and answer with the root it resolved to.
    ///
    /// Three cases, and they are the whole model:
    ///  - a user event that is NOT a tool_result STARTS a turn, so it is its own root. Every shape
    ///    qualifies - a typed prompt, a queued one, a skill expansion, a task notification - because
    ///    what a turn is for is not the question here; whether a request came after the command is.
    ///  - a tool_result is a continuation, so it inherits its parent's root. It carries the arrival
    ///    time of a tool call, which is why it must never be read as the start of anything: that
    ///    timestamp is what made a stale turn's tail look fresh.
    ///  - an assistant event inherits its parent's root, which is how a reply is attributed to the
    ///    prompt that asked for it.
    ///
    /// An unresolvable parent (evicted, or written before this watcher started reading) yields nil
    /// and is NOT recorded: a chain with a hole in it must stay unresolvable rather than silently
    /// re-rooting the rest of the turn at the first event this scan happened to see.
    @discardableResult
    mutating func record(uuid: String, parent: String?, startsTurn: Bool, at when: Date) -> Date? {
        let root: Date? = startsTurn ? when : parent.flatMap { roots[$0] }
        guard let root else { return nil }
        if roots.updateValue(root, forKey: uuid) == nil {
            order.append(uuid)
            if order.count > turnRootCapacity {
                roots.removeValue(forKey: order.removeFirst())
            }
        }
        return root
    }
}

/// Whether a line is a user event that STARTS a turn: a user record that is not a tool_result.
///
/// Deliberately not the person-acted test (`lastUserTurnAt`'s), and the difference is the reason
/// this feature needed two: that one asks "did the human do something", which a command invocation
/// satisfies and a task notification does not; this one asks "could a model request hang off this",
/// where the invocation produces nothing and the notification wakes a real turn.
func lineStartsTurn(_ line: Substring) -> Bool {
    line.contains("\"type\":\"user\"") && !line.contains("\"tool_result\"")
}

/// The `message.content` of a line, when it is a plain string. nil for a content list (tool_result,
/// meta expansions, assistant blocks), which is what makes this a cheap shape test as well as an
/// accessor.
func lineStringContent(_ line: Substring) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let message = object["message"] as? [String: Any] else { return nil }
    return message["content"] as? String
}

/// Whether a line is a slash-command record whose content OPENS with `tag`.
///
/// The position matters, and this is the whole of the hardening it exists for: the marker for a
/// `/model` is a substring, and a transcript routinely CONTAINS one without being one - a
/// tool_result carrying a file this repo's own source lives in, a prompt quoting a transcript
/// excerpt (measured in this machine's corpus: 24 lines carrying the tag, of which 3 are
/// tool_results and 1 a typed prompt). Read as a command, any of them resets a live anchor, spends
/// the served stamp, and derails the adoption of the real one.
///
/// So a command record has to look like one: a user event, not a tool_result, not a meta expansion,
/// and its content a plain string that BEGINS with the tag. The fields inside those tags appear in
/// different orders across Claude Code versions, so only the opening is asserted.
func lineIsCommandRecord(_ line: Substring, opening tag: String) -> Bool {
    guard line.contains("\"type\":\"user\""), !line.contains("\"tool_result\""),
          !line.contains("\"isMeta\":true"),
          let content = lineStringContent(line) else { return false }
    return content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(tag)
}

/// How many model requests may be served without any of them answering a pending `/model` before
/// the supervisor says so out loud.
///
/// The anchor depends on `parentUuid` chains, which are Claude Code's private format: if their shape
/// changes, roots stop resolving, the fail-safe holds (nothing is adopted) and the feature goes
/// quiet - which is the failure mode this whole design chose, but a silent one. Five is comfortably
/// past any single turn's worth of events while still landing inside one working session.
let unanchoredConfirmationLimit = 5

/// The line that says so (grep `model-anchor=lost`). Names no content: the count and the command's
/// own timestamp are enough to tell a format drift from a quiet session.
func modelAnchorLostLine(sessionID: String?, served: Int, commandAt: Date,
                         now: Date = Date()) -> String {
    let sid = sessionID.map { String($0.prefix(8)) } ?? "unknown"
    return "\(ISO8601DateFormatter().string(from: now)) session=\(sid) model-anchor=lost "
        + "served=\(served) command-at=\(ISO8601DateFormatter().string(from: commandAt))\n"
}
