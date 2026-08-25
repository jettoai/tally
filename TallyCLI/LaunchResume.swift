import Foundation

// WHICH CONVERSATION A LAUNCH PICKS UP, decided here rather than left to a flag whose meaning
// changes with the account.
//
// THE DEFECT THIS REPLACES. `tally claude` picks the account with the most headroom and then, under
// the "continue by default" start mode, injected a bare `--continue`. That flag is documented as
// "the most recent conversation in the current directory", but it is not resolved against the
// directory on disk: it is resolved against the config home the launch runs under, out of that
// home's own record of the last conversation it ran here. The transcripts are SHARED across this
// machine's config homes (`~/.claudeN/projects` are symlinks into one directory) and that record is
// NOT, so the two disagree about which conversation is newest: Tally asked the shared directory,
// claude answered from a private pointer. Every launch therefore came back to whatever the account
// it happened to land on last ran here, and because the account picker prefers the account used
// LEAST recently, the conversation walked steadily BACKWARDS - the account with the most headroom
// is the one that has been away longest, and the one that has been away longest has the oldest
// pointer. Measured across this machine's history (2026-08-25, 60 (home, project) pairs): 6
// launches resumed a conversation older than the newest one in the directory they ran in, by up to
// 1,624 hours, two of them on consecutive launches in one project.
//
// Tally already KNEW the flag was per-account - `relaunchArgs` (LaunchFlags.swift) drops it when a
// relaunch crosses accounts, for exactly this reason - but the fresh-launch path had no previous
// account to compare against, so the rule was written on one side only.
//
// THE FIX IS A FACT CHANNEL, the same shape as the one that ended the fork-join family: stop asking
// a question whose answer depends on who is asked. `--resume <id>` names one file whatever account
// runs it, which is not a hope - the cap handoff resumes by id across accounts on every cap hit,
// and it is the workaround Anthropic's own issue thread carries for this ("works and is stable
// across restarts", #87902, filed against `--continue`'s directory semantics).
//
// TWO CHANNELS, IN THIS ORDER, and the order is the whole design:
//
//   1. WHAT THIS MACHINE WATCHED HERE LAST (LastConversation.swift). Every supervised session's
//      status line reports the conversation it is drawing for, from the process writing it
//      (TranscriptIdentity.swift); the supervisor already publishes that id and now also lands it
//      per directory. It follows a `/clear` and a fork within a render, it names the conversation
//      the person was actually in rather than the file that happens to sort newest, and it cannot
//      see a `claude -p` run or a background agent at all, because neither is supervised.
//   2. READING THE DIRECTORY, when there is no such record: a machine that has not run this build
//      here yet, a session nobody supervised, a record swept away. This is a RANKING and not a
//      fact, so it is filtered hard (below) and it never overrules channel 1.
//
// WHAT "NEWEST" MEANS IN CHANNEL 2, and why it is not the mtime. A transcript's mtime moves for
// reasons that have nothing to do with the conversation (a copy into another account's tree, a
// backup, a tool that rewrites the file), and this repo has been bitten once already by reading a
// container's stamp as evidence about its contents. The stamp used here is the newest event
// timestamp INSIDE the file, parsed with fractional seconds - two events in one second are
// ordinary, and dropping the subseconds silently ties them.
//
// WHAT CANNOT BE RESUMED, read out of the CLI itself (2.1.243; the bundled source is legible in the
// binary, and this repo never RUNS `claude` to find out what it does, because the stop hook would
// hijack the session and spend quota). `--resume <id>` goes through `loadConversationForResume` and
// its three lookups all end in `getLastSessionLog`, which returns "no conversation" unless the
// transcript's leaf chain reaches a non-sidechain `user` or `assistant` record, or the file carries
// the cleared-to-empty marker (a `last-prompt` record with a null `leafUuid` and `explicit: true`).
// Of the 956 transcripts on this machine 18 are in neither state - 15 holding only startup records,
// 3 only title metadata - and every one of them would fail a launch outright. A parallel reading of
// the same binary reported by-id resume as unfiltered; the two disagree, so the gate below is the
// conservative one, and what it costs when the other reading is right is a fresh session instead of
// an empty resumed one - the same empty context either way.
//
// THE LINE FORMAT IS NOT A CONTRACT. Anthropic document the transcript as version-dependent and say
// outright that parsing it will break; the session index beside it is undocumented and known to
// miss sessions (#23726, #66499) so nothing here reads it. Channel 2 therefore asks the smallest
// questions that survive a format change - the filename's id, a line-level `timestamp`, whether any
// `user`/`assistant` record exists - and channel 1 exists so that the common path does not ask them
// at all.

