import Foundation
import ServiceManagement

/// The login item itself: read it, set it, and open the System Settings panel that governs it.
///
/// `SMAppService.mainApp` needs no helper bundle and no entitlement for an app that is not
/// sandboxed; it registers THIS running bundle, which is why the Settings row refuses to touch it
/// from a build nobody installed (see SettingsLaunchAtLoginRow).
@MainActor
enum LaunchAtLoginService {
    /// What macOS says right now. Always asked, never remembered: consent for a login item is
    /// withdrawn in System Settings and the app is never told, so a stored answer rots in silence.
    static var current: LaunchAtLoginState { state(for: SMAppService.mainApp.status) }

    /// The status mapping on its own, so it can be asserted without a login item existing
    /// (tests/run-launchatlogin-tests.sh).
    nonisolated static func state(for status: SMAppService.Status) -> LaunchAtLoginState {
        switch status {
        case .enabled: return .enabled
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    /// Register or unregister, letting the error out. Both calls throw for reasons the user needs
    /// to read (a signature macOS refuses, consent withheld), and swallowing them here is how a
    /// switch comes to flip with nothing behind it. Which of those errors is worth a line on
    /// screen is decided against the re-read state, in `LaunchAtLoginState.surfacesFailure`.
    static func setRegistered(_ registered: Bool) throws {
        if registered {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// System Settings > General > Login Items: the only place `requiresApproval` can be settled.
    static func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
