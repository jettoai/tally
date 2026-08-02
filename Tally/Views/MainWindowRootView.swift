import SwiftUI

/// The dashboard window's content: the same account panel the popover shows, plus a second tab for
/// local token history.
///
/// Only the window gets tabs. The popover and the pinned panel are glanceable surfaces answering
/// "how much quota is left" in one look, and a tab bar there would put a click between the user and
/// that answer; the window is the surface someone opens to actually study their usage.
struct MainWindowRootView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore
    @Bindable var tokens: TokenStatsStore

    enum Tab: String, CaseIterable, Identifiable {
        case usage, tokens
        var id: String { rawValue }
        var label: String { self == .usage ? L("Usage") : L("Tokens") }
    }

    /// Held outside the view, so opening the window can land the user on a chosen tab (the footer's
    /// token button) and so a language switch - which tears the whole tree down for every L() to
    /// re-resolve - does not throw the user back to the first tab.
    @Bindable private var selection = MainWindowTab.shared

    /// The account panel, also the source of the window's width: it derives that from the user's
    /// column choice, and the Tokens tab matches it so switching tabs never resizes the window
    /// sideways.
    private var usage: PopoverRootView {
        PopoverRootView(store: store, settings: settings, hostDrawsGlass: false)
    }

    var body: some View {
        VStack(spacing: 0) {
            // The window's primary control: full-size and centred above the divider, so it reads a
            // rank above the compact range picker the Tokens tab puts inside the content.
            Picker("", selection: $selection.tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: min(280, usage.popoverWidth - 24))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)
            Divider()
            switch selection.tab {
            case .usage:
                usage
            case .tokens:
                TokenStatsView(store: tokens, width: usage.popoverWidth)
                    // Every visit brings the numbers up to date; the scan itself skips files whose
                    // identity has not changed, so a repeat visit costs a directory walk.
                    .onAppear { tokens.refresh() }
            }
        }
        // Same reason as PopoverRootView's own: a language switch has to tear the tree down for
        // every L() to re-resolve, and the tab labels live above that view.
        .id(settings.languageOverride ?? "system")
    }
}

/// Which tab the dashboard window is showing.
///
/// Outside the view because the surfaces that OPEN the window decide where it lands: the footer's
/// token button goes straight to Tokens, everything else (the window button, the menu's "Open
/// Tally", a launch-time restore) opens on Usage.
@MainActor
@Observable
final class MainWindowTab {
    static let shared = MainWindowTab()

    var tab: MainWindowRootView.Tab = .usage

    private init() {}
}
