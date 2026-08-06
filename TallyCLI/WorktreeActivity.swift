import Foundation

// Is anyone still WORKING in this worktree? The question `tally worktree remove` asks before it
// tears one down.
//
// The gate first asked whether any agent process was ALIVE, and that refused the ordinary case: the
// session that finished its package and told the main line to merge is still sitting at its prompt,
// alive and doing nothing at all. A gate that stops nine ordinary cleanups out of ten teaches
// everyone to type --force by reflex, and a reflex --force does not stop for the tenth either (the
// session in the middle of an e2e run). Blocking too much and blocking nothing converge.
//
// So the signal is the supervisor's rather than the process table's: the same three-part quiet test
// every non-urgent relaunch waits for, read through `TranscriptWatcher.isQuiet` instead of
// reimplemented here, so a worktree counts as busy on exactly the evidence that keeps a reload from
// interrupting a session (transcript written recently, a tool call still open, or a subagent still
// writing). The test is shared; the threshold is this command's own (`teardownIdleSeconds`).
// Keyboard idleness is deliberately NOT part of it: `lastKeyboardInput` reads THIS process's tty,
// which says nothing about a session running in another terminal window.

/// How long a worktree's sessions must have been silent before teardown treats them as idle.
///
/// Deliberately NOT `followIdleSeconds` (120s), the bar reload, rebalance and pin-follow wait for,
/// even though the quiet test behind it is the same one. Those relaunches pick their bar against
/// what being wrong costs them: guess early and a session is restarted, which is a wait. This gate
/// pays a different price for the same mistake, because being wrong here closes the processes AND
/// deletes the conversation, and nothing brings that back.
///
/// The three signals below the mtime bar (an open tool call, a subagent still writing) cover a
/// machine that is busy while saying nothing. They do not cover a HUMAN who is busy: someone
/// reading a plan, or thinking about an answer, writes nothing to the transcript at all, and two
/// minutes of that is ordinary. Ten is not, and the ordinary teardown is unaffected either way: the
/// worktree being cleaned up was merged first, so its line has been quiet far longer than this.
///
/// 600s also matches `subagentIdleSeconds` and `openTurnMaxSeconds`, the other two windows in this
/// codebase that absorb a long silence rather than a typical one.
let teardownIdleSeconds: TimeInterval = 600

/// What the gate could learn about a worktree's sessions.
enum WorktreeActivity: Equatable {
    /// At least one session is mid turn, mid tool call, or waiting on a subagent.
    case busy
    /// Transcripts exist and every one of them is quiet.
    case idle
    /// No transcript for this worktree in any account home, so there is no state to read. Kept
    /// distinct from `idle` because "silent" and "invisible" must not be answered the same way:
    /// the gate refuses this one rather than guessing about work it cannot see.
    case unknown
}

/// Every session transcript belonging to a worktree: `<home>/projects/<slug>/*.jsonl` across the
/// homes the launch side seeds. Homes that resolve to one physical tree are read once (a machine
/// that symlinks `projects` across accounts would otherwise weigh the same file twice).
func worktreeTranscriptFiles(slug: String, homes: [String]) -> [URL] {
    guard !slug.isEmpty else { return [] }
    var seenTrees = Set<String>()
    var files: [URL] = []
    for home in homes {
        let dir = realpathString("\(home)/projects/\(slug)")
        guard seenTrees.insert(dir).inserted else { continue }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for name in names where name.hasSuffix(".jsonl") {
            files.append(URL(fileURLWithPath: "\(dir)/\(name)"))
        }
    }
    return files
}

