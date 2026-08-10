import Foundation

// The Claude Code skill integration - split from IntegrationsStore.swift for file size. The
// stored `skillStatus` property stays in the store (extensions cannot add stored properties);
// everything else about the skill (content, discovery, surgery) lives here.
extension IntegrationsStore {
    // MARK: Claude Code skill - agent sessions learn to answer quota questions themselves

    /// Bump when the skill markdown changes; older installs are flagged in Settings and brought
    /// up to date by `autoUpdateSkill()` at the next launch.
    nonisolated static let skillVersion = 15

    /// The skill Tally installs into every Claude account's skills folder: Claude Code loads
    /// it on demand and learns to read `tally status --json` instead of guessing at quota.
    /// The comment line under the frontmatter carries the version for detection.
    nonisolated static func skillMarkdown() -> String {
        """
        ---
        name: tally-quota
        description: Check AI subscription quota on this machine with Tally, every Claude and Codex account's 5-hour, weekly, and flagship-model windows, reset times, the pooled fleet view, which account a launch would land on, and the usage advisor's verdict on whether the current accounts cover the workload. Also sets a per-project launch profile (which model this repo runs), moves a running conversation to another account (one the user names or the one with the most headroom), and opens, lists and tears down git worktrees, the parallel lines of work a repository runs sessions in. Use when the user asks how much quota is left, about rate limits or resets, which account to use, whether to add another account, how usage is trending, before starting heavy multi-agent work, when a project should run a cheaper model than the fleet default, when the user asks to switch this session to a particular account, when the account a session is on runs low mid-conversation, or when the user wants to start a parallel line of work on a branch of its own and to clean one up once it is merged.
        ---

        <!-- tally-skill v\(skillVersion), managed by Tally.app (Settings -> Integrations); safe to delete -->

        # Checking quota with Tally

        Run:

        ```
        tally status --json
        ```

        The output is a versioned, additive-only contract (`version: 1`). How to read it:

        - `accounts[]`: one entry per account. `sessionRemaining` (the 5-hour window),
          `weeklyRemaining`, and `modelRemaining` (the flagship window named by
          `modelWindowName`, e.g. Fable) are percent left, 0-100; each pairs with a
          `...ResetsAt` ISO 8601 timestamp. A missing key means the provider does not
          report that window.
        - `best: true` marks the account `tally claude` / `tally codex` would launch right
          now (a manual pin is honoured); `pinned` marks the pin itself. `launchHome` is
          that account's config directory (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`).
        - `fleetPools.<provider>[]` is the pooled view across accounts, leading pool first
          (a flagship pool like Fable may lead the weekly pool). Pool units differ from
          account percents: `remaining` and `capacity` count one account's full weekly
          window as 100, so capacity 200 means two accounts. `dryAt` forecasts when the
          pool runs dry at the current pace; `sustainable: true` means the pace holds to
          the reset.
        - `advisor.<provider>` is the usage advisor's verdict, computed from the burn-rate
          history the app records rather than from the current percentages. The key is
          absent when there is no history yet (the app has not been running long enough):
          say so instead of inventing a trend.
        - Top-level `stale: true`, or a non-zero exit, means the Tally app is not running
          and the numbers are old: say so rather than quoting them as current.

        Reading the advisor:

        - `verdict` is one of three values. `collecting` means there is too little history
          to judge yet, so draw no conclusion from it. `addAccount` means weekly demand or
          starved time crossed the trigger, so another account would pay off. `sufficient`
          means the current accounts cover the demand.
        - `headline` is a finished English one-liner for that verdict, safe to quote as is.
        - The numbers behind it: `demandPerWeek` is the pooled weekly burn in account-weeks
          (1.0 is one full account's weekly quota spent per week, so 2.4 needs three
          accounts), `starvedHoursPerWeek` is how many hours a week every account in a pool
          sat at zero quota at once, `activeBurnPerHour` is percent of a window spent per
          hour of actual work, and `daysOfData` is how much history the reading rests on.
        - `tierDemands[]` splits `demandPerWeek` by the plan each account is on (`plan`,
          `demandPerWeek`, `accountCount`), largest first, and always adds back up to it.
          Read it whenever it holds more than one plan: accounts are interchangeable only
          within a tier, so "0.9 on Pro and 1.0 on Team" is the answer and their 1.9 is
          not a plan anyone can buy. A snapshot that names no plan yields ONE tier that
          carries the whole figure with its `plan` key left out entirely, not an empty
          list, so the array can always be summed; the list is empty only when there are
          no weekly samples at all.

        Guidance:

        - Answer quota questions from this data directly; include reset times when a
          window is low.
        - For "which account should I use", prefer the account with `best: true`;
          launching through `tally claude` / `tally codex` applies the same choice
          automatically.
        - For "is my quota enough", "should I add an account", or "how is my usage
          trending", answer from `advisor` and quote its `headline`: the account
          percentages describe only this moment, the advisor is the trend. When the verdict
          is `collecting`, say the app is still gathering history instead of guessing. With
          more than one plan in `tierDemands`, name the tier the demand is on rather than
          answering "add an account" in the abstract.
        - Before heavy multi-agent or long autonomous work, check the binding window (the
          smallest remaining among session, weekly, and model) and warn when it is nearly
          drained.
        - If the `tally` command is missing, the Command line tool integration in Tally's
          Settings installs it.

        # A per-project launch profile

        Most projects want the flagship model. Some do not, and those are exactly the ones
        whose sessions should stop spending the flagship window. When the user says
        something like "this project can run on opus" or "stop burning Fable here", write
        it down instead of remembering it:

        ```
        tally project set --model opus            # run from inside the project
        tally project set --model opus --effort high
        tally project set --account "Claude 2"    # pin this project to one account
        tally project show                        # what this directory runs, and what it overrides
        tally project clear                       # drop the profile
        ```

        What it does:

        - The profile belongs to the whole repository, worktrees included, so a parallel
          line launched with `tally claude -w <name>` inherits it.
        - Precedence is a flag you type, then the project profile, then the app defaults.
          Typing `--model haiku` still wins for that one launch.
        - It steers the ACCOUNT pick, not only the flag. Tally scores an account on the
          model the session will actually run, so under an opus profile an account whose
          Fable window is drained is eligible again. That is the point: the projects that
          need Fable keep the accounts that still have it.
        - `tally status --json` reports the profile of the directory it runs in as a
          top-level `projectPolicy` (`path`, and `providers.<provider>` with `model`,
          `effort`, `accountID`); the key is absent when the directory has no profile. The
          `best` flags in the same output already reflect it.

        # The model this conversation runs

        Tally adopts Claude Code's own `/model`. When the user changes the model that way in a
        supervised session, the supervisor reads the choice out of the transcript and pins the
        session to it, so the model survives every relaunch Tally makes of its own accord (an
        account handoff, a reload, an app self-update) instead of being replaced by the one the
        session was launched with. It is no longer read as a server-side degradation to be undone.

        So when the user says they already changed the model themselves, believe them and check
        rather than re-doing it:

        ```
        tally model                  # what this session runs, and which layer decided it
        ```

        `tally model <model> [effort]` is for what the picker cannot do: naming a model without
        opening it, setting one as a tool call, pinning an EFFORT, and `tally model auto` to release
        the pin (the only way out, including out of an adopted one). The adoption needs one served
        turn to confirm it, so immediately after `/model` the reading still describes the previous
        answer; that is stated in the output rather than guessed at.

        # Moving this session to a named account

        When the user says "switch to Claude 4", "move this session to my other account",
        or "this one is nearly dry, hop over", run it from inside the session:

        ```
        tally account "Claude 4"      # pin this session there
        tally account --auto          # release the pin, follow automatic selection again
        ```

        The name is matched against the account labels and config-dir names `tally status`
        shows, case-insensitively.

        THE USER HAS A CHEAPER WAY, and it is worth telling them about the first time they
        ask you to move accounts. Tally installs a `/tally` command with this skill, and a
        prompt hook answers it before any model is woken:

        ```
        /tally Claude 4               # zero turns: the hook queues the move and stops there
        /tally                        # zero turns: the hook OFFERS accounts AND models to pick from
        /tally opus high              # zero turns: a model instead, since the line names one
        ! tally account "Claude 4"    # zero turns too, under respondToBashCommands: false
        ```

        Note the second line: `/tally` with nothing named does NOT reach a model. The hook
        reads the snapshot itself and offers every account with its remaining windows,
        marking the one with the most headroom, beside the models this session can run: on a
        recent Claude Code that is a native panel they answer with the arrow keys, and where
        one cannot be drawn it is the same reading as text, answered with a second
        `/tally <name>`. Either way, no turn. That matters because the usual reason to move
        accounts is that this one has no model left to answer with, and an escape hatch may
        not depend on the thing it is escaping.

        The `!` line is the fallback worth naming when the command is not installed: it
        runs in their shell, and with `respondToBashCommands: false` in settings its output
        never goes to a model at all. In a terminal of their own, `tally account` with no
        argument opens an arrow-key picker over the same fleet reading (that menu is for
        real terminals only: it never appears under Claude Code, whose screen it would
        fight).

        Prefer that phrasing when they ask "how do I switch accounts": a move that costs a
        turn to ask for is a move that costs part of what it saves. You cannot type a slash
        command yourself, so when THEY ask YOU to move the session, run `tally account` as
        the tool call above.

        When the user asks to switch WITHOUT naming an account ("move me to whichever has
        room", "switch accounts"), read the fleet and let them choose rather than choosing
        for them: run `tally status`, then ask with AskUserQuestion, one option per Claude
        account, the account's label as the option and its remaining session, weekly and
        model windows as the description, the account with the most headroom first and
        marked Recommended. Then run `tally account` on the one they picked. This is the
        path for a request made IN CONVERSATION, where a turn is already running and the
        picker is the fastest way to answer it; `/tally` typed by the user is the free path
        and needs nothing from you.

        What happens next, and what to tell the user:

        - THE MOVE HAPPENS WHEN THE CURRENT TURN ENDS, not while you are running the
          command: the request waits for the session to stop writing, which includes the
          tool call you just made. Finish your answer as normal. The session then restarts
          on the named account with the conversation intact, so the next thing the user
          types is answered from the same context on the new account.
        - IT STICKS FOR THE REST OF THE SESSION. The account named is where this
          conversation stays: automatic account selection (the idle rebalance off a nearly
          dry account, the model-degradation rescue, a pin moved in the Tally panel) stops
          moving it. Say so when you relay the move, because it is the difference between
          this and asking again in ten minutes.
        - The pin is the user's to release (`tally account --auto`), and a hard cap no longer
          takes it from them. A hard cap is answered inside that decision where it can be: the
          session keeps the account and drops to the fallback model Settings declares, provided
          this account can still serve one COMFORTABLY (a window with a few percent left does not
          count). Otherwise it is handed on, which clears the pin and says so on the terminal -
          unless `tally model` has pinned the model too (that pin wins: the model is kept, the
          account is not), or the numbers to decide on are missing, in which case it waits: about
          two minutes for a fresh reading of this account, and for as long as it takes if Tally
          has stopped publishing the snapshot or its own pin leaves this session nowhere to go.
          Do not tell them to re-pin after a cap: unless the terminal said the session was handed
          on, the pin is still there.
        - No project profile is touched either way, and the pin dies with the session.
        - It exits 0 having queued the move, or non-zero having changed nothing: no such
          account, a name that fits SEVERAL accounts (the message lists them - type one of those
          exactly), or a session nothing is supervising (launched bare, with `--no-handoff`, or
          with an `--account` pin). Read the message rather than assuming it worked.
        - When the session's supervisor is from another build, the move waits for it to
          replace itself at an idle moment; the command says so. Relay that rather than
          running the command again, which only queues the same move twice.
        - Switching to a drained account is allowed and warned about: an explicit
          instruction outranks the quota check (up to the cap above).

        For "this project should ALWAYS run on that account", write it down instead:
        `tally project set --account "Claude 4"` (the section above). The two are different
        instructions: `switch` moves this conversation now, `project set` decides where
        future launches in this repo land. They stack in that order, so a session pin beats
        the project profile, which beats the app's own pin or smart pick.

        # Parallel lines of work on the same repository

        A worktree is a second checkout of one repository on its own branch: its own
        directory, its own sessions, one shared history. Tally owns the whole life cycle:

        ```
        tally claude -w <name>        # open, or rejoin, the line named <name>
        tally worktree list           # one line per line of work, for reading and grep
        tally worktree root           # the main repo's path, from anywhere inside it
        tally worktree remove <name>  # tear one down once its branch is merged
        ```

        Opening one (`-w`) creates `<repo>-<name>` beside the main repository the first
        time and reuses it afterwards, shares the project's memory into it, and runs the
        repo's `.tally/worktree-setup.sh` if it has one. The project profile above belongs
        to the repository, so a parallel line launches on the same model without being
        told again.

        `tally worktree list` prints one tab-separated line per worktree: branch, age,
        a `*` when the working tree is dirty, the live agent count (`2 agents`, or `-`
        when none are running there), and the last commit subject.

        Before running `remove`, four things worth knowing, because it is the one
        irreversible command here:

        - It CLOSES the sessions in that worktree. Every agent process whose working
          directory is the worktree is signalled, then the worktree directory and its
          branch are deleted. Read the agent column of `tally worktree list` first and say
          what is there: `-` means nobody is working in it, `2 agents` means closing it
          ends two sessions. The command refuses on its own while those agents are mid
          turn, and `--force` is what overrides that refusal.
        - `<name>` is the BRANCH, the first column of `tally worktree list`, not the
          directory name: the directory carries a `<repo>-` prefix that this command does
          not want. Always pass it, since a bare `tally worktree remove` opens an
          interactive menu that an agent cannot answer.
        - An unmerged branch is refused, naming how many commits would be lost. Merge it
          from the main repo first; `--force` is for when losing them is the intent.
        - Transcripts are KEPT. The conversations that ran in the worktree stay readable
          and keep counting toward the repository's usage, which is the row the app files
          them under, and they go on doing so after the worktree directory itself is gone.
          `--purge-transcripts` deletes them and nothing else does, so offer it rather
          than assuming it; passing it together with `--keep-transcripts` is refused
          rather than guessed at.

        Run it from the main repository: removing the worktree the current directory sits
        in is refused, which is the right answer and not a bug to work around.

        # When an account runs low mid-conversation

        `tally resume` continues THIS directory's most recent Claude conversation on
        another account:

        ```
        tally resume
        ```

        It finds the newest session transcript for the current directory across all
        accounts, picks the best OTHER eligible account by the same scoring `tally claude`
        uses, copies the transcript over when the accounts do not share a projects tree
        (never overwriting), and launches `claude --resume <id>` there. With no other
        eligible account it says so and resumes on the account the session is already on.
        Suggest it when the current account's binding window is nearly drained and the
        conversation is worth keeping; a session launched through `tally claude` also hands
        itself off automatically when it actually hits a cap. Use `tally account` instead
        when the user names the account to move to: `resume` picks one by headroom.
        """
    }

