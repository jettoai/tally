import SwiftUI

/// Whether a Settings account shares the provider's primary account's setup (B-1033): the hover
/// words for the compact row's link mark (SettingsAccountRowCompact.shareMark), and the reports
/// behind it.
///
/// The verdict is `HarnessSharing.report`, the one the Launch pane's sharing row reads, and the
/// primary is the same one it compares against: the first account in the user's order.
enum AccountHomeTag {
    static func detail(_ report: HarnessSharing.Report) -> String {
        let shared = "\(L("Shared")): " + report.sharedItems.joined(separator: ", ")
        guard !report.independentItems.isEmpty else { return shared }
        return shared + "\n\(L("Independent")): " + report.independentItems.joined(separator: ", ")
    }

    /// `-TallyDemoAccounts` (DemoManyAccounts.swift): sharing against each provider's first
    /// account, rotating shared, partly shared and own setup down the list. Nil off this capture,
    /// so the real comparison on disk runs instead.
    static func demoReports(_ items: [ProviderAccount]) -> [String: HarnessSharing.Report]? {
        guard DemoUsage.manyAccountsCount > 0, let first = items.first else { return nil }
        let layers = first.providerID == "claude"
            ? ["CLAUDE.md", "settings.json", "skills", "agents", "hooks", "plugins"]
            : ["config.toml", "AGENTS.md", "prompts", "mcp"]
        var reports: [String: HarnessSharing.Report] = [:]
        for (index, item) in items.enumerated().dropFirst() {
            switch index % 3 {
            case 1: reports[item.id] = HarnessSharing.Report(sharedItems: layers)
            case 2: reports[item.id] = HarnessSharing.Report(sharedItems: Array(layers.prefix(3)),
                                                             independentItems: Array(layers.dropFirst(3)))
            default: reports[item.id] = HarnessSharing.Report(independentItems: layers)
            }
        }
        return reports
    }

    /// Every non-primary account's report, worked out OFF the main thread: each compares paths on
    /// disk (tests/mainio). Keyed by account id.
    static func reports(_ items: [ProviderAccount], providerID: String) async -> [String: HarnessSharing.Report] {
        guard let primary = items.first?.launchHome else { return [:] }
        let homes = items.dropFirst().compactMap { account in account.launchHome.map { (account.id, $0) } }
        return await Task.detached(priority: .utility) {
            Dictionary(homes.map { id, home in
                (id, HarnessSharing.report(primaryHome: primary, secondaryHome: home, providerID: providerID))
            }, uniquingKeysWith: { first, _ in first })
        }.value
    }
}
