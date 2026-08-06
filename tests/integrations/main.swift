import Foundation

var passed = 0, failed = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

try MainActor.assumeIsolated {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tally-test-\(UUID())")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let f = tmp.appendingPathComponent("zshenv")
    let body = "export PATH=\"$HOME/.tally/bin:$PATH\""
    let begin = IntegrationsStore.blockBegin, end = IntegrationsStore.blockEnd

    try IntegrationsStore.upsertBlock(in: f, body: body)
    var c = try String(contentsOf: f, encoding: .utf8)
    check("upsert into missing file creates exactly one block", c == "\(begin)\n\(body)\n\(end)\n")

    try IntegrationsStore.stripBlock(in: f)
    c = try String(contentsOf: f, encoding: .utf8)
    check("strip returns to empty", c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

    let user = "# my stuff\nexport FOO=1\n\nalias x=y\n"
    try user.write(to: f, atomically: true, encoding: .utf8)
    try IntegrationsStore.upsertBlock(in: f, body: body)
    c = try String(contentsOf: f, encoding: .utf8)
    check("upsert appends after user content", c.hasPrefix(user) && c.contains(begin))
    try IntegrationsStore.stripBlock(in: f)
    c = try String(contentsOf: f, encoding: .utf8)
    check("strip preserves user content byte-for-byte", c == user)

    try IntegrationsStore.upsertBlock(in: f, body: body)
    try IntegrationsStore.upsertBlock(in: f, body: body)
    c = try String(contentsOf: f, encoding: .utf8)
    check("double upsert leaves one block", c.components(separatedBy: begin).count == 2)

    let halfOpen = "\(begin)\nhalf\n"
    try halfOpen.write(to: f, atomically: true, encoding: .utf8)
    var threw = false
    do { try IntegrationsStore.stripBlock(in: f) } catch { threw = true }
    c = try String(contentsOf: f, encoding: .utf8)
    check("unclosed block throws", threw)
    check("unclosed block leaves file untouched", c == halfOpen)

    let mid = "line1\n\(begin)\nX\n\(end)\nline2\n"
    try mid.write(to: f, atomically: true, encoding: .utf8)
    try IntegrationsStore.stripBlock(in: f)
    c = try String(contentsOf: f, encoding: .utf8)
    check("mid-file block strips cleanly", c == "line1\nline2\n")

    // MARK: statusLine surgery (settings.json) - wrap a custom command, restore it exactly.
    let ours = IntegrationsStore.statusLineCommand
    let settings = tmp.appendingPathComponent("settings.json")
    func readSettings() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings))) as? [String: Any] ?? [:]
    }
    func statusCommand() -> String? {
        (readSettings()["statusLine"] as? [String: Any])?["command"] as? String
    }

    check("missing settings gets the plain registration",
          try IntegrationsStore.upsertStatusLine(in: settings, command: ours)
              && statusCommand() == ours)
    check("re-install is idempotent",
          try IntegrationsStore.upsertStatusLine(in: settings, command: ours) == false)
    try IntegrationsStore.removeStatusLine(in: settings, command: ours)
    check("removing the plain registration deletes the entry", statusCommand() == nil)

    let custom = "~/.claude/my-status.sh --fancy 'quoted arg'"
    let foreign: [String: Any] = ["model": "opusplan",
                                  "statusLine": ["type": "command", "command": custom]]
    try JSONSerialization.data(withJSONObject: foreign).write(to: settings)
    _ = try IntegrationsStore.upsertStatusLine(in: settings, command: ours)
    check("a custom status line is wrapped, not clobbered",
          statusCommand()?.hasPrefix("\(ours) --wrap ") == true)
    check("the wrap carries a self-heal fallback",
          statusCommand()?.contains("|| printf %s") == true)

    // Self-heal end to end: with the tally binary GONE (app trashed without a clean remove),
    // the registered shell line must still run the user's original status line.
    let echoOriginal: [String: Any] = ["statusLine": ["type": "command", "command": "echo healed"]]
    let healFile = tmp.appendingPathComponent("heal-settings.json")
    try JSONSerialization.data(withJSONObject: echoOriginal).write(to: healFile)
    _ = try IntegrationsStore.upsertStatusLine(in: healFile, command: "/nonexistent/tally statusline claude")
    let healCommand = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: healFile)))
        as? [String: Any])
        .flatMap { ($0["statusLine"] as? [String: Any])?["command"] as? String } ?? ""
    let sh = Process()
    sh.executableURL = URL(fileURLWithPath: "/bin/sh")
    sh.arguments = ["-c", healCommand]
    let healOut = Pipe()
    sh.standardOutput = healOut
    sh.standardError = FileHandle.nullDevice
    try sh.run()
    let healed = String(data: healOut.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    sh.waitUntilExit()
    check("without tally the fallback runs the original status line",
          healed?.trimmingCharacters(in: .whitespacesAndNewlines) == "healed")
    check("unrelated settings keys survive the wrap", readSettings()["model"] as? String == "opusplan")
    try IntegrationsStore.removeStatusLine(in: settings, command: ours)
    check("removal restores the custom command exactly", statusCommand() == custom)
    check("unrelated settings keys survive the restore", readSettings()["model"] as? String == "opusplan")

    try IntegrationsStore.removeStatusLine(in: settings, command: ours)
    check("removing over a foreign command leaves it untouched", statusCommand() == custom)

    // The write that would cost a user their whole harness. Registering a status line into a
    // settings.json that does not parse (a truncated write, a hand edit gone wrong) must REFUSE:
    // reading it as an empty document and writing our one key over it replaces everything they
    // have, and the file it would eat is precisely the one already in trouble. Truncated rather
    // than trailing-comma on purpose - Foundation's parser accepts a trailing comma (verified
    // 2026-08-06), so that fixture would have asserted nothing.
    let brokenStatus = tmp.appendingPathComponent("broken-status.json")
    let brokenStatusText = "{\n  \"model\": \"opusplan\",\n  \"statusLine\": {\n"
    try brokenStatusText.write(to: brokenStatus, atomically: true, encoding: .utf8)
    var refusedStatus = false
    do { _ = try IntegrationsStore.upsertStatusLine(in: brokenStatus, command: ours) } catch {
        refusedStatus = true
    }
    let afterBrokenStatus = try String(contentsOf: brokenStatus, encoding: .utf8)
    check("an unparseable settings.json is refused, not restarted from an empty document",
          refusedStatus && afterBrokenStatus == brokenStatusText)
    // Removal was already safe (its guard simply finds nothing to restore), asserted here so the
    // pair is pinned together: neither direction may rewrite a file it could not read.
    try IntegrationsStore.removeStatusLine(in: brokenStatus, command: ours)
    check("…and uninstalling leaves it alone too",
          try String(contentsOf: brokenStatus, encoding: .utf8) == brokenStatusText)

    // MARK: Claude Code skill surgery - install, refuse foreign files, remove cleanly.
    let skillFile = tmp.appendingPathComponent("skills/tally/SKILL.md")
    check("fresh skill install writes the file",
          try IntegrationsStore.upsertSkill(in: skillFile) == true
              && FileManager.default.fileExists(atPath: skillFile.path))
    let written = try String(contentsOf: skillFile, encoding: .utf8)
    check("installed skill carries the version marker",
          written.contains("tally-skill v\(IntegrationsStore.skillVersion)"))
    check("skill has frontmatter with a trigger description",
          written.hasPrefix("---\nname: tally-quota\n") && written.contains("description: "))
    check("re-install is idempotent", try IntegrationsStore.upsertSkill(in: skillFile) == false)

    let stale = written.replacingOccurrences(
        of: "tally-skill v\(IntegrationsStore.skillVersion)", with: "tally-skill v0")
    try stale.write(to: skillFile, atomically: true, encoding: .utf8)
    check("an older tally skill is upgraded in place",
          try IntegrationsStore.upsertSkill(in: skillFile) == true
              && String(contentsOf: skillFile, encoding: .utf8)
                  .contains("tally-skill v\(IntegrationsStore.skillVersion)"))

    try IntegrationsStore.removeSkill(in: skillFile)
    check("remove deletes the skill and its emptied folder",
          !FileManager.default.fileExists(atPath: skillFile.path)
              && !FileManager.default.fileExists(atPath: skillFile.deletingLastPathComponent().path))

    let userSkill = "---\nname: tally\ndescription: my own thing\n---\nmine"
    try FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try userSkill.write(to: skillFile, atomically: true, encoding: .utf8)
    var refused = false
    do { _ = try IntegrationsStore.upsertSkill(in: skillFile) } catch { refused = true }
    var afterRefusal = try String(contentsOf: skillFile, encoding: .utf8)
    check("a user's own skills/tally is never clobbered", refused && afterRefusal == userSkill)
    try IntegrationsStore.removeSkill(in: skillFile)
    afterRefusal = try String(contentsOf: skillFile, encoding: .utf8)
    check("remove leaves a foreign skill untouched", afterRefusal == userSkill)

    // Unreadable is NOT absent: a file we cannot inspect must never be overwritten.
    let junk = Data([0xFF, 0xFE, 0xFA, 0x00, 0x81])   // not valid UTF-8
    try junk.write(to: skillFile)
    var refusedJunk = false
    do { _ = try IntegrationsStore.upsertSkill(in: skillFile) } catch { refusedJunk = true }
    let junkAfter = try Data(contentsOf: skillFile)
    check("an undecodable skills/tally is refused, not clobbered",
          refusedJunk && junkAfter == junk)

    // MARK: skill content - the advisor guidance, its tier contract, and the no-em-dash rule.
    let currentSkill = IntegrationsStore.skillMarkdown()
    check("skill is at version 8", IntegrationsStore.skillVersion == 8)
    check("skill teaches the advisor field", currentSkill.contains("advisor.<provider>"))
    check("skill spells out every verdict",
          currentSkill.contains("`collecting`") && currentSkill.contains("`addAccount`")
              && currentSkill.contains("`sufficient`"))
    check("skill points at the headline and the numbers behind it",
          currentSkill.contains("`headline`") && currentSkill.contains("demandPerWeek")
              && currentSkill.contains("starvedHoursPerWeek")
              && currentSkill.contains("daysOfData"))
    check("skill answers the capacity question from the advisor",
          currentSkill.contains("should I add an account"))
    // The prompt is a contract with a reader that cannot check the source. What the CLI actually
    // emits for a snapshot naming no plan is ONE tier with its `plan` key omitted entirely
    // (asserted behaviourally in the advisor suite, documented on
    // `StatusReport.Advisor.tierDemands`), so a skill that promised an empty list there taught a sum
    // and an emptiness check that never fire.
    // Read as prose rather than as lines: the markdown is hard-wrapped, so any sentence in it can
    // be re-flowed by an edit that changes nothing a reader would notice.
    let skillProse = currentSkill.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    // Down to the shape of the absence: the report's structs are synthesized Encodables, so a nil
    // field is written as NO KEY rather than as a null (tests/statusjson pins that house rule). A
    // skill promising a null taught a reader to look for a key that is never there.
    check("skill states the no-plan case the CLI actually emits",
          skillProse.contains(
            "carries the whole figure with its `plan` key left out entirely, not an empty list"))
    check("…and never promises a null the encoder does not write",
          !skillProse.contains("null `plan`"))
    check("…and reserves the empty list for having no weekly samples",
          skillProse.contains("the list is empty only when there are no weekly samples at all"))
    check("skill carries no em dash", !currentSkill.contains("\u{2014}"))

    // The two commands the skill exists to make reachable. A subcommand named in prose but spelled
    // wrong is worse than one left out: the agent runs it, gets exit 2, and concludes the feature
    // is missing. Each is checked against the CLI's own vocabulary, not against a paraphrase.
    check("skill teaches the per-project launch profile",
          currentSkill.contains("tally project set --model opus")
              && currentSkill.contains("tally project show")
              && currentSkill.contains("tally project clear"))
    check("skill says the profile covers worktrees, not just the directory",
          skillProse.contains("worktrees included"))
    check("skill states the precedence a reader would otherwise guess at",
          skillProse.contains("a flag you type, then the project profile, then the app defaults"))
    check("skill explains the account-pick effect, which is the non-obvious half",
          skillProse.contains("steers the ACCOUNT pick"))
    check("skill names the JSON key the profile surfaces as",
          currentSkill.contains("`projectPolicy`"))
    check("skill teaches resuming a conversation on another account",
          currentSkill.contains("tally resume"))
    check("…and describes what resume actually does, per TallyCLI/main.swift",
          skillProse.contains("picks the best OTHER eligible account")
              && skillProse.contains("copies the transcript over"))

    // `tally switch` is the one command here whose main caller is the agent reading this file, run
    // from inside the session it moves - so what the prose has to get right is the TIMING. An agent
    // that believes the move is immediate stops mid-answer waiting for a restart that is waiting
    // for it, and one that believes nothing happened says so to the user.
    check("skill teaches switching this session to a named account",
          currentSkill.contains("tally switch \"Claude 4\""))
    check("skill says the move waits for the turn the agent is in",
          skillProse.contains("THE MOVE HAPPENS WHEN THE CURRENT TURN ENDS"))
    check("…and tells the agent to finish answering rather than wait",
          skillProse.contains("Finish your answer as normal"))
    check("…and promises the conversation survives it",
          skillProse.contains("with the conversation intact"))
    check("skill separates the one-shot move from the persistent profile",
          skillProse.contains("`switch` moves this conversation now, `project set` decides where"))
    check("skill says a failure changes nothing, so exit codes are read",
          skillProse.contains("or non-zero having changed nothing"))
    check("skill names the sessions that cannot be switched",
          skillProse.contains("launched bare, with `--no-handoff`, or with an `--account` pin"))
    check("…and tells the agent not to re-run a move that is merely waiting",
          skillProse.contains("Relay that rather than running the command again"))

    // The zero-turn paths. The skill's job here is not to teach the agent a new tool (it cannot
    // type a slash command) but to make it hand the cheap route to the USER: a move that costs a
    // turn to ask for spends part of what it saves, and the whole point of the hook is that asking
    // is free. Spelled exactly as the user must type them, because a paraphrase is not runnable.
    check("skill hands the user the zero-turn slash command",
          currentSkill.contains("/tally-switch Claude 4"))
    check("…names the bang path and the setting that makes it free too",
          currentSkill.contains("! tally switch \"Claude 4\"")
              && skillProse.contains("respondToBashCommands: false"))
    check("…and says why it is preferred, so the agent volunteers it",
          skillProse.contains("Prefer that phrasing when they ask \"how do I switch accounts\""))
    check("…while keeping the agent's own route unambiguous",
          skillProse.contains("You cannot type a slash command yourself"))
    // Unnamed account = a choice, and a choice is the user's. The picker spec is written in both
    // places an agent can arrive from (this skill, and the command file), so the two are asserted
    // against the same four requirements.
    check("skill sends an unnamed switch through the account picker",
          skillProse.contains("read the fleet and let them choose rather than choosing")
              && skillProse.contains("ask with AskUserQuestion, one option per Claude"))
    check("…with headroom on every option and the best one recommended first",
          skillProse.contains("remaining session, weekly and model windows as the description")
              && skillProse.contains("most headroom first and marked Recommended"))

    // The worktree section. `remove` is the one command in this file that destroys work, and the
    // agent reading it is the one who will be asked to run it ("we merged it, clean it up"), so
    // what the prose has to carry is the CONSEQUENCE and the check that comes before it. Each claim
    // is pinned against the CLI's own behaviour (TallyCLI/Worktree.swift, WorktreeTeardown.swift,
    // WorktreeTree.swift), not against a paraphrase of it.
    check("skill teaches opening and listing a parallel line",
          currentSkill.contains("tally claude -w <name>")
              && currentSkill.contains("tally worktree list")
              && currentSkill.contains("tally worktree remove <name>"))
    check("skill says removal closes the sessions running there",
          skillProse.contains("It CLOSES the sessions in that worktree"))
    check("…and points at the agent column as the check that comes first",
          skillProse.contains("Read the agent column of `tally worktree list` first")
              && skillProse.contains("`-` means nobody is working in it"))
    check("skill names the argument as the branch, not the directory",
          skillProse.contains("is the BRANCH, the first column of `tally worktree list`, not the")
              && skillProse.contains("`<repo>-` prefix"))
    check("…and warns that a bare remove opens a menu no agent can answer",
          skillProse.contains("interactive menu that an agent cannot answer"))
    // The behaviour this version changed. An agent that still believes teardown deletes the
    // conversation would either talk the user out of a cleanup they should run, or promise a
    // deletion that no longer happens.
    check("skill states the transcript default the CLI now has",
          skillProse.contains("Transcripts are KEPT")
              && skillProse.contains("`--purge-transcripts` deletes them and nothing else does"))
    check("…including the part that survives the directory, which is why teardown leaves a note",
          skillProse.contains("after the worktree directory itself is gone"))
    check("…and that the two transcript flags together are refused, not resolved",
          skillProse.contains("refused rather than guessed at"))
    check("skill names the gates that refuse on their own",
          skillProse.contains("refuses on its own while those agents are mid turn")
              && skillProse.contains("An unmerged branch is refused"))
    check("skill says a parallel line inherits the project profile",
          skillProse.contains("The project profile above belongs to the repository"))

    // MARK: auto-update - old installs follow the app, absent and foreign files never do.
    let autoDir = tmp.appendingPathComponent("auto")
    func autoFile(_ name: String, _ content: String) throws -> URL {
        let url = autoDir.appendingPathComponent("\(name)/SKILL.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    let oldSkill = currentSkill.replacingOccurrences(
        of: "tally-skill v\(IntegrationsStore.skillVersion)", with: "tally-skill v1")
    let oldFile = try autoFile("old", oldSkill)
    let currentFile = try autoFile("current", currentSkill)
    let foreignFile = try autoFile("foreign", userSkill)
    let orphanFile = try autoFile("orphan", oldSkill)
    let absentFile = autoDir.appendingPathComponent("absent/SKILL.md")   // never written

    let auto = IntegrationsStore.autoUpdateSkills(
        in: [oldFile, currentFile, absentFile, foreignFile, orphanFile])
    check("an older install is brought to the current version",
          try String(contentsOf: oldFile, encoding: .utf8) == currentSkill)
    check("an orphan on a manifest-only path is updated too",
          try String(contentsOf: orphanFile, encoding: .utf8) == currentSkill)
    check("only the outdated files count as updated", auto.updated == 2 && auto.error == nil)
    check("an absent skill is never installed",
          !FileManager.default.fileExists(atPath: absentFile.path))
    check("a foreign skills/tally is never overwritten",
          try String(contentsOf: foreignFile, encoding: .utf8) == userSkill)
    check("a current install is left alone",
          try String(contentsOf: currentFile, encoding: .utf8) == currentSkill)
    check("the manifest records our files only, absent and foreign excluded",
          auto.ours.map(\.path).sorted() == [oldFile, currentFile, orphanFile].map(\.path).sorted())
    check("a second pass changes nothing",
          IntegrationsStore.autoUpdateSkills(in: [oldFile, currentFile, orphanFile]).updated == 0)

    // A total failure (unwritable skills folder) must still surface: nothing gets recorded, but
    // the error travels back so `autoUpdateSkill` can put it in `lastError`. Asserted on the
    // return value rather than the store's property: reaching `lastError` means touching the
    // MainActor singleton, which would read and rewrite this machine's real claude homes.
    let lockedFile = try autoFile("locked", oldSkill)
    let lockedDir = lockedFile.deletingLastPathComponent().path
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: lockedDir)
    let locked = IntegrationsStore.autoUpdateSkills(in: [lockedFile])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedDir)
    check("an update that cannot be written reports the failure",
          locked.updated == 0 && locked.error != nil)
    check("a failed update leaves the old file intact",
          try String(contentsOf: lockedFile, encoding: .utf8) == oldSkill)

    // The manifest is what makes a logged-out account's orphan reachable at all.
    let manifest = tmp.appendingPathComponent("manifest.json")
    try JSONSerialization.data(withJSONObject: [
        "claudeSkill": ["paths": [orphanFile.path], "installedAt": "2026-01-01T00:00:00Z"],
    ]).write(to: manifest)
    check("manifest paths are read back for the install set",
          IntegrationsStore.manifestPaths("claudeSkill", manifest: manifest) == [orphanFile.path])
    check("a missing manifest yields no paths",
          IntegrationsStore.manifestPaths("claudeSkill",
                                          manifest: tmp.appendingPathComponent("nope.json")).isEmpty)

    // The other half of the skill integration: the `/tally-switch` command file and the prompt hook
    // that answers it without a model turn (switchcommandchecks.swift).
    try runSwitchCommandChecks(tmp: tmp, skill: currentSkill)

    try? FileManager.default.removeItem(at: tmp)
}

