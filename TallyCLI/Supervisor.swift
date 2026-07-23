import Darwin
import Foundation

// Auto-handoff supervision (Phase B).
//
// `tally claude` stays resident as a thin parent around the interactive claude child. It tails the
// session transcript for a cap-hit event; on a hit it terminates the child, re-picks the best other
// account, and relaunches `claude --resume <session>` in the same terminal - the conversation
// continues on the fresh account with no manual step.
//
// Detection is grounded in real transcript data (this machine's history, 2026-07-16): genuine cap
// hits are `isApiErrorMessage:true` events whose text starts with "You've" ("You've hit your
// session limit…", "You've reached your Fable 5 limit…"). Server-side trouble ("API Error: …",
// "Server is temporarily limiting requests (not your usage limit)", 529/500, login expiry) never
// starts with "You've" and must never trigger a handoff.

/// Watches one session transcript for a cap-hit event newer than `since`.
struct TranscriptWatcher {
    let projectDir: URL
    var file: URL?
    var offset: UInt64 = 0
    let since: Date
    /// The session id this child was launched to resume, when known (set after a handoff, which
    /// relaunches with `--resume <id>`). Lets `locateFile` pin `<id>.jsonl` directly instead of
    /// guessing by mtime - two sessions in one directory otherwise cross-bind to whichever file
    /// was touched last. nil on a fresh launch, where the heuristic still applies.
    var resumeID: String?
    /// The model id of the newest assistant event seen so far - how the supervisor notices a
    /// server-side model fallback.
    var lastModel: String?
    /// The timestamp of the newest main-chain, real, post-launch assistant event. A cap recovery
    /// is cleared when this passes the cap time (a genuine turn happened after the cap, so the
    /// account came back on its own). Same three guards as `lastModel`.
    var lastMainChainEventAt: Date?

    /// The event timestamp of one transcript line, without a full JSON parse.
    func lineTimestamp(_ line: Substring) -> Date? {
        guard let key = line.range(of: "\"timestamp\":\"") else { return nil }
        let rest = line[key.upperBound...]
        guard let quote = rest.firstIndex(of: "\"") else { return nil }
        return parseISO(String(rest[..<quote]))
    }

    /// True when the transcript has been silent for `seconds` - the between-turns proxy. An
    /// active turn appends events (tool calls, messages) every few seconds, so a quiet file
    /// means no response is being cut mid-stream. Non-urgent handoffs (pin follow, degradation
    /// rescue, fallback profile) wait for this; a cap hit does not (that turn is already dead).
    mutating func isQuiet(_ seconds: TimeInterval = 5) -> Bool {
        locateFile()
        // Fresh URL on purpose: resourceValues are cached per URL instance, and a cached
        // mtime would report an active turn as quiet forever.
        guard let file,
              let modified = (try? URL(fileURLWithPath: file.path)
                  .resourceValues(forKeys: [.contentModificationDateKey]))?
                  .contentModificationDate else { return true }
        return Date().timeIntervalSince(modified) > seconds
    }

    /// The newest session transcript created/updated after launch - the child's session.
    mutating func locateFile() {
        guard file == nil else { return }
        // A resumed handoff knows its session id, so bind `<id>.jsonl` directly: mtime guessing
        // would otherwise pick the wrong file when the directory holds a second session (a
        // sibling tab, an unrelated older conversation). Only a first launch (no known id, or
        // the file not yet copied into this account's tree) falls back to the heuristic below.
        if let resumeID {
            let pinned = projectDir.appendingPathComponent("\(resumeID).jsonl")
            if FileManager.default.fileExists(atPath: pinned.path) { file = pinned; return }
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let candidate = files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate else { return nil }
                return modified >= since.addingTimeInterval(-5) ? (url, modified) : nil
            }
            .max { $0.1 < $1.1 }
        file = candidate?.0
    }

    /// Scan newly-appended lines; true when a genuine cap-hit event (newer than launch) appears.
    mutating func sawCapHit() -> Bool {
        locateFile()
        guard let file, let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset += UInt64(data.count)
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return false }

