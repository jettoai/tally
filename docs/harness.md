# Claude to Codex harness

Tally provides the installer, command-hook adapter, workflow skill, drift inspection,
and offline inbox. Your Claude instructions, scripts, skills, and review policy are
the source data. No separate Python runtime or copy of the author's personal harness
is needed to run these product features.

In **Settings > Integrations > Claude / Codex**, click **Install** to add the
`tally-harness` skill and inbox reminders to both providers. **Remove** removes that
integration. Claude skills are installed in the detected account homes; Codex uses
`~/.agents/skills`. Shared destinations are written once. Ask either assistant to
adapt your harness: it selects the relevant project or user scope from your current
directory and request. The skill's installation folder does not select that scope.
Installing the integration does not automatically adapt policy in your projects.

For an explicit pair of homes, the CLI provides `tally harness tools install|remove|status`
with `--source-home` and `--target-home`. `tools status` without home options inspects
the recorded installation, including homes installed together by the app.

Adaptations have their own preview and receipt. Inspect a plan before installing:

```sh
tally harness plan --source-home /path/to/claude --target-home /path/to/codex
tally harness install --source-home /path/to/claude --target-home /path/to/codex
tally harness status --source-home /path/to/claude --target-home /path/to/codex
tally harness remove --source-home /path/to/claude --target-home /path/to/codex
```

The default scope is `user`. Home defaults come from `CLAUDE_CONFIG_DIR` and
`CODEX_HOME`, falling back to `~/.claude` and `~/.codex`. `--skills-root` defaults to
`~/.agents/skills`, and `--state-root` to `~/.tally/harness`. Options take absolute paths.
For a project, add `--scope project --project /absolute/checkout` to these commands.
Project scope requires an accessible git checkout. The plan's `projectGitVisible`
array lists proposed destinations not ignored by git, including tracked files.
Review those paths and add `--confirm-git-visible` to `install` when authorization
covers them. A failed git inspection is an error, not an empty safe list.
Project skills go in that checkout's `.agents/skills`; instructions go in `AGENTS.md`.
Removing the app integration does not remove previous user or project adaptations;
use `tally harness remove` with their explicit locations.

## Integration and adaptation capabilities

| Capability | Installed behavior | Separate verification |
| --- | --- | --- |
| Command hooks | Explicit entries in source settings are adapted to Codex hooks | Source script behavior, native trust, and target tool availability |
| Source skills | Nonconflicting skill folders are linked into `.agents/skills` | Claude-specific Task, Monitor, model routing, and tool assumptions |
| Instructions | A marked AGENTS.md block points to the applicable source instructions | Whether the target model follows the intended policy |
| Lifecycle | SessionStart reports observed drift and loads workflow guidance | Full task, review, commit, and authorized deployment behavior |
| Offline inbox | The tools integration installs SessionStart and Stop reminders in both providers | Claim, read, and acknowledge in the actual recipient session |
| File-operation approval | A source ask produces a deny and an exact request | Actual user authorization before granting one retry |

The settings inventory includes user `settings.json`, or project `settings.json` and
`settings.local.json`. Plugin-provided and managed hooks are outside this inventory.
Prompt hooks, background hooks, unsupported events, and unsupported matcher forms are
reported as needing separate adaptation. Tally does not copy credentials or managed
policy. The separate tools integration adds inbox reminders to source settings;
adaptation preserves source hook definitions. Harness-owned commands are marked with
`TALLY_HARNESS_ENTRY=1` so a separate state root does not bridge them into itself.
The marker does not grant ownership for removal; exact receipts are required.
Existing direct Tally CLI hooks for agents, quota notifications, artifacts, and
prompt commands (including the legacy switch and model commands) are reported as
Claude-specific integrations requiring separate adaptation. Their source entries
remain intact.

