import Foundation

// THE PURE HALF OF THIS FEATURE: what a tick believes is standing (`openWaitRequest`), what changed
// since the last tick believed something (`reconcileWaitRequests`), and how a request that stopped
// standing is explained (`resolvedWaitOutcome`). Nothing here touches a file, a clock outside its
// own arguments, or a network call: the same split `SessionStateSync.swift` and its neighbours
// keep between "what decides" and "what publishes", so this is assertable without a supervisor.
//
// The caller that wires these into a real tick (`SessionStateSync.swift`'s `SessionWaitTracker`,
// plan §6.8) is a later package (P3) and is not touched here. What this file promises is the
// contract that caller will drive: given the same tick inputs `syncSessionState` already computes,
// and the belief it held a moment ago, these three functions say what happened and what to publish.

/// What this tick believes is STANDING, or nil when nothing is. Pure: every input is something the
/// tick already computed (`notice`, `waiting`, `question`, `quiet`, `wait`) or was told
/// (`permissionTool`, from a sidecar a later package wires in).
///
/// THE §3.4 TABLE, ROW BY ROW, in the order the plan gives it, not merged into fewer branches,
/// because a merge is exactly how a row silently stops matching what the table says it should.
/// The question row is checked first regardless of provider: `AskUserQuestion` fires no
/// `Notification` at all (C3, plan §2), so it is the one case `notice` can never carry.
func openWaitRequest(provider: String, sessionKey: String, notice: UserNotice?, waiting: Bool,
                     question: String?, questionSince: Date?, quiet: Bool,
                     wait: UserWait?, permissionTool: String?) -> SessionWaitRequest? {
    // Row: claude, `openUserQuestion` non-nil -> question, confirmed. Provider-agnostic in this
    // repo today (only Claude opens a question, X4 in the plan marks Codex's as unproven), but
    // checked ahead of the provider split because the transcript signal, when it exists, always
    // outranks a notice-based reading.
    if let question, let since = questionSince {
        let id = sessionWaitRequestID(sessionKey: sessionKey, kind: SessionWaitKind.question.rawValue,
                                      noticeType: nil, since: since)
        return SessionWaitRequest(id: id, kind: SessionWaitKind.question.rawValue,
                                  confidence: SessionWaitConfidence.confirmed.rawValue, since: since,
                                  noticeType: nil, tool: question,
                                  summary: sessionWaitSummary(userQuestionTools[question]))
    }

    guard waiting, let notice else { return nil }

    /// One request built from the standing `notice`, varying only in what the table says about it.
    func request(kind: SessionWaitKind, confidence: SessionWaitConfidence,
                tool: String?) -> SessionWaitRequest {
        let id = sessionWaitRequestID(sessionKey: sessionKey, kind: kind.rawValue,
                                      noticeType: notice.type, since: notice.at)
        return SessionWaitRequest(id: id, kind: kind.rawValue, confidence: confidence.rawValue,
                                  since: notice.at, noticeType: notice.type, tool: tool,
                                  summary: sessionWaitSummary(notice.message.isEmpty ? nil : notice.message))
    }

    // Row: codex, `PermissionRequest` hook arrived -> permission, suspected (§9 blind spot 1: Codex
    // can never prove a dialog reached a person, so this is the ceiling for it in v1). `waiting` and
    // `notice` carry the same "is something still open" and "what did it say" shape a later
    // package's Codex adapter will build from its own `pendingPermission` (plan §4.2); reusing
    // `UserNotice` here rather than inventing a second envelope is what keeps this function to one
    // signature for both providers.
    if provider == "codex" {
        return request(kind: .permission, confidence: .suspected, tool: permissionTool)
    }

    // Row: claude, noticeType in {permission_prompt, worker_permission_prompt} -> permission, confirmed.
    if let type = notice.type, ["permission_prompt", "worker_permission_prompt"].contains(type) {
        return request(kind: .permission, confidence: .confirmed, tool: permissionTool)
    }
    // Row: claude, noticeType in {elicitation_dialog, elicitation_url_dialog, agent_needs_input}
    // -> question, confirmed.
    if let type = notice.type,
       ["elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"].contains(type) {
        return request(kind: .question, confidence: .confirmed, tool: nil)
    }
    // Row: claude, noticeType == idle_prompt && quiet == true -> unknown, suspected. Judgement 2:
    // this is the one confidence a plain text question and a session nobody is even talking to can
    // both produce, and the two are indistinguishable on this signal alone (plan §9 blind spot 2).
    if notice.type == "idle_prompt", quiet {
        return request(kind: .unknown, confidence: .suspected, tool: nil)
    }
    // Row: claude, noticeType == nil or an unfamiliar string, && wait == .hard -> unknown, unknown.
    // `wait` is the caller's own `userWait(notificationType:)` reading (SessionState.swift), which
    // already fails open to `.hard` for exactly "nil or unfamiliar" and stays `.soft` for the one
    // known type this function did not already return on above (`idle_prompt` while not quiet, the
    // fan-out case judgement 3 exists for), so asking for `wait == .hard` here, having already
    // returned on every row that would make it hard for a RECOGNISED reason, is the literal reading
    // of this row rather than a merge of it with anything above.
    if wait == .hard {
        return request(kind: .unknown, confidence: .unknown, tool: nil)
    }
    // Row: codex, anything else -> no event. And its claude mirror: a soft wait over a moving
    // conversation (fan-out writing subagents) is not somebody being waited for either.
    return nil
}

