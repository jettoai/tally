import Foundation

/// Posts one notification when a session on the account set as Claude in Chrome's reports "not
/// connected", asking the user to check the setting. Driven by the refresh loop; reads the signal
/// the CLI hook writes (Tally/Core/ChromeSettingSignal.swift). Never changes the setting.
@MainActor
final class ChromeSettingNotifier {
    static let shared = ChromeSettingNotifier()
    private let seenKey = "ai.jetto.tally.chromeAccount.seen"
    private let setAtKey = "ai.jetto.tally.chromeAccount.setAt"
    private let notifiedKey = "ai.jetto.tally.chromeAccount.notified"
    private init() {}

    func evaluate(accounts: [AccountUsage]) {
        let setting = LaunchPolicyStore.shared.chromeAccount
        // A new choice, first seen on this pass, re-arms the notification and ignores any signal
        // written before it. Kept here rather than in the store so the store stays free of the app.
        if UserDefaults.standard.string(forKey: seenKey) != setting {
            UserDefaults.standard.set(setting, forKey: seenKey)
            UserDefaults.standard.set(Date(), forKey: setAtKey)
            UserDefaults.standard.set(false, forKey: notifiedKey)
        }
        guard chromeSettingGapShouldNotify(
            setting: setting, setAt: UserDefaults.standard.object(forKey: setAtKey) as? Date,
            signal: readChromeSettingGapSignal(),
            notified: UserDefaults.standard.bool(forKey: notifiedKey)),
            let setting else { return }
        UserDefaults.standard.set(true, forKey: notifiedKey)
        let name = accounts.first { $0.id == setting }?.accountLabel ?? setting
        Task {
            _ = await SystemAlert.post(
                title: L("Claude in Chrome account may be wrong"),
                body: String(format: L("A session on %@, the account set for Claude in Chrome, could not reach the extension. Check which account the extension is signed in to and update Settings."), name))
        }
    }
}
