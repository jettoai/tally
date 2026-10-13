import Foundation

// A login lands its credential a moment before it writes `oauthAccount` (B-1702). The provider reads
// the profile up front and once more after the usage probe when the first read named nobody, so a
// card that appears in that gap still learns whose it is on the same round.
func runProfileChecks(tmp: URL) throws {
    let dir = tmp.appendingPathComponent("profile-home/.claude97")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = claudeStateFile(forConfigDir: dir)
    try #"{"hasCompletedOnboarding":true}"#.write(to: file, atomically: true, encoding: .utf8)
    let before = ClaudeAccounts.profile(configDir: dir.path)
    check("a config with no oauthAccount names nobody", before.email == nil && before.plan == nil)

    try #"{"hasCompletedOnboarding":true,"oauthAccount":{"emailAddress":"replay@example.com","organizationRateLimitTier":"default_claude_max_20x"}}"#
        .write(to: file, atomically: true, encoding: .utf8)
    let after = ClaudeAccounts.profile(configDir: dir.path, unlessNamed: before)
    check("an unnamed first read is read again and finds the login that landed",
          after.email == "replay@example.com" && after.plan == "Max 20x")

    try FileManager.default.removeItem(at: file)
    let kept = ClaudeAccounts.profile(configDir: dir.path, unlessNamed: after)
    check("a named first read is not read again", kept.email == "replay@example.com")

    let provider = (try? String(contentsOfFile: "Tally/Providers/Claude/ClaudeProvider.swift", encoding: .utf8)) ?? ""
    let probe = provider.range(of: "fetchUsageText(")
    let reread = provider.range(of: "unlessNamed:")
    check("the provider reads the profile again after the usage probe returns",
          probe != nil && reread != nil && probe!.lowerBound < reread!.lowerBound)
}