/// Whether work is still happening in a worktree, decided per transcript by the supervisor's own
/// quiet test. EVERY transcript in the worktree is checked, not just the newest: a worktree can
/// hold several sessions, and the busy one is not always the one touched last (a turn blocked on a
/// subagent writes nothing while a second, idle session ticks over beside it).
///
/// `bar` is `teardownIdleSeconds`, this command's own quiet window: the quiet TEST is the
/// supervisor's, the threshold is not (see the constant for why an irreversible deletion waits
/// longer than a relaunch does).
///
/// A transcript that cannot be READ makes the whole worktree `.unknown` rather than counting as
/// quiet. `isQuiet` answers "quiet" for a file it cannot stat or open, which is the right way round
/// for the supervisor (never hold up a relaunch over a file nobody can see) and exactly the wrong
/// way round here, where the same answer closes live processes and deletes the conversation. So
/// readability is established HERE, before the quiet test is asked anything, instead of by changing
/// what `isQuiet` means for its other caller.
///
/// `isBoundFileQuiet` rather than `isQuiet`: the files are already enumerated, so the fork
/// discovery in front of `isQuiet` would re-scan this directory once per file.
func worktreeActivity(slug: String, homes: [String],
                      bar: TimeInterval = teardownIdleSeconds) -> WorktreeActivity {
    let files = worktreeTranscriptFiles(slug: slug, homes: homes)
    guard !files.isEmpty else { return .unknown }
    var busy = false
    for file in files {
        guard transcriptIsReadable(file) else { return .unknown }
        var watcher = TranscriptWatcher(projectDir: file.deletingLastPathComponent(),
                                        file: file, since: .distantPast)
        if !watcher.isBoundFileQuiet(bar) { busy = true }
    }
    return busy ? .busy : .idle
}

/// Whether this transcript can actually be read: it must still be there to stat (a file listed a
/// moment ago can be gone now) AND open for reading (a mode or an ACL can refuse us). Both are
/// checked because the quiet test needs both and reports neither: it reads an mtime and then a tail.
private func transcriptIsReadable(_ file: URL) -> Bool {
    guard (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate != nil else { return false }
    guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
    try? handle.close()
    return true
}

// MARK: - The gate and what it says

/// Whether teardown may proceed. `--force` always may. With no agent process running there is
/// nothing in flight to protect, whatever the transcripts say: a session that exited a minute ago
/// leaves a transcript still warm, and refusing to clean up after it would be the very false
/// refusal that trains people to type --force. Otherwise only an idle worktree passes, and an
/// unreadable one (`unknown`) does not.
func worktreeRemovalAllowed(liveAgents: Int, activity: WorktreeActivity, force: Bool) -> Bool {
    if force || liveAgents == 0 { return true }
    return activity == .idle
}

/// "1 agent" / "3 agents", shared by every line below.
private func agentPhrase(_ count: Int) -> String {
    "\(count) agent\(count == 1 ? "" : "s")"
}

/// The way out, and what it does to the conversation: someone stopped by the gate wants to know how
/// to take the worktree down anyway, and whether doing so costs them what the session recorded.
private let worktreeForceHint = "or --force to close them now, keeping their transcripts "
    + "(add --purge-transcripts to delete those too)"

/// The one-line refusal, naming the worktree, how many agents it has, and why they are not being
/// closed: still working, or working unobserved.
func worktreeRemovalRefusal(branch: String, liveAgents: Int, activity: WorktreeActivity) -> String {
    let reason = activity == .busy
        ? "is still working (\(agentPhrase(liveAgents)) mid turn)"
        : "has \(agentPhrase(liveAgents)) and no transcript to tell whether they are working"
    return "worktree \(branch) \(reason) - let them finish, \(worktreeForceHint)"
}

/// The note an idle teardown prints on its way past the gate. Telling, not asking: the agents are
/// quiet, so closing them is the point of the command, but which of them and what happens to their
/// conversation should never be a surprise.
func worktreeIdleNote(branch: String, liveAgents: Int, purgeTranscripts: Bool) -> String {
    "worktree \(branch): closing \(agentPhrase(liveAgents)) that went idle, "
        + (purgeTranscripts ? "deleting their transcripts" : "keeping their transcripts")
}
