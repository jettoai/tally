// File arguments belong to these explicit maintenance commands, not the launch prompt.
let tallyHarnessCompletionZsh = #"""
_tally_harness_command() {
  if [[ "${words[2]}" == tools ]]; then
    shift words
    (( CURRENT-- ))
    _arguments \
      ":action:(install remove status)" \
      "--source-home[Claude configuration home]:directory:_directories" \
      "--target-home[Codex configuration home]:directory:_directories" \
      "--skills-root[shared skill directory]:directory:_directories" \
      "--state-root[Tally receipts]:directory:_directories"
    return
  fi
  _arguments \
    ":action:(plan status install remove grant record tools)" \
    "--scope[configuration scope]:scope:(user project)" \
    "--confirm-git-visible[confirm the reviewed project paths for install]" \
    "--source-home[Claude configuration home]:directory:_directories" \
    "--target-home[Codex configuration home]:directory:_directories" \
    "--project[explicit project checkout]:directory:_directories" \
    "--skills-root[shared skill directory]:directory:_directories" \
    "--state-root[Tally harness receipts]:directory:_directories" \
    "--manifest[installation manifest]:file:_files" \
    "--request[exact approval request]:hash:" \
    "--authorization[prior user authorization reference]:reference:" \
    "--file[evaluation result JSON]:file:_files"
}

_tally_inbox_command() {
  _arguments \
    ":action:(list post claim read ack release recover status)" \
    "--provider[recipient provider]:provider:_tally_providers" \
    "--home[addressed account home]:directory:_directories" \
    "--project[addressed checkout]:directory:_directories" \
    "--root[mailbox directory]:directory:_directories" \
    "--file[message body file]:file:_files" \
    "--id[message UUID]:id:" \
    "--owner[native session UUID]:owner:" \
    "--nonce[claim nonce]:nonce:" \
    "--previous-owner[abandoned claim owner]:owner:" \
    "--reason[recovery evidence]:reason:" \
    "--confirm-abandoned[confirm the previous session was checked]" \
    "--all-homes[list this checkout across provider homes]"
}
"""#