/// How many bytes of each end of a transcript one launch reads.
///
/// Both ends are needed and neither needs more: whether a conversation has a turn in it is answered
/// by its HEAD (measured over this machine's 956 transcripts: the first `user`/`assistant` record
/// sits 4.7 KB in at the median, 21 KB at the 95th percentile, 26 KB at the worst), and when it last
/// did anything is answered by its TAIL (the last timestamp sits within 2 KB of the end in every
/// file that has one). 64 KB covers both with room to spare and costs 3 to 6 ms over the largest
/// project directories here (305, 111 and 90 transcripts, measured 2026-08-25) - a launch pays it
/// once, unlike the supervisor's scans, which run every two seconds.
let conversationScanBytes = 1 << 16

/// What one transcript in a project directory offers a launch.
struct ConversationCandidate: Equatable {
    /// Claude Code's own id for the conversation, which is the transcript's basename.
    let id: String
    /// The newest event timestamp INSIDE the file, or nil when it holds none (a session created and
    /// abandoned before it wrote anything datable). Never the file's mtime.
    let lastEventAt: Date?
    /// Whether `claude --resume <id>` can resolve it (see the header for the rule and where it was
    /// read from).
    let resumable: Bool
    /// Whether this is an interactive CLI conversation at all, rather than a background agent, a
    /// one-shot `claude -p` run or an SDK session. Claude Code's own `--continue` skips those, and
    /// so must anything standing in for it.
    let interactive: Bool
}

/// What a launch does about the start mode.
enum ConversationStart: Equatable {
    /// Pick this conversation up by id.
    case resume(String)
    /// This directory holds nothing this launch may take: no transcript at all, none that is an
    /// interactive conversation with a turn in it, or every candidate is already being written by a
    /// live session.
    case none
    /// The conversation this machine last watched here has no turn in it yet - a `/clear` nobody
    /// typed into, a window opened and left. It cannot be resumed by id, and the one behind it is a
    /// step BACKWARDS, which is the whole defect this file exists to end, so the launch starts
    /// fresh. That lands in the same empty context a resumed clear would (owner ruling, 2026-08-25:
    /// a cleared session must never fall back onto what came before it).
    case unstarted
}

/// The conversation a launch continues.
///
/// Pure, and the whole decision: the caller reads the record, the directory and the live set; this
/// ranks them. `recorded` is channel 1 (LastConversation.swift) and outranks everything, which is
/// what makes a `/clear` land where the person left it rather than where the files sort.
///
/// A RECORD THAT CANNOT BE RESUMED ENDS THE SEARCH rather than falling through to the directory.
/// Falling through is precisely the step backwards this exists to prevent: the machine knows which
/// conversation was open here, and "that one has no turn in it" is an answer, not a miss. A record
/// naming a conversation that is GONE (its file deleted, or nothing in the directory matches it) is
/// a miss, and that one does fall through.
///
/// `live` is refused rather than ranked, because resuming a conversation another process is writing
/// puts two writers on one transcript - Claude Code does not stop you (#88393), and the failure that
/// orphaned about three hours of turns here on 2026-07-29 arrived from the other side of it.
///
/// A candidate with no timestamp cannot be ordered against the others, so it is not ranked at all.
/// That is not a special case for a rare shape: a transcript with nothing datable in it has no
/// `user` or `assistant` record either (checked across all 956 transcripts here - the two questions
/// answer together, 938 yes and 18 no, with no file answering them differently), so every file this
/// drops is one `--resume` could not have resolved anyway.
///
/// The id breaks a tie, so two conversations stamped in the same instant give a stable answer rather
/// than one that depends on the order the directory happened to be listed in.
func conversationStart(recorded: String?, among candidates: [ConversationCandidate],
                       live: Set<String>) -> ConversationStart {
    if let recorded, let match = candidates.first(where: { $0.id == recorded }) {
        if live.contains(match.id) { return .none }
        return match.resumable ? .resume(match.id) : .unstarted
    }
    let newest = candidates
        .filter { $0.interactive && $0.resumable && !live.contains($0.id) }
        .compactMap { candidate in candidate.lastEventAt.map { (candidate, $0) } }
        .max { ($0.1, $0.0.id) < ($1.1, $1.0.id) }
    guard let newest = newest?.0 else { return .none }
    return .resume(newest.id)
}

// MARK: - The launch's own entry point

