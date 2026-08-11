import Foundation

// `tally completion zsh` - the shell completion script, and the third way into what this binary
// can do. `tally help` answers somebody who already knows there is a list; the line at the foot of
// `tally status` tells them there is one; this one answers the hand that never asks, because the
// list arrives at the cursor of the command they were already typing.
//
// A CONSTANT RATHER THAN A `print` IN THE DISPATCH, for the reason Usage.swift gives for the usage
// text: main.swift is top-level code that execs on nearly every path, so nothing in it can be
// linked into an assertion harness. What the tests pin (tests/statusline) is that this script and
// the dispatch agree about which commands exist, because that is the one way this file goes wrong:
// a command renamed or removed while the completion goes on offering it, which is worse than
// offering nothing at all - a suggested word that the binary answers with usage and exit 2.
//
// ZSH ONLY, on purpose. This machine's shell is zsh, and a bash script nobody runs is a second
// list to keep in step with the first.
//
// The lists below are STATIC where the answer belongs to this binary (its subcommands, its own
// flags, the names a launch axis takes) and ASKED where the answer belongs to this machine (which
// accounts exist, which worktrees exist). The static half is interpolated from the same constants
// the commands themselves validate against, so there is no second copy to drift.
let tallyCompletionZsh = #"""
#compdef tally

# Tab completion for tally. Printed by `tally completion zsh`; install it either way:
#
#   eval "$(tally completion zsh)"                 in ~/.zshrc, after compinit has run
#   tally completion zsh > "${fpath[1]}/_tally"    picked up by compinit through the tag above
#
# EVERYTHING ASKED OF THE MACHINE DEGRADES TO NO SUGGESTIONS, never to an error: a Tab press lands
# in the middle of a line somebody is typing, so a helper that prints a diagnostic there has broken
# the thing it was helping with. The binary it would ask can be absent from PATH, mid-update, or
# newer than this script, and a stale copy of this file can outlive the binary entirely.

_tally_bin() {
  # The binary BEING COMPLETED rather than whatever `tally` in PATH resolves to: somebody
  # completing /opt/tally/tally has to be answered by that one. `_tally` captures the command word
  # before `_arguments` shifts `words` out from under these helpers.
  local bin=${_tally_command:-tally}
  command -v -- "$bin" > /dev/null 2>&1 || return 1
  print -r -- "$bin"
}

