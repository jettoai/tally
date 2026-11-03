import Foundation

/// Copies a bundle to its destination through a temporary sibling, so a failure at any step
/// leaves the destination exactly as it was and no half copy behind.
struct AppMover {
    var source: URL
    var destination: URL            // e.g. /Applications/Tally.app
    var executableName: String      // CFBundleExecutable of the source
    var dittoPath = "/usr/bin/ditto"
    var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    /// `.<name>.moving` beside the destination: same directory, so the final rename is atomic.
    var temporary: URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent("." + destination.lastPathComponent + ".moving")
    }

    /// Synchronous; callers run it off the main thread. nil = moved.
    func run(replacing: Bool) -> MoveFailure? {
        let fm = FileManager.default
        func cleanup() { try? fm.removeItem(at: temporary) }
        if fm.fileExists(atPath: temporary.path) {
            do { try fm.removeItem(at: temporary) } catch { return .copyFailed }
        }
        // ditto keeps every xattr, quarantine included (its --noqtn does not strip it, measured on
        // macOS 27), and a copy that still carries com.apple.quarantine is translocated again on
        // open, lands under AppTranslocation, and the move window would come back for ever. So the
        // quarantine is removed explicitly. The user already passed Gatekeeper for this copy by
        // opening it, and the attribute is not part of the signature.
        guard Self.run(dittoPath, [source.path, temporary.path]),
              Self.run("/usr/bin/xattr", ["-r", "-d", "com.apple.quarantine", temporary.path])
        else { cleanup(); return .copyFailed }
        let executable = temporary.appendingPathComponent("Contents/MacOS/" + executableName)
        guard fm.fileExists(atPath: executable.path) else { cleanup(); return .copyFailed }
        // The old copy goes only once the new one is whole, so a failed copy never costs the user
        // the install they already had.
        if replacing, fm.fileExists(atPath: destination.path) {
            do { try trash(destination) } catch { cleanup(); return .trashFailed }
        }
        do { try fm.moveItem(at: temporary, to: destination) } catch { cleanup(); return .copyFailed }
        return nil
    }

    /// Runs a tool to completion with no pipes (a full pipe buffer would stall waitUntilExit for
    /// good); true when it exits 0.
    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Allocated size of everything in the bundle, nil when it cannot be read.
    static func bundleSize(_ url: URL) -> Int64? {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        var failed = false
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, _ in failed = true; return true }) else { return nil }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return failed ? nil : total
    }

    /// Free bytes on the volume the directory is on, nil when unknown.
    static func freeBytes(at directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
