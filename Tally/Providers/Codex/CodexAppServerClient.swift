import Foundation

/// Reads Codex usage through the official CLI's app-server (JSON-RPC over stdio):
/// `initialize` → `initialized` → `account/rateLimits/read`. The CLI talks to its vendor with its
/// own first-party identity and credentials - Tally never reads `auth.json` tokens.
///
/// Response shape verified live (2026-07-17): `result.rateLimits.{primary,secondary}` carry
/// `usedPercent` / `windowDurationMins` / `resetsAt` (epoch s), plus `planType` - camelCase,
/// unlike the old HTTP endpoint's snake_case.
enum CodexAppServerClient {
    struct Reading: Sendable {
        var metrics: [UsageMetric]
        var plan: String?
    }

    private struct RPCLine: Decodable {
        let id: Int?
        let result: Result?
        struct Result: Decodable { let rateLimits: RateLimits? }
    }

    private struct RateLimits: Decodable {
        struct Window: Decodable {
            let usedPercent: Double?
            let windowDurationMins: Double?
            let resetsAt: Double?
        }
        let primary: Window?
        let secondary: Window?
        let planType: String?
    }

    static func read(codexHome: String, timeout: TimeInterval = 20) async -> Reading? {
        guard let binary = CLIRunner.resolve("codex") else { return nil }
        let raw: Data? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: rateLimitsLine(binary: binary, codexHome: codexHome,
                                                              timeout: timeout))
            }
        }
        guard let raw,
              let line = try? JSONDecoder().decode(RPCLine.self, from: raw),
              let limits = line.result?.rateLimits else { return nil }

        var metrics: [UsageMetric] = []
        for window in [limits.primary, limits.secondary].compactMap({ $0 }) {
            guard let used = window.usedPercent else { continue }
            let isWeekly = (window.windowDurationMins ?? 0) >= 1_440
            metrics.append(UsageMetric(
                id: isWeekly ? "weekly_all" : "session",
                kind: isWeekly ? .weeklyAll : .session,
                label: isWeekly ? "Weekly" : "Session",
                modelName: nil,
                usedPercent: used, severity: .fromUsedPercent(used),
                resetsAt: window.resetsAt.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                isActive: false))
        }
        let plan = limits.planType?.trimmingCharacters(in: .whitespaces).capitalized
        return Reading(metrics: metrics.uniquingIDs(), plan: (plan?.isEmpty == false) ? plan : nil)
    }

    /// Blocking JSON-RPC exchange (runs on a utility queue): the raw response line for request 2.
    private static func rateLimitsLine(binary: String, codexHome: String, timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = codexHome
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }

        let buffer = RPCLineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            buffer.append(handle.availableData)
        }
        func send(_ json: String) {
            stdin.fileHandleForWriting.write(Data((json + "\n").utf8))
        }

        let deadline = Date().addingTimeInterval(timeout)
        send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"Tally","version":"1.0"}}}"#)
        while buffer.line(withID: 1) == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        guard buffer.line(withID: 1) != nil else { return nil }
        send(#"{"jsonrpc":"2.0","method":"initialized","params":{}}"#)
        send(#"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}"#)
        while buffer.line(withID: 2) == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        return buffer.line(withID: 2)
    }
}

/// Accumulates app-server stdout and indexes complete JSON-RPC lines by response id.
/// Thread-safe: the readability handler appends from its own queue while the RPC loop polls.
private final class RPCLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var byID: [Int: Data] = [:]

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending.prefix(upTo: newline))
            pending.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = object["id"] as? Int else { continue }
            byID[id] = line
        }
    }

    func line(withID id: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return byID[id]
    }
}
