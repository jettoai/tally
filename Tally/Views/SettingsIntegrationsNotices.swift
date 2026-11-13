import SwiftUI

/// The Integrations pane's notice strips. Split out of SettingsIntegrationsPane.swift at the repo's
/// 500-line cap; the strips themselves are `SettingsNoticeBar` (the skeleton's `NoticeSurface`).

extension SettingsView {
    /// What the app did without being asked, said once, with the way back beside it
    /// (IntegrationsAutoFollow.swift).
    ///
    /// A STRIP AT THE TOP OF THIS PANE rather than a window, an alert or a badge somewhere else: this
    /// is where the thing it is about lives, so the sentence sits above the group it names and the
    /// Undo beside it is the row's own Remove. It stands until it is dismissed or undone, launches
    /// included, because nobody was at the machine when the install happened and a notice they were
    /// not there for is not a notice.
    @ViewBuilder
    func autoFollowNotices(_ integrations: IntegrationsStore) -> some View {
        ForEach(integrations.autoFollowNotices, id: \.self) { key in
            if let component = IntegrationsStore.autoFollowComponent(key) {
                // The name is an ARGUMENT, never spelled into the key: a message built by
                // interpolation has a catalog key that only exists for whatever it was
                // built from that day (localizationchecks.swift).
                SettingsNoticeBar(
                    kind: .info,
                    title: String(format: L("Tally enabled %@ for your Claude accounts."), component.title()),
                    message: L("Your other Claude integrations were already installed, so this one followed. Undo removes it again, and Tally will not put it back.")) {
                    Button(L("Undo")) { integrations.undoAutoFollow(component) }
                        .buttonStyle(.borderless).font(.system(size: SettingsType.noticeTitle, weight: .medium))
                    Button(L("Dismiss")) { integrations.dismissAutoFollowNotice(key) }
                        .buttonStyle(.borderless).font(.system(size: SettingsType.noticeTitle, weight: .medium))
                }
            }
        }
    }
}
