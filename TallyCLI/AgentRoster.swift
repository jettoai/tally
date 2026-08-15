import Foundation

// HOW MANY SUBAGENTS A SESSION HAS WORKING, published for the surfaces outside its terminal.
//
// One file per supervisor pid in `supervisorStateDir`, on the same terms as the state reading and
// the pending notice beside it: read only while that pid is alive, swept when it is not, best-effort
// and atomic, additive-only in its fields. It is the one reading on the session card that no amount
// of looking at the machine can produce - a subagent is a conversation inside a process, not a
// process, so nothing in the process table separates a Claude Code answering one turn from a Claude
// Code fanning out to six.
//
// SO CLAUDE CODE IS ASKED, THROUGH ITS PUBLIC HOOKS. `SubagentStart` and `SubagentStop` are the
// edges, and the `background_tasks` list a turn boundary carries is the roll call. Both are
// documented surfaces with a version behind them, which is the whole reason they are used: the
// transcript JSONL under `~/.claude/projects` holds the same facts and is an internal format with
// no promise attached, so counting out of it is a feature that breaks on somebody else's release.
//
// COMPILED INTO BOTH TARGETS (see project.yml) for the reason SessionState.swift is: the hook
// writes this document and the panel reads it, they are separate processes speaking through a file,
// and a drifted field name is a count that is always zero while every session reports correctly.
// The DECIDING is all here, because it is pure arithmetic on a set; the hook next door
// (HookAgents.swift) does nothing but parse an event and hand it over.

/// The suffix separating an agent roster from the presence/drift file of the same pid.
let sessionAgentsSuffix = ".agents"

/// What a session's Claude Code has told us about its subagents.
///
/// EVERY FIELD OPTIONAL-BY-DEFAULT ON THE ADDITIVE RULE this whole track is under: a record written
/// by an older build decodes with the default rather than being rejected, and rejecting is losing
/// the whole reading.
struct SessionAgentsRecord: Codable, Equatable, Sendable {
    /// The subagents believed to be working, by the ids Claude Code gives them. Sorted, so two
    /// records describing the same set compare equal and a tick that changed nothing writes nothing.
    var live: [String] = []
    /// Whether this session's Claude Code is one whose count can be BELIEVED, which is a different
    /// question from whether it fires the hooks at all (`agentCensusClaudeVersion` says why).
    var trusted = false
    var updatedAt: Date

    /// What a card may draw: the number working, or nothing at all when the count cannot be
    /// believed. FAIL-CLOSED, and that is the whole design of the field above: an edge-counted
    /// roster with no roll call behind it drifts the first time a subagent dies without a stop
    /// event, and a card saying "3 agents" about a session with none is worse than a card saying
    /// nothing - it is the reading somebody would act on.
    var reportable: Int? { trusted ? live.count : nil }
}

// MARK: - What one hook event says

/// One `SubagentStart`, `SubagentStop` or `Stop`, reduced to what the roster is decided from.
struct AgentRosterEvent: Equatable {
    enum Kind: String, Equatable, CaseIterable {
        /// A subagent has begun working.
        case started = "SubagentStart"
        /// One has finished.
        case stopped = "SubagentStop"
        /// The turn itself has ended, which carries no edge and is here for the roll call alone.
        case boundary = "Stop"
    }

    /// The three events, in the order a registration writes them. Derived from the cases rather
    /// than typed a second time: the app builds one settings.json entry per name
    /// (IntegrationsAgentHook.swift) and the CLI answers to the same names on its command line, so
    /// a second hand-written list is how one end comes to register an event the other ignores.
    static let events = Kind.allCases.map(\.rawValue)

    var kind: Kind
    /// The subagent this event is ABOUT, when it is about one.
    var agentID: String?
    /// Whether the payload carried a `background_tasks` list at all, readable or not. THE
    /// CAPABILITY, as opposed to its contents: the key's presence is what proves this Claude Code
    /// publishes the roll call, which is exactly what the version bar below stands in for.
    var carriedCensus = false
    /// The subagents it named, and only when every entry could be named: a list that dropped the
    /// one entry whose id this build did not recognise would be a roll call that quietly reads as
    /// "that one has finished" (`agentRosterEvent`).
    var census: [String]?
}