    /// One SKILL.md per discovered claude home, deduplicated by physical file (shared setups
    /// symlink the same skills tree everywhere - one edit must not be counted N times).
    private static func claudeSkillFiles() -> [URL] {
        var seen = Set<String>()
        return ClaudeAccounts.discover().compactMap { account -> URL? in
            guard let home = account.launchHome else { return nil }
            let url = URL(fileURLWithPath: home).appendingPathComponent("skills/tally/SKILL.md")
            return seen.insert(url.resolvingSymlinksInPath().path).inserted ? url : nil
        }
    }

    /// Every path the skill can actually live at: the discovered accounts' files plus every path
    /// the manifest remembers. Accounts that logged out since install are no longer discovered,
    /// but their SKILL.md is still on disk, so both remove and the auto-update must see it -
    /// otherwise an orphan lies in wait for a later re-login.
    static func installedSkillFiles() -> [URL] {
        var files = claudeSkillFiles()
        for path in manifestPaths("claudeSkill") where !files.contains(where: { $0.path == path }) {
            files.append(URL(fileURLWithPath: path))
        }
        return files
    }

    /// Whether a skills file on disk is one Tally wrote. The one predicate behind "is the skill
    /// installed here", asked by the launch-time update and by the settings self-heal, which must
    /// agree: a heal that judged installation differently would put hooks back into a home the user
    /// had uninstalled from.
    static func skillFileIsOurs(_ contents: String) -> Bool { contents.contains("tally-skill v") }

