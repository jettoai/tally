import Foundation

/// Fixture accounts for marketing and README screenshots:
/// `open Tally.app --args -TallyDemoData YES`.
///
/// The flag lives in the volatile argument domain, so a normal launch always shows real data. Demo
/// mode never runs a provider CLI and never writes the launch snapshot, so a demo instance on
/// screen can't steer the `tally` CLI's account picking.
enum DemoUsage {
    static var isActive: Bool { UserDefaults.standard.bool(forKey: "TallyDemoData") }

    static func accounts(now: Date = Date()) -> [AccountUsage] {
        [
            // Every remaining percentage stays double-digit (10-99): a mixed column of "8%" and
            // "100%" reads ragged in the right-aligned figures, and this grid IS the README shot.
            claude("Claude", plan: "Max 20x", model: 3, session: 2, weekly: 8,
                   modelResetDays: 6.4, sessionResetHours: 4.6, weeklyResetDays: 6.4, now: now),
            claude("Claude 2", plan: "Max 20x", model: 52, session: 25, weekly: 39,
                   modelResetDays: 1.2, sessionResetHours: 3.1, weeklyResetDays: 1.2, now: now),
            claude("Claude 3", plan: "Max 20x", model: 88, session: 66, weekly: 82,
                   modelResetDays: 0.8, sessionResetHours: 1.4, weeklyResetDays: 0.8, now: now),
            claude("Claude 4", plan: "Max 20x", model: 27, session: 12, weekly: 20,
                   modelResetDays: 4.2, sessionResetHours: 2.3, weeklyResetDays: 4.2, now: now),
            claude("Claude 5", plan: "Max 20x", model: 45, session: 89, weekly: 59,
                   modelResetDays: 2.6, sessionResetHours: 0.6, weeklyResetDays: 2.6, now: now),
            codex("Codex", plan: "Pro", session: 42, weekly: 69,
                  sessionResetHours: 2.4, weeklyResetDays: 5.9, resets: 3, now: now),
            codex("Codex 2", plan: "Pro", session: 71, weekly: 14,
                  sessionResetHours: 0.9, weeklyResetDays: 3.3, resets: 1, now: now),
            codex("Codex 3", plan: "Pro", session: 18, weekly: 83,
                  sessionResetHours: 3.8, weeklyResetDays: 1.7, resets: 0, now: now),
            // Nine accounts total (a 3-column demo screenshot lands as a full 3x3 grid); the
            // one non-premium plan sits last, not mid-pack.
            codex("Codex 4", plan: "Team", session: 47, weekly: 62,
                  sessionResetHours: 1.6, weeklyResetDays: 4.8, resets: 2, now: now),
        ]
    }

    /// Fabricated burn rates so the fleet strip's forecast renders in screenshots: Claude spends
    /// faster than its combined refill budget (a concrete "lasts about …"), Codex within it
    /// (the "sustainable" state). Real instances estimate these from ~/.tally/history.jsonl.
    static var fleetRates: [String: FleetRate] {
        ["claude": FleetRate(perHour: 4.6, sampledHours: 72),
         "codex": FleetRate(perHour: 1.4, sampledHours: 72)]
    }

    /// A Claude account shaped exactly like ClaudeUsageCLI's mapping: a model-scoped weekly window
    /// (the headline), the 5h session, and the all-model weekly. A nil session reset mirrors the
    /// untouched-account case ("5h starts on first use").
    private static func claude(_ label: String, plan: String, model: Double, session: Double,
                               weekly: Double, modelResetDays: Double?, sessionResetHours: Double?,
                               weeklyResetDays: Double?, now: Date) -> AccountUsage {
        AccountUsage(
            id: "claude:demo-\(label)", providerID: "claude", accountLabel: label, planName: plan,
            metrics: [
                UsageMetric(id: "weekly_model:Fable", kind: .weeklyModel, label: "Fable",
                            modelName: "Fable", usedPercent: model,
                            severity: .fromUsedPercent(model),
                            resetsAt: modelResetDays.map { now.addingTimeInterval($0 * 86_400) },
                            isActive: false),
                UsageMetric(id: "session", kind: .session, label: "Session", modelName: nil,
                            usedPercent: session, severity: .fromUsedPercent(session),
                            resetsAt: sessionResetHours.map { now.addingTimeInterval($0 * 3_600) },
                            isActive: false),
                UsageMetric(id: "weekly_all", kind: .weeklyAll, label: "Weekly", modelName: nil,
                            usedPercent: weekly, severity: .fromUsedPercent(weekly),
                            resetsAt: weeklyResetDays.map { now.addingTimeInterval($0 * 86_400) },
                            isActive: false),
            ],
            refreshedAt: now)
    }

    /// A Codex account shaped like CodexAppServerClient's mapping: the 5h primary window plus
    /// the weekly secondary, both with resets (some real plans report only the weekly; the demo
    /// shows the full shape).
    private static func codex(_ label: String, plan: String, session: Double, weekly: Double,
                              sessionResetHours: Double, weeklyResetDays: Double, resets: Int,
                              now: Date) -> AccountUsage {
        AccountUsage(
            id: "codex:demo-\(label)", providerID: "codex", accountLabel: label, planName: plan,
            metrics: [
                UsageMetric(id: "session", kind: .session, label: "Session", modelName: nil,
                            usedPercent: session, severity: .fromUsedPercent(session),
                            resetsAt: now.addingTimeInterval(sessionResetHours * 3_600),
                            isActive: false),
                UsageMetric(id: "weekly_all", kind: .weeklyAll, label: "Weekly", modelName: nil,
                            usedPercent: weekly, severity: .fromUsedPercent(weekly),
                            resetsAt: now.addingTimeInterval(weeklyResetDays * 86_400),
                            isActive: false),
            ],
            refreshedAt: now,
            resetCreditsAvailable: resets > 0 ? resets : nil)
    }
}