/// The keys a background task might carry its own id under, in the order they are tried. Claude
/// Code spells the subagent's id `agent_id` in the `SubagentStart` payload; the others are the
/// plausible spellings for an entry in a list that names tasks rather than agents, and reading a
/// list of one shape while the far end writes another is what this list exists to survive.
let agentTaskIDKeys = ["agent_id", "agentId", "id", "task_id", "taskId"]

/// The `background_tasks` entry type that is a subagent. Anything else in that list (a shell
/// command left running, a fetch) is a background task of a different kind and is not what the card
/// counts: it says "agents", and a session's agents are the conversations working under it.
let subagentTaskType = "subagent"

/// What one hook payload says, or nil when it is not an event this reads.
///
/// - Parameter registered: the event name this hook was registered under, used when the payload
///   does not name itself. Claude Code sends `hook_event_name`, and this is the belt behind it: the
///   command line we registered says which of the three fired, and it cannot be wrong the way a
///   field that moved can.
func agentRosterEvent(_ payload: [String: Any]?, registered: String?) -> AgentRosterEvent? {
    let spelled = (payload?["hook_event_name"] as? String).flatMap(AgentRosterEvent.Kind.init)
    guard let kind = spelled ?? registered.flatMap(AgentRosterEvent.Kind.init) else { return nil }
    var event = AgentRosterEvent(kind: kind, agentID: identifier(in: payload))
    guard let tasks = payload?["background_tasks"] as? [[String: Any]] else { return event }
    event.carriedCensus = true
    let subagents = tasks.filter { ($0["type"] as? String) == subagentTaskType }
    let names = subagents.compactMap(identifier(in:))
    // All or nothing, deliberately: a partial roll call is indistinguishable from a complete one
    // that is missing somebody, and acting on it would retire an agent that is still working.
    if names.count == subagents.count { event.census = names }
    return event
}

/// The id a payload or a task entry carries, under whichever of the spellings it uses. An empty
/// string is not an id: a field written blank says nothing, and treating it as a name would let two
/// nameless agents count as one.
private func identifier(in object: [String: Any]?) -> String? {
    guard let object else { return nil }
    return agentTaskIDKeys.lazy.compactMap { object[$0] as? String }.first { !$0.isEmpty }
}

// MARK: - The rules

/// This session's roster after one event.
///
/// THE ROLL CALL IS APPLIED FIRST AND THE EDGE SECOND, which is the only order that is right in both
/// directions. `background_tasks` describes the session as of the event, and the event itself is the
/// change: a `SubagentStop` whose roll call was taken before the agent was struck off would put it
/// straight back, and a `SubagentStart` whose roll call already holds it is an insert that changes
/// nothing. Read the other way round, half of every stop would be undone.
///
/// AN ID MAY COME BACK, and nothing here assumes otherwise. A subagent resumed by a message goes
/// live, idle and live again under the ONE id, so the roster is a set that is inserted into and
/// removed from rather than a high-water mark or a counter - a `+1/-1` tally cannot survive a second
/// start for a name it has already seen, and the second reading of that is a session permanently
/// one agent over.
///
/// CRASHES ARE NOT ANSWERED HERE, because they cannot be: an agent that dies takes its stop event
/// with it, so the edges alone drift upward for as long as the session lives. Two things bound that
/// and both are outside this function - the roll call at every turn boundary, which is what makes
/// the count trustworthy at all, and the supervisor's own death, which takes the file with it.
///
/// - Parameter declared: whether this session's Claude Code is one whose roll call can be expected,
///   read off its version rather than off a payload (`claudeCodeReportsAgents`). Either that or a
///   payload that actually carried one is enough, and both are sticky: a build does not stop
///   publishing the roster halfway through a session.
func advanceAgentRoster(_ record: SessionAgentsRecord?, event: AgentRosterEvent,
                        declared: Bool, now: Date = Date()) -> SessionAgentsRecord {
    var live = Set(record?.live ?? [])
    if let census = event.census { live = Set(census) }
    if let id = event.agentID {
        switch event.kind {
        case .started: live.insert(id)
        case .stopped: live.remove(id)
        case .boundary: break
        }
    }
    return SessionAgentsRecord(live: live.sorted(),
                               trusted: (record?.trusted ?? false) || event.carriedCensus || declared,
                               updatedAt: now)
}

