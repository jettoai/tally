import Foundation
import Security

/// Reads generic-password Keychain items.
///
/// Secret reads go through `/usr/bin/security` (a subprocess), NOT `SecItemCopyMatching` — the
/// OpenUsage-proven pattern. Keychain authorization evaluates the process that talks to `securityd`:
/// the Apple-signed `security` tool sits in the item's partition list (`apple-tool:`), so reading an
/// item Claude Code created is silently allowed. An in-process `SecItemCopyMatching` is evaluated as
/// Tally itself, which re-prompts every time the item is rewritten (each CLI token rotation) or the
/// binary changes (every dev rebuild) — the "why does it keep asking" loop.
///
/// Secrets discipline: the token travels only through the subprocess stdout pipe into memory —
/// never logged, printed, or persisted.
enum KeychainReader {
    /// Read the raw data of a generic-password item by service (and optional account).
    /// Returns `nil` when the item is absent (`security` exits 44) or any read failure.
    static func genericPassword(service: String, account: String? = nil) -> Data? {
        var arguments = ["find-generic-password", "-s", service, "-w"]
        if let account { arguments += ["-a", account] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()   // discard; stderr may name the service, never a secret

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        // `-w` prints the value followed by a trailing newline; the credential itself is JSON (ASCII).
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }

    /// Cheap existence probe by attributes only (no secret returned, so never a consent prompt even
    /// in-process). Used for account discovery.
    static func exists(service: String, account: String? = nil) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // errSecInteractionNotAllowed = item exists but is locked; still "present".
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
}
