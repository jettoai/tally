import Foundation

var passed = 0
var failed = 0
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { passed += 1 } else { failed += 1; print("FAIL: \(label)") }
}
func data(_ text: String) -> Data { Data(text.utf8) }
func credential(_ value: String) -> Data {
    data("{\"claudeAiOauth\":{\"refreshTokenExpiresAt\":\(value),\"accessToken\":\"fixture-token\"}}")
}

let milliseconds = 1_791_617_039_890.0
let deadline = Date(timeIntervalSince1970: milliseconds / 1000)
expect(ClaudeLoginExpiry.parse(credential("1791617039890")) == deadline, "epoch milliseconds preserve precision")
expect(ClaudeLoginExpiry.parse(credential("1.791617039890e12")) == deadline, "numeric exponent uses millisecond units")
for value in ["null", "true", "false", "\"1791617039890\"", "{}", "[]", "-1", "0",
              "1791617039", "1791617039.890", "1791617039890.5", "1e309", "NaN", "Infinity",
              "253402300800000"] {
    expect(ClaudeLoginExpiry.parse(credential(value)) == nil, "invalid deadline \(value) stays unknown")
}
for text in ["{}", "[]", "null", "{", "{\"claudeAiOauth\":null}",
             "{\"claudeAiOauth\":{\"expiresAt\":1791617039890}}",
             "{\"refreshTokenExpiresAt\":1791617039890}",
             "{\"mcpOAuth\":{\"refreshTokenExpiresAt\":1791617039890}}"] {
    expect(ClaudeLoginExpiry.parse(data(text)) == nil, "missing login deadline stays unknown")
}
let accessOnly = data("{\"claudeAiOauth\":{\"expiresAt\":1791617039890}}")
let accessExpired = data("{\"claudeAiOauth\":{\"expiresAt\":1600000000000,\"refreshTokenExpiresAt\":1791617039890}}")
expect(ClaudeLoginExpiry.parse(accessExpired) == deadline, "expired access token does not replace login deadline")

let now = Date(timeIntervalSince1970: 1_789_000_000)
expect(ClaudeLoginExpiry.state(deadline: nil, now: now) == .unknown, "no deadline does not warn")
expect(ClaudeLoginExpiry.state(deadline: now.addingTimeInterval(-1), now: now) == .expired, "past deadline is expired")
expect(ClaudeLoginExpiry.state(deadline: now, now: now) == .expired, "exact deadline is expired")
expect(ClaudeLoginExpiry.state(deadline: now.addingTimeInterval(1), now: now) == .expiring, "one second ahead warns")
expect(ClaudeLoginExpiry.state(deadline: now.addingTimeInterval(259200), now: now) == .expiring, "exact three days warns")
expect(ClaudeLoginExpiry.state(deadline: now.addingTimeInterval(259201), now: now) == .valid, "more than three days does not warn")
expect(ClaudeLoginExpiry.state(deadline: Date(timeIntervalSince1970: .infinity), now: now) == .unknown,
       "nonfinite date stays unknown")

let unicode = data("{\"claudeAiOauth\":{\"refreshTokenExpiresAt\":1791617039890},\"mcpOAuth\":{\"label\":\"測試\"}}")
let hex = unicode.map { String(format: "%02x", $0) }.joined()
expect(ClaudeLoginExpiry.decodeSecurityOutput(data(hex + "\n")) == unicode, "security hex preserves Unicode document")
expect(ClaudeLoginExpiry.parse(ClaudeLoginExpiry.decodeSecurityOutput(data(hex + "\n"))) == deadline,
       "hex encoded Unicode credentials yield deadline")
expect(ClaudeLoginExpiry.decodeSecurityOutput(credential("1791617039890") + data("\n")) == credential("1791617039890"),
       "ASCII document strips security newline")
expect(ClaudeLoginExpiry.decodeSecurityOutput(data("6162\n")) == data("6162"), "printable hex-looking text stays literal")
expect(ClaudeLoginExpiry.decodeSecurityOutput(data("xyz\n")) == data("xyz"), "malformed hex stays literal")

