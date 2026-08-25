import Foundation

// WHICH CONVERSATION A LAUNCH PICKS UP (TallyCLI/LaunchResume.swift, LastConversation.swift): the
// ranking, the filters it runs the directory through, and the reading of one transcript that feeds
// them. Split from launchchecks.swift, which asserts what the ARGS come out as, on the seam the
// source uses: this file is "which conversation", that one is "launched how".
//
// THE DEFECT BEHIND ALL OF IT. `tally claude` picked the account with the most headroom and injected
// a bare `--continue`, which claude resolves against a pointer private to that account's config
// home while the transcripts are shared between homes. The account with the most headroom is the one
// away longest, and the one away longest has the oldest pointer, so the conversation walked steadily
// backwards. Measured 2026-08-25 over this machine's history: 6 launches resumed something older
// than the newest conversation in the directory they ran in, by up to 1,624 hours.

// MARK: - Transcript fixtures
//
// Shaped from real records rather than invented: a session opens with a `mode`, a timestamped
// `queue-operation`, an `attachment` carrying the entrypoint and a `system` line, and only writes a
// `user` record when somebody types. The 15 message-less transcripts on this machine all look like
// `startupOnlyTranscript`, down to the `last-prompt` naming a leaf that is not a message - which is
// exactly what makes them unresumable.