// MARK: - Noticing a new account without polling for it

// `tally add` finishes a login and the app used to learn about it on the next timer tick (a minute
// at best, five by default). A filesystem watcher closes that gap, but the config dirs are among the
// busiest directories on the machine: `.claude.json` is rewritten constantly by every session and
// `projects/` is a shared symlink. So the event only ever buys a cheap local discovery pass, and
// only a discovery pass whose ANSWER differs buys a refresh. Both filters are asserted here, because
// getting either wrong turns typing into usage-API traffic.
let watchHome = "/Users/x"
check("a config dir is worth looking at",
      accountDirEventIsInteresting(path: "/Users/x/.claude3", home: watchHome))
check("so is something written inside one",
      accountDirEventIsInteresting(path: "/Users/x/.claude3/projects/foo", home: watchHome))
check("and a codex home too",
      accountDirEventIsInteresting(path: "/Users/x/.codex2", home: watchHome))
// The home directory ITSELF, which is how a brand new account actually arrives: at directory
// granularity, creating `~/.claude4` is reported as a change to `~`. Rejecting this meant missing a
// login outright, and every unit test still passed until a real stream was run against it.
check("the home directory itself is, because a new account arrives as a new entry in it",
      accountDirEventIsInteresting(path: "/Users/x", home: watchHome))