// MARK: - Which Claude Code can be believed

/// The first Claude Code that puts `background_tasks` on a hook payload, and so the first whose
/// subagent count is worth drawing. Below it the two edge events exist (from 2.0.43) and nothing
/// corrects them, so the count is right until the first agent that ends without saying so and wrong
/// from then until the session exits.
let agentCensusClaudeVersion = [2, 1, 145]

/// Which Claude Code is behind a hook, read off the path of the program that spawned it.
///
/// `CLAUDE_CODE_EXECPATH` IS THE READING, and the version is the file name itself: the native
/// installer puts each build at `~/.local/share/claude/versions/<version>` and exports that path to
/// everything it spawns (measured on this machine, 2026-08-15 - a hook's own environment carries it
/// while `CLAUDE_CODE_VERSION` is not exported at all). Read from the runtime rather than asked of
/// the binary, which would be a fork and an exec of a 300MB program on an event that fires several
/// times a turn.
///
/// nil for an install that is not laid out that way - a package manager's `bin/claude`, a build run
/// from a checkout - and nil is FAIL-CLOSED here: it is the declared half of a bar that the observed
/// half can still clear on its own (`advanceAgentRoster`), so a version this cannot read costs one
/// turn boundary of hiding rather than the feature.
func claudeCodeVersion(executablePath: String?) -> [Int]? {
    guard let executablePath else { return nil }
    let name = (executablePath as NSString).lastPathComponent
    let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    let numbers = parts.compactMap { Int($0) }
    guard !parts.isEmpty, numbers.count == parts.count else { return nil }
    return numbers
}

/// Whether that build publishes the roll call. Compared segment by segment, with a missing segment
/// read as zero, so `2.2` is above `2.1.145` and `2.1` is below it.
func claudeCodeReportsAgents(executablePath: String?) -> Bool {
    guard let version = claudeCodeVersion(executablePath: executablePath) else { return false }
    for index in 0 ..< max(version.count, agentCensusClaudeVersion.count) {
        let mine = index < version.count ? version[index] : 0
        let bar = index < agentCensusClaudeVersion.count ? agentCensusClaudeVersion[index] : 0
        if mine != bar { return mine > bar }
    }
    return true
}

// MARK: - The file

/// The file a supervisor's agent roster lives in.
func sessionAgentsFile(pid: String, dir: URL = supervisorStateDir) -> URL {
    dir.appendingPathComponent(pid + sessionAgentsSuffix)
}

/// Write the roster. Best-effort and atomic, like every other file on this track.
@discardableResult
func writeSessionAgents(_ record: SessionAgentsRecord, pid: String,
                        dir: URL = supervisorStateDir) -> Bool {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(record) else { return false }
    do { try data.write(to: sessionAgentsFile(pid: pid, dir: dir), options: .atomic) } catch {
        return false
    }
    return true
}

/// Read a supervisor's agent roster, or nil when there is none (or the file is from a format this
/// build does not know, which reads the same way: nothing to say).
func readSessionAgents(pid: String, dir: URL = supervisorStateDir) -> SessionAgentsRecord? {
    guard let data = try? Data(contentsOf: sessionAgentsFile(pid: pid, dir: dir)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(SessionAgentsRecord.self, from: data)
}
