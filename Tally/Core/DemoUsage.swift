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
            claude("Claude 3", plan: "Max 5x", model: 88, session: 66, weekly: 82,
                   modelResetDays: 0.8, sessionResetHours: 1.4, weeklyResetDays: 0.8, now: now),
            claude("Claude 4", plan: "Max 5x", model: 27, session: 12, weekly: 20,
                   modelResetDays: 4.2, sessionResetHours: 2.3, weeklyResetDays: 4.2, now: now),
            claude("Claude 5", plan: "Max 5x", model: 45, session: 89, weekly: 59,
                   modelResetDays: 2.6, sessionResetHours: 0.6, weeklyResetDays: 2.6, now: now),
            codex("Codex", plan: "Pro", weekly: 69, weeklyResetDays: 5.9, now: now),
            codex("Codex 2", plan: "Pro", weekly: 14, weeklyResetDays: 3.3, now: now),
            codex("Codex 3", plan: "Business", weekly: 83, weeklyResetDays: 1.7, now: now),
        ]
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

    private static func codex(_ label: String, plan: String, weekly: Double,
                              weeklyResetDays: Double, now: Date) -> AccountUsage {
        AccountUsage(
            id: "codex:demo-\(label)", providerID: "codex", accountLabel: label, planName: plan,
            metrics: [
                UsageMetric(id: "weekly_all", kind: .weeklyAll, label: "Weekly", modelName: nil,
                            usedPercent: weekly, severity: .fromUsedPercent(weekly),
                            resetsAt: now.addingTimeInterval(weeklyResetDays * 86_400),
                            isActive: false),
            ],
            refreshedAt: now)
    }
}
