#!/bin/zsh
# Asks a real, interactive zsh what `tally <Tab>` offers, and checks the answer.
#
# WHY A REAL SHELL. Everything about the completion script can be asserted by reading it except the
# one thing it is for: what appears at the cursor. That is decided by zsh's completion system, which
# spec form binds which word, when a rest-args spec stops the option names being offered, when the
# longest common prefix is inserted instead of a list. Every defect this suite exists for was
# invisible to a source-level check and obvious here: a worktree flag that offered every file in the
# directory, and then, after that was fixed, a flag that offered nothing at all in a repository that
# HAD a worktree, because the fix had only ever been tried where there were none (2026-08-11).
#
# ABSENCE IS NEVER THE PASS. Every behaviour is checked by naming what MUST appear. A suite that only
# said "no file names here" passed just as happily on a script that offered nothing whatsoever, which
# is precisely how the second defect shipped.
#
# ONE SHELL PER PRESS. The menu these completions open is a mode: it survives the line, so a second
# press typed into the same shell is typed into whatever the first one left behind (seen: a second
# probe answering with the first probe's options). A fresh shell costs a second and buys a reading
# that means what it says.
#
# NO ENTER IS EVER SENT, anywhere in this file. The keys used are Tab, Escape and Ctrl-C. This drives
# a real binary's completion, and one of these lines accepted and run is a real command on a real
# machine: an earlier hand-run probe pressed Enter, ran `tally account`, and moved a live session.
emulate -L zsh
zmodload zsh/zpty

fpathdir=$1
stubdir=$2
workdir=$3
integer failures=0

check() {
  print -r -- "$([[ $2 == 1 ]] && print PASS || print FAIL): $1"
  [[ $2 == 1 ]] || (( failures++ ))
}

# Read what the pty has to say, and notice when it stops. `zpty -r -t` takes NO timeout: a number
# after the parameter name is a pattern to wait for, so the first version of this file read almost
# nothing and reported it as "offers nothing" - this suite's own failure mode, in its own plumbing.
pty_read() {
  local chunk='' acc=''
  integer quiet=0
  while (( quiet < 5 )); do
    chunk=''
    if zpty -r -t tally chunk 2>/dev/null; then
      acc+=$chunk
      quiet=0
    else
      (( quiet++ ))
      sleep 0.1
    fi
  done
  print -rn -- "$acc"
}

# Type one line, press Tab once, and hand back what the screen then said. Two Tabs would accept an
# unambiguous match and complete the NEXT position, which reads exactly like a leak that is not
# there (it did, for a whole round of review).
tab() {
  # $3, when given, is a line of setup run before the probe: what a user's own zshrc would have said.
  local mode=$1 line=$2 extra=${3:-:} presses=${4:-1} ready='' answer=''
  integer waited=0
  zpty -d tally 2>/dev/null
  zpty tally zsh -f -i
  zpty -w tally "export PATH=$stubdir:\$PATH TALLY_STUB_MODE=$mode; fpath=($fpathdir \$fpath); autoload -Uz compinit; compinit -u -d $fpathdir/.zcompdump; PROMPT='%%'; RPROMPT=''; LISTMAX=999; setopt nolistbeep; cd $workdir; $extra; print SHELL-READY"
  # Waited for rather than slept off, so the setup echo is swallowed here instead of arriving in the
  # middle of the answer and being read as part of it.
  while (( waited < 40 )); do
    ready+=$(pty_read)
    [[ $ready == *SHELL-READY* ]] && break
    (( waited++ ))
  done
  # `presses` exists for the one contract that is about the SECOND press: a shell with the menu
  # turned off grows the common prefix first and lists after, like every other completion it has.
  zpty -w -n tally "$line$(printf '\t%.0s' {1..$presses})"
  answer=$(pty_read)
  zpty -w -n tally $'\e'      # leave the menu
  zpty -w -n tally $'\003'    # abandon the line, unrun
  zpty -d tally 2>/dev/null
  print -r -- "$answer" | perl -pe 's/\e\[[0-9;?]*[a-zA-Z]//g; s/\e[>=]//g; s/\r/\n/g'
}

local out plain
local -a lesson

# 1. The lesson at an empty word: the flags this command has, and what each one is for. This is the
#    press somebody makes when they want to know what there is (Albert, 2026-08-11).
out=$(tab full "tally claude ")
check "an empty launch word offers the worktree flag" "$([[ $out == *"--worktree"* ]] && print 1)"
check "…and its short spelling" "$([[ $out == *"-w"* ]] && print 1)"
check "…and says what it is for" "$([[ $out == *"git worktree"* ]] && print 1)"
check "…and offers the account flag" "$([[ $out == *"--account"* ]] && print 1)"
check "…under a heading of its own" "$([[ $out == *"launch option"* ]] && print 1)"
# Not one argument of this binary takes a path, so the working directory is never an answer.
check "…and offers no file from the directory" "$([[ $out != *"a-file-here.txt"* ]] && print 1)"
# ONE LINE PER FLAG. The two spellings of the worktree flag arrive as a spec each and were listed
# twice, the same sentence under each, in a lesson five lines long (Albert, seeing it, 2026-08-11).
# Counted over the flag names with duplicates collapsed, because the screen redraws mid-answer and a
# truncated repeat of a line is not a sixth flag.
lesson=(${(f)"$(print -r -- $out | grep -oE '^--?[a-zA-Z][a-zA-Z-]*(, --[a-zA-Z-]+)?  --  ' | sed 's/  --  $//' | sort -u)"})
check "…as five lines, one per flag" "$([[ $#lesson == 5 ]] && print 1)"
check "…with the two spellings of one flag on one line" \
  "$([[ $out == *"-w, --worktree  --  "* ]] && print 1)"
