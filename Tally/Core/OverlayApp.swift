import SwiftUI

// What a private build adds to the app. The public build adds nothing.
#if !TALLY_OVERLAY
enum OverlayApp {
    @MainActor static func didFinishLaunching() {}
    @MainActor static func panelAppeared() {}
    @MainActor static func panelDisappeared() {}
}

extension PopoverRootView {
    /// A strip a private build shows under the advisor row.
    @ViewBuilder var overlayStrip: some View { EmptyView() }
}
#endif
