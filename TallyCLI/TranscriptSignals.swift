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

/// Where a turn started, in the two ways this feature needs to know.
struct TurnRoot: Equatable {
    /// The root user event's own timestamp, for the places that want a moment (the badge's stamp).
    let at: Date
    /// WHERE IN THE FILE it was read, which is what "after the command" is actually judged by.
    ///
    /// Timestamps in a transcript are NOT monotonic, and not by a little: around a compaction this
    /// machine's corpus holds a summary stamped 07:01:11 followed by a command record stamped
    /// 06:58:54 - two minutes and seventeen seconds EARLIER (corpus probe, 2026-08-07). Compared by
    /// time, a command whose stamp is deflated like that reads as older than a turn that was already
    /// running when it was typed, and that turn's tail then qualifies as its answer: the exact
    /// failure this anchor exists to prevent, re-entered through the clock.
    ///
    /// A transcript is APPEND-ordered, so "was this turn started after the command was written" is a
    /// question about position - and position is what the scan already has, since it reads lines in
    /// order. No later stamp can rewrite it.
    let seq: Int
}

/// Which exchange each event belongs to, kept as "event uuid -> where its chain starts". Bounded and
/// insertion-ordered, exactly like the excerpt map next door.
struct TurnRoots {
    private(set) var roots: [String: TurnRoot] = [:]
    private var order: [String] = []
    /// How many entries have been dropped to stay inside the cap, and WHICH ones.
    ///
    /// The count alone was a mistake this replaced: it turned the canary off for the rest of a
    /// session the moment any eviction happened, which on a long conversation is within the first
    /// hour - so a real format drift after that point would never be reported (decision review,
    /// 2026-08-07). What the exemption has to be about is THIS parent: an event whose parent was
    /// evicted cannot resolve and that is expected; an event whose parent was never here at all is
    /// the symptom the canary exists for.
    ///
    /// The set is bounded the same way the map is, and by the same eviction: a parent that fell out
    /// of it left more than `turnRootCapacity` entries ago, which is a chain no live turn has.
    private(set) var evicted = 0
    private(set) var evictedIDs: Set<String> = []
    private var evictedOrder: [String] = []

    /// Whether this uuid is one the cap dropped - or one whose own lineage it dropped, which is the
    /// same thing to anything hanging off it. The only reason an absent parent is expected rather
    /// than a symptom.
    func wasEvicted(_ uuid: String?) -> Bool {
        guard let uuid else { return false }
        return evictedIDs.contains(uuid)
    }

    /// Remember an id as gone, under the same bound as the map itself.
    private mutating func markEvicted(_ uuid: String) {
        guard evictedIDs.insert(uuid).inserted else { return }
        evictedOrder.append(uuid)
        if evictedOrder.count > turnRootCapacity {
            evictedIDs.remove(evictedOrder.removeFirst())
        }
    }

    /// Record where `uuid` sits, and answer with the root it resolved to.
    ///
    /// Three cases, and they are the whole model:
    ///  - a user event that is NOT a tool_result STARTS a turn, so it is its own root. Every shape
    ///    qualifies - a typed prompt, a queued one, a skill expansion, a task notification, and an
    ///    auto-compact summary (rare, and a sampling once concluded it never happens; this machine's
    ///    corpus has one, and it is harmless: a reply rooted at a summary is still a reply, and what
    ///    it carries is still the model that served it) - because what a turn is FOR is not the
    ///    question here; whether a request came after the command is.
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
    mutating func record(uuid: String, parent: String?, startsTurn: Bool, at when: Date,
                         seq: Int) -> TurnRoot? {
        let root: TurnRoot? = startsTurn ? TurnRoot(at: when, seq: seq)
            : parent.flatMap { roots[$0] }
        guard let root else {
            // UNRESOLVED BECAUSE THE PARENT WAS EVICTED is a property that has to travel down the
            // chain. Recording nothing left the grandchild's parent - this event - unknown to
            // `wasEvicted`, so the next event in the same turn read as a genuine mystery: six normal
            // descendants of one evicted entry were enough to report a format drift that had not
            // happened (review, 2026-08-07). Marking this uuid as evicted too says what is true of
            // it - its lineage is gone - and carries that fact to everything hanging off it.
            //
            // A parent that was never here at all is left alone, which is the case the canary is
            // for: nothing about it is expected.
            if wasEvicted(parent) { markEvicted(uuid) }
            return nil
        }
        if roots.updateValue(root, forKey: uuid) == nil {
            order.append(uuid)
            if order.count > turnRootCapacity {
                let dropped = order.removeFirst()
                roots.removeValue(forKey: dropped)
                evicted += 1
                markEvicted(dropped)
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

/// How long the transcript must have been silent before a held candidate is settled without waiting
/// for the next turn to open.
///
/// The next turn opening is the better signal and stays the primary one: something else starting is
/// proof the previous turn stopped. But a user who chooses a model, reads the answer and then walks
/// away never produces it - and a candidate held forever is not merely late, it is DANGEROUS: the
/// session's expected model stays the old one while the transcript shows the new one, which is
/// exactly the difference the degradation rescue acts on. It would move the conversation to another
/// account to "restore" the model the user just chose to leave (decision review, 2026-08-07).
///
/// Silence carries the same structural claim as the next root, one step weaker: the records that
/// explain a turn - a fallback flag above all - are written by the same client in the same breath as
/// the records they explain, so a transcript that has not been appended to for this long has
/// finished saying what happened in that turn. It is the repo's existing between-turns proxy
/// (`isQuiet`), at the same 5 seconds, so this settles no later than the rescue's own gate opens -
/// and the settlement runs earlier in the tick than the rescue does (`observeCapHit` precedes it in
/// Supervisor.swift, asserted in the suite), so the pin is in place before anything reasons about a
/// difference.
///
/// The refutable form: a record that disqualifies a turn is never written more than five seconds
/// after the last record of that turn. To refute it, produce a transcript where a
/// `model_refusal_fallback` lands that late; the cost would be one adoption of a model the API chose
/// rather than the user, which is why the wait exists at all rather than being skipped outright.
let pendingSettleQuietSeconds: TimeInterval = 5

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
