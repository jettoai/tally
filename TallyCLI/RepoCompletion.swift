// The two subcommands whose subject is the REPOSITORY somebody is standing in: `tally worktree`,
// which opens and tears down its parallel lines, and `tally project`, which declares what every
// launch inside it runs.
//
// A FILE OF THEIR OWN for the reason HarnessCompletion.swift is one, and Completion.swift had grown
// past the size a file in this repo may be. Both of these are completed by a STATE MACHINE rather
// than by a flag list - a verb of their own first, then that verb's flags - which is several times
// the size of the one-line branches the rest of the dispatch takes, and none of it is about the
// launcher the rest of that script is about.
//
// Interpolated back where they were written, above `_tally` and beside the harness pair, so the
// script zsh reads is the one this file used to print.
let tallyRepoCompletionZsh = #"""
_tally_worktree_command() {
  local curcontext="$curcontext" state line
  local -a subcommands
  subcommands=(
    "tree:the main repo and its worktrees as one overview, marking where you are"
    "root:print the main repo absolute path, one line for scripts"
    "list:one tab-separated line per worktree, for grep and pipes"
    "remove:tear down a merged worktree, killing its agents and deleting its branch"
  )
  _arguments -C '1: :->sub' '*:: :->args'
  case $state in
    (sub) _describe -t worktree-commands "worktree command" subcommands ;;
    (args)
      case $words[1] in
        (remove)
          # --keep-transcripts is deliberately not offered: it is accepted for the scripts that
          # still carry it, and it asks for what happens anyway.
          _arguments \
            "--force[remove it even though its branch is not merged]" \
            "--purge-transcripts[delete the conversations its agents wrote as well]" \
            ":worktree:_tally_worktrees"
          ;;
      esac
      ;;
  esac
}

_tally_project_command() {
  local curcontext="$curcontext" state line
  local -a subcommands
  subcommands=(
    "set:declare what this project launches, the whole repo including its worktrees"
    "show:this directory's profile and the app defaults it overrides"
    "list:every project with a profile, one tab-separated line per provider"
    "clear:drop this project's profile, or one provider's half of it"
  )
  _arguments -C '1: :->sub' '*:: :->args'
  case $state in
    (sub) _describe -t project-commands "project command" subcommands ;;
    (args)
      case $words[1] in
        (set)
          # Which provider's accounts may be named depends on what this line says, and THE WHOLE
          # LINE says it: `runProjectSet` reads the flag with `optionValue`, which scans the entire
          # argument list and takes the first occurrence, so `--provider codex` written AFTER the
          # account is a perfectly legal Codex profile. Reading only what is left of the cursor
          # offered claude accounts to a line that had already said codex, and the command then
          # refuses the name it was handed (review, 2026-08-11). First match and a claude default
          # for a dangling flag, because that is what `optionValue` answers.
          local provider=claude i
          for (( i = 1; i <= $#words; i++ )); do
            [[ $words[i] == --provider ]] && { provider=${words[i+1]:-claude}; break }
          done
          _arguments \
            "--model[the model every launch in this project runs]:model:_tally_models" \
            "--effort[the depth those launches run at]:effort:_tally_efforts" \
            "--account[the account those launches land on]:account: _tally_accounts $provider" \
            "--provider[which CLI this profile is for]:provider:_tally_providers"
          ;;
        (clear)
          _arguments \
            "--provider[clear one provider's half only]:provider:_tally_providers"
          ;;
      esac
      ;;
  esac
}
"""#
