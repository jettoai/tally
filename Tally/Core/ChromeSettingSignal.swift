import Foundation

// THE ONE FACT THE CLI HANDS THE APP ABOUT THE CHROME SETTING: a session running on the very
// account the user set as Claude in Chrome's reported "not connected". Written by the hook
// (TallyCLI/ChromeReach.swift) only on that one route, which is decided by the setting and the
// event alone; the chrome-reach ledger never writes or gates it. The app posts one notification
// asking the user to check the setting (Tally/Core/ChromeSettingNotifier.swift).

struct ChromeSettingGapSignal: Codable, Equatable {
    var account: String
    var at: Date
}

let chromeSettingGapSignalFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/chrome-setting-gap.json")

func writeChromeSettingGapSignal(_ signal: ChromeSettingGapSignal,
                                 file: URL = chromeSettingGapSignalFile) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    if let data = try? encoder.encode(signal) { try? data.write(to: file, options: .atomic) }
}

func readChromeSettingGapSignal(file: URL = chromeSettingGapSignalFile) -> ChromeSettingGapSignal? {
    guard let data = try? Data(contentsOf: file) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(ChromeSettingGapSignal.self, from: data)
}

/// Whether the app should post the "check your Chrome account setting" notification now.
/// Once per setting value: `setAt` is when the user last chose an account (a signal older than
/// that is about an earlier choice), and `notified` is whether this choice was already reported.
/// The signal is stamped to the whole second, so a gap in the same second as the choice is missed.
func chromeSettingGapShouldNotify(setting: String?, setAt: Date?,
                                  signal: ChromeSettingGapSignal?, notified: Bool) -> Bool {
    guard let setting, !setting.isEmpty, let signal, signal.account == setting, !notified
    else { return false }
    return signal.at > (setAt ?? .distantPast)
}