    /// Those of `files` that exist and are ours. Absence is the signal the self-heal reads as "the
    /// user does not want this here", so it is asked of the file rather than of the manifest, which
    /// records intent from install time and not the state now.
    static func oursAmong(_ files: [URL]) -> [URL] {
        files.filter {
            (try? String(contentsOf: $0, encoding: .utf8)).map(skillFileIsOurs) == true
        }
    }

    /// The paths the manifest records for one component; empty when the entry, or the file, is
    /// absent or unreadable. Internal for the unit tests.
    static func manifestPaths(_ component: String, manifest url: URL = manifestURL) -> [String] {
        let manifest = (try? JSONSerialization.jsonObject(
            with: (try? Data(contentsOf: url)) ?? Data())) as? [String: Any]
        return ((manifest?[component] as? [String: Any])?["paths"] as? [String]) ?? []
    }

    static func detectSkill() -> Status {
        let files = claudeSkillFiles()
        guard !files.isEmpty else { return .notInstalled }
        var ours = 0, older = 0, foreign = 0
        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if content.contains("tally-skill v\(skillVersion)") { ours += 1 }
            else if content.contains("tally-skill v") { older += 1 }
            else { foreign += 1 }
        }
        if foreign > 0 { return .broken(L("A different skill occupies skills/tally")) }
        if older > 0 { return .broken(L("Older version installed")) }
        if ours == 0 { return .notInstalled }
        guard ours == files.count else { return .broken(L("Not installed for every account")) }
        // The slash commands and their prompt hooks ship WITH the skill, so an install carrying
        // only the SKILL.md - or carrying one command but not a second the app has since gained -
        // is an install from an older app: the same "bring it up to date" answer the version marker
        // gets, and `autoUpdateSkill()` does exactly that at the next launch.
        return Self.promptCommandsAreCurrent(forSkillFiles: files, population: Self.claudeHomes())
            ? .installed : .broken(L("Older version installed"))
    }

    func installSkill() {
        guard guardNotDev() else { return }
        lastError = nil
        let files = Self.claudeSkillFiles()
        do {
            for file in files { _ = try Self.upsertSkill(in: file) }
            recordManifest("claudeSkill", paths: files.isEmpty ? nil : files.map(\.path))
        } catch {
            lastError = error.localizedDescription
        }
        // Outside the do/catch above on purpose: a skills folder that refused the SKILL.md says
        // nothing about the commands folder next to it, and this call reports its own failures.
        syncPromptCommands(forSkillFiles: files)
        refresh()
    }

    func removeSkill() {
        guard guardNotDev() else { return }
        lastError = nil
        let files = Self.installedSkillFiles()
        do {
            for file in files { try Self.removeSkill(in: file) }
            recordManifest("claudeSkill", paths: nil)
        } catch {
            lastError = error.localizedDescription
        }
        removePromptCommands(forSkillFiles: files)
        refresh()
    }

    /// Launch-time upkeep: a skill left behind by an older app version is brought to the current
    /// one, so the agent guidance ships with the app instead of waiting for someone to notice the
    /// "Older version installed" row in Settings. Deliberately narrow, and nothing here asks the
    /// user first: an absent file stays absent (not having the skill is a choice), a foreign
    /// skills/tally is never touched, and a failure only lands in `lastError`.
    func autoUpdateSkill() {
        // Shared state belongs to the INSTALLED release app; not `guardNotDev()`, whose user-facing
        // error has no place in a task that runs silently at launch. A locally built Release is
        // caught here too (`isUnshipped`): it wears the release bundle id, so nothing else about it
        // says it must not write, and what it wrote was a hook path inside a build tree.
        guard !BuildVariant.isUnshipped else { return }
        let result = Self.autoUpdateSkills(in: Self.installedSkillFiles())
        // Before the early return: when EVERY update failed (an unwritable skills folder) there is
        // nothing to record, but the failure is exactly what Settings must be able to show.
        if let error = result.error { lastError = error }
        // The command files and their hooks follow the SKILL.md's PRESENCE, not their own: an
        // install from an app that predates one has neither, and "an absent file stays absent" would
        // keep it that way forever. Run whether or not the skill itself needed rewriting, because a
        // hook can also go stale on its own (the app moved, so its binary path did).
        let commandsChanged = result.ours.isEmpty ? false
            : syncPromptCommands(forSkillFiles: result.ours)
        guard result.updated > 0 || commandsChanged else { return }
        recordManifest("claudeSkill", paths: result.ours.map(\.path))
        refresh()
    }

    /// The auto-update over a given file set, split out so it is testable without discovering the
    /// machine's real claude homes. Rewrites every file that exists AND carries our marker AND is
    /// not already current; returns the files that are ours (the install set the manifest should
    /// record), how many were rewritten, and the first failure if any.
    static func autoUpdateSkills(in files: [URL]) -> (ours: [URL], updated: Int, error: String?) {
        var ours: [URL] = []
        var updated = 0
        var failure: String?
        for file in files {
            // Absent, unreadable, or not ours: leave it exactly as it is.
            guard let existing = try? String(contentsOf: file, encoding: .utf8),
                  skillFileIsOurs(existing) else { continue }
            ours.append(file)
            guard !existing.contains("tally-skill v\(skillVersion)") else { continue }
            do {
                if try upsertSkill(in: file) { updated += 1 }
            } catch {
                failure = failure ?? error.localizedDescription
            }
        }
        return (ours, updated, failure)
    }

    /// Writes the skill into one skills file. A file that is not ours is never clobbered -
    /// a user's own skills/tally survives untouched (install reports the conflict instead).
    /// Existence and readability are distinct on purpose: an unreadable or non-UTF-8 file
    /// throws here (never overwrite what could not be inspected); only a truly absent file
    /// is a fresh install. Returns true when the file changed. Internal for the unit tests.
    static func upsertSkill(in file: URL) throws -> Bool {
        if FileManager.default.fileExists(atPath: file.path) {
            let existing = try String(contentsOf: file, encoding: .utf8)
            if existing == skillMarkdown() { return false }   // already ours - idempotent
            guard existing.contains("tally-skill v") else {
                throw NSError(domain: "tally", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: L("A different skill occupies skills/tally"),
                ])
            }
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try skillMarkdown().write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    /// Reverses `upsertSkill`: removes only a skill that IS ours, then clears the skill
    /// folder when nothing else lives inside. Anything not ours is left untouched.
    static func removeSkill(in file: URL) throws {
        guard let existing = try? String(contentsOf: file, encoding: .utf8),
              existing.contains("tally-skill v") else { return }
        try FileManager.default.removeItem(at: file)
        let dir = file.deletingLastPathComponent()
        if let leftovers = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
           leftovers.isEmpty {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