/// Applies the app's "continue by default" start mode to a launch, given the home it will run
/// under. Returns the args to launch with, plus the one line to print when nothing was resumed
/// (nil = nothing to say).
///
/// WHAT IS INJECTED IS `--resume <id>`, NEVER A BARE `--continue`, for the reason this whole file
/// exists: that flag reads a pointer private to the config home the launch lands on, the transcripts
/// are shared across those homes, and picking accounts by headroom therefore walked the conversation
/// backwards one launch at a time.
///
/// A hand-typed flag is left exactly as typed: the worktree path strips one, but that is a launch
/// into a directory the user just asked to create, whereas here someone who typed `--continue`
/// deserves the CLI's own behaviour rather than a silently rewritten flag.
///
/// `live` is passed in rather than read here, and it is the one input this cannot fetch for itself:
/// finding it means reading the supervisors' state directory, which belongs to the caller's world
/// and not to a decision about args. The rest is read here, because "which conversation" is exactly
/// what this function is for.
func applyStartMode(_ args: [String], policy: LaunchPolicy, wantsNew: Bool, home: String,
                    live: Set<String>,
                    cwd: String = FileManager.default.currentDirectoryPath,
                    recordDir: URL = lastConversationDir)
    -> (args: [String], note: String?) {
    guard policy.startMode == "continue", !wantsNew,
          !optionsOnly(args).contains(where: { sessionFlags.contains($0) })
    else { return (args, nil) }
    let dir = claudeProjectsDir(home: home)
        .appendingPathComponent(projectSlug(forCwd: cwd))
    switch conversationStart(recorded: readLastConversation(cwd: cwd, dir: recordDir),
                             among: conversationCandidates(in: dir), live: live) {
    case .resume(let id):
        return (injectingOptions(args, ["--resume", id]), nil)
    case .none:
        return (args, "no conversation to pick up in this directory - starting fresh")
    case .unstarted:
        return (args, "the last conversation here was cleared and never used - starting fresh")
    }
}

// MARK: - Reading the directory

/// Where a config home keeps its transcripts.
///
/// NOT a hardcoded `~/.claude/projects`, which is what every reader here used to assume. Anthropic's
/// documented default on macOS is `~/Library/Caches/claude`, with `~/.claude` used only where it
/// already exists, so a machine that met Claude Code after that change keeps its transcripts
/// somewhere this repo had never looked. Tally's own accounts always run under an explicit
/// `CLAUDE_CONFIG_DIR` and so answer on the first line; the fallbacks are for the launches that set
/// none (the bare-CLI paths in main.swift) on a machine laid out the new way.
func claudeProjectsDir(home: String,
                       caches: URL = FileManager.default.homeDirectoryForCurrentUser
                           .appendingPathComponent("Library/Caches/claude")) -> URL {
    let own = URL(fileURLWithPath: home).appendingPathComponent("projects")
    if FileManager.default.fileExists(atPath: own.path) { return own }
    let shipped = caches.appendingPathComponent("projects")
    return FileManager.default.fileExists(atPath: shipped.path) ? shipped : own
}

/// Every transcript in `projectDir`, as candidates. An unreadable directory is an empty one, which
/// the caller starts fresh on - the same thing it does for a directory that is genuinely empty.
func conversationCandidates(in projectDir: URL,
                            scan: Int = conversationScanBytes) -> [ConversationCandidate] {
    let files = (try? FileManager.default.contentsOfDirectory(
        at: projectDir, includingPropertiesForKeys: nil)) ?? []
    return files.compactMap { conversationCandidate(at: $0, scan: scan) }
}

/// One transcript read, or nil when the file is not one.
///
/// The name is checked as well as the extension: a file claude has moved aside keeps the `.jsonl`
/// suffix and gains a middle segment (`<id>.orphaned-<stamp>-<rand>.jsonl`), and the stem of that is
/// not an id anything can be resumed by.
func conversationCandidate(at url: URL, scan: Int = conversationScanBytes) -> ConversationCandidate? {
    guard url.pathExtension == "jsonl" else { return nil }
    let id = url.deletingPathExtension().lastPathComponent
    guard isTranscriptSessionID(id) else { return nil }
    let head = transcriptHead(of: url, bytes: scan) ?? ""
    // A file shorter than the window gives the same text twice, which is right: both questions are
    // then being asked of the whole of it. Each end is split into lines ONCE and the readings share
    // it - three questions of one block is three passes only if you let it be.
    let tail = transcriptTail(of: url, bytes: scan) ?? head
    let headLines = head.split(separator: "\n")
    let tailLines = tail.split(separator: "\n")
    return ConversationCandidate(id: id, lastEventAt: newestEventTime(tailLines),
                                 resumable: carriesTurn(headLines) || clearedToEmpty(tailLines),
                                 interactive: isInteractiveConversation(headLines))
}

