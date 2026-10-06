import AppKit
import CoreGraphics
import Foundation

/// `-TallyWindowSnapshot <dir>`: write every window this launch put on screen to a PNG in `dir`,
/// then leave. The capture flag family's last mile.
///
/// WHY THE APP TAKES ITS OWN PICTURE. The other flags in the family (`-TallyPanelCapture`,
/// `-TallySettingsCapture`) exist so a surface can be photographed without synthesizing the clicks
/// that would take the pointer and the frontmost app away from whoever is using the machine
/// (~/.claude/docs/patterns/macos-app-verification.md). They put the window up; something else was
/// then expected to run `screencapture -o -l <windowID>`. That step needs Screen Recording, which is
/// a permission granted to a particular app - so on a machine where the shell driving the review has
/// not been granted it, every one of those flags stops one step short of the picture, and the answer
/// "ask the user to open System Settings" is the desktop-interrupting move they were added to avoid.
///
/// A PROCESS ALWAYS CAPTURES ITS OWN WINDOWS. `CGWindowListCreateImage` blanks other applications'
/// content without the permission and never the caller's, so this path needs no grant at all - and
/// unlike rendering the view hierarchy by hand it goes through the compositor, which is what keeps
/// the material, the transparency and the rounded corners that a panel screenshot is mostly about.
///
/// SAME SHAPE AS `-TallyStripSnapshot`, one surface up: a demo/dev-only flag carrying a path, a
/// write, and no state that outlives the launch.
enum WindowSnapshot {
    static let flagKey = "TallyWindowSnapshot"

    /// How long the windows are given to finish laying out before the shutter.
    ///
    /// A CAPTURE LAUNCH IS NOT A STEADY STATE: the Settings window sizes itself from a content
    /// height the view reports after its first full layout, and the panel is drawn from a refresh
    /// round. Photographed at `applicationDidFinishLaunching` both are mid-flight, which is a
    /// picture of the app assembling itself rather than of the thing under review.
    private static let settleDelay: TimeInterval = 1.5

    /// Take the pictures, if this launch asked for them.
    static func captureIfRequested() {
        // Demo data or a dev build, like every flag in this family: it must never be reachable in a
        // release instance somebody is actually using.
        guard DemoUsage.isActive || BuildVariant.isDev,
              let dir = UserDefaults.standard.string(forKey: flagKey), !dir.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(settleDelay))
            // A token or cost page on real data is still reading transcripts at this point; a
            // picture of its spinner is not the page. Bounded so a stuck scan still gets a shot.
            for _ in 0..<240 where TokenStatsStore.shared.isScanning {
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? await Task.sleep(for: .milliseconds(500))
            write(into: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
        }
    }

    /// One PNG per window, named after the window's title (the untitled ones - the pinned panel is
    /// one - fall back to their number, which is what tells two of them apart).
    @MainActor private static func write(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for window in NSApp.windows where window.isVisible && window.frame.width > 1 {
            // NOT EVERY `windowNumber` IS A `CGWindowID`. AppKit hands the status item's own windows
            // numbers at and above 2^32 (4294967296 and its multiples, measured here 2026-08-20)
            // while a CGWindowID is 32 bits, so the ordinary conversion TRAPS - a crash with no
            // picture and no reason printed, on the first capture this flag ever took. `exactly` is
            // the one that answers instead, and the windows it answers nothing for are the menu bar
            // items, which are `-TallyStripSnapshot`'s subject rather than this one's.
            guard let id = CGWindowID(exactly: window.windowNumber) else { continue }
            let title = window.title.isEmpty ? "window-\(window.windowNumber)"
                : window.title.replacingOccurrences(of: "/", with: "-")
            // Through the compositor. `boundsIgnoreFraming` keeps the shot to the window itself
            // rather than to the shadow around it, which is what leaves the corners transparent
            // instead of sitting on a grey halo.
            let composited = CGWindowListCreateImage(.null, .optionIncludingWindow, id,
                                                     [.boundsIgnoreFraming, .bestResolution])
                .map(NSBitmapImageRep.init(cgImage:))
            // THE COMPOSITOR SOMETIMES HANDS BACK A FULLY TRANSPARENT IMAGE of a window that is on
            // screen (a tall Settings window, 2026-09-27; not reproduced by screen, height or
            // off-screen placement). Then the window draws itself instead: no material or rounded
            // corners, but a picture rather than an empty file.
            let rep: NSBitmapImageRep
            if let composited, !isBlank(composited) {
                rep = composited
            } else if let drawn = selfDrawn(window) {
                rep = drawn
                FileHandle.standardError.write(Data(
                    "snapshot: compositor image of \"\(title)\" was blank, drew the window instead\n".utf8))
            } else { continue }
            let file = dir.appendingPathComponent("\(title).png")
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: file)
            FileHandle.standardError.write(Data("snapshot: \(file.path)\n".utf8))
        }
        // The launch existed to take these; nothing else it could do afterwards is wanted, and a
        // capture instance left running is a second Tally in the menu bar the user did not ask for.
        NSApp.terminate(nil)
    }

    /// Every sampled pixel fully transparent. A grid rather than every pixel: a real window has
    /// opaque content across most of its area, so a sparse sample cannot miss it.
    private static func isBlank(_ rep: NSBitmapImageRep) -> Bool {
        for y in stride(from: 0, to: rep.pixelsHigh, by: 16) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 16)
            where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 { return false }
        }
        return true
    }

    /// The window drawn by AppKit rather than the compositor. The content view's superview is the
    /// frame view, so the title bar comes along with the content.
    @MainActor private static func selfDrawn(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}
