import Foundation

// Where the two dispatch paths actually land on disk, and therefore what the idle walk has to see.
//
// The subagent arm of `isQuiet` is the only thing standing between a live work package and a
// non-urgent relaunch that kills it, and it finds that package by walking one directory. So the
// question is not "does the walk work" but "does it cover every shape a dispatch can take". Both
// paths were censused 2026-08-02 across every transcript on this machine (1,589 agent transcripts,
// 273 workflow runs), and the fixtures below use the shapes that census found, verbatim:
//
//   - `subagents/agent-a<hex>.jsonl`               the Agent tool
//   - `subagents/agent-a<name>-<hex>.jsonl`        an agent team member (dispatch carrying a name)
//   - `subagents/workflows/wf_<id>/…`              a Workflow fan-out, one level deeper
//
// Not one agent transcript in that corpus lives outside a `subagents/` directory, and none nests
// deeper than the workflow shape. The sibling `<session>/workflows/` holds the run's state json and
// generated script, is written only when the run ENDS, and is deliberately outside the walk - the
// last check here is what stops that being quietly "fixed" into a per-poll cost that buys nothing.

/// Stamp every directory under `root` old, because building a fixture leaves them all at NOW and
/// the walk enumerates subdirectories as well as files.
///
/// Old, rather than "as new as the freshest thing inside", and the difference is the whole point. A
/// directory's mtime moves when one of its own DIRECT entries is created, renamed or removed, and
/// never when a descendant is appended to. So a workflow that has been streaming into
/// `wf_<id>/agent-a3b2….jsonl` for ten minutes leaves both `subagents/workflows/` and `wf_<id>/`
/// sitting at the time their entries were created, and only the transcript is moving. Model
/// directories as newest-child instead and every nested check passes on a parent's mtime without
/// the walk ever descending, which silently un-tests the nesting that is the entire reason the walk
/// is recursive. Verified by mutation: stamped this way, taking the recursion out of
/// `newestSubagentWrite` turns the workflow checks red, and it does not otherwise.
func ageFixtureDirectories(under root: URL, by seconds: TimeInterval = 3600) {
    for entry in (try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil)) ?? [] {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory)
        if isDirectory.boolValue { ageFixtureDirectories(under: entry, by: seconds) }
    }
    try! FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: root.path)
}

/// The fixture behind section 19 of main.swift, which asks the same question from the other side:
/// given a set of subagent paths and how long ago each was written, is the session quiet? Keys are
/// relative to `<session>/subagents/`, so a nested workflow agent is a key with a slash in it.
func watcherWatchingSubagents(sessionAge: TimeInterval,
                              subagents: [String: TimeInterval]?) -> TranscriptWatcher {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-subagent-idle-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("session.jsonl")
    try! "{}".write(to: file, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-sessionAge)], ofItemAtPath: file.path)
    if let subagents {
        let subDir = dir.appendingPathComponent("session").appendingPathComponent("subagents")
        try! FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        for (name, age) in subagents {
            let url = subDir.appendingPathComponent(name)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try! "{}".write(to: url, atomically: true, encoding: .utf8)
            try! FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        // Without this the nested workflow key passes on its parent directory's mtime and the walk
        // never has to descend, so that check reads as covering workflow fan-out while testing
        // nothing about it. See `ageFixtureDirectories` above.
        ageFixtureDirectories(under: subDir)
    }
    return TranscriptWatcher(projectDir: dir, file: file, since: launch)
}

/// One session's worth of on-disk layout: `<dir>/session.jsonl` plus whatever it dispatched.
struct DispatchLayoutFixture {
    let dir: URL
    let file: URL

    /// `sessionAge` is how long the session's OWN transcript has been silent, which is the state
    /// every check here starts from: the turn is blocked on a dispatch, so the main file says
    /// nothing while the work happens.
    init(_ label: String, sessionAge: TimeInterval = 600) {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-dispatch-\(label)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("session.jsonl")
        try! "{}".write(to: file, atomically: true, encoding: .utf8)
        age(file, by: sessionAge)
    }

    /// A file at `path` relative to the session directory, last written `age` seconds ago. Ages are
    /// real offsets from now because the window they answer to (`subagentIdleSeconds`) is measured
    /// against the wall clock.
    func put(_ path: String, age seconds: TimeInterval) {
        let url = dir.appendingPathComponent("session").appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try! "{}".write(to: url, atomically: true, encoding: .utf8)
        age(url, by: seconds)
    }

    private func age(_ url: URL, by seconds: TimeInterval) {
        try! FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }

    func watcher() -> TranscriptWatcher {
        ageFixtureDirectories(under: dir.appendingPathComponent("session"))
        return TranscriptWatcher(projectDir: dir, file: file, since: launch)
    }
}