/// The newest event timestamp in a block of transcript lines.
///
/// The MAXIMUM rather than the last line's, because a transcript's stamps do not run in order (the
/// rule `TurnRoot.seq` exists for), and the question here is when this conversation was last touched
/// rather than what its final record says.
func newestEventTime(_ lines: [Substring]) -> Date? {
    lines.compactMap(lineTimestamp).max()
}

/// Whether these lines hold a turn: a non-sidechain `user` or `assistant` record, which is what a
/// resume needs the leaf chain to reach.
///
/// The substring is a prefilter only and the decision is made on a top-level parse, the rule the
/// fork scan already follows (TranscriptFork.swift): these transcripts are full of tool results and
/// attachments quoting other transcripts, and a quoted event type is not an event.
func carriesTurn(_ lines: [Substring]) -> Bool {
    for line in lines {
        guard line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\""),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                  as? [String: Any],
              (object["isSidechain"] as? Bool) != true else { continue }
        let type = object["type"] as? String
        if type == "user" || type == "assistant" { return true }
    }
    return false
}

/// Whether these lines end in claude's own cleared-to-empty state: a `last-prompt` record naming no
/// leaf and saying so explicitly. Such a conversation resumes as an empty one rather than failing.
///
/// The LAST such record decides, because a later one naming a leaf takes the state back off (read
/// out of the CLI's transcript parser, 2.1.243). Nothing on this machine carries the marker yet - 0
/// of 956 transcripts - so what this buys is a cleared conversation becoming resumable the day the
/// CLI starts writing it, at the cost of one pass over a block already in memory.
func clearedToEmpty(_ lines: [Substring]) -> Bool {
    var cleared = false
    for line in lines {
        guard line.contains("\"type\":\"last-prompt\""),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                  as? [String: Any],
              object["type"] as? String == "last-prompt" else { continue }
        cleared = object["leafUuid"] is NSNull && object["explicit"] as? Bool == true
    }
    return cleared
}

/// Whether these lines belong to an interactive CLI conversation, which is the only kind a
/// `--continue` stands in for.
///
/// TWO REFUSALS, both read off records this machine actually writes (2026-08-25, 956 transcripts):
///
///   - `sessionKind`, which a background agent's records carry (`"bg"`, 12 files, and they land in
///     ordinary project directories: 2 in this repo's own, 7 in another). Claude Code's own continue
///     filter refuses any session that has one, whatever it says, and so does this.
///   - an `entrypoint` that is not the CLI. 506 of those 956 are `sdk-cli` - `claude -p` runs, the
///     probe traffic Tally itself makes, agent SDK sessions - and while most sit in directories
///     nobody launches from, several do not (4 in one project directory here, 3 in another). Two are
///     `claude-desktop`, which is somebody else's window.
///
/// An ABSENT field is not a refusal, the rule every other second-hand reading here follows: older
/// transcripts predate these fields, and reading their silence as "not interactive" would start
/// fresh on the very conversations this fix exists to bring back.
///
/// The `sessionKind` refusal reads the WHOLE block rather than stopping at the first record that
/// declares anything. On this machine the two fields always arrive together on one record (checked
/// across the 12 background transcripts here), so an early return would agree today - and would
/// silently stop agreeing the day claude writes them apart, which is the kind of assumption this
/// repo has been caught on before. The entrypoint is taken from the first record that names one.
func isInteractiveConversation(_ lines: [Substring]) -> Bool {
    var entrypoint: String?
    for line in lines {
        guard line.contains("\"sessionKind\"") || line.contains("\"entrypoint\""),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                  as? [String: Any] else { continue }
        if object["sessionKind"] != nil { return false }
        if entrypoint == nil { entrypoint = object["entrypoint"] as? String }
    }
    return entrypoint == nil || entrypoint == "cli"
}

/// The head of `url` as complete lines, or nil when it cannot be read.
///
/// The mirror of `transcriptTail` (OpenTurn.swift), and split from it for the reason the two windows
/// differ: a read that starts at the beginning starts on a line boundary, so nothing is dropped in
/// front, and only a read that stopped SHORT of the end has a partial line to drop behind. A file
/// smaller than the window is returned whole, trailing newline or not.
func transcriptHead(of url: URL, bytes: Int = conversationScanBytes) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let raw = try? handle.read(upToCount: bytes), !raw.isEmpty else { return nil }
    if raw.count < bytes { return String(data: raw, encoding: .utf8) }
    guard let last = raw.lastIndex(of: 0x0A) else { return nil }   // one line fills it all
    return String(data: Data(raw[..<last]), encoding: .utf8)
}
