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
  tally codex [args…]       launch Codex on the best account
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
  tally session type <text> [--submit] [--session <pid>]
                            type <text> into a supervised session's own terminal, exactly as if it
                            had been typed there, and with --submit press Return afterwards. Run it
                            inside the session it is meant for (the agent in that conversation can
                            run it as a tool call); --session names another one by the supervisor
                            pid `tally status --json` lists. It WAITS for the answer: the text is
                            typed at the first moment that session is waiting on you or idle, so a
                            request made mid-turn lands when the turn ends, and nothing is typed
                            while it is working, while it is not reporting what it is doing, or
                            while somebody is typing in that terminal. At most 200 bytes - a slash
                            command, an answer to a prompt - and every one of them is recorded in
                            ~/.tally/logs/input.log
  tally reload [--now]      restart every supervised session at its next idle moment, so edited
                            hooks, skills, and instructions take effect everywhere without
                            visiting each terminal (--now waits only for a 5s quiet gap, so it
                            may land closer to an active turn)
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
