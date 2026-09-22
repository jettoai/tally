// WHAT `tally` CAN DO, in one place, because two surfaces print it and they are not the same event.
// `tally help` ASKS for it, so it answers on stdout and exits 0; a word this binary does not
// recognise gets the same text as a complaint, on stderr and exit 2 (main.swift's dispatch). Shells
// and scripts read exactly that difference, and `tally help | less` needs the first half of it.
//
// A CONSTANT RATHER THAN A `print` INSIDE THE DISPATCH, so that a test can read it: main.swift is
// top-level code that execs on nearly every path, so nothing in it can be linked into an assertion
// harness. What is asserted (tests/statusline) is that this text and the dispatch agree about which
// commands exist, which is the one way this file goes wrong: a command renamed or removed while the
// text goes on describing it.
let tallyUsage = """
usage:
  tally claude [args…]      launch Claude Code on the best account (auto-handoff on cap hit;
                            opt out with --no-handoff or TALLY_AUTO_HANDOFF=0)
  tally claude --account <n>  pin a specific account (label or config-dir name)
  tally claude -w [name]    launch in a git worktree (creates ../<repo>-<name> if needed,
                            shares project memory, runs .tally/worktree-setup.sh); bare -w lists existing
  tally codex [args…]       launch Codex on the best account. An exact `resume <UUID>` with no
                            explicit prompt submits one visible native initialization prompt only
                            when status hooks are installed and Tally launches it through its private
                            TTY. It uses one model turn and subscription quota, is never retried
                            automatically, and does not enforce its instruction or bypass native
                            trust. Caller prompts and all other resume shapes are unchanged.
  tally resume [args…]      continue this directory's latest Claude session on the best account
  tally worktree            overview of the main repo and its worktrees, marking where you
                            are (same as `tally worktree tree`)
  tally worktree root       print the main repo's absolute path, one line for scripts
  tally worktree list       one tab-separated line per worktree, for grep and pipes
  tally worktree remove [name]  tear down a merged worktree (kill its agents, remove the
                            worktree and its branch, keeping their transcripts unless
                            --purge-transcripts); bare picks from a menu
  tally project set --model <model> [--effort <effort>] [--account <name>]
                            declare what THIS project launches (the whole repo, worktrees
                            included): overrides the app's defaults, is overridden by a flag
                            you type, and steers the account pick too - a project on opus
                            stops letting a drained flagship window rule an account out.
                            `show` / `list` / `clear` round it out
  tally status [--json]     show every account's remaining windows (--json: versioned
                            machine-readable report for scripts, hooks, agent skills)
  tally best-dir <provider> print the export line for the best account
  tally launch-dir <provider> shim interface: like best-dir but honours the app's
                            launch policy (off → prints nothing)
  tally add <provider>      log in one more account (next free ~/.claudeN / ~/.codexN,
                            directory created for you). The main account's harness
                            (CLAUDE.md/AGENTS.md, skills, hooks, agents, settings) and
                            conversation record are symlinked in BY DEFAULT: one setup
                            serves every account. Opt out with --no-share
  tally share <provider> <account>|--all
                            put an account you ALREADY have on the main account's harness: the
                            same links `tally add` makes for a new one, applied to a home that is
                            already full. Nothing is deleted - the conversations, inboxes and
                            memory notes are merged into the main account, and anything else in
                            the way is renamed to <name>.local-<date> and left where it is
  tally account <account>   pin THIS session to another account, keeping the conversation: run
                            it inside the session (the agent in it can run it too) and the move
                            happens when the current turn ends. It STAYS there - automatic
                            selection stops moving this session - until `tally account --auto`
                            releases it. A hard cap is answered inside that decision where it
                            can be: the session keeps the account and drops to the fallback
                            model Settings declares, provided this account can still serve one
                            COMFORTABLY (a window with a few percent left does not count).
                            Otherwise it is handed on, which clears the pin and says so -
                            unless `tally model` has pinned the model too (that pin wins: the
                            model is kept, the account is not), or the numbers to decide on are
                            missing, in which case it waits: about two minutes for a fresh
                            reading of this account, and for as long as it takes if Tally has
                            stopped publishing the snapshot or its own pin leaves this session
                            nowhere to go. No project profile is touched: for "this project
                            always runs
                            there", use `tally project set --account`. Inside Claude Code,
                            typing `/tally <account>` does the same without waking a model
                            (installed with the Claude Code skill integration). Also answers to
                            `tally switch`, the name it shipped under
  tally account --auto      release that pin: this session follows automatic account selection
                            again (the project profile, then the app's pin or smart pick)
  tally model <model> [effort]
                            run THIS conversation on that model (and depth) for the rest of its
                            life: it changes when the current turn ends and STAYS, surviving
                            every relaunch - a cap handoff, a reload, an app self-update - which
                            is what Claude Code's own `/model` cannot do, since the supervisor
                            relaunches from its own command line. Name only a model and the
                            effort is left alone. `tally model auto` hands the session back to
                            this project's profile and then the app's default; bare, in a
                            terminal, it shows what is running and offers a menu. Inside Claude
                            Code, `/tally opus xhigh` does the same without waking a model
                            (installed with the Claude Code skill integration)
  tally message <claude|codex> [<text> | --file <absolute-file>]
                              [--project <dir-or-name> | --session <pid>] [--dry-run]
                            hand one message to a session's own native transport: it appears in that
                            conversation as a user message, and no key is pressed. Addressed like
                            `tally type` - this session by default, another by pid or by launch
                            directory or bare project name - and a session of the other kind is
                            refused. For Claude the socket and transcript UUID are looked up in the
                            same pair `tally status --json` publishes; a session publishing neither
                            is refused rather than guessed at. Codex takes an explicit address only
                            (nothing publishes which home and thread a supervised Codex session
                            writes to): `tally message codex --home <absolute-home> --thread <UUID>`.
                            The Claude address can be written out too: `tally message claude
                            --socket <absolute-socket> --session <UUID>`. Message: one argument or
                            --file, never both, nonempty UTF-8 of at most 65536 bytes, and Codex
                            rejects NUL bytes. A written frame is not a recipient receipt
  tally harness tools install|remove|status [--source-home <Claude-home>] [--target-home <Codex-home>]
                            install or remove the workflow skill and inbox reminders for both providers.
                            Optional --skills-root and --state-root take absolute paths. Projects are
                            adapted separately when the skill runs in an assistant session.
  tally harness plan|status|install|remove [--scope user|project]
                            install concise Codex guidance; no source hooks or skill links by default.
                            Plan/install accept repeated --hook <plan-id> and --skill <name> for opt-in.
                            Existing selections are preserved; remove before changing them. Optional --source-home,
                            --target-home, --skills-root, and --state-root take absolute paths.
                            Project scope requires --project <absolute-checkout>. Inspect plan and use
                            --confirm-git-visible for reviewed git-visible writes. Review native /hooks trust.
                            Status reports drift,
                            not behavioral parity. Remove preserves unrelated configuration.
  tally harness migrate [scope/location options] [--drop-hook <installed-id>] [--drop-skill <name>]
                            Preview selective retirement; repeat selectors, then add --apply to execute.
                            Preserves retained hooks and unrelated edits. Project writes need --confirm-git-visible.
  tally harness record --file <absolute-result.json> [--state-root <absolute-directory>]
                            retain caller-reported model, oracle, quality, duration, and cost evidence.
  tally inbox list|post|claim|read|ack|release|recover|status --provider claude|codex
                            address a mailbox with --home <absolute-home> --project <absolute-checkout>.
                            Use --file for post, --id and --owner for claim, then --nonce for read,
                            ack, and release. List supports --all-homes. Recover requires --id,
                            --owner, --previous-owner, --reason, and --confirm-abandoned after checking
                            the previous session. Optional --root sets the mailbox directory.
                            Post is not a receipt. Message contents are external-unverified data.
  tally type <claude|codex> [<text>] [--project <dir-or-name> | --session <pid>]
                            the same send as `tally session send`, addressed provider-first: the
                            word after the verb says which kind of session is meant, and one that
                            turns out to be the other kind is refused rather than typed into.
                            `tally send` is the earlier spelling of this and still works.
                            --project takes a bare project name (the last component of a launch
                            directory, matched exactly) as well as a path. There is no --provider
                            flag here, the position having answered that. `tally message
                            <provider>` is the other thing and not a synonym: this one types into
                            the terminal and presses Return, so it can answer a dialog and run a
                            slash command; that one hands a message to the native transport, so it
                            touches no keyboard and can do neither. Neither is a receipt
  tally session send [<text>] [--session <pid> | --project <dir-or-name>]
                            send <text> to one exact supervised terminal and press Return. For
                            Claude, no text presses Return alone to answer a prompt on its default.
                            Run it inside that session, or name its exact supervisor or terminal
                            child pid from `tally status --json`; it never chooses another terminal
                            or the frontmost window. --project looks that pid up instead, from the
                            directory a session was launched in or from a bare project name matched
                            against the last component of one, and refuses rather than guesses when
                            the answer is not exactly one session. Claude retains send and clear
                            behavior. Codex advertises only send after a trusted native binding,
                            exact terminal, and completed native turn are observed. It accepts
                            nonempty plain prompts, not slash commands or bare Return. It queues
                            while Codex is working, blocked, unknown, waiting for permission, or a
                            human may be typing, and expires after 15 minutes. Quiet unexplained
                            input is refused: send a real prompt in that exact Codex session, wait
                            for it to finish, then retry. Delivery needs Codex's matching new user
                            message; a terminal write without it is unconfirmed and never retried
                            automatically, including custom Enter key mappings. A monitoring-only
                            Codex session is refused: exit it and use `tally codex resume <UUID>`.
                            Its qualifying no-prompt exact resume needs no manual bootstrap, but
                            human startup input remains draft-held. Codex still advertises send only
                            after a trusted binding, exact terminal, completed native turn, and
                            receipt. Text is limited to 200 UTF-8 bytes; served or refused outcomes
                            go to ~/.tally/logs/input.log.
                            `tally session clear` is a distinct Claude control, not a Codex action
  tally session clear [--session <pid>]
                            close a session's context window: the same `/clear`, queued on the same
                            terms, with one thing typing cannot do. At the moment it lands, if the
                            account under that session is nearly dry and a sibling has room, the
                            session is REOPENED there instead - restarted with no context, which is
                            what a clear is - rather than cleared where it stands. A cleared window
                            is empty, so that restart costs nothing, and it is the one moment a busy
                            session can be moved off a dying account for free. It stays put when the
                            account has room, when the session is pinned, and when it is waiting on
                            a person. Use `session send "/clear"` for the plain typing of those six
                            characters
  tally reload [--now]      restart supervised Claude sessions at their next idle moment, so edited
                            hooks, skills, and instructions take effect everywhere without
                            visiting each terminal (--now waits only for a 5s quiet gap, so it
                            may land closer to an active turn)
  tally keychain-repair     heal the Claude Code Keychain items Tally 0.64.0 left needing a
                            consent dialog: it rewrote their partition list, so `security`
                            (which Claude Code, this launcher and the app's usage polling all
                            read through) started asking. Every launch does this too; the
                            command is here for a machine you want to fix without one. Prints
                            one line per item and never prints a value
  tally update              check for app updates now (opens the update window)
  tally completion zsh      print the zsh tab-completion script: add
                            `eval "$(tally completion zsh)"` to ~/.zshrc, or write it to a
                            file named _tally in a directory on your fpath
  tally help                print this list (also --help, -h)
"""

/// The one line `tally status` ends on, and the reason it exists: bare `tally` IS `tally status`, so
/// the fleet report is what somebody typing the name gets, and until this line it was also all they
/// got - nothing on screen said the binary had any other command (owner report, 2026-08-10).
///
/// One line naming one command rather than a list, because it sits under a report people read many
/// times a day: the place to spend their attention is the help text they can now find, not the
/// status they came for.
let tallyStatusHelpHint = "`tally help` lists every command"