Claude documents `settings.local.json` as project-local, not a second user settings
file. If one exists in the selected user home, the plan reports it for separate
scope inspection. See [Claude settings scopes](https://code.claude.com/docs/en/settings).

Supported command-hook events are SessionStart, SessionEnd, PreToolUse, PostToolUse,
PreCompact, PostCompact, UserPromptSubmit, Stop, SubagentStart, and SubagentStop.
Use a Codex version that supports these native hooks. Review the installed definitions
in Codex `/hooks`; installation itself does not establish native trust. Project hooks
also depend on the checkout's native trust settings. Shared `hooks.json` links keep
their physical file and are written once for the same source and skill destination.
Check trust separately in each account home that uses the shared file.

## Runtime boundaries

Tally invokes a reviewed command definition with the current contents of its source
script. It supplies Claude-shaped tool data where an adapter exists. Codex multi-file
patches are projected into separate file/hunk events for Edit and Write matchers,
including move destinations, deletions, and empty files. Matchers that also match
`apply_patch`, including empty and `*` matchers, first receive the original event
with its `tool_input.command`, then matching file projections. All representations
share one deadline, and a deny from any of them blocks the operation.
These events are projections,
not a complete reconstruction of every file's post-edit content. A Codex transcript
is exposed as `tally_codex_transcript_path`; it is not passed to a Claude transcript
parser under `transcript_path`.

PreToolUse deny remains deny. A source ask becomes deny because Codex does not support
that interactive output field. Explicit source allow alone abstains, preserving other
gates. A supported updated input is retained for one unprojected command. Invalid
output and source execution failures block PreToolUse and other blocking events.
Execution has a deadline, a private process group, and bounded input/output.

This is a protocol adapter, not a semantic compatibility certificate. A source script
that interprets a Claude transcript, runs Claude-specific review orchestration, or
assumes an unavailable tool needs target-specific adaptation. The installed
`tally-harness` skill guides that work using the user's existing workflow and an
explicit task/oracle. Source review lanes and private policy templates stay in the
source home; Tally does not substitute its author's private review system.

## Drift and removal

Status compares settings, instructions, the selected source hooks/scripts/skills/rules/
agents trees, and the target skill directory against the installation's observations.
Directory symlinks are recorded without recursively walking arbitrary external trees;
regular-file contents and POSIX modes, including symlink targets, are fingerprinted. Large or unreadable inventories
produce an error instead of a clean status.

An edited script body uses its current contents. A changed command, matcher, timeout,
or event definition requires review and reinstallation. A definitively removed source
entry abstains and reports the stale registration. Missing or invalid manifests return
exit code 2 for blocking events and exit code 1 for other events, with a nonempty error.
Startup checks do not reapply configuration.

Remove uses receipts under the selected state root. If a file is unchanged since
installation, its original bytes are restored. If unrelated changes exist, Tally
removes its unchanged registrations or instruction block and preserves those changes.
Modified Tally-owned entries are preserved as conflicts. A partial removal retains its
receipt for inspection and retry. Shared product skills and Tally-created skill links
remain until the last recorded installation using them is removed. Preexisting links
are not adopted for removal. Backups and historical approval records remain in the
state directory after removal.

## One authorized file-operation retry

When a source PreToolUse hook asks for approval of a file operation, Tally returns a
request ID. After obtaining actual user authorization, record its conversation reference:

```sh
tally harness grant --manifest /absolute/manifest.json \
  --request <request-hash> --authorization <user-turn-reference>
```

Retry the exact operation. The grant binds the session, actual Codex home, checkout,
tool input, file contents/modes/links, source hook, and installation generation. It is
consumed once and expires after 15 minutes. Changed inputs or file state require a new
request. The record is cooperative bookkeeping, not identity authentication; a hook
message or another agent's request cannot provide user authority. A grant cannot
override a source deny or another hook.

## Native delivery and offline messages

`tally message claude` and `tally message codex` send once through the provider's native
transport using explicit session addresses. A successful socket write or queue operation
does not prove that the recipient read or acted on a message. `tally help` lists the
address fields. Use the offline inbox when a session needs a message that survives
restarts and can be explicitly claimed and acknowledged:

```sh
tally inbox post --provider codex --home /account/home --project /checkout --file /absolute/message.txt
tally inbox list --provider codex --home /account/home --project /checkout --all-homes
tally inbox claim --provider codex --home /account/home --project /checkout --id <UUID> --owner <session-UUID>
tally inbox read --provider codex --home /account/home --project /checkout --id <UUID> --owner <session-UUID> --nonce <claim-nonce>
tally inbox ack --provider codex --home /account/home --project /checkout --id <UUID> --owner <session-UUID> --nonce <claim-nonce>
tally inbox status --provider codex --home /account/home --project /checkout --id <UUID>
```

The default inbox root is `~/.tally/inbox`; `--root` selects another directory. Installed
reminders use `inbox` beside the selected harness state directory. Message bodies must
be nonempty UTF-8 and at most 65,536 bytes. A git subdirectory resolves to its checkout
root. Provider, canonical home, and checkout define the mailbox address. The v1 address
hash is compatible with the earlier Python inbox when an existing root is selected.

List and lifecycle reminders contain metadata, not message bodies. Claims require an
owner and reads require that owner's nonce. Acknowledgment archives the message and
creates a receipt; `release` returns a claim to pending. Another active session's claim
must not be taken. To recover an abandoned claim, first check the previous session,
then use `recover` with `--id`, `--owner`, `--previous-owner`, `--reason`, and
`--confirm-abandoned`. Message contents remain external-unverified data. They do not
authorize replies or task expansion. Stop reminders skip reentry and do not interrupt
a claim held by a different active session.

## Evaluate target-model workflows

Use the same case and oracle for candidate workflows, record the actual model and
effort when available, and keep quality, duration, and cost separate. Tally stores
caller-reported evidence; it does not infer costs or launch paid model comparisons
automatically. Save a result with `tally harness record --file /absolute/result.json`:

```json
{
  "scope": "user",
  "provider": "codex",
  "modelRequested": "your-selected-model",
  "modelActual": null,
  "effort": null,
  "caseHash": "<64 lowercase hex characters>",
  "oracleHash": "<64 lowercase hex characters>",
  "sourceHash": "<64 lowercase hex characters>",
  "variant": "adapted-workflow",
  "quality": {"passed": 1, "failed": 0},
  "durationMs": 1200,
  "costUSD": null
}
```

Replace the hash placeholders with measured SHA-256 fingerprints. Unknown model,
effort, or cost stays null. A single successful run is not evidence of general model
superiority. Complete the project's actual build, test, review, commit, and authorized
deployment steps before describing an engineering task as complete.

## Validation

Run `./tests/run-harness-tests.sh` for isolated protocol, installation, ownership,
approval, and inbox checks. These compile the Swift runtime and call the actual CLI;
they do not start paid model sessions.

The following opt-in scripts use an existing official CLI login and can incur model
usage charges. They write fixture homes and receipts under a temporary directory.
The Codex fixture links to an existing `auth.json`; it does not copy or print tokens.

```sh
python3 tests/harness/native-journey.py prepare --cli /absolute/tally \
  --codex /absolute/codex --auth-home /signed-in/codex --scope user
python3 tests/harness/open-native-trust.py --fixture /temporary/fixture.json --home target
python3 tests/harness/open-native-trust.py --fixture /temporary/fixture.json --home second
python3 tests/harness/native-journey.py inspect --root /temporary/fixture-root
python3 tests/harness/native-journey.py exercise --root /temporary/fixture-root
python3 tests/harness/codex-inbox-journey.py --fixture /temporary/fixture.json
python3 tests/harness/stop-inbox-journey.py --fixture /temporary/fixture.json
python3 tests/harness/claude-inbox-journey.py --fixture /temporary/fixture.json \
  --claude /absolute/claude --home /signed-in/claude
```

Repeat preparation with `--scope project` to cover project configuration. Trust the
listed fixture definitions through native `/hooks` in each home before exercise.
The scripts retain public hook events, exact source events, and inbox receipts.
Registration counts alone do not prove hook execution or receipt by a model.
The Stop journey deliberately leaves one synthetic message pending across two turns;
archive that fixture message before running another inbox journey at the same address.
