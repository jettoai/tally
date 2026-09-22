# Session wait events

Tally can publish a stream of events about when a supervised Claude Code or Codex session is
waiting on a person, so an external watcher (a monitoring agent, a dashboard, an alert) does not
have to poll `tally status` and guess.

This is a machine-to-machine integration surface. It is documented here rather than in the app's
README because its audience is a script or another agent, not a person reading the project's own
feature list.

## Directory layout

Every file below lives at `~/.tally/events/` on the machine running the supervisor:

```
~/.tally/events/
  spool.jsonl        append-only log, one JSON event per line
  seq                the next sequence number an appended event will receive
  cursor             the last sequence number successfully delivered (or dead-lettered)
  sink.json           {"url": "...", "secret": "...", "createdAt": "..."}, mode 0600
  deliver.lock        an flock target; not meant to be read
  dead-letter.jsonl  events that ran out of retries or failed permanently
```

`seq` counts up every time a wait is decided, whether or not a sink is configured. `cursor` only
advances during a delivery pass (`tally events --deliver-once`). The two numbers can disagree, and
that disagreement is exactly what `tally events --since` exists to close: a consumer that fell
behind, or one that never had a sink registered at all, can read everything from a sequence number
forward at any time.

## Event schema

One line of `spool.jsonl` is one JSON object:

```json
{
  "v": 1,
  "seq": 1284,
  "at": "2026-09-22T23:41:07.412Z",
  "kind": "wait.opened",
  "provider": "claude",
  "session": {
    "key": "claude:41287:1758575401",
    "supervisorPid": 41287,
    "supervisorStartedAt": 1758575401,
    "childPid": 41301,
    "transcriptSessionId": "0f2c-uuid",
    "launchNonce": null,
    "account": "personal",
    "directory": "/Users/example/workspace/tally",
    "project": "tally",
    "worktree": null
  },
  "request": {
    "id": "a3f19c2b8d04e551",
    "kind": "permission",
    "confidence": "confirmed",
    "since": "2026-09-22T23:40:58.900Z",
    "noticeType": "permission_prompt",
    "tool": "Bash",
    "summary": "Claude needs your permission to use Bash"
  },
  "resolution": null,
  "idempotencyKey": "b71d0e5f9a2c4438"
}
```

Fields absent from a JSON object have their own meaning (they are not "unknown by omission"): a
missing `tool` means no tool name could be attached, a missing `summary` means the wait had nothing
to say about itself, `resolution` is only ever present on a `wait.resolved` event.

`session.supervisorStartedAt` is an opaque generation stamp, not a timestamp to be read on its own:
on Claude it is an epoch-second value, on Codex it is a microsecond-resolution generation counter
(`CodexSupervisor.swift:57`). It is not comparable across providers, and it always changes across a
restart of the same provider's supervisor.

`kind` is one of `wait.opened`, `wait.updated`, `wait.resolved`, `session.ended`. `request.kind` is
one of `permission`, `question`, `unknown`. `request.confidence` is one of `confirmed`, `suspected`,
`unknown`. `resolution`, present only on `wait.resolved`, is one of `answered`, `denied`,
`superseded`, `session-ended`, `unknown` (see Limitations below: `denied` is reserved for a future
version and is never emitted by v1).

`confidence == "confirmed"` is reserved for signals this build can prove reached a real dialog:
Claude's structured question tool call, and Claude's `permission_prompt` /
`worker_permission_prompt` / `elicitation_dialog` / `elicitation_url_dialog` / `agent_needs_input`
notifications. Every Codex signal, and Claude's plain `idle_prompt`, is `suspected` at best and is
never promoted to `confirmed`.

### How a structured question is recognised

- Claude, transcript: an `AskUserQuestion` (or `ExitPlanMode`) tool call open in the transcript.
  Claude Code 2.1.280 writes that call only after it is answered, so on 2.1.280 this row rarely
  fires.
- Claude, `permission_prompt` notice: on Claude Code 2.1.280 an `AskUserQuestion` dialog fires the
  same `permission_prompt` notification, with the same message ("Claude needs your permission"), as
  a tool permission does. What tells them apart is Claude Code's own session registry,
  `<config home>/sessions/<child pid>.json`: while a dialog is open it says `"status": "waiting"`,
  with `"waitingFor": "input needed"` for the question dialog and `"permission prompt"` for every
  permission dialog. Read that way, the wait is `kind: "question"`, `confidence: "confirmed"`,
  `tool: "AskUserQuestion"`, `noticeType: "permission_prompt"`. If the registry is read a tick after
  the notice, the wait opens as a permission and a `wait.updated` with the same `request.id` turns
  it into a question; it is never turned back.