/// One event with its idempotency key already stamped: the only way this feature builds a
/// `SessionWaitEvent`, so every kind (including a tracker's closing `session.ended`) is keyed alike.
func makeSessionWaitEvent(_ kind: SessionWaitEventKind, request: SessionWaitRequest?,
                          resolution: SessionWaitResolution?, identity: SessionWaitIdentity,
                          provider: String, now: Date) -> SessionWaitEvent {
    var built = SessionWaitEvent(at: now, kind: kind.rawValue, provider: provider,
                                 session: identity, request: request,
                                 resolution: resolution?.rawValue)
    built.idempotencyKey = sessionWaitIdempotencyKey(requestID: request?.id, sessionKey: identity.key,
                                                      kind: kind.rawValue,
                                                      resolution: resolution?.rawValue)
    return built
}

/// The events between the belief the LAST tick published and the one this tick just computed.
/// Pure; §4.1b's four per-tick rules (a fifth, what happens when the supervisor itself is shutting
/// down, is the seeding tracker's own job in a later package, see the file header).
///
/// `resolution` is an INPUT, not something this function derives: the caller has already worked out
/// what explains `current` going away (`resolvedWaitOutcome` below, for the ordinary case; a session
/// key that no longer matches a seeded request, for the restart case in plan §4.3) by the time it
/// calls this with `current == nil`.
func reconcileWaitRequests(previous: SessionWaitRequest?, current: SessionWaitRequest?,
                           resolution: SessionWaitResolution?, identity: SessionWaitIdentity,
                           provider: String, now: Date) -> [SessionWaitEvent] {
    func event(_ kind: SessionWaitEventKind, request: SessionWaitRequest?,
              resolution: SessionWaitResolution?) -> SessionWaitEvent {
        makeSessionWaitEvent(kind, request: request, resolution: resolution, identity: identity,
                             provider: provider, now: now)
    }

    switch (previous, current) {
    case (nil, nil):
        // Nothing was standing and nothing is now: the ordinary tick, and the common case by far.
        return []
    case (nil, .some(let cur)):
        return [event(.opened, request: cur, resolution: nil)]
    case (.some(let prev), nil):
        // The resolution ALWAYS has an explanation by the time this is called (`resolvedWaitOutcome`
        // for the ordinary clearing path, or a caller-decided one for the restart path); `?? .unknown`
        // is a floor against a caller that forgot to supply one, not a reading this function invents.
        return [event(.resolved, request: prev, resolution: resolution ?? .unknown)]
    case (.some(let prev), .some(let cur)):
        if prev.id == cur.id {
            // Same wait, something about how it is described changed: confidence upgraded (suspected
            // -> confirmed) or a tool/summary was filled in that was missing before. Every field
            // alike, deliberately, is the no-op that keeps this from firing every 2s tick forever.
            if prev.confidence != cur.confidence || prev.tool != cur.tool || prev.summary != cur.summary {
                return [event(.updated, request: cur, resolution: nil)]
            }
            return []
        }
        // Two different requests standing back to back with no tick in between where neither did:
        // the old one is superseded (its true outcome unknowable, plan §9 blind spot 4) and the new
        // one opens, in that order.
        return [event(.resolved, request: prev, resolution: .superseded),
                event(.opened, request: cur, resolution: nil)]
    }
}

/// §4.1c, as narrowed by plan §14 revision 1 (the `hook-permission` sidecar is cut from v1, so
/// `denied` is never returned here even though the enum keeps the case for a future package that
/// reads the transcript's own `is_error` result). Tried in order, first match wins:
///
///   1. A stamped main-chain conversation event is newer than when this wait began -> answered.
///      Not the transcript's mtime: unstamped bookkeeping records move that with nobody there.
///   2. The open question's tool call closed -> answered.
///   3. Neither -> unknown (a keyboard-burst clearing, or a wait the caller could not otherwise
///      account for: both are "somebody moved on" without evidence of WHAT they did).
func resolvedWaitOutcome(request: SessionWaitRequest, conversationMovedAt: Date?,
                         questionClosed: Bool) -> SessionWaitResolution {
    if let conversationMovedAt, conversationMovedAt > request.since {
        return .answered
    }
    if questionClosed {
        return .answered
    }
    return .unknown
}
