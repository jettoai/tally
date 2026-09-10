import Foundation
import CoreFoundation
import CryptoKit

/// Reads the saved login deadline without refreshing or changing credentials.
enum ClaudeLoginExpiry {
    struct Reading: Equatable, Sendable {
        var refreshTokenExpiresAt: Date?
        var credentialModifiedAt: Date?
    }

    enum State: Equatable { case unknown, valid, expiring, expired }

    static let warningInterval: TimeInterval = 3 * 24 * 60 * 60

    static func state(deadline: Date?, now: Date = Date()) -> State {
        guard let deadline, deadline.timeIntervalSince1970.isFinite else { return .unknown }
        let remaining = deadline.timeIntervalSince(now)
        if remaining <= 0 { return .expired }
        return remaining <= warningInterval ? .expiring : .valid
    }

    static func read(home: String) async -> Reading {
        await Task.detached(priority: .utility) {
            readSynchronously(home: home,
                              defaultHome: FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent(".claude").path,
                              keychainRead: ClaudeLoginExpiryKeychain.read,
                              fileRead: readFile)
        }.value
    }

    /// Secret bytes stay inside the read operation; its public result contains dates only.
    struct Source {
        var data: Data?
        var modifiedAt: Date?
        var isAbsent = false
    }

    static func readSynchronously(home: String, defaultHome: String,
                                  keychainRead: (String) -> Source,
                                  fileRead: (URL) -> Source) -> Reading {
        let service = keychainService(home: home, defaultHome: defaultHome)
        let keychain = keychainRead(service)
        // A readable Keychain document wins as a whole, including a missing deadline.
        if let data = keychain.data, let document = document(data) {
            return Reading(refreshTokenExpiresAt: deadline(document),
                           credentialModifiedAt: keychain.modifiedAt)
        }
        // A locked, denied, or malformed existing item does not prove an older file is active.
        guard keychain.isAbsent else {
            return Reading(refreshTokenExpiresAt: nil, credentialModifiedAt: keychain.modifiedAt)
        }
        let file = fileRead(URL(fileURLWithPath: home).appendingPathComponent(".credentials.json"))
        let expiry = file.data.flatMap(document).flatMap(deadline)
        return Reading(refreshTokenExpiresAt: expiry,
                       credentialModifiedAt: file.modifiedAt ?? keychain.modifiedAt)
    }

    static func keychainService(home: String, defaultHome: String) -> String {
        let dir = URL(fileURLWithPath: home).standardizedFileURL
        let defaultDir = URL(fileURLWithPath: defaultHome).standardizedFileURL
        if dir.path == defaultDir.path { return claudeBaseKeychainService }
        if dir.lastPathComponent != ".claude" { return claudeKeychainService(forConfigDir: dir) }
        // The shared helper uses a basename shortcut. A custom /elsewhere/.claude is not default.
        let normalized = dir.path.precomposedStringWithCanonicalMapping
        let suffix = SHA256.hash(data: Data(normalized.utf8)).prefix(4)
            .map { String(format: "%02x", $0) }.joined()
        return "\(claudeBaseKeychainService)-\(suffix)"
    }

    static func parse(_ data: Data) -> Date? { document(data).flatMap(deadline) }

    private static func document(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func deadline(_ document: [String: Any]) -> Date? {
        guard let oauth = document["claudeAiOauth"] as? [String: Any],
              let number = oauth["refreshTokenExpiresAt"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let milliseconds = number.doubleValue
        // The observed format is epoch milliseconds. Reject seconds-shaped values, not guess units.
        // Bounds cover September 2001 through year 9999 and exclude overflow and nonfinite values.
        guard milliseconds.isFinite, milliseconds >= 1_000_000_000_000,
              milliseconds <= 253_402_300_799_999,
              milliseconds.rounded(.towardZero) == milliseconds else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func readFile(_ url: URL) -> Source {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return Source(data: try? Data(contentsOf: url), modifiedAt: date)
    }

    /// `security -w` prints hex when the JSON contains non-ASCII bytes, such as an MCP label.
    static func decodeSecurityOutput(_ printed: Data) -> Data {
        let text = printed.last == 0x0a ? Data(printed.dropLast()) : printed
        guard let decoded = hexDecoded(text),
              decoded.contains(where: { $0 < 0x20 || $0 > 0x7e }) else { return text }
        return decoded
    }

    static func hexDecoded(_ text: Data) -> Data? {
        let digits = Array(text)
        guard !digits.isEmpty, digits.count % 2 == 0 else { return nil }
        func value(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 97...102: return byte - 97 + 10
            case 65...70: return byte - 65 + 10
            default: return nil
            }
        }
        var result = Data(capacity: digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = value(digits[index]), let low = value(digits[index + 1]) else { return nil }
            result.append(high << 4 | low)
        }
        return result
    }
}
