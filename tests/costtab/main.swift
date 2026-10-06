import Foundation

// SurfacePage.swift calls the app's L(); the words themselves are what this suite reads.
func L(_ key: String) -> String { key }

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "PASS: " : "FAIL: ") + name)
    if !ok { failures += 1 }
}

/// Source with `//` comments removed, so a check cannot go green on a comment that mentions a line.
func code(of path: String) -> String {
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        var quotes = 0
        var i = line.startIndex
        while i < line.endIndex {
            if line[i] == "\"" { quotes += 1 }
            let next = line.index(after: i)
            if quotes % 2 == 0, line[i] == "/", next < line.endIndex, line[next] == "/" {
                return line[..<i]
            }
            i = next
        }
        return line
    }.joined(separator: "\n")
}

// 1. THREE TABS, COST SECOND, in the order the header draws them.
check(SurfaceTab.allCases.map(\.rawValue) == ["usage", "cost", "sessions"],
      "the header offers exactly Usage, Cost, Sessions, in that order")
check(SurfaceTab(rawValue: "tokens") == nil, "…and Tokens is no longer a tab")
check(CostSubpage.allCases.map(\.rawValue) == ["spend", "tokens"],
      "Cost holds two pages, Spend first")
check(SurfacePage(tab: .cost).costPage == .spend, "…and a Cost tab never visited opens on Spend")
check(CostSubpage.spend.label == "Spend" && CostSubpage.tokens.label == "Tokens",
      "the two pages are labelled Spend and Tokens")

// 2. LAUNCH WORDS. `tokens` is what every capture command written before the move uses.
let words: [(String, SurfacePage?)] = [
    ("usage", SurfacePage(tab: .usage)),
    ("cost", SurfacePage(tab: .cost, costPage: .spend)),
    ("spend", SurfacePage(tab: .cost, costPage: .spend)),
    ("tokens", SurfacePage(tab: .cost, costPage: .tokens)),
    ("sessions", SurfacePage(tab: .sessions)),
    (" TOKENS ", SurfacePage(tab: .cost, costPage: .tokens)),
    ("bogus", nil), ("", nil),
]
for (word, want) in words {
    check(SurfacePage.named(word) == want, "-TallyTab '\(word)' opens \(String(describing: want))")
}
let launch = code(of: "Tally/Views/SurfaceTabLaunch.swift")
check(launch.contains("SurfacePage(tab: .cost, costPage: .tokens)")
        && launch.contains("TokenGraphPreview.project == nil"),
      "-TallyTokenGraphPreview alone opens Cost on its Tokens page")
check(launch.contains("let named = SurfacePage.named(raw)")
        && launch.contains("DemoUsage.isActive || BuildVariant.isDev"),
      "…the launch word is read through SurfacePage.named, demo and dev builds only")

// 3. ONE SELECTION PER HOST, AND A PIN HANDS OVER BOTH HALVES.
let state = code(of: "Tally/Views/SurfaceTabState.swift")
check(state.contains("var costPage: CostSubpage = SurfaceTabLaunch.initialPage.costPage")
        && state.contains("set { tab = newValue.tab; costPage = newValue.costPage }"),
      "the Cost page is part of each host's own selection")
check(!state.contains("static let shared") && !state.contains("UserDefaults"),
      "…shared by no host and never persisted")
for (host, path) in [("popover", "Tally/MenuBar/StatusItemController.swift"),
                     ("panel", "Tally/MenuBar/PinnedPanelController.swift"),
                     ("window", "Tally/MenuBar/MainWindowController.swift")] {
    check(code(of: path).contains("SurfaceTabState()"), "the \(host) owns its own selection")
}
check(code(of: "Tally/MenuBar/StatusItemCommands.swift").contains("showing: source.page)"),
      "pinning hands the panel the tab AND the Cost page")
let panel = code(of: "Tally/MenuBar/PinnedPanelController.swift")
check(panel.contains("showing page: SurfacePage? = nil)") && panel.contains("if let page { surfaceTab.page = page }"),
      "…and the panel adopts both")
check(panel.contains("var visiblePage: SurfacePage? { isVisible ? surfaceTab.page : nil }")
        && code(of: "Tally/MenuBar/MainWindowController.swift")
            .contains("if let page = PinnedPanelController.shared.visiblePage { surfaceTab.page = page }"),
      "the dashboard retiring the panel takes both back")

