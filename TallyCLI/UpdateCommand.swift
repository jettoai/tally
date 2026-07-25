import Foundation

// `tally update` - the CLI face of the app's Sparkle updater. Split out of main.swift purely for
// file size; the behavior is unchanged.

/// `tally update`: ask the menu bar app to run a user-initiated Sparkle check (its window
/// follows the pointer's screen), launching the app first when it isn't running. Uses pgrep +
/// a distributed notification so the statusline hot path never has to link AppKit.
func runUpdate() {
    func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
    if run("/usr/bin/pgrep", ["-xq", "Tally"]) != 0 {
        _ = run("/usr/bin/open", ["-b", "ai.jetto.tally"])
        Thread.sleep(forTimeInterval: 2)   // let the updater finish starting before we knock
    }
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("ai.jetto.tally.checkForUpdates"),
        object: nil, userInfo: nil, deliverImmediately: true)
    print("[tally] update check requested; Tally's update window will appear in a moment.")
}
