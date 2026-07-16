import Darwin
import Foundation

// Auto-handoff supervision (Phase B).
//
// `tally claude` stays resident as a thin parent around the interactive claude child. It tails the
// session transcript for a cap-hit event; on a hit it terminates the child, re-picks the best other
// account, and relaunches `claude --resume <session>` in the same terminal — the conversation
// continues on the fresh account with no manual step.
//
// Detection is grounded in real transcript data (this machine's history, 2026-07-16): genuine cap
// hits are `isApiErrorMessage:true` events whose text starts with "You've" ("You've hit your
// session limit…", "You've reached your Fable 5 limit…"). Server-side trouble ("API Error: …",
// "Server is temporarily limiting requests (not your usage limit)", 529/500, login expiry) never
// starts with "You've" and must never trigger a handoff.

let handoffFuseWindow: TimeInterval = 10 * 60
let handoffFuseMax = 3
let handoffLog = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/handoff.log")

func autoHandoffEnabled(args: [String]) -> Bool {
    if args.contains("--no-handoff") { return false }
    if let raw = getenv("TALLY_AUTO_HANDOFF"), String(cString: raw) == "0" { return false }
    return true
}

/// True when the fuse still has room: at most `handoffFuseMax` handoffs per rolling window,
/// so a systemic failure (e.g. every account capped) can't burn through logins in a loop.
func fuseAllows(now: Date = Date()) -> Bool {
    guard let text = try? String(contentsOf: handoffLog, encoding: .utf8) else { return true }
    let recent = text.split(separator: "\n")
        .compactMap { Double($0) }
        .filter { now.timeIntervalSince1970 - $0 < handoffFuseWindow }
    return recent.count < handoffFuseMax
}

func recordHandoff(now: Date = Date()) {
    let line = "\(now.timeIntervalSince1970)\n"
    if let handle = try? FileHandle(forWritingTo: handoffLog) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? FileManager.default.createDirectory(at: handoffLog.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data(line.utf8).write(to: handoffLog)
    }
}

/// Watches one session transcript for a cap-hit event newer than `since`.
struct TranscriptWatcher {
    let projectDir: URL
    var file: URL?
    var offset: UInt64 = 0
    let since: Date

    /// The newest session transcript created/updated after launch — the child's session.
    mutating func locateFile() {
        guard file == nil else { return }
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
            guard line.contains("\"isApiErrorMessage\":true") else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = object["message"] as? [String: Any] else { continue }
            let content = message["content"]
            let body = (content as? String)
                ?? ((content as? [[String: Any]])?.first?["text"] as? String) ?? ""
            guard body.hasPrefix("You've"), body.contains("limit") else { continue }
            // Ignore events older than this child (a forked resume carries the previous
            // conversation's history — including the very cap event that triggered the handoff).
            if let stamp = object["timestamp"] as? String,
               let when = parseISO(stamp), when < since { continue }
            return true
        }
        return false
    }
}

/// Resident supervision: spawn claude, tail its transcript, hand off on a cap hit.
func runSupervised(_ provider: Provider, account initial: Snapshot.Account, args: [String]) -> Never {
    let slug = projectSlug(forCwd: FileManager.default.currentDirectoryPath)

    // The parent must survive Ctrl+C — claude uses SIGINT to interrupt a turn, and the whole
    // foreground process group receives it.
    signal(SIGINT, SIG_IGN)
    signal(SIGQUIT, SIG_IGN)

    var account = initial
    var launchArgs = args.filter { $0 != "--no-handoff" }

    while true {
        let launchedAt = Date()
        let child = Process()
        // Resolve via PATH like execvp does.
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = [provider.cli] + launchArgs
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: provider.envKey)
        if let env = launchEnv(provider, home: account.launchHome!) {
            environment[env.key] = env.value
        }
        child.environment = environment
        do {
            try child.run()
        } catch {
            warn("cannot launch `\(provider.cli)`: \(error.localizedDescription)")
            exit(127)
        }

        var watcher = TranscriptWatcher(
            projectDir: URL(fileURLWithPath: account.launchHome!).appendingPathComponent("projects/\(slug)"),
            since: launchedAt)
        var handoff = false

        while child.isRunning {
            usleep(2_000_000)
            guard watcher.sawCapHit() else { continue }
            guard fuseAllows() else {
                warn("cap hit, but \(handoffFuseMax) handoffs in \(Int(handoffFuseWindow / 60))m — staying put")
                break
            }
            // Re-read the snapshot NOW; the best other account is the handoff target.
            let (snapshot, _) = loadSnapshot()
            let target = snapshot?.accounts
                .filter { $0.provider == provider.id && eligible($0) && $0.id != account.id }
                .max { headroom($0) < headroom($1) }
            guard let target else {
                warn("cap hit, but no other eligible account — staying put")
                break
            }
            guard let sessionFile = watcher.file else { break }
            let sessionID = sessionFile.deletingPathExtension().lastPathComponent

            warn("cap hit → handing off to \(target.label) (headroom \(Int(headroom(target).rounded()))%)")
            child.terminate()   // SIGTERM: let claude run its SessionEnd cleanup
            child.waitUntilExit()

            // Make the transcript visible to the target account (no-op on a shared projects tree).
            let sourceResolved = sessionFile.resolvingSymlinksInPath()
            let destDir = URL(fileURLWithPath: target.launchHome!).appendingPathComponent("projects/\(slug)")
            let dest = destDir.appendingPathComponent(sessionFile.lastPathComponent)
            if dest.resolvingSymlinksInPath() != sourceResolved,
               !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: sessionFile, to: dest)
            }

            recordHandoff()
            account = target
            // Continue the SAME conversation: swap any resume/continue flags for an explicit
            // --resume of the session we were supervising.
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
            launchArgs = ["--resume", sessionID] + next
            handoff = true
            break
        }

        if handoff { continue }
        if child.isRunning { child.waitUntilExit() }   // fuse/no-target: claude keeps running
        exit(child.terminationStatus)
    }
}