let standardHome = "/Users/fixture/.claude"
let defaultService = ClaudeLoginExpiry.keychainService(home: standardHome, defaultHome: standardHome)
expect(defaultService == "Claude Code-credentials", "exact default home uses bare service")
expect(ClaudeLoginExpiry.keychainService(home: standardHome + "/", defaultHome: standardHome) == defaultService,
       "trailing slash retains default identity")
let customService = ClaudeLoginExpiry.keychainService(home: "/elsewhere/.claude", defaultHome: standardHome)
expect(customService != defaultService, "same basename outside default does not read default credential")
expect(customService == "Claude Code-credentials-599a99e1", "custom basename hashes full normalized path")
expect(ClaudeLoginExpiry.keychainService(home: "/Users/fixture/.claude2", defaultHome: standardHome)
       == claudeKeychainService(forConfigDir: URL(fileURLWithPath: "/Users/fixture/.claude2")),
       "numbered account uses shared service rule")

let keychainDate = now.addingTimeInterval(-100)
let fileDate = now.addingTimeInterval(-200)
var fileReads = 0
var observedService = ""
var observedFile = ""
func read(keychainData: Data?, fileData: Data?, keychainAbsent: Bool = false) -> ClaudeLoginExpiry.Reading {
    ClaudeLoginExpiry.readSynchronously(home: standardHome, defaultHome: standardHome, keychainRead: { service in
        observedService = service
        return .init(data: keychainData, modifiedAt: keychainDate, isAbsent: keychainAbsent)
    }, fileRead: { url in
        fileReads += 1
        observedFile = url.path
        return .init(data: fileData, modifiedAt: fileData == nil ? nil : fileDate)
    })
}
let authoritative = read(keychainData: credential("1791617039890"), fileData: credential("1700000000000"))
expect(authoritative.refreshTokenExpiresAt == deadline, "valid Keychain wins over old file")
expect(authoritative.credentialModifiedAt == keychainDate, "Keychain reading retains Keychain modification date")
expect(fileReads == 0, "valid Keychain does not read fallback file")
expect(observedService == defaultService, "reader targets account service")
let missingField = read(keychainData: accessOnly, fileData: credential("1791617039890"))
expect(missingField.refreshTokenExpiresAt == nil, "readable Keychain missing deadline does not merge stale file")
expect(fileReads == 0, "missing deadline does not trigger fallback")
let invalidField = read(keychainData: credential("true"), fileData: credential("1791617039890"))
expect(invalidField.refreshTokenExpiresAt == nil, "invalid Keychain field does not merge file")
expect(fileReads == 0, "invalid field does not trigger fallback")
let unavailable = read(keychainData: nil, fileData: credential("1791617039890"))
expect(unavailable.refreshTokenExpiresAt == nil, "unavailable Keychain does not claim fallback is active")
expect(fileReads == 0, "unavailable Keychain does not read file")
let lockedWithOldFile = read(keychainData: nil, fileData: credential("1700000000000"))
expect(lockedWithOldFile.refreshTokenExpiresAt == nil, "locked or denied Keychain with expired file stays unknown")
expect(ClaudeLoginExpiry.state(deadline: lockedWithOldFile.refreshTokenExpiresAt, now: now) == .unknown,
       "unreadable Keychain does not issue login-expired warning from stale file")
let corrupt = read(keychainData: data("invalid fixture-token document"), fileData: credential("1791617039890"))
expect(corrupt.refreshTokenExpiresAt == nil, "unparseable existing Keychain stays unknown")
let fallback = read(keychainData: nil, fileData: credential("1791617039890"), keychainAbsent: true)
expect(fallback.refreshTokenExpiresAt == deadline, "confirmed absent Keychain uses credential file")
expect(fallback.credentialModifiedAt == fileDate, "file fallback retains file modification date")
expect(observedFile == standardHome + "/.credentials.json", "fallback stays under requested home")
let broken = read(keychainData: data("fixture-secret"), fileData: data("fixture-secret"))
expect(broken.refreshTokenExpiresAt == nil, "invalid stores remain unknown")
expect(!String(describing: broken).contains("fixture-secret"), "error result does not expose raw credential data")
let absent = read(keychainData: nil, fileData: nil, keychainAbsent: true)
expect(absent.refreshTokenExpiresAt == nil, "absent stores remain unknown")
expect(absent.credentialModifiedAt == keychainDate, "unreadable secret retains available metadata")

print("loginexpiry: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
