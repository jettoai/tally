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

    /// `-TallyDemoModelWindows Fable,Sonnet` (Debug builds only): the model-scoped weekly windows
    /// every Claude fixture reports, in order, so a capture can show a model pool other than Fable.
    /// Fable alone without it, which is what the README shots are.
    static var modelWindows: [String] {
        #if DEBUG
        if isActive, let list = UserDefaults.standard.string(forKey: "TallyDemoModelWindows") {
            let names = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !names.isEmpty { return names }
        }
        #endif
        return ["Fable"]
    }

    /// `-TallyDemoLaunchModel sonnet` (Debug builds only): the launch model the gauge focuses on,
    /// in place of this Mac's own launch policy, so a capture can put a given model pool on screen
    /// whatever the machine running it has declared. Nil without it, and always nil outside demo.
    static var launchModelOverride: String? {
        #if DEBUG
        guard isActive, let model = UserDefaults.standard.string(forKey: "TallyDemoLaunchModel"),
              !model.isEmpty else { return nil }
        return model
        #else
        return nil
        #endif
    }

    /// `-TallyDemoBurnScale 4` (Debug builds only): every fabricated burn rate multiplied, so a capture
    /// can put a pool that runs dry within a day (the red forecast) on screen; no fixture burns
    /// that fast on its own (B-1543). 1 without it, and always 1 outside demo.
    static var burnScale: Double {
        #if DEBUG
        let scale = UserDefaults.standard.double(forKey: "TallyDemoBurnScale")
        return isActive && scale > 0 ? scale : 1
        #else
        return 1
        #endif
    }

    /// `-TallyDemoProviders codex` and `-TallyDemoAccountLimit claude=1,codex=2` (Debug builds only):
    /// the fixture fleet cut to the providers named and to the first N fixtures of each, so a
    /// capture can show a Codex-only panel or a single account. Applied after every other fixture
    /// flag; a provider the limit does not name keeps all of its fixtures.
    static func scoped(_ all: [AccountUsage]) -> [AccountUsage] {
        #if DEBUG
        guard isActive else { return all }
        let defaults = UserDefaults.standard
        func list(_ key: String) -> [String] {
            (defaults.string(forKey: key) ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        }
        let providers = Set(list("TallyDemoProviders"))
        var limits: [String: Int] = [:]
        for pair in list("TallyDemoAccountLimit") {
            let parts = pair.split(separator: "=")
            if parts.count == 2, let count = Int(parts[1]) { limits[String(parts[0])] = count }
        }
        var kept: [String: Int] = [:]
        return all.filter { usage in
            guard providers.isEmpty || providers.contains(usage.providerID) else { return false }
            kept[usage.providerID, default: 0] += 1
            return kept[usage.providerID]! <= limits[usage.providerID] ?? .max
        }
        #else
        return all
        #endif
    }

    /// A fixture reading read again for the accounts `scoped` kept, so a single-account capture
    /// shows what a real one-account owner sees rather than no advice at all (B-1524). Each plan
    /// tier keeps its own per-account load over the seats still shown, which is what a smaller
    /// fleet working the same way would read: the ratio behind the verdict is unchanged, so the
    /// verdict and the starved hours (per pool, not per seat) stand. Nil for a provider with no
    /// fixture left; the reading itself, untouched, while nothing was cut.
    static func rescoped(_ reading: UsageAdvisor.Reading, shown: [AccountUsage]) -> UsageAdvisor.Reading? {
        let mine = shown.filter { $0.providerID == reading.provider }
        guard !mine.isEmpty else { return nil }
        guard mine.count != reading.accountCount else { return reading }
        func cut(_ tiers: [UsageAdvisor.TierDemand]) -> [UsageAdvisor.TierDemand] {
            tiers.compactMap { tier in
                let kept = mine.filter { $0.planName == tier.plan }.count
                guard kept > 0 else { return nil }
                return .init(plan: tier.plan,
                             demandPerWeek: tier.demandPerWeek * Double(kept) / Double(max(1, tier.accountCount)),
                             accountCount: kept)
            }
        }
        var out = reading
        out.tierDemands = cut(reading.tierDemands)
        let pooled = out.tierDemands.reduce(0) { $0 + $1.demandPerWeek }
        let scale = reading.demandPerWeek > 0 ? pooled / reading.demandPerWeek : 0
        out.demandPerWeek = pooled
        out.accountCount = mine.count
        out.windowDemands = reading.windowDemands.map { window in
            var window = window
            window.demandPerWeek = window.demandPerWeek.map { $0 * scale }
            window.tierDemands = cut(window.tierDemands)
            return window
        }
        return out
    }

    /// The config home a fixture stands for, shown in the Settings rows only on this capture (the
    /// plain demo keeps that list without homes, as it always has).
    static func manyAccountsHome(accountID: String) -> String? {
        manyAccountsCount > 0 ? launchHome(accountID: accountID) : nil
    }
}
