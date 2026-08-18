import Foundation

// The text of the Claude Code skill, and the version marker that decides whether an edit to it
// travels. Split from IntegrationsSkill.swift, which is the SURGERY - where the file goes, who
// owns it, how an old install is brought forward - and had grown past the point where the two
// belonged in one file. The split is also the seam the tests already read along: the text and the
// number are pinned to each other (tests/integrations/skillversionchecks.swift), and everything
// about placing the file is asserted separately.
extension IntegrationsStore {
    // MARK: Claude Code skill - agent sessions learn to answer quota questions themselves

    /// Bump when the skill markdown changes; older installs are flagged in Settings and brought
    /// up to date by `autoUpdateSkill()` at the next launch.
    ///
    /// THIS NUMBER IS THE ONLY THING THAT MAKES AN EDIT TRAVEL. An install already on disk is
    /// rewritten when, and only when, its marker differs from this one, so text changed without a
    /// bump reaches every fresh install and nobody who already has the skill: the machines that
    /// keep the old text are exactly the ones that have been running longest. The text and this
    /// number are pinned to each other (tests/integrations/skillversionchecks.swift), so a
    /// forgotten bump is a red suite rather than a silent one.
    nonisolated static let skillVersion = 21

    /// The skill Tally installs into every Claude account's skills folder: Claude Code loads
    /// it on demand and learns to read `tally status --json` instead of guessing at quota.
    /// The comment line under the frontmatter carries the version for detection.
    nonisolated static func skillMarkdown() -> String {
        """
        ---
        name: tally-quota
        description: Check AI subscription quota on this machine with Tally, every Claude and Codex account's 5-hour, weekly, and flagship-model windows, reset times, the pooled fleet view, which account a launch would land on, and the usage advisor's verdict on whether the current accounts cover the workload. Also sets a per-project launch profile (which model this repo runs), moves a running conversation to another account (one the user names or the one with the most headroom), opens, lists and tears down git worktrees, the parallel lines of work a repository runs sessions in, and types a line into a supervised session, this one included, which is how a slash command like /clear or an answer to a prompt gets triggered from inside a turn. Use when the user asks how much quota is left, about rate limits or resets, which account to use, whether to add another account, how usage is trending, before starting heavy multi-agent work, when a project should run a cheaper model than the fleet default, when the user asks to switch this session to a particular account, when the account a session is on runs low mid-conversation, when the user wants to start a parallel line of work on a branch of its own and to clean one up once it is merged, or when a session has to clear or compact its own context, or answer a prompt another session is sitting on.
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
          dry account, the re-pick after a `/clear`, the model-degradation rescue, a pin
          moved in the Tally panel) stops moving it. Say so when you relay the move, because
          it is the difference between
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

        # Typing a line into a session, including this one

        A conversation cannot type into its own composer, so the things that only a
        keystroke triggers (`/clear`, `/compact`, answering a prompt that is sitting on its
        default) are out of reach from inside a turn. `tally session send` is the way in:

        ```
        tally session send "/clear"              # this session, at the end of this turn
        tally session send                       # press Return alone
        tally session send "2" --session 65949   # another session, by its pid
        ```

        Run with no `--session` it addresses the session it is running in, which is what an
        agent clearing its own context wants: say what you have to say first, because the
        line is typed at the first quiet moment after the turn you are in, and that turn is
        what it waits for. So a `/clear` asked for mid-answer lands once that answer is
        finished, not in the middle of it.

        Into your OWN session the command does not wait to find out: it returns having
        queued the line, because this command runs inside the turn the line is waiting for
        and holding it open is the one way to guarantee the line is never typed. Exit 0
        there means queued with nothing refusing it, the printed line says so, and
        `~/.tally/logs/input.log` records what became of it. Do not follow it with a second
        send, a sleep, or a background retry: those were workarounds for the wait and the
        second send is refused as a duplicate.

        A cleared window may reopen on a different account, and that is deliberate. A
        conversation that has just been cleared is empty, so the restart that carries it off
        an account with nothing left costs nothing, and Tally takes that moment: if the
        account is under the nearly-dry line and a sibling has room, the session comes back
        on the sibling a few seconds after the clear. Nothing is lost and nothing needs
        doing about it. It does not happen when the account still has room, when the session
        is pinned (`tally account`), or when somebody is typing in that terminal.

        Subagents and background tasks do NOT hold a send. A session that has finished
        speaking while the agents it dispatched write on is one this line is typed into, so
        an agent still running is not a reason a window cannot be cleared. What does hold
        it: the conversation being mid-turn, a restart of it being pending, somebody typing
        in that terminal, and a session that is not reporting what it is doing at all.

        `--session` names any session this machine supervises, by either of its pids: the
        Claude Code that `tally status --json` reports as `sessions[].pid`, or the Tally
        supervising it. Look the target up in that output by `project` or `worktree` rather
        than by memory, and read its `state` first: `blocked` is a session waiting on a
        person, which is the one this is most often for.

        What it costs to get wrong, and how to tell:

        - Exit 0 means the line was typed and Return was pressed, or (for your own session)
          that it is queued to be typed when this turn ends. The one line on stdout says
          which of the two.
        - Exit 3 means nothing was queued, and the reason is on stderr: the text is over
          200 bytes of UTF-8, the pid names nothing this machine supervises, the session
          never reached a moment the line could be typed at (the refusal names what stood
          in the way), or another send is still in flight there. One send at a time per
          session, and a second is refused rather than replacing the first.
        - Exit 4 means the request was written and nobody answered: within 150 seconds, or
          because that session exited while the line was queued. The message says which.
          Neither says the line was not typed, because neither can know: the supervisor
          types before it writes the receipt. Read `~/.tally/logs/input.log` before
          sending the same line again, or the session may get it twice.
        - Exit 2 is a usage error and exit 1 is something broken here. Read the message
          rather than retrying: a retry answers none of these four.

        Keep the line short. This is for a slash command or an answer to a prompt, not for
        a prompt: anything longer belongs in the conversation itself.

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

        # The line Tally types when the account is running out

        Tally speaks into this conversation once, unasked, when the account under it is
        running low. It looks like this:

        ```
        [tally] account Claude is running low: session 12% · resets 40m, 3 sessions on it.
        Best alternative: Claude 2 (weekly 82% · resets 2d). Wrap up and switch accounts,
        or wait for the reset.
        ```

        It is typed into the composer by the supervisor watching this session, so it
        arrives as a prompt nobody sent. Nothing is broken and nothing has been done to
        the session: it is a fact handed over while there is still room to act on it,
        because Tally moves a session off a dying account only while that session is
        idle, and a conversation in the middle of a work package is exactly the one it
        leaves alone.

        Two answers, and the line carries what you need to choose between them:

        - WRAP UP AND SWITCH. Finish or checkpoint what is in flight (commit, write the
          hand-over), then run `tally account "<the account it named>"`. The move happens
          at the end of the turn and the conversation continues there with its context.
        - WAIT FOR THE RESET, which is right when the reset is close and little else is
          drawing on that window. Both numbers are in the line for that judgement: three
          sessions on one account drain it three times as fast as the percentage reads,
          so "40m" with three sessions on it is not the same runway as "40m" alone.

        `No account has headroom` in place of an alternative means every sibling is as
        spent as this one, and pausing until the reset is the honest answer there.

        It is said once per window cycle per session, so a second line is a new drought
        rather than a repeat, and it is never typed mid-turn: whatever you are writing
        finishes first. Do not reply to it in the conversation, and do not run
        `tally status` to confirm it: the numbers in it were read from the same snapshot
        that command prints.
        """
    }
}
