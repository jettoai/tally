import Foundation

// `tally codex-update [--if-due] [--codex <path>] [--timeout <sec>] [--trigger skip]`: Tally updating
// Codex outside any window, so the window it opens next has no startup menu to show. Run by the app
// every ten minutes with `--if-due` (Tally/Core/CodexUpdateSchedule.swift, an hourly check) and by a
// supervisor right after a `tally session skip-update` chose Skip. Same lock, attempt file and
// backoff as the pre-launch update (`updateCodex`, CodexUpdatePreflight.swift). Internal: not listed.

let codexUpdateLog = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tally/logs/codex-update.log")
private let codexUpdateCheckFile = codexUpdateStateDir.appendingPathComponent("codex-update-check.json")

private struct CodexUpdateCheck: Codable {
    var checkedAt: Date
}

func runCodexUpdate(args: [String]) -> Int32 {
    var ifDue = false, codexPath: String?, timeout: TimeInterval = 900, trigger = "manual"
    var rest = args[...]
    while let flag = rest.popFirst() {
        switch flag {
        case "--if-due": ifDue = true; trigger = "schedule"
        case "--codex": codexPath = rest.popFirst()
        case "--timeout":
            guard let value = rest.popFirst().flatMap(TimeInterval.init), value > 0 else { return 2 }
            timeout = value
        case "--trigger":
            guard rest.popFirst() == "skip" else { return 2 }
            trigger = "skip"
        default:
            warn("usage: tally codex-update [--if-due] [--codex <path>] [--timeout <sec>] [--trigger skip]")
            return 2
        }
    }
    let encoder = JSONEncoder(), decoder = JSONDecoder()
    encoder.dateEncodingStrategy = .iso8601
    decoder.dateDecodingStrategy = .iso8601
    let started = Date()
    if ifDue {
        let last = (try? Data(contentsOf: codexUpdateCheckFile)).flatMap { try? decoder.decode(CodexUpdateCheck.self, from: $0) }
        guard codexUpdateCheckDue(lastCheckedAt: last?.checkedAt, now: started) else { return 0 }
        // Written before checking, so a check that fails still waits its hour.
        try? FileManager.default.createDirectory(at: codexUpdateStateDir, withIntermediateDirectories: true)
        try? encoder.encode(CodexUpdateCheck(checkedAt: started)).write(to: codexUpdateCheckFile, options: .atomic)
    }
    let codex = codexPath ?? resolveProviderExecutable("codex")
    func record(_ result: String, from: String?, to: String?) -> Int32 {
        appendHandoffLine(codexUpdateLogLine(at: started, trigger: trigger, codex: codex, from: from, to: to, result: result,
                                             seconds: Int(Date().timeIntervalSince(started))), to: codexUpdateLog)
        return codexUpdateExitCode(result)
    }
    let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
    let homes = Array(Set((loadSnapshot().0?.accounts ?? []).filter { $0.provider == "codex" }.compactMap(\.launchHome) + [fallback]))
    let best = codexBestCandidate(homes.sorted().map { home in
        let url = URL(fileURLWithPath: home)
        let config = (try? String(contentsOf: url.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        return (home, try? Data(contentsOf: url.appendingPathComponent("version.json")), codexConfigDisablesUpdateCheck(config))
    })
    guard let best else { return record("no-candidate", from: nil, to: nil) }
    let installed = codexInstalledVersionRemembered(codex)
    switch codexUpdateNeed(candidate: best.version, installed: installed) {
    case .none:
        return record("current", from: installed, to: best.version)
    case .installedUnknown:
        return record("installed-unknown", from: nil, to: best.version)
    case .available(let latest):
        func stamp() -> Date? { (try? FileManager.default.attributesOfItem(atPath: codexUpdateAttemptURL.path))?[.modificationDate] as? Date }
        let before = stamp()
        let ok = updateCodex(codex, to: latest, home: best.home, timeout: timeout,
            announce: "Codex \(latest) is available; updating in the background (up to \(Int(timeout / 60)) min)...")
        if ok { return record("updated", from: installed, to: codexInstalledVersionRemembered(codex) ?? latest) }
        let attempt = (try? Data(contentsOf: codexUpdateAttemptURL)).flatMap(decodeCodexUpdateAttempt)
        let result = codexUpdateShortfallResult(attemptRewritten: before == nil || stamp() != before, attempt: attempt)
        return record(result, from: installed, to: result == "unpublished" ? attempt?.reached : latest)
    }
}
