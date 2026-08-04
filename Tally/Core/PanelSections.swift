import Foundation

/// Which provider sections the panel's card region draws, and which of them are folded away behind
/// their fleet gauge.
///
/// One rule, asked by every surface that hides or shows cards, because a fold has two entry points
/// that must never disagree: the chevron on the provider's gauge row up in the fleet strip, and the
/// section heading down in the cards themselves. Both toggle the SAME set, and both read their
/// state back out of it here - so a chevron pointing right and a section drawing no cards are two
/// renderings of one fact rather than two states that can drift apart.
///
/// The heading of a folded section stays where it was: it is the way back. Folding a section used
/// to take its heading with it, which left the fleet strip's chevron as the only way to unfold - a
/// control at the top of the panel for something that disappeared from the middle of it.
enum PanelSections {
    /// The one fold rule: a provider's cards are hidden only while its POOLED gauge is on screen to
    /// summarize them. A collapse recorded for a provider with no gauge (single account, gauges
    /// switched off) does nothing at all, so cards can never be hidden behind nothing.
    static func isFolded(_ providerID: String, pooled: Set<String>,
                         collapsed: Set<String>) -> Bool {
        collapsed.contains(providerID) && pooled.contains(providerID)
    }

    /// The other half of the same fact: what a click on either entry point leaves behind. Pure, so
    /// the store that persists it holds no rule of its own.
    static func toggling(_ providerID: String, in collapsed: Set<String>) -> Set<String> {
        var next = collapsed
        if next.contains(providerID) { next.remove(providerID) } else { next.insert(providerID) }
        return next
    }

    /// One provider's run of cards, and whether it is currently folded. Folded sections are part of
    /// the list, not filtered out of it: their headings are still drawn.
    struct Section<Item>: Identifiable {
        let providerID: String
        let items: [Item]
        let isFolded: Bool
        var id: String { providerID }
    }

    /// Every provider with accounts, in the order they first appear in the user's own card order,
    /// each keeping that order inside it - so grouping re-seats the cards without inventing a
    /// second ordering the user never chose.
    static func sections<Item>(_ accounts: [Item],
                               providerID: (Item) -> String,
                               pooled: Set<String>,
                               collapsed: Set<String>) -> [Section<Item>] {
        var order: [String] = []
        var buckets: [String: [Item]] = [:]
        for account in accounts {
            let id = providerID(account)
            if buckets[id] == nil { order.append(id) }
            buckets[id, default: []].append(account)
        }
        return order.map {
            Section(providerID: $0, items: buckets[$0] ?? [],
                    isFolded: isFolded($0, pooled: pooled, collapsed: collapsed))
        }
    }

    /// Whether the sections carry headings. One provider needs none: a label over the only section
    /// names what nothing else could be, so it is pure noise - and with no heading there is nothing
    /// for a fold to leave behind, which is why a lone section folded away shows no card region at
    /// all (its gauge chevron is then the way back, and it is the only control there was).
    static func showsHeadings(sectionCount: Int) -> Bool { sectionCount > 1 }
}
