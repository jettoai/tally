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

    // The status line registration and its settings.json surgery (statuslinechecks.swift).
    try runStatusLineChecks(tmp: tmp)

    // MARK: Claude Code skill surgery - install, refuse foreign files, remove cleanly.
    let skillFile = IntegrationsStore.claudeSkillFile(inHome: tmp)
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
    check("a user's own skill at that path is never clobbered",
          refused && afterRefusal == userSkill)
    try IntegrationsStore.removeSkill(in: skillFile)
    afterRefusal = try String(contentsOf: skillFile, encoding: .utf8)
    check("remove leaves a foreign skill untouched", afterRefusal == userSkill)

    // Unreadable is NOT absent: a file we cannot inspect must never be overwritten.
    let junk = Data([0xFF, 0xFE, 0xFA, 0x00, 0x81])   // not valid UTF-8
    try junk.write(to: skillFile)
    var refusedJunk = false
    do { _ = try IntegrationsStore.upsertSkill(in: skillFile) } catch { refusedJunk = true }
    let junkAfter = try Data(contentsOf: skillFile)
    check("an undecodable skill file is refused, not clobbered",
          refusedJunk && junkAfter == junk)

    // MARK: skill content - the advisor guidance, its tier contract, and the no-em-dash rule.
    let currentSkill = IntegrationsStore.skillMarkdown()
    runSkillVersionChecks()   // the version, and the text it stands for, pinned to each other
    // The native `/model` is adopted now, not overwritten. The command file used to teach the
    // opposite, which was true when it was written and became a lie the moment the supervisor
    // learned to read that event (geo session 7cfa11a4, 2026-08-06).
    check("the skill teaches that the native command is adopted",
          currentSkill.contains("Tally adopts Claude Code's own `/model`"))
    check("…and the command file no longer teaches that it gets put back",
          !IntegrationsStore.tallyPromptCommand.markdown.contains("puts the original model back"))
    // The skill carries that contract alone now: the command file behind it is a short answer for a
    // machine where nothing else worked (IntegrationsTallyCommand.swift), not a second copy of the
    // model rules.
    check("…and the skill still names `auto` as the only way out of an adopted pin",
          currentSkill.contains("including out of an adopted one"))
    // ONE slash command ships with the skill now, and the list every surface walks still exists for
    // the reason it always did: a command added to the sync and forgotten by the uninstall (or by
    // the "is this install current" check) is exactly the failure the list makes impossible.
    check("one slash command is managed, and it is the merged one",
          IntegrationsStore.promptCommands.map(\.name) == ["tally"])
    check("…and it carries the version marker the skill shares",
          IntegrationsStore.promptCommands.allSatisfy {
              $0.markdown.contains(IntegrationsStore.promptCommandMarker)
          })
    // THE TWO IT REPLACED ARE STILL ANSWERED FOR, which is what makes the merge cleanable rather
    // than a pair of orphans: the old names, the old subcommands and the old tools are all carried,
    // because that is what the entries and files left on a user's disk say.
    let tallyCommand = IntegrationsStore.tallyPromptCommand
    check("the merged command answers for what it replaced",
          tallyCommand.formerNames == ["tally-account", "tally-model", "tally-switch"]
              && tallyCommand.formerHookMarkers == ["hook-switch", "hook-model"]
              && tallyCommand.formerTools == [.pickAccount, .pickModel])
    check("…and runs one subcommand and calls one tool of its own",
          tallyCommand.hookMarker == "hook-tally" && tallyCommand.mcpTool == .pick
              && !tallyCommand.formerHookMarkers.contains(tallyCommand.hookMarker)
              && !tallyCommand.formerTools.contains(tallyCommand.mcpTool))
    // Normalised the way the other suite reads its own file: the markdown is hard-wrapped, so a
    // sentence to assert on crosses a line break and a literal `contains` would be asserting the
    // wrapping rather than the words.
    let commandFile = tallyCommand.markdown.split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
    // THE FALLBACK BEHIND A FALLBACK. Two hooks answer `/tally` (the native picker and its
    // backstop), so reaching this file means neither did, and the turn it costs is the one the whole
    // command exists to avoid. It therefore spends that turn on ONE answer rather than on a second
    // implementation of the picker.
    check("the command file says, first, that Tally did not answer",
          commandFile.contains("READING THIS MEANS TALLY DID NOT ANSWER")
              && commandFile.contains("/tally"))
    check("…and that this turn is the cost the command exists to avoid",
          commandFile.contains("SPEND IT ON ONE SHORT ANSWER"))
    check("…passes a model through as words and an account as one quoted word",
          commandFile.contains("tally model $ARGUMENTS")
              && commandFile.contains("tally account \"$ARGUMENTS\""))
    check("…and says naming only a model leaves the depth alone",
          commandFile.contains("leaves the depth exactly as it is"))
    check("…hands back the one form the merge cannot read rather than guessing at it",
          commandFile.contains("`auto` on its own")
              && commandFile.contains("tally model auto")
              && commandFile.contains("tally account --auto"))
    check("…tells an agent with nothing to act on to run nothing at all",
          commandFile.contains("Do not run anything and do not open a picker"))
    check("…and hands the user the lines that work without any of it",
          commandFile.contains("tally model <model> [effort]")
              && commandFile.contains("Try `/tally` again"))
    // BOTH REASONS, NEUTRALLY. The body used to say the picker "did not answer this session" and
    // send the user off to restart it - which is right when the server is not connected and wrong
    // when it is: a panel left open past the hook's deadline lets the expansion through with the
    // server perfectly healthy, and telling that user to restart their session is advice for a
    // problem they do not have (Albert, 2026-08-07: 36 minutes on an open dialog).
    check("…and names both ways a prompt can reach it, without diagnosing the wrong one",
          commandFile.contains("it is not connected, or the panel was left")
              && commandFile.contains("restart the session if it keeps happening"))
    // The property that shortening was FOR, asserted rather than assumed.
    check("…and the command file is short enough to answer inside one turn",
          IntegrationsStore.promptCommands.allSatisfy {
              $0.markdown.split(separator: "\n").count < 60
          })
    check("no slash command carries an em dash",
          IntegrationsStore.promptCommands.allSatisfy { !$0.markdown.contains("\u{2014}") })
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

    // `tally account` is the one command here whose main caller is the agent reading this file, run
    // from inside the session it moves - so what the prose has to get right is the TIMING. An agent
    // that believes the move is immediate stops mid-answer waiting for a restart that is waiting
    // for it, and one that believes nothing happened says so to the user.
    check("skill teaches switching this session to a named account",
          currentSkill.contains("tally account \"Claude 4\""))
    check("skill says the move waits for the turn the agent is in",
          skillProse.contains("THE MOVE HAPPENS WHEN THE CURRENT TURN ENDS"))
    check("…and tells the agent to finish answering rather than wait",
          skillProse.contains("Finish your answer as normal"))
    check("…and promises the conversation survives it",
          skillProse.contains("with the conversation intact"))
    check("skill separates the session-scoped move from the persistent profile",
          skillProse.contains("`switch` moves this conversation now, `project set` decides where"))
    // The half an agent will otherwise get wrong, because the command used to work the other way: a
    // switch is not a one-shot nudge that the next idle rebalance may undo. An agent that relays it
    // as one leaves the user re-asking every ten minutes, which is the report this replaced.
    check("skill says the move sticks for the rest of the session",
          skillProse.contains("IT STICKS FOR THE REST OF THE SESSION"))
    check("…and names what stops moving the session",
          skillProse.contains("stops")
              && skillProse.contains("the idle rebalance off a nearly"))
    check("skill hands the user the way back to automatic selection",
          currentSkill.contains("tally account --auto"))
    // The cap contract as it stands now: a cap drops the MODEL and keeps the account, and only an
    // account that can serve nothing hands the session on. The old text promised the opposite (a
    // cap always moved the session and cleared the pin), which would have the agent telling users
    // to re-pin after every cap - advice for a system that no longer exists.
    check("…and states that a cap drops the model rather than taking the pin",
          skillProse.contains("keeps the account and drops to the fallback model Settings declares")
              && skillProse.contains("still serve one COMFORTABLY")
              && skillProse.contains("a window with a few percent left does not count"))
    // The two limits on the other branch, named. An agent that knows only the handoff would call
    // both of them a bug: the model pin is another command's pin deciding this one's outcome, and
    // the wait looks like a hang when it is a decision to sit still until the numbers arrive.
    check("…and names what overrides the handoff, and what makes it wait instead",
          skillProse.contains("`tally model` has pinned the model too (that pin wins")
              && skillProse.contains("about two minutes for a fresh reading of this account")
              && skillProse.contains("for as long as it takes if Tally has stopped publishing "
                                     + "the snapshot")
              && skillProse.contains("Do not tell them to re-pin after a cap"))
    check("skill states the three scopes in order, so the agent can answer which wins",
          skillProse.contains("a session pin beats")
              && skillProse.contains("the project profile, which beats the app's own pin"))
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
          currentSkill.contains("/tally Claude 4"))
    check("…names the bang path and the setting that makes it free too",
          currentSkill.contains("! tally account \"Claude 4\"")
              && skillProse.contains("respondToBashCommands: false"))
    // The escape hatch may not depend on the thing it escapes: a bare `/tally-account` is answered
    // by the hook itself, from the snapshot, with no model in the loop. An agent that still
    // believed it costs a turn would talk the user out of the one command that still works when
    // their model quota is gone.
    check("skill says the bare command offers the fleet without a turn",
          currentSkill.contains("/tally                        # zero turns: the hook OFFERS "
              + "accounts AND models to pick from"))
    check("…and says the picker is native where one can be drawn, and text where it cannot",
          skillProse.contains("a native panel they answer with the arrow keys")
              && skillProse.contains("answered with a second `/tally <name>`"))
    check("…and says why that matters",
          skillProse.contains("an escape hatch may not depend on the thing it is escaping"))
    check("…and keeps the terminal menu out of Claude Code",
          skillProse.contains("that menu is for real terminals only: it never appears under "
              + "Claude Code"))
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
    check("a foreign skill file is never overwritten",
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

    // The other half of the skill integration: the `/tally-account` command file and the prompt hook
    // that answers it without a model turn (switchcommandchecks.swift).
    try runTallyCommandChecks(tmp: tmp, skill: currentSkill)
    // And keeping that hook there once something takes it out (selfhealchecks.swift).
    try runMergeChecks(tmp: tmp)
    // The other half of that release: the skill folder that took `/tally` off the menu it had just
    // been merged onto, and the move that gets an install out of it (mergechecks.swift).
    try runSkillFolderMoveChecks(tmp: tmp)
    try runSelfHealChecks(tmp: tmp, skill: currentSkill)
    // The registration those checks deliberately leave out: the native picker pair, the MCP server
    // it calls, and the gate in front of both (nativepickerchecks.swift).
    try runNativePickerChecks(tmp: tmp, skill: currentSkill)
    // Neither of which can be localized through a key it built for itself (localizationchecks.swift).
    runLocalizationKeyChecks()
    // And the one integration with no row of its own: the tab completion that goes in with the
    // command line tool (completionchecks.swift).
    try runCompletionChecks(tmp: tmp)

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
