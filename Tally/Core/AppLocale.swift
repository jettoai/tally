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
            // A demo launch carries `-appLanguage` in the volatile ARGUMENT domain; any binding
            // writeback during that run must not fossilize it into the user's real defaults
            // (live leak: a marketing capture flipped the whole app to English, 2026-07-19).
            guard !DemoUsage.isActive else { return }
            if let newValue { UserDefaults.standard.set(newValue, forKey: overrideKey) }
            else { UserDefaults.standard.removeObject(forKey: overrideKey) }
        }
    }

    /// The effective locale for formatting (dates, numbers).
    static var current: Locale {
        if let code = override { return Locale(identifier: code) }
        return Locale.autoupdatingCurrent
    }

    /// Abbreviated date + short time, formatted in the APP's language rather than the system's: a
    /// zh-TW system date inside an English UI read as a missing translation (2026-07-19). The
    /// banked-reset dialog and its notification both show one, minutes apart, so they share it.
    static func shortDateTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(current))
    }

    /// Clock time alone, in the app's language for the reason above. For an instant whose DATE
    /// carries no information: "every morning at 7:00 AM" is about the hour, and a date beside it
    /// would name one particular morning.
    static func shortTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(current))
    }

    /// The bundle to resolve translations from, matching the effective language by progressively
    /// stripping subtags ("zh-Hant-TW" → "zh-Hant" → "zh"), falling back to the main bundle.
    ///
    /// Both halves are cached: the lookup per identifier, because every `L()` used to walk the
    /// filesystem (Sentry TALLY-Y/1Q/31/1Z, 2026-09-29), and the identifier itself, because reading
    /// it is a preferences read, and a popover render calls `L()` dozens of times on the main thread
    /// (TALLY-1R, 2026-10-10, hung in `override` after the first fix). A language switch still lands
    /// at once: any defaults write in this process, or a system language change, drops the cached
    /// identifier (`identifier`).
    static var bundle: Bundle {
        let identifier = Self.identifier
        bundleLock.lock(); defer { bundleLock.unlock() }
        if let cached = cachedBundle, cached.identifier == identifier { return cached.bundle }
        let resolved = resolveBundle(identifier)
        cachedBundle = (identifier, resolved)
        return resolved
    }

    private static let bundleLock = NSLock()
    nonisolated(unsafe) private static var cachedBundle: (identifier: String, bundle: Bundle)?

    /// The language `bundle` resolves, read once and kept until something may have changed it.
    static var identifier: String {
        _ = invalidation
        identifierLock.lock()
        let hit = cachedIdentifier, generation = identifierGeneration
        identifierLock.unlock()
        if let hit { return hit }
        // Read outside the lock: a preferences read may post the notification that takes it. The
        // generation keeps a read that raced an invalidation from being stored as current.
        let fresh = override ?? Locale.preferredLanguages.first ?? "en"
        identifierLock.lock()
        if identifierGeneration == generation { cachedIdentifier = fresh }
        identifierLock.unlock()
        return fresh
    }

    private static let identifierLock = NSLock()
    nonisolated(unsafe) private static var cachedIdentifier: String?
    nonisolated(unsafe) private static var identifierGeneration = 0

    /// Registered on the first read. `UserDefaults.didChangeNotification` is posted on the writing
    /// thread for every write in this process, so the setter above and any direct write of
    /// `overrideKey` drop the cached identifier before the next read. Named blind spot: a
    /// `defaults write` from another process is not seen until this process writes a default.
    private static let invalidation: Void = {
        for name in [UserDefaults.didChangeNotification, NSLocale.currentLocaleDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                identifierLock.lock(); defer { identifierLock.unlock() }
                cachedIdentifier = nil
                identifierGeneration += 1
            }
        }
    }()

    private static func resolveBundle(_ identifier: String) -> Bundle {
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