        for line in text.split(separator: "\n") {
            // Track the ACTUAL serving model, with three guards learned from a live misfire
            // (2026-07-19: a continued session replays its whole history, whose old lines and
            // "<synthetic>" error turns poisoned lastModel and ping-ponged the rescue):
            // real model ids only, main-chain events only, and only events newer than launch.
            if let modelKey = line.range(of: "\"model\":\""),
               !line.contains("\"isSidechain\":true") {
                let rest = line[modelKey.upperBound...]
                if let quote = rest.firstIndex(of: "\""), rest[..<quote].hasPrefix("claude"),
                   let ts = lineTimestamp(line), ts >= since {
                    lastModel = String(rest[..<quote])
                    lastMainChainEventAt = ts
                }
            }
            guard line.contains("\"isApiErrorMessage\":true") else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = object["message"] as? [String: Any] else { continue }
            let content = message["content"]
            let body = (content as? String)
                ?? ((content as? [[String: Any]])?.first?["text"] as? String) ?? ""
            guard body.hasPrefix("You've"), body.contains("limit") else { continue }
            // Ignore events older than this child (a forked resume carries the previous
            // conversation's history - including the very cap event that triggered the handoff).
            if let stamp = object["timestamp"] as? String,
               let when = parseISO(stamp), when < since { continue }
            return true
        }
        return false
    }
}

/// posix_spawnp keeping the child in OUR process group. Foundation's `Process` puts the child in
/// a NEW process group, so the interactive child is background to the terminal and job control
/// stops it with SIGTTIN the moment it reads (claude suspended `T`, blank screen, 2026-07-18).
/// Same-group spawn reproduces what a plain exec gives: the child shares the foreground group.
private func spawnChild(_ argv: [String], environment: [String: String]) -> pid_t? {
    var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cArgs.append(nil)
    var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
    cEnv.append(nil)
    defer { for pointer in cArgs + cEnv { free(pointer) } }
    var pid: pid_t = 0
    return posix_spawnp(&pid, argv[0], nil, nil, cArgs, cEnv) == 0 ? pid : nil
}