- Codex: a `request_user_input` `function_call` in the rollout with no `function_call_output` for
  its `call_id` yet (Codex CLI 0.155.1 writes the call when the "Question 1/1" chooser opens and the
  output when it is answered). The wait is `kind: "question"`, `confidence: "suspected"`,
  `tool: "request_user_input"`; its output landing resolves it `answered`, the turn ending or being
  interrupted resolves it `unknown`.

### What counts as an answer

A Claude wait resolves `answered` only when a record a PERSON produced lands in the main-chain
transcript after the wait began. Census of every stamped record kind in 14 days of transcripts on
the development machine (Claude Code 2.1.277 to 2.1.280, 400 files, 2026-09-23):

| Record (type, subtype, content) | Count | Person? |
|---|---|---|
| `attachment` | 18277 | no |
| `assistant` | 13036 | no |
| `user`, tool result | 7363 | yes (a dialog's answer is written as one) |
| `queue-operation` | 3333 | no (no `uuid`, never read) |
| `user`, text, `promptSource: "system"` (task notification) | 621 | no |
| `user`, text, `isMeta` (command caveat, Stop hook feedback, skill body, peer message) | 738 | no |
| `user`, text, `<command-name>` (a slash command) | 385 | yes |
| `user`, text, `promptSource: "typed"` or `"queued"` (`origin.kind: "human"`) | 97 | yes |
| `user`, text, `promptSource: "sdk"` | 7 | yes |
| `user`, text, `[Request interrupted by user]` | 3 | yes |
| `system`, `stop_hook_summary` / `turn_duration` / `local_command` / `away_summary` / `model_fallback` / `informational` | 971 / 827 / 378 / 32 / 3 / 3 | no |
| `file-history-delta` | 194 | no |

Any `origin.kind` other than `human`, or any `promptSource` other than `typed`, `queued` or `sdk`,
is treated as not a person. When the conversation moves without a person (a task notification
wakes the session), a standing wait resolves `unknown`. A `system` record does not move the
conversation at all: an auto mode notice written 0.97 s after a wait opened used to resolve it
`answered` (H1 rerun O4). An `idle_prompt` wait, once open, stays open through Claude Code writing
to an otherwise idle transcript; only the conversation moving or a keyboard burst ends it.

## Verifying a delivered event

Each delivered event is a single HTTP POST with these headers:

```
Content-Type: application/json
X-Tally-Timestamp: 1758575401
X-Tally-Signature: sha256=<hex>
X-Tally-Idempotency-Key: b71d0e5f9a2c4438
X-Tally-Event: wait.opened
```

The signature is `HMAC-SHA256(key: secret, message: "<timestamp>.<body>")`, where `<body>` is the
exact bytes of the POST body and `<timestamp>` is the value of `X-Tally-Timestamp`, joined with a
literal `.`. A receiver written in Python:

```python
import hashlib
import hmac

def verify(secret: str, timestamp: str, body: bytes, signature_header: str) -> bool:
    message = f"{timestamp}.".encode() + body
    expected = "sha256=" + hmac.new(secret.encode(), message, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature_header)
```

Use `hmac.compare_digest` (or the equivalent constant-time comparison in your language), not `==`,
to avoid a timing side channel.

## Catching up: `tally events` vs `tally status --json`

```
tally events --since <seq> [--limit n]   # every event with seq > <seq>, oldest first (default limit 500)
tally events --latest-seq                # the highest seq written so far, for aligning on startup
tally events --deliver-once [--replay-dead-letter]   # run one delivery pass by hand
tally events sink set <url> --secret-stdin           # configure the one destination (secret read from stdin)
tally events sink show                               # print the url and whether a secret is set (never the value)
tally events sink clear                              # remove the sink configuration
```

The two read paths answer different questions:

- `tally events --since <seq>` answers "what happened between then and now" - it is the catch-up
  path for a consumer that missed some deliveries (sink was down, consumer was down, this is the
  first time it has ever asked).
- `tally status --json` answers "what is true right now" - it already reports each session's
  `state` / `noticeType` / `quiet` fields and is the reconciliation path, not the event log.

A consumer should treat `tally status --json` as the source of truth for "is this session waiting
on someone right now" and `tally events --since` as the source of truth for "what did I miss."

A delivery pass (`tally events --deliver-once`, which every supervisor spawns) holds one lock and
keeps reading past the cursor until nothing is left, then checks once more after unlocking and
takes the lock again if anything arrived. That is what delivers the `wait.resolved` and
`session.ended` a supervisor appends as it exits while an earlier pass is still sending: the
deliverer the exit path spawns loses the lock and leaves, and the pass holding it picks them up.
Both loops are bounded (5 reads, 5 lock rounds); a pass that reaches the bound with events still
waiting, having moved the cursor, spawns one fresh deliverer for the rest.

## Deduplication

Every event carries `idempotencyKey`, computed from the request it describes, the event kind, and
the resolution (when there is one). The same underlying wait event, recomputed on a retry or a
resend, always produces the same key. A consumer that records "I have already acted on key X" and
skips a repeat is safe against: webhook retries, a `--replay-dead-letter` replay, and a supervisor
self-update that takes the same session over and re-derives an event it already sent. The key
includes `session.key`, which carries the supervisor's pid and start time, so the same key only
comes back for the same supervisor identity. A NEW supervisor generation (a fresh `tally claude` or
`tally codex`, even in the same directory for the same notification) has a different `session.key`
and its events are new requests with new keys.

`request.id` is a separate, narrower key: it names the specific wait (open dialog, open question),
stable across `wait.opened` / `wait.updated` / `wait.resolved` for the same wait, and different for
every distinct wait. Use it to correlate the lifecycle of one wait across multiple events; use
`idempotencyKey` to decide whether to act on a given event at all.

## Limitations

1. Codex cannot prove a permission dialog was actually shown to a person. The hook payload carries
   no such field, and Codex's own rollout transcript records no approval history to check against.
   Every Codex permission wait is `confidence: "suspected"` and stays that way in this version.
2. A plain text question typed into Claude's response and a session nobody is talking to at all
   produce the identical signal (`idle_prompt`). Both are reported as `request.kind: "unknown"`,
   `confidence: "suspected"`. Telling them apart is left to whatever reads this stream.
3. A background worker's permission prompt is cleared by watching the main session's transcript
   move, not the worker's own result. This is a known, pre-existing gap this feature does not close.
4. Only one open wait is tracked per session at a time. If a second one appears before the first is
   resolved, the first is reported `resolution: "superseded"` - its real outcome is never known.
5. Claude Code's documented `Notification` type list and this build's own list disagree in both
   directions (the docs omit `worker_permission_prompt`, which this build has observed; this build
   does not recognize three `quota_auto_resume_*` types the docs list). This feature does not
   reconcile either list.
6. Whether `PermissionRequest` fires only when a tool call is actually presented to a person, or
   also when a hook auto-decides it, is unconfirmed by Claude Code's own documentation.
7. Where `request.tool` comes from depends on the request:
   - Claude permission and unknown waits: always absent. The Claude tracker passes no tool name,
     because nothing on the Claude side confirms which tool a notification is about; the tool is
     only mentioned in `request.summary`, as Claude Code's own message text.
   - Codex permission waits: the tool field of the pending `PermissionRequest` hook payload.
   - Structured questions (`request.kind: "question"`): the name of the question tool call that is
     open in the transcript (for example `AskUserQuestion`), `AskUserQuestion` for a question read
     off Claude Code's session registry, and `request_user_input` for Codex.
8. Codex's `~/.codex/config.toml` `notify` key is already claimed by another tool on this machine
   (a computer-use client). This feature does not read or write it.
9. Codex structured questions (`request_user_input`, Codex CLI 0.155.1) are reported from the
   rollout (see "How a structured question is recognised"). Codex MCP elicitation is unverified.
   While a Codex question stands, `tally status --json` still reports the session's `state` as
   `working`; only the event stream shows the question.
10. Out of scope for v1: Codex subagents, delivering to more than one sink, and any event older
    than what the spool trimming window retains. 8 MiB is the size that TRIGGERS a trim (together
    with delivery having caught up with at least half of the spool), not an amount that is kept. A
    trim keeps only events with `seq > cursor - 1000` plus everything not yet delivered, so right
    after a trim with every event delivered, only about the last 1000 events are left.
11. v1 cannot tell a permission request that was answered "yes" apart from one answered "no," so a
    consumer cannot use `resolution` to learn whether a permission was approved or refused.
    Measured values (H1 rerun, 2026-09-23): Claude Code 2.1.280, "No" on a Bash permission resolves
    `answered` (cell A2); Codex CLI 0.155.1, Esc on a command approval resolves `unknown` (cell B1
    deny). `resolution: "denied"` is reserved in the schema for a future version that reads the
    transcript's own tool result to tell them apart, and is never emitted by this version.
12. The structured question reading on Claude Code 2.1.280 rests on the session registry's
    `waitingFor`, which is undocumented. A version that drops or renames it reports its questions as
    permissions again (late rather than wrong). A plan awaiting approval (`ExitPlanMode`) on 2.1.280
    also fires `permission_prompt`, and the registry names it `"permission prompt"`, so it is
    reported as a permission.
13. A tool result counts as a person's answer. If Claude Code writes the result of one tool call
    while a permission dialog for another call in the same turn is still open, that wait resolves
    `answered` early. Not observed; named here because nothing rules it out.