// And the shape a real stream actually delivers: trailing slashes, on both the parent and the dirs.
check("the home with the trailing slash FSEvents sends is the same answer",
      accountDirEventIsInteresting(path: "/Users/x/", home: watchHome))
check("a config dir with a trailing slash too",
      accountDirEventIsInteresting(path: "/Users/x/.claude3/", home: watchHome))
check("and a noisy subtree with one is still rejected",
      !accountDirEventIsInteresting(path: "/Users/x/workspace/proj/", home: watchHome))
check("a trailing slash on the home does not change the answer",
      accountDirEventIsInteresting(path: "/Users/x/.claude", home: "/Users/x/"))
// The traffic this exists to reject: the user's actual work.
check("a source tree is not", !accountDirEventIsInteresting(path: "/Users/x/workspace/tally",
                                                            home: watchHome))
check("nor a deep path inside one",
      !accountDirEventIsInteresting(path: "/Users/x/workspace/tally/TallyCLI/Snapshot.swift",
                                    home: watchHome))
// The prefix is the SAME one discovery enumerates on (`.claude` / `.codex`, ClaudeAccounts.discover
// and CodexAccounts.discover), which is what matters: a filter narrower than discovery could hide a
// directory discovery would have found. `.claudius` diverges at the seventh character, so both
// reject it; `.claude-work` is a config dir under any name the user picks, so both accept it.
check("a name that only looks similar is not a config dir",
      !accountDirEventIsInteresting(path: "/Users/x/.claudius", home: watchHome))