/// Resident supervision: spawn claude, tail its transcript, hand off on a cap hit.
///
/// `follow`: adopt a later change to the launch-default model at the next quiet moment. The caller
/// sets it false when the user typed their own `--model` or passed `--no-follow`.
func runSupervised(_ provider: Provider, account initial: Snapshot.Account, args: [String],
                   follow: Bool = false) -> Never {
    let slug = projectSlug(forCwd: FileManager.default.currentDirectoryPath)

    // The parent must survive Ctrl+C - claude uses SIGINT to interrupt a turn, and the whole
    // foreground process group (which the child shares) receives it.
    signal(SIGINT, SIG_IGN)
    signal(SIGQUIT, SIG_IGN)

    var account = initial
    var launchArgs = args.filter { $0 != "--no-handoff" && $0 != "--no-follow" }
    /// The fallback profile fires at most once per session.
    var fallbackApplied = false
    /// The launch-default pair (model, effort) this session currently runs on. A Settings change
    /// is adopted only when the desired pair differs from this one, and this updates on adopt, so
    /// each change fires exactly once and an unchanged policy never churns. The fallback profile
    /// rewrites launchArgs without touching these, so a fallback in effect does not retrigger.
    var followedModel = flagValue(launchArgs, "--model")?.lowercased()
    var followedEffort = flagValue(launchArgs, "--effort")?.lowercased()
    /// Follow debounce: Settings exposes model and effort as two adjacent dropdowns, so one
    /// adjustment can arrive as two policy writes seconds apart. A change is adopted only after
    /// the desired pair has held steady for this long, so one adjustment restarts once, not twice.
    let followDebounce: TimeInterval = 10
    var pendingSince: Date?
    var pendingModel: String?
    var pendingEffort: String?
    /// The recovery fuse for THIS supervisor, held across relaunches: at most 3 automatic
    /// cross-account recoveries per 10 minutes (a cap handoff or a degradation rescue). In memory
    /// and per process, so a fleet-wide drain never trips one session on another's account
    /// switches. Deliberate moves (pin, follow) and same-account relaunches (fallback) do not count.
    var fuse = RecoveryFuse()

    while true {
        let launchedAt = Date()
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: provider.envKey)
        // The status line reads this to show "this session runs under Tally" (✦).
        environment["TALLY_LAUNCHED"] = "1"
        if let env = launchEnv(provider, home: account.launchHome!) {
            environment[env.key] = env.value
        }
        guard let childPID = spawnChild([provider.cli] + launchArgs, environment: environment) else {
            warn("cannot launch `\(provider.cli)`")
            exit(127)
        }

        // One-shot reaper around waitpid: WNOHANG polls, blocking waits, and the status is
        // remembered because a reaped pid cannot be waited on twice.
        var childStatus: Int32?
        func pollChild() {
            guard childStatus == nil else { return }
            var status: Int32 = 0
            if waitpid(childPID, &status, WNOHANG) == childPID { childStatus = status }
        }
        func awaitChild() -> Int32 {
            if let childStatus { return childStatus }
            var status: Int32 = 0
            while waitpid(childPID, &status, 0) == -1, errno == EINTR {}
            childStatus = status
            return status
        }

        var watcher = TranscriptWatcher(
            projectDir: URL(fileURLWithPath: account.launchHome!).appendingPathComponent("projects/\(slug)"),
            since: launchedAt,
            resumeID: flagValue(launchArgs, "--resume") ?? flagValue(launchArgs, "-r"))
        var handoff = false

        // Terminate the child and set up the relaunch on `target` - shared by cap-hit handoffs
        // and live UI pin switches. Continues the SAME conversation when one exists; a session
        // with no transcript yet just starts fresh on the target (any --continue/--resume flags
        // are stripped so it can't pull up an unrelated old conversation there).
        // `countingFuse` records against the per-supervisor fuse: true for AUTOMATIC recoveries
        // (cap handoff, degradation rescue), false for deliberate or same-account relaunches (pin
        // switch, follow adoption, fallback profile) - a Settings change must not eat the budget a
        // real cap hit may need minutes later. `reason` is the audit-log tag only.
        func performHandoff(to target: Snapshot.Account, reason: String, countingFuse: Bool = true) {
            let fromLabel = account.label
            kill(childPID, SIGTERM)   // let claude run its SessionEnd cleanup
            _ = awaitChild()

            watcher.locateFile()
            let sessionFile = watcher.file
            if let sessionFile {
                // Make the transcript visible to the target account (no-op on a shared tree).
                let sourceResolved = sessionFile.resolvingSymlinksInPath()
                let destDir = URL(fileURLWithPath: target.launchHome!)
                    .appendingPathComponent("projects/\(slug)")
                let dest = destDir.appendingPathComponent(sessionFile.lastPathComponent)
                if dest.resolvingSymlinksInPath() != sourceResolved,
                   !FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.createDirectory(at: destDir,
                                                             withIntermediateDirectories: true)
                    try? FileManager.default.copyItem(at: sessionFile, to: dest)
                }
            }

            logHandoff(sessionID: sessionFile?.deletingPathExtension().lastPathComponent,
                       from: fromLabel, to: target.label, reason: reason)
            if countingFuse { fuse.record() }
            account = target
            var next: [String] = []
            var skip = false
            for argument in launchArgs {
                if skip { skip = false; continue }
                switch argument {
                case "--continue", "-c": continue
                case "--resume", "-r": skip = true; continue
                default: next.append(argument)
                }
            }
            if let sessionFile {
                launchArgs = ["--resume", sessionFile.deletingPathExtension().lastPathComponent] + next
            } else {
                launchArgs = next
            }
            handoff = true
        }

        // A cap this child could not hand off yet: remembered across poll ticks so a blocked
        // handoff retries instead of stranding the session. Reset per child - a fresh launch is
        // a clean slate; the previous account's cap is not this one's.
        var pendingCap: PendingCapRecovery?

        pollChild()
        while childStatus == nil {
            usleep(2_000_000)
            pollChild()
            guard childStatus == nil else { break }
            let policy = launchPolicy(provider.id)

            // Cap recovery has top priority: scan for the cap BEFORE any relaunch path (pin,
            // follow, rescue, fallback), because a relaunch resets the watcher's `since` and would
            // filter the cap event as old history and lose it (2026-07-24). The scan also refreshes
            // the model-degradation signal the rescue/fallback blocks below read.
            let sawCap = watcher.sawCapHit()
            // The session came back on its own - a real assistant turn on the main chain, newer
            // than the cap (the account's window refilled, or the user waited the cooldown out) -
            // so a later genuine cap starts fresh.
            if let pending = pendingCap, let recovered = watcher.lastMainChainEventAt,
               recovered > pending.cappedAt {
                warn("\(account.label) resumed on its own - cap recovery cleared")
                pendingCap = nil
            }
            if sawCap, pendingCap == nil {
                pendingCap = PendingCapRecovery(
                    cappedAccountID: account.id, cappedAt: Date(),
                    primaryModel: flagValue(launchArgs, "--model") ?? policy.model,
                    nextRetry: .distantPast, reason: "")
            }

            // Live pin switch: pinning another account in the Tally panel moves the RUNNING
            // session there. An explicit human act, so no fuse; the pinned account is used even
            // when capped (that is what pinning means). Waits for a quiet transcript so an
            // in-flight response is never cut mid-stream (the next 2s poll retries).
            if policy.mode == "manual", let pinnedID = policy.pinnedAccountID, pinnedID != account.id,
               watcher.isQuiet() {
                let (snapshot, _) = loadSnapshot()
                if let target = snapshot?.accounts.first(where: {
                    $0.id == pinnedID && $0.provider == provider.id && $0.launchHome != nil
                }) {
                    warn("pinned in Tally → switching to \(target.label)")
                    performHandoff(to: target, reason: "pin", countingFuse: false)
                    break
                }
            }

            // Cap handoff / wait: a pending cap outranks follow, rescue, and fallback (the pin
            // switch above still wins - moving the pin is an explicit "go here" even mid-cap). The
            // handoff is retried at a backoff while blocked, and the terminal warns only when the
            // waiting reason changes, so a stuck session is never noisy and never abandoned.
            if var pending = pendingCap {
                if Date() >= pending.nextRetry {
                    let (snapshot, snapshotProblem) = loadSnapshot()
                    let primary = pending.primaryModel
                    let target = snapshot?.accounts
                        .filter { $0.provider == provider.id && eligible($0, primaryModel: primary)
                            && $0.id != account.id }
                        .max { smartScore($0, primaryModel: primary)
                            < smartScore($1, primaryModel: primary) }
                    let action = capRecoveryAction(mode: policy.mode, fuseAllows: fuse.allows(),
                                                   snapshotStale: snapshotProblem != nil,
                                                   hasTarget: target != nil)
                    if action == .handoff, let target {
                        warn("cap hit → handing off to \(target.label) " +
                             "(\(pickReason(target, primaryModel: primary)))")
                        performHandoff(to: target, reason: "cap")
                        break
                    }
                    if let note = action.waitingNote, note != pending.reason {
                        warn("\(account.label) capped, \(note)")
                        pending.reason = note
                    }
                    pending.nextRetry = Date().addingTimeInterval(capRetryBackoff)
                    pendingCap = pending
                }
                continue
            }

            // Follow the launch default: changing "Default model & effort" in Settings re-points
            // a RUNNING session at the next quiet moment, on the SAME account and conversation. A
            // deliberate act in the app, like a pin move, so no fuse; works in both auto and
            // pinned modes (it never switches account). `policy` is re-read every 2s loop above
            // already, so the change is noticed without any extra polling. Adoption waits until
            // the desired pair has held steady for `followDebounce` (model and effort are picked
            // one after the other), and a change reverted within the window never restarts.
            if follow {
                let desired = (policy.model?.lowercased(), policy.effort?.lowercased())
                if desired == (followedModel, followedEffort) {
                    pendingSince = nil
                } else if pendingSince == nil || desired != (pendingModel, pendingEffort) {
                    (pendingModel, pendingEffort) = desired
                    pendingSince = Date()
                } else if let since = pendingSince,
                          Date().timeIntervalSince(since) >= followDebounce, watcher.isQuiet() {
                    warn("launch default changed to \(policy.model ?? "default")/" +
                         "\(policy.effort ?? "default") → adopting it")
                    performHandoff(to: account, reason: "follow", countingFuse: false)
                    launchArgs = removingFlagPairs(launchArgs, ["--model", "--effort"])
                    if let model = policy.model { launchArgs += ["--model", model] }
                    if let effort = policy.effort { launchArgs += ["--effort", effort] }
                    (followedModel, followedEffort) = desired
                    pendingSince = nil
                    break
                }
            }

            // The session's ACTUAL model degraded away from the declared primary (claude fell
            // back server-side - e.g. the flagship weekly ran dry). Flagship-first response:
            // a sibling whose flagship window still has real room takes the conversation and
            // KEEPS the primary model. Not for pinned sessions (a pin means "this account"),
            // and under the same fuse as every automatic handoff.
            // The expectation is what THIS session was launched with (a hand-typed --model
            // outranks the configured default - a deliberate haiku session must not be
            // "rescued" back to fable).
            if let primary = (flagValue(launchArgs, "--model") ?? policy.model)?.lowercased(),
               let actual = watcher.lastModel?.lowercased(),
               !actual.contains(primary), policy.mode != "manual", fuse.allows(),
               watcher.isQuiet() {
                let (snapshot, _) = loadSnapshot()
                // Account-switching only cures QUOTA degradation. If THIS account's flagship
                // window still has real room, the cause is something a sibling shares too
                // (live case 2026-07-20: the session's context outgrew the flagship's
                // subscription tier - every account hits that same wall), so switching would
                // just churn the fuse. Skip; if quota IS the cause, the next poll's snapshot
                // shows this account dry and the rescue proceeds.
                let currentDry = (snapshot?.accounts
                    .first { $0.id == account.id }?.modelRemaining).map { $0 <= 5 } ?? true
                let rescue = !currentDry ? nil : snapshot?.accounts
                    .filter { $0.provider == provider.id && eligible($0, primaryModel: policy.model)
                        && $0.id != account.id && ($0.modelRemaining ?? 0) > 5 }
                    .max {
                        smartScore($0, primaryModel: policy.model)
                            < smartScore($1, primaryModel: policy.model)
                    }
                if let rescue {
                    warn("\(actual) took over from \(primary) → moving to \(rescue.label) " +
                         "to stay on \(primary) (\(pickReason(rescue, primaryModel: policy.model)))")
                    performHandoff(to: rescue, reason: "degraded")
                    break
                }
            }

            // Fallback profile: no sibling can serve the primary model, so accept the
            // configured fallback - a weaker model can deserve a different depth and extra
            // flags, so relaunch ONCE with the fallback pairing - same account, same
            // conversation. Deliberate configuration, no fuse.
            if !fallbackApplied,
               let fallbackList = policy.fallbackModel,
               policy.fallbackEffort != nil || policy.fallbackArgs != nil,
               let actual = watcher.lastModel?.lowercased(),
               (flagValue(launchArgs, "--model") ?? policy.model)
                   .map({ !actual.contains($0.lowercased()) }) ?? true,
               let matched = fallbackList.split(separator: ",")
                   .map({ $0.trimmingCharacters(in: .whitespaces).lowercased() })
                   .first(where: { !$0.isEmpty && actual.contains($0) }),
               watcher.isQuiet() {
                warn("model fell back to \(actual) → applying fallback profile")
                performHandoff(to: account, reason: "fallback", countingFuse: false)
                launchArgs = removingFlagPairs(launchArgs, ["--model", "--effort"])
                launchArgs += ["--model", matched]
                if let effort = policy.fallbackEffort { launchArgs += ["--effort", effort] }
                if let extra = policy.fallbackArgs {
                    launchArgs += extra.split(separator: " ").map(String.init)
                }
                fallbackApplied = true
                break
            }
        }

        if handoff { continue }
        let status = awaitChild()   // no relaunch pending: the child exited on its own, so do we
        let exited = (status & 0x7f) == 0
        exit(exited ? (status >> 8) & 0xff : 128 + (status & 0x7f))
    }
}
