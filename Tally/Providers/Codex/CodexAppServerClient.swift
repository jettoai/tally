import Foundation

/// Reads Codex usage through the official CLI's app-server (JSON-RPC over stdio):
/// `initialize` → `initialized` → `account/rateLimits/read` → `account/read`. The CLI talks to its
/// vendor with its own first-party identity and credentials - Tally never reads `auth.json` tokens.
///
/// Response shape verified live (2026-07-17): `result.rateLimits.{primary,secondary}` carry
/// `usedPercent` / `windowDurationMins` / `resetsAt` (epoch s), plus `planType` - camelCase,
/// unlike the old HTTP endpoint's snake_case.
///
/// The second request is who the account is (2026-08-04). It rides in the SAME session rather than
/// in a process of its own: an extra `codex app-server` per account per poll would double the spawn
/// cost of every refresh for one string, and the answer belongs to the login this session already
/// opened.
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
    ///
    /// A read that failed CARRIES WHY where it could tell, for the same reason: the vendor
    /// answering the usage request with an error of its own is not this app being broken, and
    /// three failures under one word left nothing to act on either (`CodexReadFailure`). Nil where
    /// this path could not tell, which no surface treats as a fourth kind.
    enum Outcome {
        case ok(Reading)
        case cliBroken
        case failed(CodexReadFailure?)
    }

    /// What one read came home with. Identity sits BESIDE the outcome rather than inside `Reading`
    /// because the two questions fail apart: a session that could not produce numbers may still
    /// have named its account, and a card whose poll failed still gets to say whose it is - the
    /// same rule Claude's provider already follows.
    struct Answer {
        var outcome: Outcome
        var accountEmail: String?
    }

    static func read(codexHome: String, timeout: TimeInterval = 20) async -> Answer {
        guard let binary = CLIRunner.resolve("codex") else { return Answer(outcome: .failed(nil)) }
        let attempt: Exchange = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: readExchange(binary: binary, codexHome: codexHome,
                                                            timeout: timeout))
            }
        }
        let email = attempt.account.flatMap(CodexIdentity.email(inAccountRead:))
        func answer(_ outcome: Outcome) -> Answer {
            Answer(outcome: outcome, accountEmail: email)
        }
        // Asked only where the read has already failed: classifying it reads the line again, and a
        // poll that WORKED must not pay for a question about failure (`CodexReadFailure`).
        func why() -> CodexReadFailure? {
            CodexReadFailure.of(limitsLine: attempt.limits, processDied: attempt.processDied,
                                timeout: timeout)
        }
        guard let raw = attempt.limits else {
            return answer(attempt.processDied ? .cliBroken : .failed(why()))
        }
        guard let line = try? JSONDecoder().decode(RPCLine.self, from: raw),
              let limits = line.result?.rateLimits else { return answer(.failed(why())) }

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
        return answer(.ok(Reading(
            metrics: metrics.uniquingIDs(), plan: (plan?.isEmpty == false) ? plan : nil,
            resetCreditsAvailable: line.result?.rateLimitResetCredits?.availableCount,
            resetCreditsNextExpiry: nextExpiry)))
    }

    /// Redeems the SOONEST-EXPIRING available banked reset for this account (waste-minimizing
    /// order), via the official app-server's `account/rateLimitResetCredit/consume`. The only
    /// write Tally ever performs against a provider, and only ever behind an explicit user
    /// confirmation. Returns a short outcome token ("redeemed", "noCredit", …); nil = transport
    /// failure before an answer.
    static func consumeSoonestResetCredit(codexHome: String,
                                          timeout: TimeInterval = 30) async -> RedeemOutcome {
        guard let binary = CLIRunner.resolve("codex") else { return .failed(nil) }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: classifyRedeem(
                    consumeFlow(binary: binary, codexHome: codexHome, timeout: timeout)))
            }
        }
    }

    /// What a redeem attempt actually did, in the app's own terms. The server answers with a bare
    /// protocol token whose vocabulary is its own ("reset", "redeemed", an error message), and the
    /// panel used to print any token it could not recognise verbatim: a successful redeem answered
    /// with "reset" surfaced as a lowercase English word floating under the card (2026-07-25). A
    /// closed type makes that structurally impossible - no raw token can reach a view again.
    enum RedeemOutcome: Equatable {
        case redeemed
        case alreadyUsed
        case noCredit
        /// The server's own words, kept for the hover tooltip only, never for the row.
        case failed(String?)
    }

    /// Map the server's token onto the closed set. Success is spelled several ways across versions,
    /// so recognition is by vocabulary rather than one exact string, and anything unrecognised is a
    /// failure carrying its detail rather than a mystery word in the UI.
    static func classifyRedeem(_ token: String?) -> RedeemOutcome {
        guard let token, !token.isEmpty else { return .failed(nil) }
        let lowered = token.lowercased()
        if lowered.contains("already") { return .alreadyUsed }
        if lowered == "nocredit" { return .noCredit }
        for word in ["redeem", "reset", "success", "consumed", "ok"] where lowered.contains(word) {
            return .redeemed
        }
        return .failed(token)
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

    /// How long the identity answer may lag behind the numbers before the session gives up on it.
    private static let identityGrace: TimeInterval = 3

    /// The raw response lines one session came home with.
    private struct Exchange {
        var limits: Data?
        var account: Data?
        var processDied: Bool
    }

    /// Blocking JSON-RPC exchange (runs on a utility queue): the raw response lines for requests 2
    /// and 3. Both are written before either is awaited, so the second question costs a round trip
    /// the server is already answering rather than a second wait.
    private static func readExchange(binary: String, codexHome: String,
                                     timeout: TimeInterval) -> Exchange {
        guard let session = RPCSession(binary: binary, codexHome: codexHome) else {
            return Exchange(limits: nil, account: nil, processDied: true)
        }
        defer { session.close() }
        let deadline = Date().addingTimeInterval(timeout)
        session.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"Tally","version":"1.0"}}}"#)
        guard session.awaitLine(id: 1, until: deadline) != nil else {
            return Exchange(limits: nil, account: nil, processDied: session.processDied)
        }
        session.send(#"{"jsonrpc":"2.0","method":"initialized","params":{}}"#)
        session.send(#"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}"#)
        session.send(#"{"jsonrpc":"2.0","id":3,"method":"account/read","params":{}}"#)
        let limits = session.awaitLine(id: 2, until: deadline)
        // Identity is the optional half, and it was asked one line after the numbers: by the time
        // they land its answer is already on the way. So it gets a short grace rather than the
        // whole deadline - a codex that simply never answers it must not hold a refresh open.
        let account = session.awaitLine(id: 3, until: min(deadline,
                                                          Date().addingTimeInterval(identityGrace)))
        return Exchange(limits: limits, account: account, processDied: session.processDied)
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
