import Foundation

/// Why a move did not happen, one case per sentence the window can show.
enum MoveFailure: String, CaseIterable {
    case notWritable, notEnoughSpace, trashFailed, copyFailed, launchFailed
}

/// What to do once the user presses Move.
enum MovePlan: Equatable {
    case openExisting             // a copy at the destination is running, or is as new as this one
    case copy(replacing: Bool)    // replacing = an older copy is there and goes to the Trash after the copy
    case fail(MoveFailure)
}

/// The facts the plan is decided from, gathered by the caller so the decision stays pure.
struct MoveSituation: Equatable {
    var destinationExists: Bool
    var destinationRunning: Bool
    var destinationVersion: String?   // CFBundleShortVersionString read from the plist on disk
    var sourceVersion: String?
    var directoryWritable: Bool
    var freeBytes: Int64?             // nil = unknown, never blocks
    var neededBytes: Int64?           // nil = unknown, never blocks
}

/// Where this copy of the app is running from, and what moving it to Applications should do.
/// Foundation only, so the decision compiles and runs without the app (tests/movetoapps).
enum InstallLocation {
    /// Whether this bundle runs from a disk image (mounted read-only under /Volumes, or a
    /// translocated copy of one) and so must be moved before it may do anything else.
    static func isRunningFromDiskImage(bundlePath: String, volumeIsReadOnly: Bool,
                                       isDev: Bool, isDemo: Bool) -> Bool {
        if isDev || isDemo { return false }
        let lowered = bundlePath.lowercased()
        // A build tree is not an install. Own list: BuildVariant.isBuildProductsPath also answers
        // true for AppTranslocation, which is exactly the case this has to detect.
        if ["/deriveddata/", "/build/products/", ".xcarchive/"].contains(where: lowered.contains) {
            return false
        }
        if lowered.contains("/apptranslocation/") { return true }
        return lowered.hasPrefix("/volumes/") && volumeIsReadOnly
    }

    /// statfs on the path itself, so a nested mount answers for the volume the bundle is on. false
    /// when statfs fails: a miss here means today's behaviour, a false hit would block a real install.
    static func volumeIsReadOnly(atPath path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        return info.f_flags & UInt32(MNT_RDONLY) != 0
    }

    static func plan(_ s: MoveSituation) -> MovePlan {
        if s.destinationRunning { return .openExisting }
        if s.destinationExists,
           installedIsAtLeastAsNew(installed: s.destinationVersion, source: s.sourceVersion) {
            return .openExisting
        }
        if !s.directoryWritable { return .fail(.notWritable) }
        if let free = s.freeBytes, let needed = s.neededBytes, free < needed {
            return .fail(.notEnoughSpace)
        }
        return .copy(replacing: s.destinationExists)
    }

    /// true when both versions are known and installed >= source (numeric, so 0.85.9 < 0.85.80).
    static func installedIsAtLeastAsNew(installed: String?, source: String?) -> Bool {
        guard let installed, let source else { return false }
        return installed.compare(source, options: .numeric) != .orderedAscending
    }
}

/// The dev-only launch flags that preview the move window and redirect where it copies to.
struct MoveToApplicationsLaunch: Equatable {
    static let previewKey = "TallyMoveToApplicationsPreview"
    static let destinationKey = "TallyMoveToApplicationsDest"
    static let failKey = "TallyMoveToApplicationsFail"
    static let autoMoveKey = "TallyMoveToApplicationsAutoMove"
    static let applicationsDirectory = URL(fileURLWithPath: "/Applications", isDirectory: true)

    var preview = false
    var destinationDirectory = applicationsDirectory
    var forcedFailure: MoveFailure? = nil
    var autoMove = false

    /// `devOrDemo` is `BuildVariant.isDev || DemoUsage.isActive`, passed in by the caller. The three
    /// modifiers do nothing without the preview flag.
    static func read(from defaults: UserDefaults, devOrDemo: Bool) -> MoveToApplicationsLaunch {
        var launch = MoveToApplicationsLaunch()
        guard devOrDemo, CaptureLaunch.isActive(rawValue: defaults.object(forKey: previewKey)) else {
            return launch
        }
        launch.preview = true
        if let dir = defaults.string(forKey: destinationKey), !dir.isEmpty {
            launch.destinationDirectory = URL(
                fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        let fail = defaults.object(forKey: failKey)
        if CaptureLaunch.isActive(rawValue: fail) {
            let named = (fail as? String).flatMap { name in
                MoveFailure.allCases.first { $0.rawValue.lowercased() == name.lowercased() }
            }
            launch.forcedFailure = named ?? .copyFailed
        }
        launch.autoMove = CaptureLaunch.isActive(rawValue: defaults.object(forKey: autoMoveKey))
        return launch
    }
}
