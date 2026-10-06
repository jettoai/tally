import Foundation

/// WHICH PAGE A SURFACE IS ON, as plain values: the header's tabs, the two pages inside the Cost tab,
/// and the pair the pin hand-off and the launch flags carry. Kept apart from `SurfaceTabState` (the
/// observable per-host copy) so it can be named without SwiftUI, and so the tests can compile it.

/// What a surface is showing, in the order the header's switch draws it (`allCases`). Not a window
/// concept: the popover, the pinned panel and the dashboard window are all the same view.
///
/// Three questions, deliberately not merged: how much quota is left, what the tokens cost and where
/// they went (`CostTabPage`, whose Tokens page is the token history that used to be a tab of its
/// own), and what is running right now (`SessionBoardView`). Cost sits second, in the place the
/// Tokens tab held (B-5671).
enum SurfaceTab: String, CaseIterable, Identifiable {
    case usage, cost, sessions
    var id: String { rawValue }
    var label: String {
        switch self {
        case .usage: return L("Usage")
        case .cost: return L("Cost")
        case .sessions: return L("Sessions")
        }
    }
}

/// The Cost tab's two pages: what the tokens cost at list prices (`CostPage`) and the token counts
/// themselves (`TokenStatsView`). Both read the one `TokenStatsStore`, so switching between them is
/// instant and never rescans.
enum CostSubpage: String, CaseIterable, Identifiable {
    case spend, tokens
    var id: String { rawValue }
    var label: String {
        switch self {
        case .spend: return L("Spend")
        case .tokens: return L("Tokens")
        }
    }
}

/// A surface's whole selection: the tab, and which Cost page is up. A value, so a hand-off copies
/// it and two hosts never share one selection (`SurfaceTabState`).
struct SurfacePage: Equatable {
    var tab: SurfaceTab
    var costPage: CostSubpage = .spend

    /// The page a launch word names (`-TallyTab`), regardless of case and surrounding spaces. A Cost
    /// page's own word opens Cost on that page, which is what keeps `tokens` (the word every capture
    /// command written before Tokens moved inside Cost uses) opening the token history. Nil for a
    /// word with no page.
    static func named(_ word: String) -> SurfacePage? {
        let word = word.trimmingCharacters(in: .whitespaces).lowercased()
        if let page = CostSubpage(rawValue: word) { return SurfacePage(tab: .cost, costPage: page) }
        return SurfaceTab(rawValue: word).map { SurfacePage(tab: $0) }
    }
}
