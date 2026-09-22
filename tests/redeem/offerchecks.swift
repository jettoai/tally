import Foundation

// The four reset states every account answers (Tally/Core/ResetOffer.swift), Claude's CLI flag
// cache (B1), and the wording locks on the confirmation and the hint.

private func usage(_ provider: String, count: Int? = nil, list: [BankedResetCredit]? = nil,
                   error: String? = nil, failed: Bool = false, windows: Bool = true) -> AccountUsage {
    var value = AccountUsage(
        id: "\(provider):x", providerID: provider, accountLabel: "x", planName: nil,
        metrics: windows ? [UsageMetric(id: "weekly_all", kind: .weeklyAll, label: "Weekly",
                                        modelName: nil, usedPercent: 40, severity: .normal,
                                        resetsAt: nil, isActive: false)] : [],
        refreshedAt: Date(), error: error, resetCreditsAvailable: count, resetCredits: list)
    value.lastRefreshFailed = failed
    return value
}

private func flags(_ json: String) -> Bool? { claudeLimitResetFlagsOff(inState: Data(json.utf8)) }

func runOfferChecks() {
    let dated = BankedResetCredit(id: "a", resetType: "codexRateLimits", status: "available",
                                  expiresAt: Date())
    // Codex, four states.
    expect(ResetOffer.of(usage("codex", count: 1, list: [dated]), claudeState: .unknown)
           == .codexCredits(1), "offer: codex with a banked reset is available")
    expect(ResetOffer.of(usage("codex", count: 0, list: []), claudeState: .unknown) == .codexNone,
           "offer: codex with zero banked is 'none', not hidden")
    expect(ResetOffer.of(usage("codex"), claudeState: .unknown) == .codexNotReported,
           "offer: codex read fine without the key is not supported")
    expect(ResetOffer.of(usage("codex", error: "read failed", windows: false), claudeState: .unknown)
           == .codexUnknown, "offer: codex failed read with nothing held is unknown")
    expect(ResetOffer.of(usage("codex", failed: true), claudeState: .unknown) == .codexUnknown,
           "offer: codex whose latest poll failed cannot claim 'not supported'")
    let redeeming = BankedResetCredit(id: "r", resetType: nil, status: "redeeming", expiresAt: nil)
    expect(ResetOffer.of(usage("codex", count: 0, list: [redeeming]), claudeState: .unknown)
           == .codexUnknown, "offer: codex credit mid-redeem is unknown")
    expect(ResetOffer.of(usage("codex", count: 1, list: [dated]), claudeState: .unknown).stateName
           == "available", "offer: available names itself")
    expect(ResetOffer.of(usage("codex", count: 0, list: []), claudeState: .unknown).stateName
           == "used", "offer: zero banked names itself used")

    // Claude: unknown is an offer, not nil.
    expect(ResetOffer.of(usage("claude"), claudeState: .unknown) == .claudeSessionLimit(.unknown),
           "offer: claude with nothing observed is drawn as unknown")
    expect(ResetOffer.of(usage("claude"), claudeState: .unknown).stateName == "unknown",
           "offer: claude unknown names itself")
    expect(ResetOffer.of(usage("claude"), claudeState: .notEnabled).stateName == "notSupported",
           "offer: claude not enabled is not supported")

    // B1: the flag cache, two keys only, renames fail to unknown.
    expect(flags(#"{"cachedGrowthBookFeatures":{"tengu_nifty_lemur":{"enabled":false,"version":0}}}"#)
           == true, "flags: nifty off and cedar absent reads off (the fleet's real shape)")
    expect(flags(#"{"cachedGrowthBookFeatures":{"tengu_nifty_lemur":{"enabled":false},"tengu_cedar_ember":{"enabled":true}}}"#)
           == false, "flags: cedar on reads on")
    expect(flags(#"{"cachedGrowthBookFeatures":{"tengu_nifty_lemur":{"enabled":true}}}"#) == false,
           "flags: nifty on reads on")
    expect(flags(#"{"cachedGrowthBookFeatures":{"tengu_renamed":{"enabled":false}}}"#) == nil,
           "flags: both renamed away cannot tell")
    expect(flags(#"{"cachedGrowthBookFeatures":{"tengu_nifty_lemur":{"enabled":"no"}}}"#) == nil,
           "flags: an unreadable value cannot tell")
    expect(flags("not json") == nil && flags("{}") == nil, "flags: no cache cannot tell")
    expect(claudeResetState(observed: .unknown, flagsOff: true) == .notEnabled,
           "flags: unobserved and off is not supported")
    expect(claudeResetState(observed: .unknown, flagsOff: nil) == .unknown,
           "flags: unobserved and unreadable stays unknown")
    expect(claudeResetState(observed: .available, flagsOff: true) == .available,
           "flags: an observed state is never overridden")

    // Wording locks: the old claims are gone from the confirmation and the hint.
    let redeem = (try? String(contentsOfFile: "Tally/Views/RedeemAction.swift", encoding: .utf8)) ?? ""
    let notifier = (try? String(contentsOfFile: "Tally/Core/ResetHintNotifier.swift",
                                encoding: .utf8)) ?? ""
    expect(!redeem.isEmpty && !redeem.contains("there is one reset a week"),
           "wording: the Claude confirmation no longer claims one reset a week")
    expect(!redeem.contains("redeeming now would mostly be wasted"),
           "wording: 'mostly wasted' is no longer said regardless of expiry")
    expect(!notifier.isEmpty && !notifier.contains("would not go to waste"),
           "wording: the hint no longer promises no waste")
}