check "…and neither spelling repeating a line of its own" \
  "$([[ $out != *$'\n-w  --  '* && $out != *$'\n--worktree  --  '* ]] && print 1)"

# 2. The flag that started all this: the lines this repository already has, by name.
out=$(tab full "tally claude -w ")
check "the worktree flag offers the worktrees that exist" \
  "$([[ $out == *"wt-alpha"* && $out == *"wt-beta"* ]] && print 1)"
check "…and no files beside them" "$([[ $out != *"a-file-here.txt"* ]] && print 1)"
out=$(tab full "tally worktree remove ")
check "so does the teardown command" \
  "$([[ $out == *"wt-alpha"* && $out == *"wt-beta"* ]] && print 1)"

# 3. The accounts, under the names the CLI will accept for them. An account label is free text, so
#    most of them have a space in the middle, and zsh shows and inserts them quoted - hence the
#    unquoting here, and the check below that the quoting was really there. It is what makes the
#    suggestion usable: `tally account Stub\ One` reaches the matcher as one argument.
out=$(tab full "tally claude --account ")
plain=${out//\\ / }
check "the account flag offers this provider's accounts" \
  "$([[ $plain == *"Stub One"* && $plain == *"Stub Two"* ]] && print 1)"
check "…quoted, so a name with a space arrives as one argument" "$([[ $out == *'\ '* ]] && print 1)"
out=$(tab full "tally account ")
plain=${out//\\ / }
check "and so does the command that moves a session" "$([[ $plain == *"Stub One"* ]] && print 1)"

# 4. Nothing to say is said with nothing, rather than with the contents of the directory.
out=$(tab full "tally resume ")
check "resume offers no file names" "$([[ $out != *"a-file-here.txt"* ]] && print 1)"

# 5. THE WORD AFTER SOMEBODY ELSE'S FLAG IS THAT FLAG'S VALUE, not a place to teach. The child CLI
#    has flags that take a path (`claude --add-dir`, `codex --cd`), and because the lesson is
#    inserted rather than merely shown, the first Tab handed the child `--add-dir --account` and a
#    launch that fails for want of a directory (review, 2026-08-11).
out=$(tab full "tally claude --add-dir ")
check "the press reached the shell at all" "$([[ $out == *"--add-dir"* ]] && print 1)"
check "a child flag's value position is not taught at" "$([[ $out != *"launch option"* ]] && print 1)"
check "…and nothing is inserted as its value" "$([[ $out != *"--add-dir --account"* ]] && print 1)"
out=$(tab full "tally codex --cd ")
check "the same for codex" \
  "$([[ $out != *"launch option"* && $out != *"--cd --account"* ]] && print 1)"

# 6. A flag already on the line is not offered again: `_arguments` drops one once it is used, and
#    this path went round that. A second `--account` matters because the launcher strips only the
#    first pair, so the extra one reaches the child.
out=$(tab full "tally claude --new ")
check "after one of our own valueless flags, the lesson still runs" \
  "$([[ $out == *"launch option"* ]] && print 1)"
check "…without the flag that was just used" "$([[ $out != *"--new  --  "* ]] && print 1)"
check "…and still with the ones that were not" "$([[ $out == *"--account"* ]] && print 1)"
out=$(tab full "tally claude -w wt-alpha ")
check "a used flag takes its whole alias set with it" \
  "$([[ $out == *"launch option"* && $out != *"-w, --worktree"* ]] && print 1)"

# 7. `menu no` means no menu, including the one this script would otherwise force. Respecting the
#    style and then forcing the behaviour was respecting nothing (review, 2026-08-11).
out=$(tab full "tally claude " "zstyle ':completion:*' menu no")
check "with menu turned off, nothing is inserted into the line" \
  "$([[ $out != *"claude --account"* ]] && print 1)"
out=$(tab full "tally claude " "zstyle ':completion:*' menu no" 2)
check "…and the options are still all reachable, a press later" \
  "$([[ $out == *"--worktree"* && $out == *"--account"* && $out == *"--no-handoff"* ]] && print 1)"

# 8. The same flag where there is nothing to offer: quiet, and quiet WITHOUT spilling a diagnostic
#    onto the line being typed. The pair matters - check 2 alone passes on a script that offers
#    everything, and this one alone passes on a script that offers nothing.
out=$(tab bare "tally claude -w ")
check "with no worktrees, the flag offers nothing" "$([[ $out != *"wt-alpha"* ]] && print 1)"
check "…and says nothing about it either" \
  "$([[ $out != *"no worktrees"* && $out != *"not inside"* ]] && print 1)"

exit $(( failures > 0 ))