func write(_ text: String, to url: URL) {
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

/// The records every session writes before anybody types into it.
func startupLines(at stamp: String, entrypoint: String = "cli", kind: String? = nil) -> [String] {
    let sessionKind = kind.map { ",\"sessionKind\":\"\($0)\"" } ?? ""
    return [
        "{\"type\":\"mode\",\"mode\":\"default\",\"sessionId\":\"s\"}",
        "{\"type\":\"queue-operation\",\"sessionId\":\"s\",\"timestamp\":\"\(stamp)\"}",
        "{\"type\":\"attachment\",\"entrypoint\":\"\(entrypoint)\"\(sessionKind),"
            + "\"isSidechain\":false,\"timestamp\":\"\(stamp)\"}",
        "{\"type\":\"system\",\"isMeta\":true,\"isSidechain\":false,\"timestamp\":\"\(stamp)\"}",
        "{\"type\":\"last-prompt\",\"leafUuid\":\"7f4c0b1e-0000-0000-0000-000000000001\","
            + "\"sessionId\":\"s\"}",
    ]
}

/// A conversation somebody actually had: the startup records, then a turn.
func turnTranscript(at stamp: String, entrypoint: String = "cli", kind: String? = nil) -> String {
    (startupLines(at: stamp, entrypoint: entrypoint, kind: kind) + [
        "{\"type\":\"user\",\"isSidechain\":false,\"timestamp\":\"\(stamp)\","
            + "\"message\":{\"content\":\"hello\"}}",
    ]).joined(separator: "\n") + "\n"
}

/// A session opened and never typed into - a `/clear` nobody used, a window left standing.
func startupOnlyTranscript(at stamp: String, entrypoint: String = "cli") -> String {
    startupLines(at: stamp, entrypoint: entrypoint).joined(separator: "\n") + "\n"
}

// MARK: - The checks

func runConversationChecks() {
    // MARK: - The ranking
    //
    // Values rather than files, so the rule is asserted without a directory: the reading of a
    // transcript is checked on its own further down.
    func candidate(_ id: String, _ stamp: String?, resumable: Bool = true,
                   interactive: Bool = true) -> ConversationCandidate {
        ConversationCandidate(id: id, lastEventAt: stamp.flatMap(parseISO), resumable: resumable,
                              interactive: interactive)
    }
    let older = candidate("older", "2026-08-25T09:00:00.000Z")
    let newer = candidate("newer", "2026-08-25T10:00:00.000Z")

    check("with no record the newest conversation wins",
          conversationStart(recorded: nil, among: [older, newer], live: []) == .resume("newer"))
    check("an empty directory starts fresh",
          conversationStart(recorded: nil, among: [], live: []) == ConversationStart.none)

    // THE FACT CHANNEL OUTRANKS THE RANKING. What the machine watched here last is reported by the
    // process writing it; "newest file" is a guess about the same question.
    check("a record is taken even when another file is newer",
          conversationStart(recorded: "older", among: [older, newer], live: []) == .resume("older"))
    // …and a record naming something no longer on disk is a MISS, not an answer.
    check("a record naming nothing here falls through to the ranking",
          conversationStart(recorded: "gone", among: [older, newer], live: []) == .resume("newer"))

    // THE OWNER RULING, 2026-08-25: a cleared conversation must never fall back onto what came
    // before it. It cannot be resumed by id (the CLI needs the leaf chain to reach a user or
    // assistant record), so the launch starts FRESH - which lands in the same empty context.
    let clearedRecord = candidate("cleared", "2026-08-25T11:00:00.000Z", resumable: false)
    check("a recorded conversation with no turn starts fresh",
          conversationStart(recorded: "cleared", among: [older, newer, clearedRecord], live: [])
              == .unstarted)
    check("…and specifically does NOT step back to the one behind it",
          conversationStart(recorded: "cleared", among: [older, newer, clearedRecord], live: [])
              != .resume("newer"))

    // THE FALLBACK DOES NOT PICK EMPTIES EITHER, and for the opposite reason: with no record there
    // is nothing saying that empty session is where the person was, and `--resume` would fail on it.
    check("the ranking skips a conversation with no turn, however new",
          conversationStart(recorded: nil, among: [newer, clearedRecord], live: [])
              == .resume("newer"))
    check("a directory of nothing but empty sessions starts fresh",
          conversationStart(recorded: nil, among: [clearedRecord], live: [])
              == ConversationStart.none)

    // WHAT `--continue` ITSELF SKIPS, mirrored: a background agent, a `claude -p` run, an SDK
    // session. Several of each sit in ordinary project directories on this machine.
    let background = candidate("bg", "2026-08-25T12:00:00.000Z", interactive: false)
    check("the ranking skips a non-interactive session, however new",
          conversationStart(recorded: nil, among: [newer, background], live: [])
              == .resume("newer"))

    // A LIVE CONVERSATION IS NOT THIS LAUNCH'S TO TAKE: two processes on one transcript is how turns
    // get orphaned, and Claude Code will not refuse it for you.
    check("a live conversation is skipped and the next one taken",
          conversationStart(recorded: nil, among: [older, newer], live: ["newer"])
              == .resume("older"))
    check("a live RECORD is not resumed either",
          conversationStart(recorded: "newer", among: [older, newer], live: ["newer"])
              == ConversationStart.none)

    // ORDERING IS BY THE STAMP INSIDE THE FILE, and it is read with fractional seconds: two events
    // in one second are ordinary, and dropping the subseconds silently ties them.
    let early = candidate("early", "2026-08-25T10:00:00.100Z")
    let late = candidate("late", "2026-08-25T10:00:00.500Z")
    check("subsecond stamps decide the order",
          conversationStart(recorded: nil, among: [early, late], live: []) == .resume("late"))
    // A candidate nothing can be dated cannot be ranked at all.
    check("a conversation with no timestamp is never ranked",
          conversationStart(recorded: nil, among: [older, candidate("undated", nil)], live: [])
              == .resume("older"))
    check("…and a directory of only those starts fresh",
          conversationStart(recorded: nil, among: [candidate("undated", nil)], live: [])
              == ConversationStart.none)
    // A tie is broken by id rather than by whatever order the directory listed in.
    check("a tie is broken the same way every time",
          conversationStart(recorded: nil,
                            among: [candidate("bbb", "2026-08-25T10:00:00.000Z"),
                                    candidate("aaa", "2026-08-25T10:00:00.000Z")], live: [])
              == .resume("bbb"))

    // MARK: - Reading one transcript

    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-conversation-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func file(_ name: String, _ body: String) -> URL {
        let url = root.appendingPathComponent(name)
        write(body, to: url)
        return url
    }

    let hadTurn = conversationCandidate(at: file("turn.jsonl",
                                                 turnTranscript(at: "2026-08-25T10:00:00.250Z")))
    check("a transcript is named by its filename", hadTurn?.id == "turn")
    check("a conversation with a turn is resumable", hadTurn?.resumable == true)
    check("and is read as interactive", hadTurn?.interactive == true)
    check("its stamp is the newest event inside it, subseconds and all",
          hadTurn?.lastEventAt == parseISO("2026-08-25T10:00:00.250Z"))

    let empty = conversationCandidate(at: file("empty.jsonl",
                                               startupOnlyTranscript(at: "2026-08-25T10:00:00Z")))
    check("a session nobody typed into is not resumable", empty?.resumable == false)
    check("…but it is still dated, so it is still ranked against the others",
          empty?.lastEventAt == parseISO("2026-08-25T10:00:00Z"))

    // Claude Code's own cleared-to-empty marker: a `last-prompt` naming no leaf and saying so
    // explicitly. Such a conversation resumes as an empty one instead of failing, so it counts.
    let clearedBody = startupOnlyTranscript(at: "2026-08-25T10:00:00Z")
        + "{\"type\":\"last-prompt\",\"leafUuid\":null,\"explicit\":true,\"sessionId\":\"s\"}\n"
    check("the cleared-to-empty marker makes a turnless conversation resumable",
          conversationCandidate(at: file("clearedmark.jsonl", clearedBody))?.resumable == true)
    // …and a later record naming a leaf takes that state back off.
    check("a later last-prompt naming a leaf clears the marker",
          conversationCandidate(at: file("remarked.jsonl", clearedBody
              + "{\"type\":\"last-prompt\",\"leafUuid\":\"7f4c0b1e-0000-0000-0000-000000000002\"}\n"))?
              .resumable == false)

    // A QUOTED EVENT IS NOT AN EVENT. These transcripts are full of tool results carrying other
    // transcripts; the substring is a prefilter and the decision is a top-level parse.
    let quoting = startupOnlyTranscript(at: "2026-08-25T10:00:00Z")
        + "{\"type\":\"system\",\"isSidechain\":false,\"timestamp\":\"2026-08-25T10:00:01Z\","
        + "\"content\":\"a line reading \\\"type\\\":\\\"assistant\\\" inside it\"}\n"
    check("a quoted event type does not make a turnless conversation resumable",
          conversationCandidate(at: file("quoting.jsonl", quoting))?.resumable == false)
    // A sidechain turn is a subagent's, not this conversation's.
    let sidechain = startupOnlyTranscript(at: "2026-08-25T10:00:00Z")
        + "{\"type\":\"assistant\",\"isSidechain\":true,\"timestamp\":\"2026-08-25T10:00:01Z\"}\n"
    check("a sidechain turn does not count as one",
          conversationCandidate(at: file("sidechain.jsonl", sidechain))?.resumable == false)

    check("an SDK session is not interactive",
          conversationCandidate(at: file("sdk.jsonl",
                                         turnTranscript(at: "2026-08-25T10:00:00Z",
                                                        entrypoint: "sdk-cli")))?.interactive == false)
    check("a background agent is not interactive",
          conversationCandidate(at: file("bg.jsonl",
                                         turnTranscript(at: "2026-08-25T10:00:00Z",
                                                        kind: "bg")))?.interactive == false)
    // Both fields land on one record in every background transcript on this machine, and nothing
    // says they must: the refusal reads the whole block rather than stopping at the first record
    // that declares an entrypoint.
    let splitFields = "{\"type\":\"attachment\",\"entrypoint\":\"cli\",\"isSidechain\":false,"
        + "\"timestamp\":\"2026-08-25T10:00:00Z\"}\n"
        + "{\"type\":\"system\",\"sessionKind\":\"bg\",\"isSidechain\":false,"
        + "\"timestamp\":\"2026-08-25T10:00:01Z\"}\n"
        + "{\"type\":\"user\",\"isSidechain\":false,\"timestamp\":\"2026-08-25T10:00:02Z\"}\n"
    check("a sessionKind on a later record than the entrypoint still refuses",
          conversationCandidate(at: file("splitfields.jsonl", splitFields))?.interactive == false)
    // An ABSENT field is not a refusal: transcripts written before these fields existed would
    // otherwise all read as machine traffic, which is the very history this fix exists to bring back.
    check("a transcript declaring neither field is taken as interactive",
          conversationCandidate(at: file("old.jsonl",
              "{\"type\":\"user\",\"isSidechain\":false,\"timestamp\":\"2026-08-25T10:00:00Z\"}\n"))?
              .interactive == true)

    check("a file that is not a transcript is not a candidate",
          conversationCandidate(at: file("notes.txt", "hello")) == nil)
    // A file claude has moved aside keeps the extension and gains a segment; its stem names nothing
    // anything can be resumed by.
    check("a moved-aside transcript is not a candidate",
          conversationCandidate(at: file("abc.orphaned-1-2.jsonl",
                                         turnTranscript(at: "2026-08-25T10:00:00Z"))) == nil)

    // The directory read, and the two files above it that must not appear in it.
    let listed = Set(conversationCandidates(in: root).map(\.id))
    check("the directory read finds every transcript in it", listed.contains("turn")
        && listed.contains("empty") && listed.contains("sdk"))
    check("…and nothing that is not one",
          !listed.contains("notes") && !listed.contains("abc.orphaned-1-2"))
    check("an unreadable directory reads as an empty one",
          conversationCandidates(in: root.appendingPathComponent("absent")).isEmpty)

    // MARK: - The record file
    //
    // A state file is only as trustworthy as the last thing that wrote it, so the id is validated
    // both ways; an unusable one reads as NO record, which falls back to reading the directory.
    let records = root.appendingPathComponent("records")
    let here = root.appendingPathComponent("cwd").path
    writeLastConversation("kept-one", cwd: here, dir: records)
    check("a record round-trips", readLastConversation(cwd: here, dir: records) == "kept-one")
    write("../../etc/passwd", to: lastConversationFile(cwd: here, dir: records))
    check("a record that is not an id reads as no record",
          readLastConversation(cwd: here, dir: records) == nil)
    writeLastConversation("../../etc/passwd", cwd: here, dir: records)
    check("…and one like that is never written in the first place",
          readLastConversation(cwd: here, dir: records) == nil)

    // The writer replaces the file only when the conversation has actually changed: it is fed from a
    // 2-second poll, and a write per tick for the life of a session is what the guard exists to
    // avoid. Asserted by taking the file away and seeing whether an unchanged sync puts it back.
    var writer = LastConversationWriter()
    writer.sync("first-one", cwd: here, dir: records)
    check("the writer publishes a change", readLastConversation(cwd: here, dir: records) == "first-one")
    try? FileManager.default.removeItem(at: lastConversationFile(cwd: here, dir: records))
    writer.sync("first-one", cwd: here, dir: records)
    check("…and writes nothing when the conversation has not changed",
          readLastConversation(cwd: here, dir: records) == nil)
    writer.sync(nil, cwd: here, dir: records)
    check("…nor when there is nothing to say yet",
          readLastConversation(cwd: here, dir: records) == nil)
    writer.sync("second-one", cwd: here, dir: records)
    check("…and publishes the next change",
          readLastConversation(cwd: here, dir: records) == "second-one")

    // MARK: - Where the transcripts are
    //
    // NOT a hardcoded `~/.claude/projects`: Anthropic's documented macOS default is
    // `~/Library/Caches/claude`, with `~/.claude` used only where it already exists.
    let home = root.appendingPathComponent("home")
    let caches = root.appendingPathComponent("caches")
    try? FileManager.default.createDirectory(at: caches.appendingPathComponent("projects"),
                                             withIntermediateDirectories: true)
    check("a home with its own projects directory answers first",
          { try? FileManager.default.createDirectory(at: home.appendingPathComponent("projects"),
                                                     withIntermediateDirectories: true)
            return claudeProjectsDir(home: home.path, caches: caches)
                == home.appendingPathComponent("projects") }())
    let bare = root.appendingPathComponent("bare-home")
    check("a home without one falls back to the platform default",
          claudeProjectsDir(home: bare.path, caches: caches)
              == caches.appendingPathComponent("projects"))
    check("and with neither in place it still names the home's own",
          claudeProjectsDir(home: bare.path, caches: root.appendingPathComponent("nowhere"))
              == bare.appendingPathComponent("projects"))

    try? FileManager.default.removeItem(at: root)
}
