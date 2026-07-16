import Foundation

/// App-controlled UI language, defaulting to the system locale but overridable in Settings.
///
/// Pattern adapted from jetto: every `String(localized:bundle:)` call passes `AppLocale.bundle`
/// so switching the in-app language takes effect immediately without a relaunch. `nil` override
/// (the default) means "follow the system", satisfying the "預設當地 locale" requirement.
enum AppLocale {
    static let overrideKey = "appLanguage"

    /// The language codes Tally ships translations for (must match project.yml `localizations:`).
    static let supported = ["en", "zh-Hant", "zh-Hans", "ja", "ko"]

    /// The user's explicit override, or `nil` to follow the system.
    static var override: String? {
        get { UserDefaults.standard.string(forKey: overrideKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: overrideKey) }
            else { UserDefaults.standard.removeObject(forKey: overrideKey) }
        }
    }

    /// The effective locale for formatting (dates, numbers).
    static var current: Locale {
        if let code = override { return Locale(identifier: code) }
        return Locale.autoupdatingCurrent
    }

    /// The bundle to resolve translations from, matching the effective language by progressively
    /// stripping subtags ("zh-Hant-TW" → "zh-Hant" → "zh"), falling back to the main bundle.
    static var bundle: Bundle {
        let identifier = override ?? Locale.preferredLanguages.first ?? "en"
        var components = identifier.split(separator: "-")
        while !components.isEmpty {
            let candidate = components.joined(separator: "-")
            if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
            components.removeLast()
        }
        return .main
    }
}

/// Localize a key through the app's effective language bundle (respects the in-app override).
/// Returns an already-resolved `String`, so `Text(L("…"))` renders it verbatim rather than
/// re-localizing against the main bundle.
func L(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), bundle: AppLocale.bundle)
}
