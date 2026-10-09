import Foundation

/// `-TallyDemoData YES -TallyDemoAccounts 22` (Debug builds only): the fixture fleet padded out to
/// N accounts, roughly sixteen Claude to six Codex, for capturing the Settings account list at the
/// size real users run it. Names, addresses, plans, usage and sharing all vary, and every sharing
/// state appears (shared, partly shared, own setup).
///
/// The nine fixtures the README shots rely on are left exactly as they are; this only appends.
/// Without the flag nothing here does anything.
extension DemoUsage {
    static var manyAccountsCount: Int {
        #if DEBUG
        return isActive ? UserDefaults.standard.integer(forKey: "TallyDemoAccounts") : 0
        #else
        return 0
        #endif
    }

    private static let extraClaudeNames = ["Claude 6", "Studio", "Research", "Client Acme",
                                           "Night shift", "Claude 11", "Pairing", "Ops",
                                           "Claude 14", "Sandbox", "Review", "Claude 17",
                                           "Writing", "Claude 19"]
    private static let extraCodexNames = ["Codex 5", "Team Beta", "Codex 7", "Infra", "Codex 9"]

    /// The accounts past the fixtures, numbered on from them (`Claude 6`, `Codex 5`, ...) so each
    /// stands for its own `~/.claudeN` / `~/.codexN`.
    static func manyAccountsExtras(now: Date) -> [AccountUsage] {
        let total = manyAccountsCount
        guard total > 9 else { return [] }
        let codexTotal = max(4, Int((Double(total) * 6 / 22).rounded()))
        let claudeExtra = min(extraClaudeNames.count, max(0, total - codexTotal - 5))
        let codexExtra = min(extraCodexNames.count, max(0, codexTotal - 4))
        let claudePlans = ["Max 20x", "Max 5x", "Pro", "Max 20x", "Team"]
        let codexPlans = ["Plus", "Pro", "Team"]

        func figure(_ seed: Int, _ step: Int, _ floor: Int, _ span: Int) -> Double {
            Double(seed * step % span + floor)
        }
        func renamed(_ usage: AccountUsage, _ name: String, number: Int) -> AccountUsage {
            var copy = usage
            copy.accountLabel = name
            if !name.hasSuffix(" \(number)") {
                copy.accountEmail = name.lowercased().filter { $0.isLetter } + "@example.com"
            }
            // Two shapes the row has to hold: a 32-character address that must not be cut, and a
            // nicknamed login that never reported one (its row names the config home instead).
            if name == "Research" { copy.accountEmail = "albert.liu.long.test@example.com" }
            if name == "Night shift" { copy.accountEmail = nil }
            return copy
        }

        let claudes = (0 ..< claudeExtra).map { index -> AccountUsage in
            let number = index + 6
            let usage = claude("Claude \(number)", plan: claudePlans[index % claudePlans.count],
                               model: figure(number, 29, 4, 90), session: figure(number, 37, 3, 92),
                               weekly: figure(number, 53, 8, 88), modelResetDays: 1 + Double(index % 6),
                               sessionResetHours: 0.5 + Double(index % 5),
                               weeklyResetDays: 1 + Double(index % 6), now: now)
            return renamed(usage, extraClaudeNames[index], number: number)
        }
        let codexes = (0 ..< codexExtra).map { index -> AccountUsage in
            let number = index + 5
            let usage = codex("Codex \(number)", plan: codexPlans[index % codexPlans.count],
                              email: "sam\(number)@example.com", session: figure(number, 31, 6, 88),
                              weekly: figure(number, 47, 9, 84), sessionResetHours: 1 + Double(index),
                              weeklyResetDays: 2 + Double(index), resets: index % 3, now: now)
            return renamed(usage, extraCodexNames[index], number: number)
        }
        return claudes + codexes
    }

    /// The config home a fixture stands for, shown in the Settings rows only on this capture (the
    /// plain demo keeps that list without homes, as it always has).
    static func manyAccountsHome(accountID: String) -> String? {
        manyAccountsCount > 0 ? launchHome(accountID: accountID) : nil
    }
}