// 4. THE COST TAB DRAWS BOTH PAGES OFF ONE STORE, AND THE HEADER TREATS IT AS ONE TAB.
let root = code(of: "Tally/Views/PopoverRootView.swift")
check(root.contains("CostTabPage(store: tokens, page: $tabState.costPage,")
        && !root.contains("tab == .tokens"),
      "the root draws the Cost tab through CostTabPage, with this host's own page")
let cost = code(of: "Tally/Views/CostPage.swift")
check(cost.contains("if page == .spend {") && cost.contains("CostPage(store: store, width: width)")
        && cost.contains("if page == .tokens {") && cost.contains("TokenStatsView(store: store, width: width)"),
      "Spend is the cost page and Tokens the token history, unchanged")
check(cost.components(separatedBy: ".onAppear { store.refresh() }").count == 2
        && !cost.contains("dragsWindow"),
      "…one refresh per arrival on the tab, none per page switch, and the switch is not a grab area")
// One range switch for both pages, on the Cost tab's own control line beside Spend / Tokens.
let views = (try? FileManager.default.contentsOfDirectory(atPath: "Tally/Views")) ?? []
let rangeSwitches = views.filter { $0.hasSuffix(".swift") }.flatMap { file in
    Array(repeating: file, count: code(of: "Tally/Views/" + file)
        .components(separatedBy: "TokenStatsRange.allCases").count - 1)
}
let controlLine = cost.range(of: "struct CostTabPage")
    .flatMap { tab in cost.range(of: "struct CostPage:").map { tab.upperBound..<$0.lowerBound } }
check(rangeSwitches == ["CostPage.swift"]
        && controlLine.map { cost[$0].contains("TokenStatsRange.allCases") } == true,
      "the range switch is drawn once, on the Cost tab's control line, for both pages")
let header = code(of: "Tally/Views/PopoverHeaderView.swift")
check(header.contains("case .cost: tokens.refresh()") && header.contains("case .cost: return tokens.isScanning"),
      "the header's refresh and spinner follow the token scan on either Cost page")

// 5. THE BACKGROUND SCAN: due by age, ridden on the quota poll, faster than the slowest poll.
let now = Date(timeIntervalSince1970: 2_000_000_000)
check(TokenScanCadence.isDue(lastStart: nil, now: now), "a scan that never ran is due")
check(!TokenScanCadence.isDue(lastStart: now.addingTimeInterval(-13 * 60), now: now),
      "…one begun 13 minutes ago is not")
check(TokenScanCadence.isDue(lastStart: now.addingTimeInterval(-14 * 60), now: now),
      "…one begun 14 minutes ago is")
check(TokenScanCadence.isDue(lastStart: now.addingTimeInterval(3_600), now: now),
      "…and a clock set back does not hold the file still")
check(TokenScanCadence.maxAge < 15 * 60,
      "the cadence is under the slowest quota poll, so a 15-minute poll scans on every tick")
check(code(of: "Tally/Stores/SettingsStore.swift").contains("[1, 2, 5, 15].contains(interval)"),
      "…and 15 minutes is still the slowest poll Settings offers")
let usage = code(of: "Tally/Stores/UsageStore.swift")
// Order, not adjacency: a comment line sits between the two calls (stripped to blank by `code`).
let limits = usage.range(of: "LimitResetStore.shared.refresh()")
let scan = usage.range(of: "TokenStatsStore.shared.refreshIfStale()")
check(limits != nil && scan != nil && limits!.upperBound < scan!.lowerBound
        && usage.components(separatedBy: "refreshIfStale()").count == 2,
      "every quota poll asks the token scan whether it is due, once, at the refresh's tail")
let store = code(of: "Tally/Stores/TokenStatsStore.swift")
check(store.contains("guard TokenScanCadence.isDue(lastStart: lastScanStart, now: now) else { return }")
        && store.contains("lastScanStart = Date()\n        isScanning = true"),
      "…which goes through the one guarded refresh, timed from when any scan began")

print(failures == 0 ? "\nAll cost tab tests passed." : "\n\(failures) cost tab test(s) FAILED.")
exit(failures == 0 ? 0 : 1)
