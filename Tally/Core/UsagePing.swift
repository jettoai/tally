import Foundation

/// The anonymous install count: one POST to jetto.ai at launch and once a day while the app stays
/// open, carrying the product, a random device id and the app version. Nothing else: no hardware
/// serial, no account, no Authorization header. Failures are dropped, never retried, and never wait
/// on anything. On by default; the Settings switch (SettingsUsagePingRow) turns it off, and off
/// means no request at all and no device id is made.
enum UsagePing {
    static let enabledKey = "usagePingEnabled"
    static let deviceKey = "jetto.deviceId"
    static let interval: TimeInterval = 24 * 60 * 60
    /// Dev only: `-TallyPingURL http://127.0.0.1:<port>/api/v1/ping` points the ping at a local
    /// stand-in (tests/usageping). Without it a Debug build sends nothing, so development runs do
    /// not count as installs.
    static let urlOverrideKey = "TallyPingURL"
    static let endpoint = URL(string: "https://jetto.ai/api/v1/ping")!

    /// The private build is compiled with TALLY_OVERLAY (its Overlay.xcconfig).
    static var product: String {
        #if TALLY_OVERLAY
        return "tally-pro"
        #else
        return "tally"
        #endif
    }

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func setEnabled(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: enabledKey)
    }

    /// The stored id, made on first use. Only called once the switch is known to be on.
    static func deviceID(_ defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: deviceKey), UUID(uuidString: id) != nil { return id.lowercased() }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: deviceKey)
        return id
    }

    static func request(url: URL, device: String, version: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["product": product, "device": device, "version": version], options: [.sortedKeys])
        return request
    }

    /// Sends one ping if the switch is on. Returns whether a request went out; `done` gets the
    /// outcome (true on 2xx) on URLSession's queue and is for tests only.
    @discardableResult
    static func send(to url: URL, defaults: UserDefaults = .standard,
                     version: String = BuildVariant.version ?? "0",
                     done: (@Sendable (Bool) -> Void)? = nil) -> Bool {
        guard isEnabled(defaults) else { return false }
        let request = request(url: url, device: deviceID(defaults), version: version)
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            done?(error == nil && (200..<300).contains(code))
        }.resume()
        session.finishTasksAndInvalidate()
        return true
    }

    /// Whether a timer tick should send: a day since the last ping. A tick after a long sleep sees
    /// the gap once and sends once, then the stamp moves.
    static func isDue(lastSent: Date?, now: Date) -> Bool {
        guard let lastSent else { return true }
        return now.timeIntervalSince(lastSent) >= interval
    }

    @MainActor private static var lastSent: Date?
    @MainActor private static var timer: Timer?

    /// Launch hook: one ping now, then an hourly check that sends when a day has passed. The timer
    /// lives on the app's run loop, so nothing runs while the app is closed.
    @MainActor static func start() {
        guard timer == nil, let url = resolvedURL else { return }
        tick(url)
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in tick(url) }
        }
        timer?.tolerance = 5 * 60
    }

    @MainActor private static func tick(_ url: URL) {
        let now = Date()
        guard isDue(lastSent: lastSent, now: now), send(to: url) else { return }
        lastSent = now
    }

    private static var resolvedURL: URL? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: urlOverrideKey).flatMap(URL.init(string:))
        #else
        return endpoint
        #endif
    }
}
