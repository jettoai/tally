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

## Deduplication

Every event carries `idempotencyKey`, computed from the request it describes, the event kind, and
the resolution (when there is one). The same underlying wait event, recomputed on a retry or a
resend, always produces the same key. A consumer that records "I have already acted on key X" and
skips a repeat is safe against: webhook retries, a `--replay-dead-letter` replay, and a supervisor
restart that re-derives an event it already sent.

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
7. In v1, `request.tool` is populated from the notification's own message text where available and
   is otherwise absent - there is no separate hook confirming the tool name, so it should not be
   read as independently verified.
8. Codex's `~/.codex/config.toml` `notify` key is already claimed by another tool on this machine
   (a computer-use client). This feature does not read or write it.
9. Unverified in this version: Codex structured questions or MCP elicitation. The real-CLI matrix
   row B4 is still pending; if Codex turns out to surface them, this is a gap to close, not a scope
   decision.
10. Out of scope for v1: Codex subagents, delivering to more than one sink, and any event older
    than what the spool trimming window retains (at least the most recent 1000 delivered events, or
    8 MiB, whichever is larger).
11. v1 cannot tell a permission request that was answered "yes" apart from one answered "no." Both
    resolve as `resolution: "answered"` or `"unknown"`. `resolution: "denied"` is reserved in the
    schema for a future version that reads the transcript's own tool result to tell them apart, and
    is never emitted by this version.
