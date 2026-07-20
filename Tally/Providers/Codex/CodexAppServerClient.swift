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
        /// Reset banking (verified live 2026-07-19): `result.rateLimitResetCredits.availableCount`.
        var resetCreditsAvailable: Int?
        /// When the soonest available banked reset expires (drives the redeem dialog's context).
        var resetCreditsNextExpiry: Date?
    }

    private struct RPCLine: Decodable {
        let id: Int?
        let result: Result?
        struct Result: Decodable {
            let rateLimits: RateLimits?
            let rateLimitResetCredits: ResetCredits?
        }
    }

    private struct ResetCredits: Decodable {
        let availableCount: Int?
        let credits: [Credit]?
        struct Credit: Decodable {
            let id: String?
            let status: String?
            let expiresAt: Double?
        }
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

    /// Distinguishes the failure the user can act on: `cliBroken` means the app-server process
    /// died before answering (a codex too old to know `app-server`, or one that crashes on
    /// launch), where "read failed" would send the user chasing network or login ghosts.
    enum Outcome {
        case ok(Reading)
        case cliBroken
        case failed
    }

    static func read(codexHome: String, timeout: TimeInterval = 20) async -> Outcome {
        guard let binary = CLIRunner.resolve("codex") else { return .failed }
        let attempt: (line: Data?, processDied: Bool) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: rateLimitsLine(binary: binary, codexHome: codexHome,
                                                              timeout: timeout))
            }
        }
        guard let raw = attempt.line else { return attempt.processDied ? .cliBroken : .failed }
        guard let line = try? JSONDecoder().decode(RPCLine.self, from: raw),
              let limits = line.result?.rateLimits else { return .failed }

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
        let nextExpiry = line.result?.rateLimitResetCredits?.credits?
            .filter { $0.status == "available" }
            .compactMap(\.expiresAt)
            .min()
            .map { Date(timeIntervalSince1970: $0) }
        return .ok(Reading(metrics: metrics.uniquingIDs(), plan: (plan?.isEmpty == false) ? plan : nil,
                           resetCreditsAvailable: line.result?.rateLimitResetCredits?.availableCount,
                           resetCreditsNextExpiry: nextExpiry))
    }

    /// Redeems the SOONEST-EXPIRING available banked reset for this account (waste-minimizing
    /// order), via the official app-server's `account/rateLimitResetCredit/consume`. The only
    /// write Tally ever performs against a provider, and only ever behind an explicit user
    /// confirmation. Returns a short outcome token ("redeemed", "noCredit", …); nil = transport
    /// failure before an answer.
    static func consumeSoonestResetCredit(codexHome: String, timeout: TimeInterval = 30) async -> String? {
        guard let binary = CLIRunner.resolve("codex") else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: consumeFlow(binary: binary, codexHome: codexHome,
                                                           timeout: timeout))
            }
        }
    }

    private static func consumeFlow(binary: String, codexHome: String,
                                    timeout: TimeInterval) -> String? {
        guard let session = RPCSession(binary: binary, codexHome: codexHome) else { return nil }
        defer { session.close() }
        let deadline = Date().addingTimeInterval(timeout)
        session.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"Tally","version":"1.0"}}}"#)
        guard session.awaitLine(id: 1, until: deadline) != nil else { return nil }
        session.send(#"{"jsonrpc":"2.0","method":"initialized","params":{}}"#)
        session.send(#"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}"#)
        guard let limitsLine = session.awaitLine(id: 2, until: deadline),
              let line = try? JSONDecoder().decode(RPCLine.self, from: limitsLine),
              let credit = line.result?.rateLimitResetCredits?.credits?
                  .filter({ $0.status == "available" && $0.id?.isEmpty == false })
                  .min(by: { ($0.expiresAt ?? .infinity) < ($1.expiresAt ?? .infinity) }),
              let creditID = credit.id
        else { return "noCredit" }
        // idempotencyKey: the server's own double-spend guard - a retry of THIS request can
        // never consume a second credit.
        session.send(#"{"jsonrpc":"2.0","id":3,"method":"account/rateLimitResetCredit/consume","params":{"creditId":"\#(creditID)","idempotencyKey":"\#(UUID().uuidString)"}}"#)
        guard let outcomeLine = session.awaitLine(id: 3, until: deadline),
              let object = try? JSONSerialization.jsonObject(with: outcomeLine) as? [String: Any]
        else { return nil }
        if let error = object["error"] as? [String: Any] {
            return (error["message"] as? String) ?? "error"
        }
        // Outcome shape kept tolerant: surface whatever token the server answers with.
        if let result = object["result"] as? [String: Any] {
            if let outcome = result["outcome"] as? String { return outcome }
            if let status = result["status"] as? String { return status }
            return "redeemed"
        }
        return "redeemed"
    }

    /// Blocking JSON-RPC exchange (runs on a utility queue): the raw response line for request 2.
    private static func rateLimitsLine(binary: String, codexHome: String,
                                       timeout: TimeInterval) -> (line: Data?, processDied: Bool) {
        guard let session = RPCSession(binary: binary, codexHome: codexHome) else { return (nil, true) }
        defer { session.close() }
        let deadline = Date().addingTimeInterval(timeout)
        session.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"Tally","version":"1.0"}}}"#)
        guard session.awaitLine(id: 1, until: deadline) != nil else {
            return (nil, session.processDied)
        }
        session.send(#"{"jsonrpc":"2.0","method":"initialized","params":{}}"#)
        session.send(#"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}"#)
        return (session.awaitLine(id: 2, until: deadline), session.processDied)
    }
}

/// One live app-server process with line-indexed responses: send JSON-RPC strings, await a
/// response id, close. Shared by the read path and the consume flow.
private final class RPCSession {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let buffer = RPCLineBuffer()

    init?(binary: String, codexHome: String) {
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = codexHome
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [buffer] handle in
            buffer.append(handle.availableData)
        }
    }

    /// True when app-server exited on its own (old codex without the subcommand, or a crash),
    /// which callers use to tell "broken CLI" apart from a slow or unresponsive one.
    var processDied: Bool { !process.isRunning }

    func send(_ json: String) {
        stdinPipe.fileHandleForWriting.write(Data((json + "\n").utf8))
    }

    func awaitLine(id: Int, until deadline: Date) -> Data? {
        while buffer.line(withID: id) == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return buffer.line(withID: id)
    }

    func close() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
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
