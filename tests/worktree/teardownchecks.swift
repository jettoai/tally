import Foundation

// Groups 10-13 and 19 of the worktree assertions (kill decision, path guards, git cleanup end to
// end, and the liveness gate that stands in front of all of it), split out of main.swift for file
// size. They run as one function main.swift calls, which also owns the shared harness (`check`,
// `sh`, `tempDir`, `rp`).

func runTeardownChecks() {
    // MARK: - 10. Teardown: kill decision (pure)

    check("a claude process inside the worktree is killed",
          shouldKill(name: "claude", cwd: "/a/b/wt", worktreePath: "/a/b/wt"))
    check("a process nested under the worktree is killed",
          shouldKill(name: "fswatch", cwd: "/a/b/wt/sub/dir", worktreePath: "/a/b/wt"))
    check("tally is in the allowlist", shouldKill(name: "tally", cwd: "/a/b/wt", worktreePath: "/a/b/wt"))
    check("a shell is never killed even inside the worktree",
          !shouldKill(name: "zsh", cwd: "/a/b/wt", worktreePath: "/a/b/wt"))
    check("an unrelated binary is not killed", !shouldKill(name: "node", cwd: "/a/b/wt", worktreePath: "/a/b/wt"))
    check("a sibling sharing a path prefix is not a false positive",
          !shouldKill(name: "claude", cwd: "/a/b/wtx", worktreePath: "/a/b/wt"))
    check("a process outside the worktree is not killed",
          !shouldKill(name: "claude", cwd: "/other/place", worktreePath: "/a/b/wt"))

    // The selection fed to the killer, over a scan mixing a worktree's own agents with a shell, an
    // unrelated binary and an outsider. This is the shape of the 2026-07-26 failure: git had let go
    // of the registration while five session processes were still alive, and teardown reported
    // "killed 0" because the scan behind this selection stopped short of them.
    let liveScan = [
        ProcInfo(pid: 101, name: "claude", cwd: "/a/b/wt"),
        ProcInfo(pid: 102, name: "tally", cwd: "/a/b/wt"),
        ProcInfo(pid: 103, name: "claude", cwd: "/a/b/wt/sub/dir"),
        ProcInfo(pid: 104, name: "zsh", cwd: "/a/b/wt"),
        ProcInfo(pid: 105, name: "node", cwd: "/a/b/wt"),
        ProcInfo(pid: 106, name: "claude", cwd: "/a/b/wtx"),
    ]
    check("every agent rooted in the worktree is selected, never zero",
          worktreeProcessesToKill(liveScan, worktreePath: "/a/b/wt").map(\.pid) == [101, 102, 103])
    check("an empty scan selects nothing",
          worktreeProcessesToKill([], worktreePath: "/a/b/wt").isEmpty)
    check("the same selection is what the list report counts as live agents",
          worktreeListLines([WorktreeEntry(path: "/a/b/wt", branch: "wt")], processes: liveScan)
            .first?.contains("\t3 agents\t") == true)

    // The guard on deleting a worktree directory ourselves.
    check("a path git no longer registers may be removed",
          worktreeDirRemovalAllowed(path: "/a/b/repo-feat", mainRepo: "/a/b/repo", registered: false))
    check("a still-registered path is left to git",
          !worktreeDirRemovalAllowed(path: "/a/b/repo-feat", mainRepo: "/a/b/repo", registered: true))
    check("the main repo itself is never removed",
          !worktreeDirRemovalAllowed(path: "/a/b/repo", mainRepo: "/a/b/repo", registered: false))
    check("an ancestor of the main repo is never removed",
          !worktreeDirRemovalAllowed(path: "/a/b", mainRepo: "/a/b/repo", registered: false))
    check("the filesystem root is never removed",
          !worktreeDirRemovalAllowed(path: "/", mainRepo: "/a/b/repo", registered: false))
    check("a relative path is refused (nothing to resolve it against)",
          !worktreeDirRemovalAllowed(path: "repo-feat", mainRepo: "/a/b/repo", registered: false))

    // MARK: - 11. Teardown: slug + transcript path guards (pure)

    check("the transcript slug turns / and . into -",
          worktreeTranscriptSlug(forResolvedPath: "/Users/x/repo-feat.1")
            == "-Users-x-repo-feat-1")
    let guardHome = "/Users/x/.claude"
    check("a target under the home's projects dir passes the guard",
          transcriptGuardPasses(target: "\(guardHome)/projects/-Users-x-repo-feat", home: guardHome))
    check("the projects dir itself does not pass (nothing to remove)",
          !transcriptGuardPasses(target: "\(guardHome)/projects/", home: guardHome))
    check("a path outside the projects dir is refused",
          !transcriptGuardPasses(target: "\(guardHome)/somewhere/else", home: guardHome))
    check("a secondary account home guards on its own projects dir",
          transcriptGuardPasses(target: "/Users/x/.claude2/projects/-Users-x-repo-feat",
                                home: "/Users/x/.claude2") &&
          !transcriptGuardPasses(target: "\(guardHome)/projects/-Users-x-repo-feat",
                                 home: "/Users/x/.claude2"))
    check("an empty slug yields a target that is just the prefix and is refused",
          !transcriptGuardPasses(target: "\(guardHome)/projects/", home: guardHome))

    // The removal loop sweeps every account home the launch side seeds, not just the default one.
    let homeA = rp(tempDir())
    let homeB = rp(tempDir())
    let sweepSlug = "-Users-x-repo-feat"
    for base in [homeA, homeB] {
        try? FileManager.default.createDirectory(atPath: "\(base)/projects/\(sweepSlug)",
                                                 withIntermediateDirectories: true)
    }
    check("both account homes hold the transcript dir before the sweep",
          FileManager.default.fileExists(atPath: "\(homeA)/projects/\(sweepSlug)") &&
          FileManager.default.fileExists(atPath: "\(homeB)/projects/\(sweepSlug)"))
    check("the sweep removes the dir in both homes and reports success",
          removeTranscriptDirs(slug: sweepSlug, homes: [homeA, homeB]))
    check("the transcript dir is gone from the default home",
          !FileManager.default.fileExists(atPath: "\(homeA)/projects/\(sweepSlug)"))
    check("the transcript dir is gone from the secondary home",
          !FileManager.default.fileExists(atPath: "\(homeB)/projects/\(sweepSlug)"))
    check("a second sweep finds nothing to remove but does not fail",
          !removeTranscriptDirs(slug: sweepSlug, homes: [homeA, homeB]))
    check("an empty slug removes nothing", !removeTranscriptDirs(slug: "", homes: [homeA, homeB]))

    // MARK: - 12. Teardown: git cleanup end to end (real git, no killing)

    // Where the "this worktree belonged to that repository" notes go for the rest of this function.
    // A temp file, never `~/.tally/worktree-origins.json`: a test must not write into the record the
    // running app reads, and asserting on the real one would depend on this machine's own history.
    let originsFile = URL(fileURLWithPath: tempDir()).appendingPathComponent("origins.json")

    // A merged worktree tears all the way down: worktree gone, branch gone, exit 0.
    let mergedRepo = tempDir()
    sh("git init -q && git config user.email t@t && git config user.name t && " +
       "git commit -q --allow-empty -m init", cwd: mergedRepo)
    FileManager.default.changeCurrentDirectoryPath(mergedRepo)
    let mergedWt = resolveWorktree(name: "feat")   // reuse the launch resolver to create it
    sh("git commit -q --allow-empty -m work", cwd: mergedWt.path)
    sh("git merge -q feat", cwd: mergedRepo)        // fast-forward main to feat so feat is an ancestor
    let mergedCode = performWorktreeRemove(name: "feat", force: false, purgeTranscripts: false,
                                           originsFile: originsFile,
                                           listProcesses: { _ in [] })
    check("a merged worktree removes cleanly (exit 0)", mergedCode == 0)
    check("the merged worktree directory is gone", !FileManager.default.fileExists(atPath: mergedWt.path))
    check("the merged branch is deleted",
          sh("git show-ref --verify --quiet refs/heads/feat", cwd: mergedRepo) != 0)

    // The note that outlives the directory. Keeping the transcripts is only half of keeping the
    // history: the app rebuilds attribution from the filesystem, and the `.git` file that said whose
    // parallel line this was has just been deleted. What is asserted here is exactly what
    // TokenProjectMap reads back (tests/tokenprojectmap builds its fixture through this same
    // writer, so the two suites cannot drift into different spellings of one file).
    let mergedOrigin = WorktreeOrigins.load(from: originsFile).first { $0.repository == rp(mergedRepo) }
    check("teardown remembers which repository the worktree belonged to", mergedOrigin != nil)
    check("…under the worktree's own resolved path, which is what a transcript recorded",
          mergedOrigin?.paths.contains(rp(mergedWt.path)) == true)
    check("…and dates it, so the oldest notes are the ones dropped when the file fills up",
          mergedOrigin?.removedAt?.isEmpty == false)

    // An unmerged worktree is refused without --force, then removed with it.
    let unmergedRepo = tempDir()
    sh("git init -q && git config user.email t@t && git config user.name t && " +
       "git commit -q --allow-empty -m init", cwd: unmergedRepo)
    FileManager.default.changeCurrentDirectoryPath(unmergedRepo)
    let unmergedWt = resolveWorktree(name: "feat2")
    sh("git commit -q --allow-empty -m unmerged", cwd: unmergedWt.path)   // ahead of main, not merged
    let refusedCode = performWorktreeRemove(name: "feat2", force: false, purgeTranscripts: false,
                                            originsFile: originsFile,
                                            listProcesses: { _ in [] })
    check("an unmerged worktree is refused without --force (exit 1)", refusedCode == 1)
    check("the refused worktree is left in place", FileManager.default.fileExists(atPath: unmergedWt.path))
    let forcedCode = performWorktreeRemove(name: "feat2", force: true, purgeTranscripts: false,
                                           originsFile: originsFile,
                                           listProcesses: { _ in [] })
    check("--force removes the unmerged worktree (exit 0)", forcedCode == 0)
    check("the forced worktree directory is gone", !FileManager.default.fileExists(atPath: unmergedWt.path))
    check("--force deletes the unmerged branch (branch -D)",
          sh("git show-ref --verify --quiet refs/heads/feat2", cwd: unmergedRepo) != 0)

    // A caller sitting inside the target worktree is refused before anything is torn down (git alone
    // would not refuse: the git subprocess runs from mainRepo, so only this guard protects the caller).
    let insideRepo = tempDir()
    sh("git init -q && git config user.email t@t && git config user.name t && " +
       "git commit -q --allow-empty -m init", cwd: insideRepo)
    FileManager.default.changeCurrentDirectoryPath(insideRepo)
    let insideWt = resolveWorktree(name: "feat3")
    sh("git commit -q --allow-empty -m work", cwd: insideWt.path)
    sh("git merge -q feat3", cwd: insideRepo)       // merged, so only the cwd guard can refuse
    FileManager.default.changeCurrentDirectoryPath(insideWt.path)
    let insideCode = performWorktreeRemove(name: "feat3", force: false, purgeTranscripts: false,
                                           originsFile: originsFile,
                                           listProcesses: { _ in [] })
    check("removal from inside the target worktree is refused (exit 1)", insideCode == 1)
    check("the worktree the caller sits in is left in place",
          FileManager.default.fileExists(atPath: insideWt.path))
    FileManager.default.changeCurrentDirectoryPath(insideRepo)

    // A tag carrying the branch's name must not shadow the branch in the merged check (gitrevisions
    // resolves tags before heads): the unmerged branch stays refused even when the tag is merged.
    let shadowRepo = tempDir()
    sh("git init -q && git config user.email t@t && git config user.name t && " +
       "git commit -q --allow-empty -m init", cwd: shadowRepo)
    FileManager.default.changeCurrentDirectoryPath(shadowRepo)
    let shadowWt = resolveWorktree(name: "feat4")
    sh("git commit -q --allow-empty -m unmerged", cwd: shadowWt.path)
    sh("git tag feat4 HEAD", cwd: shadowRepo)       // tag at main HEAD, which IS an ancestor
    let shadowCode = performWorktreeRemove(name: "feat4", force: false, purgeTranscripts: false,
                                           originsFile: originsFile,
                                           listProcesses: { _ in [] })
    check("a merged same-name tag does not waive the merged gate (exit 1)", shadowCode == 1)
    check("the tag-shadowed worktree is left in place",
          FileManager.default.fileExists(atPath: shadowWt.path))

    // A half-removed worktree: the registration survives but its checkout no longer validates (the
    // .git file is gone, which git reports as "prunable"), so `git worktree remove` refuses while the
    // directory stays on disk. Teardown prunes, sees git has let go of the path, and deletes the
    // directory itself rather than reporting success over a directory nobody owns.
    let staleRepo = tempDir()
    sh("git init -q && git config user.email t@t && git config user.name t && " +
       "git commit -q --allow-empty -m init", cwd: staleRepo)
    FileManager.default.changeCurrentDirectoryPath(staleRepo)
    let staleWt = resolveWorktree(name: "feat5")
    sh("git commit -q --allow-empty -m work", cwd: staleWt.path)
    sh("git merge -q feat5", cwd: staleRepo)
    sh("rm -f .git", cwd: staleWt.path)             // registration kept, checkout no longer validates
    check("the half-removed worktree directory is on disk before teardown",
          FileManager.default.fileExists(atPath: staleWt.path))
    let staleCode = performWorktreeRemove(name: "feat5", force: false, purgeTranscripts: false,
                                          originsFile: originsFile,
                                          listProcesses: { _ in [] })
    check("a half-removed worktree still tears down (exit 0)", staleCode == 0)
    check("teardown deletes the directory git left behind",
          !FileManager.default.fileExists(atPath: staleWt.path))
    check("the stale registration is pruned",
          !runGit(["worktree", "list", "--porcelain"], cwd: staleRepo).out.contains(staleWt.path))
    check("the branch of a half-removed worktree is deleted",
          sh("git show-ref --verify --quiet refs/heads/feat5", cwd: staleRepo) != 0)
    check("the main repo is untouched by the directory removal",
          FileManager.default.fileExists(atPath: "\(staleRepo)/.git"))

    // MARK: - 13. Teardown: killWorktreeProcesses with no targets is a no-op

    check("killing an empty target list touches nothing and returns zero",
          killWorktreeProcesses([]) == 0)

    // MARK: - 19. Teardown: the gate (pure, then real git with a real live process)

    // The decision. What matters is that a WORKING worktree is refused while an idle one goes
    // through: a gate that also stopped the ordinary case (a finished session sitting at its
    // prompt) would teach every caller to type --force, and then it would stop nothing at all.
    check("a working worktree is refused without --force",
          !worktreeRemovalAllowed(liveAgents: 1, activity: .busy, force: false))
    check("--force goes through a working worktree",
          worktreeRemovalAllowed(liveAgents: 2, activity: .busy, force: true))
    check("an IDLE worktree needs no flag at all",
          worktreeRemovalAllowed(liveAgents: 3, activity: .idle, force: false))
    check("a worktree whose state cannot be read is refused",
          !worktreeRemovalAllowed(liveAgents: 1, activity: .unknown, force: false))
    check("--force goes through an unreadable one too",
          worktreeRemovalAllowed(liveAgents: 1, activity: .unknown, force: true))
    check("with no agent running there is nothing to protect, whatever the transcripts say",
          worktreeRemovalAllowed(liveAgents: 0, activity: .busy, force: false) &&
          worktreeRemovalAllowed(liveAgents: 0, activity: .unknown, force: false))

    // What it says. Both refusals name both ways out, since someone stopped here next wants to know
    // how to take the worktree down WITHOUT losing the conversation.
    let busyText = worktreeRemovalRefusal(branch: "feat", liveAgents: 2, activity: .busy)
    check("the busy refusal says the worktree is working, not that it is alive",
          busyText.contains("is still working (2 agents mid turn)") && !busyText.contains("live"))
    let unknownText = worktreeRemovalRefusal(branch: "feat", liveAgents: 1, activity: .unknown)
    check("the unreadable refusal says why it cannot tell",
          unknownText.contains("1 agent") && unknownText.contains("no transcript"))
    check("both refusals name --force and say the conversation survives it",
          [busyText, unknownText].allSatisfy {
              $0.contains("--force to close them now, keeping their transcripts")
                  && $0.contains("--purge-transcripts")
          })
    check("the idle note tells what is being closed and what happens to the conversation",
          worktreeIdleNote(branch: "feat", liveAgents: 1, purgeTranscripts: false)
            == "worktree feat: closing 1 agent that went idle, keeping their transcripts" &&
          worktreeIdleNote(branch: "feat", liveAgents: 2, purgeTranscripts: true)
            .hasSuffix("closing 2 agents that went idle, deleting their transcripts"))

    // The flag vocabulary, at the parser. `--purge-transcripts` is the only way to ask for the
    // deletion that used to be the default, and `--keep-transcripts` (which every note and script
    // written before the flip still says) must not be an unknown flag: it asks for what already
    // happens.
    let plainFlags = parseWorktreeRemoveFlags(["feat"])
    check("no flags at all keeps the transcripts",
          plainFlags?.name == "feat" && plainFlags?.force == false
              && plainFlags?.purgeTranscripts == false)
    check("--purge-transcripts is how deletion is asked for",
          parseWorktreeRemoveFlags(["feat", "--purge-transcripts"])?.purgeTranscripts == true)
    check("--keep-transcripts is accepted and changes nothing",
          parseWorktreeRemoveFlags(["--keep-transcripts"])?.purgeTranscripts == false)
    let forcedFlags = parseWorktreeRemoveFlags(["--force", "feat"])
    check("--force parses beside a name that follows it",
          forcedFlags?.force == true && forcedFlags?.name == "feat")
    check("an unknown flag is refused", parseWorktreeRemoveFlags(["feat", "--nope"]) == nil)
    check("a second name is refused", parseWorktreeRemoveFlags(["feat", "other"]) == nil)
    // Both transcript flags at once is refused rather than resolved, in either order. Last-wins
    // would let an old script that still carries --keep-transcripts (written when it was the only
    // way to save a conversation) end up deleting one, and that direction is not undoable.
    check("asking to keep AND purge is refused",
          parseWorktreeRemoveFlags(["feat", "--keep-transcripts", "--purge-transcripts"]) == nil)
    check("…whichever order they were typed in",
          parseWorktreeRemoveFlags(["feat", "--purge-transcripts", "--keep-transcripts"]) == nil)
    check("…and the refusal is the command's own exit 2, not a teardown that ran halfway",
          runWorktreeRemove(args: ["feat", "--keep-transcripts", "--purge-transcripts"]) == 2)

    // A transcript fixture: `body` with a chosen mtime, which is what the quiet test reads first.
    func seedTranscript(_ dir: String, body: String, ageSeconds: TimeInterval) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = "\(dir)/session.jsonl"
        try? body.write(toFile: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-ageSeconds)], ofItemAtPath: file)
    }
    func isoAgo(_ seconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(-seconds))
    }
    // A turn that finished (prose, no tool call left open) and one still inside a tool call: the
    // second is the case a file mtime alone reads as idle, which is why the gate reads the tail.
    let closedTurn = "{\"type\":\"assistant\",\"isSidechain\":false,\"timestamp\":\"\(isoAgo(900))\","
        + "\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}"
    let openTurn = "{\"type\":\"assistant\",\"isSidechain\":false,\"timestamp\":\"\(isoAgo(60))\","
        + "\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_open\"}]}}"

    // A transcript nobody can READ must not read as quiet. `isQuiet` answers "quiet" for a file it
    // cannot open, which is right for the supervisor and catastrophic here: the gate would call the
    // worktree idle and delete a session it never managed to look at.
    let blindHome = rp(tempDir())
    let blindSlug = "-blind-worktree"
    let blindDir = "\(blindHome)/projects/\(blindSlug)"
    seedTranscript(blindDir, body: closedTurn, ageSeconds: 900)
    check("a readable, silent transcript is idle",
          worktreeActivity(slug: blindSlug, homes: [blindHome]) == .idle)
    sh("chmod 000 '\(blindDir)/session.jsonl'")
    check("a transcript that cannot be opened makes the worktree unknown, never idle",
          worktreeActivity(slug: blindSlug, homes: [blindHome]) == .unknown)
    check("and unknown is refused without --force",
          !worktreeRemovalAllowed(liveAgents: 1, activity: .unknown, force: false))
    sh("chmod 600 '\(blindDir)/session.jsonl'")
    check("restoring the mode restores the reading",
          worktreeActivity(slug: blindSlug, homes: [blindHome]) == .idle)
    // A file listed and then deleted before it could be read is the same class of blindness.
    try? FileManager.default.removeItem(atPath: "\(blindDir)/session.jsonl")
    check("an empty transcript directory is unknown too (nothing to read a state from)",
          worktreeActivity(slug: blindSlug, homes: [blindHome]) == .unknown)

    // The gate judges the files it enumerated, one directory scan for the lot. Going through
    // `isQuiet` instead would re-run fork discovery per file (and read every sibling), which is
    // both the I/O blowup and, here, a different answer: the fork lands on the busy file.
    let forkDir = rp(tempDir())
    // The trailing newline matters: the fork scan only trusts lines it has read whole.
    let forkMarker = "{\"type\":\"assistant\",\"isSidechain\":false,\"session_id\":\"a\","
        + "\"sessionId\":\"b\",\"timestamp\":\"\(isoAgo(30))\"}\n"
    try? closedTurn.write(toFile: "\(forkDir)/a.jsonl", atomically: true, encoding: .utf8)
    try? forkMarker.write(toFile: "\(forkDir)/b.jsonl", atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-900)], ofItemAtPath: "\(forkDir)/a.jsonl")
    var boundToA = TranscriptWatcher(projectDir: URL(fileURLWithPath: forkDir),
                                     file: URL(fileURLWithPath: "\(forkDir)/a.jsonl"),
                                     since: .distantPast)
    check("the bound-file test judges the file it was given, with no fork discovery",
          boundToA.isBoundFileQuiet(teardownIdleSeconds))
    var following = boundToA
    check("the supervisor's isQuiet still follows the fork, unchanged",
          !following.isQuiet(teardownIdleSeconds))

    // End to end over a MERGED worktree, so the merged check cannot be what refuses: only this gate
    // stands between a working session and an irreversible teardown. The live agent is a real child
    // process (a sleep wearing an agent's name in the injected scan), so a regression that lets the
    // kill through is observable rather than theoretical, and nothing outside this test can ever be
    // signalled. Transcripts live in a temp home injected through `transcriptHomes`, never the
    // account homes this machine really uses.
    let liveRepo = tempDir()
    sh("git init -q && git config user.email t@t && git config user.name t && " +
       "git commit -q --allow-empty -m init", cwd: liveRepo)
    FileManager.default.changeCurrentDirectoryPath(liveRepo)
    let liveWt = resolveWorktree(name: "feat-live")
    sh("git commit -q --allow-empty -m work", cwd: liveWt.path)
    sh("git merge -q feat-live", cwd: liveRepo)

    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    try? sleeper.run()
    let liveAgentScan = { (_: String) in
        [ProcInfo(pid: sleeper.processIdentifier, name: "claude", cwd: liveWt.path)]
    }
    let liveHome = rp(tempDir())
    let liveTranscripts = "\(liveHome)/projects/\(worktreeTranscriptSlug(forResolvedPath: liveWt.path))"
    func removeLive(force: Bool = false, purgeTranscripts: Bool = false) -> Int32 {
        performWorktreeRemove(name: "feat-live", force: force, purgeTranscripts: purgeTranscripts,
                              transcriptHomes: [liveHome], originsFile: originsFile,
                              listProcesses: liveAgentScan)
    }
    func liveWorktreeUntouched() -> Bool {
        FileManager.default.fileExists(atPath: liveWt.path)
            && sh("git show-ref --verify --quiet refs/heads/feat-live", cwd: liveRepo) == 0
            && sleeper.isRunning
    }

    // No transcript anywhere: the state cannot be read, so the gate refuses rather than guess.
    check("a worktree with no transcript to judge is refused (exit 1)", removeLive() == 1)
    check("nothing was touched by that refusal", liveWorktreeUntouched())

    // Written seconds ago: a session mid turn.
    seedTranscript(liveTranscripts, body: closedTurn, ageSeconds: 0)
    check("a worktree whose transcript was just written is refused (exit 1)", removeLive() == 1)
    check("nothing was touched by the busy refusal", liveWorktreeUntouched())
    check("its transcripts are still there",
          FileManager.default.fileExists(atPath: "\(liveTranscripts)/session.jsonl"))

    // Silent for eight minutes, past this command's own quiet bar, but the last turn is still
    // inside a tool call: busy, and only the tail read can tell. This is the case the old
    // process-liveness gate and a plain mtime check both get wrong in opposite directions.
    seedTranscript(liveTranscripts, body: openTurn, ageSeconds: 700)
    check("a worktree silent inside an open tool call is still refused (exit 1)", removeLive() == 1)
    check("nothing was touched by the open-turn refusal", liveWorktreeUntouched())

    // Silent for eight minutes with the turn CLOSED is idle, so the bar is what decides here: at
    // 500s (past the supervisor's 120s follow bar, short of this command's 600s) the worktree is
    // still busy. Teardown waits longer than a relaunch does because being wrong deletes the
    // conversation instead of restarting it.
    seedTranscript(liveTranscripts, body: closedTurn, ageSeconds: 500)
    check("a worktree quiet for 500s is still busy, so the teardown bar is not the follow bar",
          teardownIdleSeconds > followIdleSeconds && removeLive() == 1)
    check("nothing was touched while it was under the bar", liveWorktreeUntouched())

    // The transcript flag is not a way around the gate, in either direction: it decides what
    // happens to a conversation, never to a process.
    check("--purge-transcripts does not waive the gate", removeLive(purgeTranscripts: true) == 1)
    check("nothing was touched by that attempt either", liveWorktreeUntouched())
    check("and the transcripts it named are still there",
          FileManager.default.fileExists(atPath: "\(liveTranscripts)/session.jsonl"))

    // --force is the documented way through a session that IS working, and it still does the whole
    // teardown - except to the conversation, which it now leaves alone. Someone forcing a busy
    // worktree down is the LEAST likely to also mean "and delete what it recorded".
    check("--force tears down a working worktree (exit 0)", removeLive(force: true) == 0)
    var waited = 0
    while sleeper.isRunning, waited < 50 { usleep(100_000); waited += 1 }
    check("--force killed the working agent", !sleeper.isRunning)
    check("the forced worktree directory is gone",
          !FileManager.default.fileExists(atPath: liveWt.path))
    check("the forced branch is deleted",
          sh("git show-ref --verify --quiet refs/heads/feat-live", cwd: liveRepo) != 0)
    check("the forced run keeps the transcripts the gate had protected",
          FileManager.default.fileExists(atPath: "\(liveTranscripts)/session.jsonl"))

    // The case the whole change is for: agents alive, quiet well past the bar, no flags typed. This
    // is the ordinary end of a worktree, so it must not need one.
    let idleWt = resolveWorktree(name: "feat-idle")
    sh("git commit -q --allow-empty -m work", cwd: idleWt.path)
    sh("git merge -q feat-idle", cwd: liveRepo)
    let idler = Process()
    idler.executableURL = URL(fileURLWithPath: "/bin/sleep")
    idler.arguments = ["30"]
    try? idler.run()
    let idleAgentScan = { (_: String) in
        [ProcInfo(pid: idler.processIdentifier, name: "claude", cwd: idleWt.path)]
    }
    let idleTranscripts = "\(liveHome)/projects/\(worktreeTranscriptSlug(forResolvedPath: idleWt.path))"
    seedTranscript(idleTranscripts, body: closedTurn, ageSeconds: 900)
    check("the idle worktree's transcript is in place before the run",
          FileManager.default.fileExists(atPath: "\(idleTranscripts)/session.jsonl"))
    let idleCode = performWorktreeRemove(name: "feat-idle", force: false, purgeTranscripts: false,
                                         transcriptHomes: [liveHome], originsFile: originsFile,
                                         listProcesses: idleAgentScan)
    check("an idle worktree tears down with no flags at all (exit 0)", idleCode == 0)
    waited = 0
    while idler.isRunning, waited < 50 { usleep(100_000); waited += 1 }
    check("the idle agent was closed", !idler.isRunning)
    check("the idle worktree directory is gone",
          !FileManager.default.fileExists(atPath: idleWt.path))
    check("the idle branch is deleted",
          sh("git show-ref --verify --quiet refs/heads/feat-idle", cwd: liveRepo) != 0)
    // The flip: the app credits a worktree's usage to the repository it was cut from, so its
    // transcripts are part of that project's own history. An ordinary teardown keeps them.
    check("the idle worktree's transcripts outlive it",
          FileManager.default.fileExists(atPath: "\(idleTranscripts)/session.jsonl"))

    // And the one flag that still deletes them, over a worktree torn down the same ordinary way.
    let purgeWt = resolveWorktree(name: "feat-purge")
    sh("git commit -q --allow-empty -m work", cwd: purgeWt.path)
    sh("git merge -q feat-purge", cwd: liveRepo)
    let purgeTranscripts = "\(liveHome)/projects/\(worktreeTranscriptSlug(forResolvedPath: purgeWt.path))"
    seedTranscript(purgeTranscripts, body: closedTurn, ageSeconds: 900)
    let purgeCode = performWorktreeRemove(name: "feat-purge", force: false, purgeTranscripts: true,
                                          transcriptHomes: [liveHome], originsFile: originsFile,
                                          listProcesses: { _ in [] })
    check("--purge-transcripts tears the worktree down too (exit 0)", purgeCode == 0)
    check("the purged worktree directory is gone",
          !FileManager.default.fileExists(atPath: purgeWt.path))
    check("--purge-transcripts is what deletes the transcript directory",
          !FileManager.default.fileExists(atPath: purgeTranscripts))
    // And with the conversation deliberately gone there is nothing left to attribute, so no note is
    // written: the origins file records repositories to credit, not worktrees that once existed.
    check("a purging teardown leaves no origin note behind",
          !WorktreeOrigins.load(from: originsFile).contains { $0.paths.contains(purgeWt.path) })
    check("while the teardown that kept its transcripts did leave one",
          WorktreeOrigins.load(from: originsFile).contains { $0.paths.contains(idleWt.path) })

    // MARK: - 21. The origins ledger itself (what every teardown above writes through)

    // Split into tests/worktree/originschecks.swift for file size; same arrangement as the groups
    // main.swift splits out.
    runOriginsChecks()
}