check("but a custom-suffixed config dir is, exactly as discovery treats it",
      accountDirEventIsInteresting(path: "/Users/x/.claude-work", home: watchHome))
check("nor anything outside the home entirely",
      !accountDirEventIsInteresting(path: "/tmp/.claude9", home: watchHome))

// The second filter: only an account appearing or disappearing is news.
func watched(_ ids: [String], home: String = "/h") -> [ProviderAccount] {
    ids.map { ProviderAccount(id: $0, providerID: "claude", label: $0, locator: [:],
                              launchHome: home + "/" + $0) }
}
check("a new account is a change", accountSetChanged(from: watched(["a"]), to: watched(["a", "b"])))
check("an account disappearing is too",
      accountSetChanged(from: watched(["a", "b"]), to: watched(["a"])))
check("the same set is not, however busy the dirs were",
      !accountSetChanged(from: watched(["a", "b"]), to: watched(["a", "b"])))
check("and order is not identity",
      !accountSetChanged(from: watched(["a", "b"]), to: watched(["b", "a"])))
check("an account whose launch home moved IS a change",
      accountSetChanged(from: watched(["a"]), to: watched(["a"], home: "/elsewhere")))
// Identity is the id and the launch home, and deliberately nothing else. Widening it to any field
// that changes for other reasons (a nickname edited in Settings, and one day a usage number if this
// type ever grows one) would spend a refresh on news the timer already covers.
var renamed = watched(["a"])
renamed[0].label = "a nickname the user just typed"
check("a renamed account is the same account", !accountSetChanged(from: watched(["a"]), to: renamed))
// Dormancy is the exception, because it is not a field that drifts: it flips when a credential
// appears or disappears, which is the one event this watcher exists to catch. A signed-out account
// comes back from the memory with the SAME id and the same home (KnownAccounts.swift), so without
// this the login landing read as no change at all and the "Login expired" chip stayed up until the
// next poll tick (codex review, 2026-08-03).
var dormant = watched(["a"])
dormant[0].isDormant = true
check("an account signing back in is a change, though its id and home never moved",
      accountSetChanged(from: dormant, to: watched(["a"])))
check("…and so is it signing out", accountSetChanged(from: watched(["a"]), to: dormant))
check("…while a dormant account that stays dormant is not",
      !accountSetChanged(from: dormant, to: dormant))
check("nothing to nothing is nothing", !accountSetChanged(from: [], to: []))
check("the first account ever found is a change", accountSetChanged(from: [], to: watched(["a"])))
print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