func runDispatchLayoutChecks() {
    // The bar the caller asks on. Deliberately far below `subagentIdleSeconds`, so every answer
    // below is the subagent arm speaking and not the session's own silence.
    let bar: TimeInterval = 60
    let working: TimeInterval = 300     // silent, but well inside the subagent window
    let finished: TimeInterval = 700    // silent past it: the package really is done

    // 1. The Agent tool, in the shape this repo's own executor packages take. `spawnDepth` reaches
    //    4 in the corpus without the path ever nesting, so a subagent dispatched BY a subagent is
    //    another flat sibling here rather than a deeper directory.
    let tool = DispatchLayoutFixture("agent-tool")
    tool.put("subagents/agent-a500d9cae3c919612.jsonl", age: working)
    var toolWatcher = tool.watcher()
    check("a live Agent tool subagent keeps the session busy", !toolWatcher.isQuiet(bar))

    // 2. An agent team member. The dispatch carries a name, which lands in the FILENAME
    //    (`taskKind:in_process_teammate`), so a scan keyed on the plain hex shape would miss it.
    let team = DispatchLayoutFixture("agent-team")
    team.put("subagents/agent-aauthz-counterexample-28c4386af22e2114.jsonl", age: working)
    var teamWatcher = team.watcher()
    check("a live agent team member is seen despite its named filename", !teamWatcher.isQuiet(bar))

    // 3. A Workflow fan-out, which nests one level deeper. These are the longest packages of all,
    //    so this is the shape with the most to lose from a relaunch.
    let flow = DispatchLayoutFixture("workflow")
    flow.put("subagents/workflows/wf_5a23f470-39d/agent-a3b273b656da7c735.jsonl", age: working)
    var flowWatcher = flow.watcher()
    check("a live workflow agent nested under wf_<id> keeps the session busy",
          !flowWatcher.isQuiet(bar))

    // 4. The instant after a workflow dispatches: the `.meta.json` sidecar is on disk before its
    //    transcript has anything in it, and it is the only fresh file in the tree. No extension
    //    filter is what makes this count.
    let dispatching = DispatchLayoutFixture("workflow-dispatching")
    dispatching.put("subagents/workflows/wf_5a23f470-39d/agent-a3b273b656da7c735.jsonl",
                    age: finished)
    dispatching.put("subagents/workflows/wf_5a23f470-39d/agent-a4f9eb5ef279eda34.meta.json",
                    age: working)
    var dispatchingWatcher = dispatching.watcher()
    check("a just-dispatched workflow agent counts on its sidecar alone",
          !dispatchingWatcher.isQuiet(bar))

    // 5. Between phases, when the previous phase's agents have gone quiet and the next has not
    //    started: the run's `journal.jsonl` is appended a line per agent started and per result, so
    //    it is the tree's only moving file in that gap.
    let between = DispatchLayoutFixture("workflow-between-phases")
    between.put("subagents/workflows/wf_5a23f470-39d/agent-a3b273b656da7c735.jsonl", age: finished)
    between.put("subagents/workflows/wf_5a23f470-39d/journal.jsonl", age: working)
    var betweenWatcher = between.watcher()
    check("a workflow between phases counts on its journal", !betweenWatcher.isQuiet(bar))

    // 6. The bound is still there for both shapes at once: a session that dispatched down both
    //    paths and whose every package went silent past the window is free again. Without this a
    //    single finished workflow would pin its session busy for the rest of its life.
    let done = DispatchLayoutFixture("both-finished")
    done.put("subagents/agent-a500d9cae3c919612.jsonl", age: finished)
    done.put("subagents/workflows/wf_5a23f470-39d/agent-a3b273b656da7c735.jsonl", age: finished + 200)
    done.put("subagents/workflows/wf_5a23f470-39d/journal.jsonl", age: finished)
    var doneWatcher = done.watcher()
    check("a session whose Agent and Workflow packages both finished is quiet",
          doneWatcher.isQuiet(bar))

    // 7. The deliberate exclusion, and the reason it needs a test of its own: `<session>/workflows/`
    //    is a SIBLING of `subagents/`, and it looks like it belongs in the walk. It does not. Its
    //    `wf_<id>.json` is written once, when the run ends (mtime minus run end is 0.0s across all
    //    273 runs), so during the run it is stale, and by the time it moves the `Workflow` tool call
    //    has returned and the session's own mtime has already answered. Walking it would add a
    //    directory to every 2s poll and detect nothing. This fixture is the trap: every real
    //    package finished long ago, and only the end-of-run state file and its generated script are
    //    fresh, so a walk rooted one level too high reads a finished session as busy forever.
    let ended = DispatchLayoutFixture("workflow-state-file")
    ended.put("subagents/workflows/wf_5a23f470-39d/agent-a3b273b656da7c735.jsonl", age: finished)
    ended.put("workflows/wf_5a23f470-39d.json", age: 1)
    ended.put("workflows/scripts/rule-regression-13-wf_5a23f470-39d.js", age: 1)
    var endedWatcher = ended.watcher()
    check("the end-of-run workflow state file does not hold the session busy",
          endedWatcher.isQuiet(bar))
}
