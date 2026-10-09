import SwiftUI

/// The config home on a Settings account row, and whether that account shares the provider's
/// primary account's setup (B-1033): a link mark and "~/.claude3 · Shared with hyde", or "Partly
/// shared with" when only some layers are, with the layers on hover. The primary itself and an
/// account with its own harness show the path alone.
///
/// The verdict is `HarnessSharing.report`, the one the Launch pane's sharing row reads, and the
/// primary is the same one it compares against: the first account in the user's order.
struct AccountHomeTag: View {
    let home: String
    let report: HarnessSharing.Report?
    /// The primary account's display name (nickname applied), so a rename shows here too.
    let primaryName: String

    /// No container of its own: the pieces lay out as siblings of the name in the row's line, so
    /// the name is the one that gives way. Neither the path nor the "Shared with" words do: the
    /// primary's name is the point of the mark, and cut to "Shared with C…" it says nothing (owner's
    /// review, 2026-10-09). The name's full text is in its own hover.
    @ViewBuilder
    var body: some View {
        let path = AccountIdentity.homeName(home)
        if let report, let tag = report.tag {
            Image(systemName: "link").modifier(HomeStyle()).help(Self.detail(report))
            Text(path).modifier(HomeStyle()).help(Self.detail(report))
            Text("· " + String(format: L(tag == .shared ? "Shared with %@" : "Partly shared with %@"),
                               primaryName))
                .modifier(HomeStyle())
                .help(Self.detail(report))
        } else {
            Text(path).modifier(HomeStyle())
        }
    }

    static func detail(_ report: HarnessSharing.Report) -> String {
        let shared = "\(L("Shared")): " + report.sharedItems.joined(separator: ", ")
        guard !report.independentItems.isEmpty else { return shared }
        return shared + "\n\(L("Independent")): " + report.independentItems.joined(separator: ", ")
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

/// The home's look, unchanged from when it was a bare path: short, fixed, never the part that gives
/// way (SettingsAccountsView.nameLine says why).
private struct HomeStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.caption).foregroundStyle(.tertiary).lineLimit(1).layoutPriority(1)
    }
}
