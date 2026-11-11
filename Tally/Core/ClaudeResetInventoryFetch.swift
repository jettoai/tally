import Foundation
import OSLog

/// Reads one Claude login's limit-reset inventory from Anthropic's OAuth usage endpoint, the same
/// request Claude Code 2.1.311 makes for its own `/usage` (`cedar_ember=1&skip_spend=1`).
///
/// THE ONE PLACE TALLY SENDS A CLAUDE TOKEN ANYWHERE, so its rules are spelled out here:
/// - The token comes from the credential Claude Code keeps, through the prompt-free read the
///   login-expiry check already uses (`ClaudeLoginExpiryKeychain.read`, gated by
///   `permitsSecurityRead`). A Keychain that would ask is skipped, never prompted.
/// - It lives in memory for one request. No log, file, snapshot or error carries it, and
///   `Credential` prints as redacted, so an interpolation by mistake cannot leak it either.
/// - An expired token is not refreshed: Claude Code refreshes its own on its next `/usage`, and
///   rotating a credential another process owns could sign that process out. This waits instead.
/// - Redirects are refused, so the Authorization header goes to the one host named below.
enum ClaudeResetInventoryFetch {
    struct Credential: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        fileprivate let accessToken: String
        let expiresAt: Date
        var description: String { "Credential(<redacted>)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: ["expiresAt": expiresAt]) }
    }

    enum Outcome: Equatable {
        case read(ClaudeResetInventory)
        /// No token usable without a prompt, or the one there has expired. Nothing was sent.
        case noCredential
        /// The request went out and no readable body came back. Carries the HTTP status only.
        case failed(status: Int?)
    }

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!

    /// The usable access token in a Claude Code credential document, or nil when it is missing,
    /// undated, or inside a minute of expiry (so it cannot run out in flight).
    static func credential(from document: Data, now: Date) -> Credential? {
        guard let root = (try? JSONSerialization.jsonObject(with: document)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty,
              let number = oauth["expiresAt"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        // Epoch milliseconds, the same bounds `ClaudeLoginExpiry` holds the refresh deadline to.
        let milliseconds = number.doubleValue
        guard milliseconds.isFinite, milliseconds >= 1_000_000_000_000,
              milliseconds <= 253_402_300_799_999 else { return nil }
        let expiresAt = Date(timeIntervalSince1970: milliseconds / 1000)
        guard expiresAt.timeIntervalSince(now) > 60 else { return nil }
        return Credential(accessToken: token, expiresAt: expiresAt)
    }

    /// The Keychain item wins as a whole, as it does for the login deadline: an existing item that
    /// is locked, denied or malformed does not make an older `.credentials.json` the live login.
    static func readCredential(home: String, defaultHome: String, now: Date,
                               keychainRead: (String) -> ClaudeLoginExpiry.Source,
                               fileRead: (URL) -> Data?) -> Credential? {
        let keychain = keychainRead(ClaudeLoginExpiry.keychainService(home: home, defaultHome: defaultHome))
        if let data = keychain.data { return credential(from: data, now: now) }
        guard keychain.isAbsent else { return nil }
        return fileRead(URL(fileURLWithPath: home).appendingPathComponent(".credentials.json"))
            .flatMap { credential(from: $0, now: now) }
    }

    /// Claude Code's version for the User-Agent when the installed one cannot be read.
    static let fallbackVersion = "2.1.311"

    /// Claude Code's own client name. The server answers `cedar_ember` by client: without it the
    /// same token reads as `eligible: false` with no grants (Tally Dev, 2026-11-11).
    static func userAgent(version: String) -> String { "claude-cli/\(version) (external, cli)" }

    /// The version the way Claude Code finds its own: the last component of the path the `claude`
    /// launcher resolves to (`~/.local/bin/claude` -> `~/.local/share/claude/versions/2.1.311`).
    /// Anything that is not a plain x.y.z there (an npm `cli.js`, a wrapper script, no CLI at all)
    /// gets the fallback, which also keeps whatever the file system says out of a request header.
    static func version(executable: String?) -> String {
        guard let executable else { return fallbackVersion }
        let last = URL(fileURLWithPath: executable).resolvingSymlinksInPath().lastPathComponent
        return last.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil ? last : fallbackVersion
    }

    static func request(_ credential: Credential, version: String) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue(userAgent(version: version), forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// One account's inventory. The credential read (a `security` child process) and
    /// `clientVersion` (a PATH search and a symlink read, `version(executable:)`) run detached, so
    /// no caller's thread waits on them.
    static func fetch(home: String, clientVersion: @escaping @Sendable () -> String) async -> Outcome {
        let (credential, version) = await Task.detached(priority: .utility) {
            (readCredential(home: home,
                            defaultHome: FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent(".claude").path,
                            now: Date(),
                            keychainRead: ClaudeLoginExpiryKeychain.read,
                            fileRead: { try? Data(contentsOf: $0) }),
             clientVersion())
        }.value
        guard let credential else { return .noCredential }
        let response = try? await session.data(for: request(credential, version: version),
                                               delegate: NoRedirects())
        guard let (body, reply) = response else { return .failed(status: nil) }
        let status = (reply as? HTTPURLResponse)?.statusCode
        if status == 200 {
            let seen = ClaudeResetInventory.programFields(body)
            log.info("response status=200 cedar_ember=\(seen.block, privacy: .public) eligible=\(seen.eligible, privacy: .public) ineligible_reason=\(seen.reason, privacy: .public) client=\(version, privacy: .public)")
        }
        guard status == 200, let inventory = ClaudeResetInventory.parse(body, now: Date()) else {
            return .failed(status: status)
        }
        return .read(inventory)
    }

    private static let log = Logger(subsystem: "ai.jetto.tally", category: "reset-inventory")

    /// Nothing written to disk: no URL cache, no cookies, no credential store.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
