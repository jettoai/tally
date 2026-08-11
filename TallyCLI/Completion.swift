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

_tally_accounts() {
  # $1 is the provider whose accounts may be named HERE. It is not optional in spirit: `tally claude
  # --account` offering a Codex account offers a word `accountMatching` refuses by construction
  # (AccountPick.swift filters on the provider first), and an account you cannot pick is worse than
  # one you had to type out.
  #
  # ASKED OF THE BINARY RATHER THAN PARSED OUT OF `status --json`. A label is free text somebody
  # typed into the rename popover, so it can carry a quote or a backslash, which `JSONEncoder` then
  # escapes; a shell reader that stops at the next `"` hands the cursor a name no account answers to.
  # The binary already owns the matcher that decides which names resolve, so it says which words are
  # answers and this asks. The cost is that script and binary must be of one version, which they are:
  # this script comes out of that binary, and a mismatch prints nothing rather than the wrong thing.
  local bin provider=${1:-claude}
  local -a names
  bin=$(_tally_bin) || return 0
  names=(${(f)"$("$bin" completion data accounts $provider 2>/dev/null)"})
  names=(${(M)names:#?*})
  (( $#names )) || return 0
  _wanted accounts expl account compadd -a names
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

_tally_teach() {
  # The flags a command has, shown as a group of their own with what each one is for.
  #
  # WHY THIS EXISTS RATHER THAN LEAVING IT TO `_arguments`: at a word that a rest-args spec can also
  # match, zsh stops offering option names, so `tally claude <TAB>` answered with a listing of the
  # current directory. Everything the command can do was one keystroke away and invisible, and -w -
  # the reason most people come to this binary - was reachable only by already knowing it was there
  # (Albert, 2026-08-11: "I expect tally claude to tell me what I can do, especially worktrees").
  #
  # BUILT FROM THE VERY SPEC STRINGS `_arguments` IS GIVEN, handed in by the caller, so what is
  # taught cannot drift from what works: a flag renamed in the spec is renamed in the lesson.
  local label=$1 spec name desc
  local -a names displays
  shift
  for spec in "$@"; do
    spec=${spec#\(*\)}                  # the exclusion group, when the spec carries one
    name=${spec%%\[*}
    # Anything without a description is not a lesson: positional specs and bare flags are skipped
    # rather than listed with an empty explanation.
    [[ $name == -* && $name != $spec ]] || continue
    desc=${spec#*\[}
    displays+=("$name  --  ${desc%%\]*}")
    names+=("$name")
  done
  (( $#names )) || return 0
  _wanted tally-options expl $label compadd -d displays -a names
}

_tally_rest() {
  # Teach at an empty word, and offer nothing at all once the word has a shape: `_arguments` is
  # already answering anything that starts with a dash, and the rest of a launch line is a prompt or
  # a flag belonging to the child CLI, which this script does not pretend to know.
  #
  # NO FILE COMPLETION, HERE OR ANYWHERE: not one argument of this binary takes a path, so offering
  # the working directory was offering a whole category of answer that is never right (Albert,
  # 2026-08-11). Silence does not stop anyone typing; a wrong suggestion accepted does become a
  # command, which is how a file name once turned into a worktree branch.
  #
  # `_tally_specs` is the caller's array, reached the way this whole system reaches `words` and
  # `CURRENT`: an action runs inside the function that called `_arguments`.
  [[ -z ${words[CURRENT]} ]] && _tally_teach "launch option" $_tally_specs
  return 0
}

_tally_model_effort() {
  # `auto` releases the pin and takes nothing after it: `modelIntent` returns nil for two words when
  # either is the release, so `tally model auto high` is usage and exit 2 (run, 2026-08-11). Both
  # spellings, because both are accepted (`auto` and `--auto`, ModelCommand.swift).
  [[ ${(L)words[2]} == (auto|--auto) ]] && return 0
  _tally_efforts
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
          # Which provider's accounts may be named depends on what this line has already said:
          # `--provider` defaults to claude (ProjectPolicy.swift), and a `--provider` typed after
          # the account is not on the line yet to be read, which is the same order the command
          # itself would refuse in.
          local provider=claude i
          for (( i = 1; i < CURRENT; i++ )); do
            [[ $words[i] == --provider ]] && provider=${words[i+1]:-claude}
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

_tally() {
  local curcontext="$curcontext" state line
  # Captured before `_arguments` rewrites `words`, because every helper that asks this machine a
  # question has to ask THIS binary (see `_tally_bin`).
  local _tally_command=${words[1]}
  # How this command's answers are PRESENTED: each kind of answer in its own titled group, and an
  # arrow-key menu to walk them. Scoped to `tally`, so these are statements about this completion
  # rather than about the user's shell.
  #
  # ASKED BEFORE SET, and asked with `-s` rather than `-t`: `-t` tests whether a style is TRUE, and
  # `menu select` is not a boolean, so a `-t` probe reads "unset" for somebody who set `menu no` on
  # purpose and would then have the menu forced back on. `-s` answers the question actually being
  # asked, which is whether anything the user wrote already applies here.
  zmodload -i zsh/complist 2>/dev/null
  local _tally_style
  zstyle -s ':completion:*:*:tally:*' menu _tally_style \
    || zstyle ':completion:*:*:tally:*' menu select
  zstyle -s ':completion:*:*:tally:*' group-name _tally_style \
    || zstyle ':completion:*:*:tally:*' group-name ''
  zstyle -s ':completion:*:*:tally:*:descriptions' format _tally_style \
    || zstyle ':completion:*:*:tally:*:descriptions' format '%B%d%b'
  # AND SHOW IT ON THE PRESS THAT ASKED. At an empty word there is no prefix to grow, so zsh grows
  # the longest common one instead and waits: with the file fallback gone every candidate here
  # starts with a dash, so Tab inserted "-" and displayed nothing - the same "it told me nothing"
  # this whole change is about. Asked for only where the word is empty, which is the press that
  # means "what is there"; once something is typed, the ordinary prefix behaviour is what a person
  # is expecting.
  [[ -z ${words[CURRENT]} ]] && compstate[insert]=menu
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
        # tally's own flags only, and the accounts of the provider being launched. Everything else
        # on the line belongs to the child CLI, which has its own dozens and publishes them itself,
        # so the rest of the line falls back to the default completer rather than to a hand-copied
        # half of somebody else's flag list.
        #
        # THE WORKTREE ARGUMENT IS WRITTEN AS REQUIRED (`:worktree:`, not `::worktree:`) EVEN THOUGH
        # A BARE -w IS LEGAL, and that is the whole protection: with an optional argument zsh
        # completes this position twice, once as the worktree name and once as though the name were
        # already given, and the union put every file in the directory among the branch names. A file
        # name accepted there is not passed to claude at all - `extractWorktreeFlag` takes any
        # non-flag word as a worktree NAME, so the launch goes and creates a branch and a directory
        # called `README.md` (Worktree.swift; leak reported by review 2026-08-11, and the second
        # parse is invisible to any guard the fallback could carry - it looks exactly like the
        # ordinary next position). Bare `-w` still works; it is completion, not validation.
        (claude)
          local -a _tally_specs
          _tally_specs=(
            "--account[pin a specific account, by label or config-dir name]:account: _tally_accounts claude"
            "(-w --worktree)"{-w,--worktree}"[launch in a git worktree: bare lists the lines this repo already has, a new name opens one]:worktree:_tally_worktrees"
            "--new[start a fresh conversation, ignoring a continue-by-default setting]"
            "--no-handoff[run unsupervised, with no automatic move when this account caps]"
            "--no-follow[keep this session on its model when the Settings default changes]"
          )
          _arguments $_tally_specs "*: :_tally_rest"
          ;;
        (codex)
          local -a _tally_specs
          _tally_specs=(
            "--account[pin a specific account, by label or config-dir name]:account: _tally_accounts codex"
          )
          _arguments $_tally_specs "*: :_tally_rest"
          ;;
        # Named with nothing to say, on purpose. Everything typed after `resume` is appended to the
        # claude invocation `runResume` execs (main.swift) and tally has no flag of its own there,
        # so there is nothing to suggest - and the branch says so out loud, because the last reader
        # to find it empty filled it with file completion.
        (resume) ;;
        (worktree) _tally_worktree_command ;;
        (project) _tally_project_command ;;
        (status) _arguments "--json[versioned machine-readable report for scripts and hooks]" ;;
        # `switch` is the name `account` shipped under. Still answered here, as the dispatch still
        # answers it, but deliberately absent from the list above: it is not the name to learn.
        (account|switch)
          # Claude only, as the command is: a codex launch is a plain exec with no supervisor
          # resident to move anything (SwitchCommand.swift takes `providers[0]`).
          _arguments \
            "--auto[release the pin, following automatic account selection again]" \
            ":account: _tally_accounts claude"
          ;;
        (model) _arguments ":model:_tally_model_targets" ":effort:_tally_model_effort" ;;
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
    case "data":
        return runCompletionData(args: Array(args.dropFirst()))
    default:
        warn("usage: tally completion zsh")
        return 2
    }
}

/// The names `--account` will accept for one provider's accounts, one per line: what the completion
/// script offers at the cursor.
///
/// ASKED OF THE MATCHER ITSELF rather than assembled beside it. A name is offered only when
/// `accountMatching` resolves it to exactly this account, which makes the suggestion true by
/// construction: the completion cannot offer a Codex account to `tally claude --account` (the
/// matcher filters on the provider first), and it cannot offer a label two accounts share, which
/// the matcher answers with "name one of them exactly" - the one answer a suggestion must never be.
///
/// The label is preferred and the config-dir name is the fallback, in the order a person reads them
/// off `tally status`: one name per account, and the directory appears only for the accounts whose
/// label cannot pick them out. An account neither name resolves is offered under neither, because
/// there is nothing to type that would land on it.
func completionAccountNames(_ snapshot: Snapshot?, provider: String) -> [String] {
    var names: [String] = []
    for account in snapshot?.accounts ?? [] where account.provider == provider {
        guard let home = account.launchHome else { continue }
        let candidates = [account.label, URL(fileURLWithPath: home).lastPathComponent]
        // A newline cannot be a candidate on a line-per-candidate channel, and a label is free text
        // (the rename popover accepts anything). Dropped rather than escaped: nothing could type it
        // back in anyway.
        guard let name = candidates.first(where: { candidate in
            guard !candidate.isEmpty, !candidate.contains("\n") else { return false }
            guard case .one(let match) = accountMatching(candidate, provider: provider,
                                                         in: snapshot) else { return false }
            return match.id == account.id
        }) else { continue }
        names.append(name)
    }
    return names
}

/// `tally completion data <what> [args]` - the plumbing the completion script asks its questions
/// through. Not in `tally help` and not offered at the cursor: it is one program talking to itself,
/// and a person reading the list of commands has nothing to do with it.
///
/// A SUBCOMMAND RATHER THAN A SHELL PARSE OF `status --json`. That report is pretty-printed JSON
/// carrying free text a user typed, so a shell reader has to get quoting and escaping right to hand
/// back a name that matches; here the binary that owns the matcher answers with the words that
/// resolve. Silent about every failure, including a snapshot it could not read: this runs at a
/// cursor, where the only two outcomes allowed are suggestions and no suggestions.
func runCompletionData(args: [String]) -> Int32 {
    guard args.first == "accounts", let providerID = args.dropFirst().first,
          providers.contains(where: { $0.id == providerID }) else {
        warn("usage: tally completion data accounts <\(providers.map(\.id).joined(separator: "|"))>")
        return 2
    }
    let (snapshot, _) = loadSnapshot()
    for name in completionAccountNames(snapshot, provider: providerID) { print(name) }
    return 0
}