_tally_json_field() {
  # Every value of one string field in a JSON document, one per line, using shell builtins only:
  # jq is not on every machine, and /usr/bin/python3 on a Mac without the command line tools opens
  # an installer dialog, which is not a thing a Tab press may do. A value carrying an escaped quote
  # would come out truncated; the one field read here (an account label) has none.
  #
  # THE SPACING IS SKIPPED RATHER THAN ASSUMED. `status --json` is pretty-printed, so a key and its
  # value read `"label" : "Claude"`, and a reader keyed on `"label":"` finds nothing whatsoever in
  # it - which on screen is indistinguishable from a machine with no accounts. Found by running
  # this against the real report rather than by reading it.
  local field=$1 rest=$2 needle
  local -a out
  needle="\"$field\""
  while [[ $rest == *$needle* ]]; do
    rest=${rest#*$needle}
    while [[ $rest == [[:space:]]* ]]; do rest=${rest#?}; done
    [[ $rest == :* ]] || continue
    rest=${rest#:}
    while [[ $rest == [[:space:]]* ]]; do rest=${rest#?}; done
    # Not a string value (a number, an object, or a key of the same name nested somewhere else):
    # skipped rather than guessed at.
    [[ $rest == \"* ]] || continue
    rest=${rest#\"}
    out+=("${rest%%\"*}")
    rest=${rest#*\"}
  done
  (( $#out )) && print -rl -- "${out[@]}"
  return 0
}

_tally_accounts() {
  # The fleet as this machine has it. No snapshot yet (the app has never run), no binary, or a
  # report this parse does not recognise all end the same way: nothing offered, nothing said.
  local bin json
  local -a labels
  bin=$(_tally_bin) || return 0
  json=$("$bin" status --json 2>/dev/null) || return 0
  labels=(${(f)"$(_tally_json_field label "$json")"})
  labels=(${(M)labels:#?*})
  (( $#labels )) || return 0
  _wanted accounts expl account compadd -a labels
}

_tally_worktrees() {
  # The branch column of `tally worktree list`, which is the machine-readable report and a stable
  # stdout contract. Outside a git repository it exits 1 with nothing on stdout, which is already
  # the no-suggestions case.
  local bin line tab
  local -a lines branches
  bin=$(_tally_bin) || return 0
  tab=$'\t'
  lines=(${(f)"$("$bin" worktree list 2>/dev/null)"})
  for line in $lines; do
    branches+=("${line%%$tab*}")
  done
  branches=(${(M)branches:#?*})
  (( $#branches )) || return 0
  _wanted worktrees expl worktree compadd -a branches
}

# SUGGESTIONS, NEVER A GATE: the model axis is open (anything the provider accepts is legal, from a
# dated snapshot id to a Bedrock arn), so these are the aliases the pickers offer, and typing past
# them stays legal. The effort axis is the closed one, and this is the list the CLI validates
# against.
_tally_models() {
  local -a models
  models=(\#(claudeModelAliases.joined(separator: " ")))
  _wanted models expl model compadd -a models
}

_tally_model_targets() {
  # `tally model` takes one word the launch axis does not: `auto`, which releases the pin rather
  # than naming a model. A SECOND FUNCTION rather than one taking the extra word as an argument:
  # `_arguments` calls an action function with compadd options of its own in `$@`, so a list built
  # from `$@` offers `-J` and `-default-` at the cursor (seen, at the cursor, 2026-08-11).
  local -a targets
  targets=(\#(claudeModelAliases.joined(separator: " ")) auto)
  _wanted models expl model compadd -a targets
}

_tally_efforts() {
  local -a efforts
  efforts=(\#(claudeEffortNames().joined(separator: " ")))
  _wanted efforts expl effort compadd -a efforts
}

_tally_providers() {
  local -a ids
  ids=(\#(providers.map(\.id).joined(separator: " ")))
  _wanted providers expl provider compadd -a ids
}

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
          _arguments \
            "--model[the model every launch in this project runs]:model:_tally_models" \
            "--effort[the depth those launches run at]:effort:_tally_efforts" \
            "--account[the account those launches land on]:account:_tally_accounts" \
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

_tally() {
  local curcontext="$curcontext" state line
  # Captured before `_arguments` rewrites `words`, because every helper that asks this machine a
  # question has to ask THIS binary (see `_tally_bin`).
  local _tally_command=${words[1]}
  local -a commands
  commands=(
    "claude:launch Claude Code on the account with the most headroom"
    "codex:launch Codex on the account with the most headroom"
    "resume:continue this directory's latest Claude session on the best account"
    "worktree:the main repo and its worktrees, and the teardown of a merged one"
    "project:declare what this project launches, overriding the app defaults"
    "status:every account's remaining windows, with --json for scripts"
    "best-dir:print the export line for the best account"
    "launch-dir:like best-dir, but honouring the app's launch policy"
    "add:log in one more account in the next free config home"
    "account:pin THIS session to another account, keeping the conversation"
    "model:run THIS conversation on another model and depth, for the rest of its life"
    "reload:restart every supervised session at its next idle moment"
    "update:check for app updates now"
    "completion:print the shell completion script"
    "help:print the list of commands"
  )
  _arguments -C '1: :->command' '*:: :->args'

  case $state in
    (command) _describe -t commands "tally command" commands ;;
    (args)
      case $words[1] in
        (claude)
          # tally's own flags only. The rest of the line belongs to the child CLI, which has its
          # own dozens and publishes them itself, so the fallback is the default completer rather
          # than a hand-copied half of somebody else's flag list.
          _arguments \
            "--account[pin a specific account, by label or config-dir name]:account:_tally_accounts" \
            "(-w --worktree)"{-w,--worktree}"[launch in a git worktree, bare lists the existing ones]::worktree:_tally_worktrees" \
            "--new[start a fresh conversation, ignoring a continue-by-default setting]" \
            "--no-handoff[run unsupervised, with no automatic move when this account caps]" \
            "--no-follow[keep this session on its model when the Settings default changes]" \
            "*: :_default"
          ;;
        (codex)
          _arguments \
            "--account[pin a specific account, by label or config-dir name]:account:_tally_accounts" \
            "*: :_default"
          ;;
        (worktree) _tally_worktree_command ;;
        (project) _tally_project_command ;;
        (status) _arguments "--json[versioned machine-readable report for scripts and hooks]" ;;
        # `switch` is the name `account` shipped under. Still answered here, as the dispatch still
        # answers it, but deliberately absent from the list above: it is not the name to learn.
        (account|switch)
          _arguments \
            "--auto[release the pin, following automatic account selection again]" \
            ":account:_tally_accounts"
          ;;
        (model) _arguments ":model:_tally_model_targets" ":effort:_tally_efforts" ;;
        (add)
          _arguments \
            ":provider:_tally_providers" \
            "--no-share[do not share the main account's harness and conversations]"
          ;;
        (best-dir|launch-dir) _arguments ":provider:_tally_providers" ;;
        (reload) _arguments "--now[wait only for a 5s quiet gap rather than for idle]" ;;
        (completion) _arguments ":shell:(zsh)" ;;
      esac
      ;;
  esac
}

# Both installations end here. Autoloaded from fpath, this file IS the body of `_tally` on its
# first call, so it defines the real one above and then calls it; eval'd into a running shell, it
# binds instead. compinit is what puts `compdef` there, so a shell that has not run it is told
# rather than left with a Tab key that silently does nothing.
if [[ $funcstack[1] == _tally ]]; then
  _tally "$@"
elif (( $+functions[compdef] )); then
  compdef _tally tally
else
  print -u2 -- "tally: run compinit (autoload -Uz compinit && compinit) before this script"
fi
"""#

/// `tally completion <shell>` - print a completion script on stdout, for eval or for fpath.
///
/// Named rather than defaulted: bare `tally completion` is a usage error rather than zsh, so the
/// day a second shell arrives nothing that was written down changes meaning. Same shape as the
/// other subcommands with a list: the text goes to stderr with exit 2, since a word this command
/// does not know is a mistake rather than a request.
func runCompletion(args: [String]) -> Int32 {
    switch args.first {
    case "zsh":
        print(tallyCompletionZsh)
        return 0
    default:
        warn("usage: tally completion zsh")
        return 2
    }
}
