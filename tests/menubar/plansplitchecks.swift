import Foundation

// A provider on two plans pools per plan in the menu bar (FleetMath.summaries(byPlan: true)).
func planSplitChecks() {
    // Plan split: Albert's Codex Pro (80% left) and Team (2% left) must not average to 41%.
    do {
        let split = [
            account("pro", provider: "codex", metrics: [metric(.session, used: 20), metric(.weeklyAll, used: 20)],
                    plan: "Pro"),
            account("team", provider: "codex", metrics: [metric(.session, used: 98), metric(.weeklyAll, used: 98)],
                    plan: "Team"),
        ]
        let segments = pooled(split)
        expect(segments.count == 2, "plan split: one pooled segment per plan")
        expect(segments.map(\.lines) == [["80%", "80%"], ["2%", "2%"]],
               "plan split: each segment carries its own plan's numbers")
        expect(!segments.flatMap(\.lines).contains("41%"), "plan split: no averaged 41% figure")
        expect(segments.map(\.tag) == ["P", "T"], "plan split: the corner names the plan")
        let groups = MenuBarSegments.poolGroups(split, summaries: stripSummaries(split))
        expect(groups.map { $0.planTier?.name } == ["Pro", "Team"]
               && groups.map { $0.members.map(\.id) } == [["pro"], ["team"]],
               "plan split: the hover's groups list both plans with their own members")
        // A plan whose accounts all failed keeps its mark instead of vanishing.
        let withDead = split + [account("pro2", provider: "codex", metrics: [], error: "Login expired",
                                        plan: "Plus")]
        expect(pooled(withDead).map(\.tag) == ["Pr", "T", "Pl"] && pooled(withDead)[2].lines == ["!"],
               "plan split: a failed plan still shows, tags stay distinct")
        // Single plan, or no nameable plan: segments exactly as before the split existed.
        let one = split.map { usage -> AccountUsage in var u = usage; u.planName = "Pro"; return u }
        let unsplit = MenuBarSegments.pooled(one, summaries: FleetMath.summaries(
            accounts: one, now: now, minMembers: 1) { $0.accountLabel }, mode: .remaining,
            focusedModel: flagshipFocus)
        expect(pooled(one).map(\.lines) == unsplit.map(\.lines) && pooled(one).count == 1
               && pooled(one)[0].tag == nil && pooled(one)[0].badge == 2,
               "single plan: one segment, numbers and badge unchanged")
        expect(MenuBarSegments.planTags(["Pro", "Pro Max"]) == ["Pro": "Pro", "Pro Max": "Pro "],
               "plan tags: a name that prefixes another keeps its full spelling")
    }
    do {
        let hoverSource = readSource("Tally/Stores/UsageStorePresentation.swift")
        expect(hoverSource.contains("MenuBarSegments.poolGroups(orderedAccounts, summaries: menuBarPools)")
               && hoverSource.contains("group.planTier.map"),
               "the hover walks the strip's plan groups and names each plan")
        let stripSource = readSource("Tally/MenuBar/MenuBarStrip.swift")
        expect(stripSource.contains("segment.tag ?? segment.badge.map(String.init)")
               && stripSource.contains("\\($0.tag ?? \"\")"),
               "the strip draws the plan tag in the corner slot and memoizes on it")
    }
}
