import Foundation
import UserNotifications

/// Says out loud that an update has been waiting (`UpdateLag`). Driven by the updater's idle timer,
/// which runs exactly while there is an offer; keeps no timer of its own.
@MainActor
final class UpdateLagNotifier {
    static let shared = UpdateLagNotifier()
    nonisolated static let categoryID = "ai.jetto.tally.updateLag"
    nonisolated static let installActionID = "install"
    private let announcedKey = "ai.jetto.tally.updateLag.announcedInstalledBuild"
    private var posting = false

    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryID,
            actions: [UNNotificationAction(identifier: installActionID,
                                           title: L("Install now"), options: [])],
            intentIdentifiers: [])
    }

    private init() {}

    func evaluate(_ state: UpdateState, now: Date = Date()) {
        guard !posting else { return }
        let announced = UserDefaults.standard.object(forKey: announcedKey) as? Int
        guard let release = UpdateLag.due(state, now: now, announcedFor: announced),
              let since = state.knownSince else { return }
        posting = true
        Task { @MainActor in
            defer { self.posting = false }
            guard await self.post(release, since: since) else { return }
            UserDefaults.standard.set(state.installedBuild, forKey: self.announcedKey)
        }
    }

    /// Post one sample (the `-TallyUpdateLagTest` launch flag): the alert's look and its button,
    /// without touching the persisted announcement.
    func postSampleNotification() {
        let sample = FeedRelease(build: 0, display: "0.99.0", minimumSystemVersion: nil)
        Task { _ = await post(sample, since: Date().addingTimeInterval(-4 * 3600)) }
    }

    private func post(_ release: FeedRelease, since: Date) async -> Bool {
        let installed = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        let title = String(format: L("Tally %@ has not installed yet"), release.display)
        let body = String(format: L("This Mac is still on %1$@; the update has been waiting since %2$@."),
                          installed, UsageFormat.noticeCountdown(since).clock)
        NotificationRouter.shared.refreshCategories()
        return await SystemAlert.post(title: title, body: body, categoryID: Self.categoryID)
    }
}
