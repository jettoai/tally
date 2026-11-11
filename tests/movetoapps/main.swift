import Foundation

// Assertion harness for the move-to-Applications layer: where a copy is running from
// (InstallLocation), what pressing Move does (MovePlan), the dev launch flags, the file mover
// (AppMover) and the order of the launch gate in AppDelegate. Writes only inside a temp directory.

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL"): \(name)")
    if !ok { failures += 1 }
}

// MARK: - A: isRunningFromDiskImage

let tr = "/private/var/folders/ab/xyz/T/AppTranslocation/0F3A/d/Tally.app"
let derived = "/Users/me/Library/Developer/Xcode/DerivedData/T-abc/Build/Products/Release/Tally.app"
let tableA: [(String, Bool, Bool, Bool, Bool)] = [
    ("/Volumes/Tally/Tally.app", true, false, false, true),
    ("/Volumes/Tally 1/Tally.app", true, false, false, true),
    ("/Volumes/Tally/Tally.app", false, false, false, false),
    ("/Volumes/External/Apps/Tally.app", false, false, false, false),
    ("/Applications/Tally.app", false, false, false, false),
    ("/Applications/Tally.app", true, false, false, false),
    ("/Users/me/Applications/Tally.app", false, false, false, false),
    (tr, false, false, false, true),
    (tr.replacingOccurrences(of: "AppTranslocation", with: "apptranslocation"), true, false, false, true),
    (tr.replacingOccurrences(of: "AppTranslocation", with: "APPTRANSLOCATION"), true, false, false, true),
    ("/volumes/Tally/Tally.app", true, false, false, true),
    ("/VolumesX/Tally.app", true, false, false, false),
    ("/Volumes/Tally/Tally.app", true, true, false, false),
    ("/Volumes/Tally/Tally.app", true, false, true, false),
    (tr, true, true, false, false),
    (derived, false, false, false, false),
    ("/Volumes/Dev/DerivedData/T/Build/Products/Debug/Tally.app", true, false, false, false),
    ("/Volumes/Dev/repo/build/Products/Release/Tally.app", true, false, false, false),
    ("/Volumes/Dev/repo/build/Tally.xcarchive/Products/Applications/Tally.app", true, false, false, false),
]
for (path, ro, dev, demo, expected) in tableA {
    check("A \(path) ro=\(ro) dev=\(dev) demo=\(demo) -> \(expected)",
          InstallLocation.isRunningFromDiskImage(
              bundlePath: path, volumeIsReadOnly: ro, isDev: dev, isDemo: demo) == expected)
}
check("A statfs: the temp directory is writable",
      InstallLocation.volumeIsReadOnly(atPath: NSTemporaryDirectory()) == false)
check("A statfs: a missing path answers false",
      InstallLocation.volumeIsReadOnly(atPath: "/no/such/path") == false)

// MARK: - B: plan

func situation(exists: Bool, running: Bool, dest: String?, src: String?, writable: Bool,
               free: Int64?, need: Int64?) -> MoveSituation {
    MoveSituation(destinationExists: exists, destinationRunning: running, destinationVersion: dest,
                  sourceVersion: src, directoryWritable: writable, freeBytes: free, neededBytes: need)
}
let gb: Int64 = 1_000_000_000, hundredMB: Int64 = 100_000_000
let tableB: [(MoveSituation, MovePlan)] = [
    (situation(exists: false, running: false, dest: nil, src: "0.85.80", writable: true, free: gb, need: hundredMB), .copy(replacing: false)),
    (situation(exists: true, running: false, dest: "0.85.9", src: "0.85.80", writable: true, free: gb, need: hundredMB), .copy(replacing: true)),
    (situation(exists: true, running: false, dest: "0.85.80", src: "0.85.80", writable: true, free: gb, need: hundredMB), .openExisting),
    (situation(exists: true, running: false, dest: "0.86.0", src: "0.85.80", writable: true, free: gb, need: hundredMB), .openExisting),
    (situation(exists: true, running: true, dest: "0.80.0", src: "0.85.80", writable: true, free: gb, need: hundredMB), .openExisting),
    (situation(exists: true, running: true, dest: "0.80.0", src: "0.85.80", writable: false, free: nil, need: nil), .openExisting),
    (situation(exists: false, running: false, dest: nil, src: "0.85.80", writable: false, free: gb, need: hundredMB), .fail(.notWritable)),
    (situation(exists: true, running: false, dest: "0.80.0", src: "0.85.80", writable: false, free: gb, need: hundredMB), .fail(.notWritable)),
    (situation(exists: false, running: false, dest: nil, src: "0.85.80", writable: true, free: 10_000_000, need: hundredMB), .fail(.notEnoughSpace)),
    (situation(exists: false, running: false, dest: nil, src: "0.85.80", writable: true, free: nil, need: hundredMB), .copy(replacing: false)),
    (situation(exists: true, running: false, dest: nil, src: "0.85.80", writable: true, free: gb, need: hundredMB), .copy(replacing: true)),
    (situation(exists: true, running: false, dest: "0.85.80", src: nil, writable: true, free: gb, need: hundredMB), .copy(replacing: true)),
]
for (i, (s, expected)) in tableB.enumerated() {
    check("B row \(i + 1): \(s.destinationVersion ?? "nil") vs \(s.sourceVersion ?? "nil") -> \(expected)",
          InstallLocation.plan(s) == expected)
}

// MARK: - C: launch flags

func launch(devOrDemo: Bool, _ values: [String: String]) -> MoveToApplicationsLaunch {
    let name = "movetoapps.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    for (k, v) in values { defaults.set(v, forKey: k) }
    return MoveToApplicationsLaunch.read(from: defaults, devOrDemo: devOrDemo)
}
let P = MoveToApplicationsLaunch.previewKey, D = MoveToApplicationsLaunch.destinationKey
let F = MoveToApplicationsLaunch.failKey, A = MoveToApplicationsLaunch.autoMoveKey
let plain = MoveToApplicationsLaunch()
check("C release build ignores every flag",
      launch(devOrDemo: false, [P: "YES", D: "/tmp/x", F: "YES", A: "YES"]) == plain)
check("C no flags -> defaults", launch(devOrDemo: true, [:]) == plain)
check("C preview", { let l = launch(devOrDemo: true, [P: "YES"]); return l.preview && l.destinationDirectory.path == "/Applications" }())
check("C preview + dest", launch(devOrDemo: true, [P: "YES", D: "/tmp/x"]).destinationDirectory.path == "/tmp/x")
check("C tilde dest", launch(devOrDemo: true, [P: "YES", D: "~/x"]).destinationDirectory.path == NSHomeDirectory() + "/x")
check("C dest without preview -> defaults", launch(devOrDemo: true, [D: "/tmp/x"]) == plain)
check("C preview=NO + autoMove -> defaults", launch(devOrDemo: true, [P: "NO", A: "YES"]) == plain)
check("C fail=YES -> copyFailed", launch(devOrDemo: true, [P: "YES", F: "YES"]).forcedFailure == .copyFailed)
check("C fail=notwritable", launch(devOrDemo: true, [P: "YES", F: "notwritable"]).forcedFailure == .notWritable)
check("C fail=LaunchFailed", launch(devOrDemo: true, [P: "YES", F: "LaunchFailed"]).forcedFailure == .launchFailed)
check("C fail=NO -> nil", launch(devOrDemo: true, [P: "YES", F: "NO"]).forcedFailure == nil)
check("C autoMove", launch(devOrDemo: true, [P: "YES", A: "YES"]).autoMove)

// MARK: - D: AppMover on a real file system (temp directory only)

let fm = FileManager.default
let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("movetoapps-\(UUID().uuidString)", isDirectory: true)
try! fm.createDirectory(at: root, withIntermediateDirectories: true)

func makeBundle(at dir: URL, marker: String) -> URL {
    let app = dir.appendingPathComponent("Fake.app", isDirectory: true)
    let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try! fm.createDirectory(at: macos, withIntermediateDirectories: true)
    try! marker.write(to: macos.appendingPathComponent("Fake"), atomically: true, encoding: .utf8)
    let plist: [String: Any] = ["CFBundleExecutable": "Fake", "CFBundleShortVersionString": "1.0"]
    (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
    return app
}
func exe(_ app: URL) -> String? {
    try? String(contentsOf: app.appendingPathComponent("Contents/MacOS/Fake"), encoding: .utf8)
}
var caseNumber = 0
func freshDir(_ prefix: String) -> URL {
    caseNumber += 1
    let dir = root.appendingPathComponent("\(prefix)-\(caseNumber)", isDirectory: true)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

let src = makeBundle(at: freshDir("src"), marker: "new")

do { // D1 success
    let dest = freshDir("dest").appendingPathComponent("Fake.app")
    let mover = AppMover(source: src, destination: dest, executableName: "Fake")
    check("D1 moved", mover.run(replacing: false) == nil)
    check("D1 destination holds the new executable", exe(dest) == "new")
    check("D1 no temporary left", !exists(mover.temporary))
    check("D1 source still there", exe(src) == "new")
}
do { // D2 ditto fails
    let dest = freshDir("dest").appendingPathComponent("Fake.app")
    var mover = AppMover(source: src, destination: dest, executableName: "Fake")
    mover.dittoPath = "/usr/bin/false"
    check("D2 copyFailed", mover.run(replacing: false) == .copyFailed)
    check("D2 nothing left", !exists(mover.temporary) && !exists(dest))
}
do { // D3 leftover temporary
    let dir = freshDir("dest")
    let dest = dir.appendingPathComponent("Fake.app")
    let mover = AppMover(source: src, destination: dest, executableName: "Fake")
    try! fm.createDirectory(at: mover.temporary, withIntermediateDirectories: true)
    try! "x".write(to: mover.temporary.appendingPathComponent("junk"), atomically: true, encoding: .utf8)
    check("D3 moved", mover.run(replacing: false) == nil)
    check("D3 no temporary and no junk",
          !exists(mover.temporary) && !exists(dest.appendingPathComponent("junk")))
}
do { // D4 missing executable
    let dest = freshDir("dest").appendingPathComponent("Fake.app")
    let mover = AppMover(source: src, destination: dest, executableName: "Missing")
    check("D4 copyFailed", mover.run(replacing: false) == .copyFailed)
    check("D4 nothing left", !exists(mover.temporary) && !exists(dest))
}
do { // D5 replace
    let dir = freshDir("dest")
    let dest = makeBundle(at: dir, marker: "old")
    let trashDir = freshDir("trash")
    var mover = AppMover(source: src, destination: dest, executableName: "Fake")
    mover.trash = { try fm.moveItem(at: $0, to: trashDir.appendingPathComponent($0.lastPathComponent)) }
    check("D5 moved", mover.run(replacing: true) == nil)
    check("D5 destination is new", exe(dest) == "new")
    check("D5 the old copy went to the trash", exe(trashDir.appendingPathComponent("Fake.app")) == "old")
    check("D5 no temporary left", !exists(mover.temporary))
}
do { // D6 trash fails
    let dir = freshDir("dest")
    let dest = makeBundle(at: dir, marker: "old")
    var mover = AppMover(source: src, destination: dest, executableName: "Fake")
    mover.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
    check("D6 trashFailed", mover.run(replacing: true) == .trashFailed)
    check("D6 the old copy is untouched", exe(dest) == "old")
    check("D6 no temporary left", !exists(mover.temporary))
}
do { // D7 quarantine dropped, other xattrs kept
    let qsrc = makeBundle(at: freshDir("src"), marker: "q")
    let file = qsrc.appendingPathComponent("Contents/MacOS/Fake").path
    let quarantine = Array("0081;00000000;Test;".utf8), keep = Array("keep-me".utf8)
    check("D7 set quarantine on the file", setxattr(file, "com.apple.quarantine", quarantine, quarantine.count, 0, 0) == 0)
    check("D7 set quarantine on the bundle", setxattr(qsrc.path, "com.apple.quarantine", quarantine, quarantine.count, 0, 0) == 0)
    check("D7 set other xattr", setxattr(file, "com.example.keep", keep, keep.count, 0, 0) == 0)
    let dest = freshDir("dest").appendingPathComponent("Fake.app")
    check("D7 moved", AppMover(source: qsrc, destination: dest, executableName: "Fake").run(replacing: false) == nil)
    let copy = dest.appendingPathComponent("Contents/MacOS/Fake").path
    check("D7 quarantine is gone from the file", getxattr(copy, "com.apple.quarantine", nil, 0, 0, 0) == -1)
    check("D7 quarantine is gone from the bundle", getxattr(dest.path, "com.apple.quarantine", nil, 0, 0, 0) == -1)
    var buffer = [UInt8](repeating: 0, count: 16)
    let n = getxattr(copy, "com.example.keep", &buffer, buffer.count, 0, 0)
    check("D7 the other xattr is kept", n == keep.count && Array(buffer[..<n]) == keep)
}
check("D8 bundle size", (AppMover.bundleSize(src) ?? 0) > 0)
check("D9 free bytes", (AppMover.freeBytes(at: root) ?? 0) > 0)
try? fm.removeItem(at: root)

// MARK: - E: the launch gate is in the right place (source-order lock)

func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
/// The text of `func ...` from its opening brace to the matching close.
func body(of signature: String, in text: String) -> String {
    guard let start = text.range(of: signature),
          let open = text[start.upperBound...].firstIndex(of: "{") else { return "" }
    var depth = 0
    var index = open
    while index < text.endIndex {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1; if depth == 0 { return String(text[open...index]) } }
        index = text.index(after: index)
    }
    return ""
}
func pos(_ needle: String, in text: String) -> Int? {
    text.range(of: needle).map { text.distance(from: text.startIndex, to: $0.lowerBound) }
}
func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

let delegate = read("Tally/App/AppDelegate.swift")
let launchBody = body(of: "func applicationDidFinishLaunching(", in: delegate)
let gateText = "if MoveToApplicationsWindowController.shared.showIfNeeded() { return }"
let gate = pos(gateText, in: launchBody) ?? -1
func before(_ needle: String) -> Bool { gate >= 0 && (pos(needle, in: launchBody).map { gate < $0 } ?? false) }
check("E1 the gate exists, once", gate >= 0 && count(gateText, in: delegate) == 1)
check("E2 after the older Dev instances are closed",
      (pos("closeOlderDevInstances()", in: launchBody).map { $0 < gate } ?? false) && gate >= 0)
check("E3 before the focus recorder", before("FocusEventRecorder.shared.install()"))
check("E4 before the first-launch read and write",
      before("LaunchAtLoginDefault.appliedKey") && before("LaunchAtLoginDefault.applyIfNeeded()"))
check("E5 before the welcome window", before("WelcomeWindowController.shared.showAtLaunchIfNeeded("))
check("E6 before the status item and the updater",
      before("statusItemController.install()") && before("UpdaterController.shared.start()"))
check("E7 appearance runs once, before the gate",
      count("applyPreviewAppearance()", in: launchBody) == 1
          && (pos("applyPreviewAppearance()", in: launchBody).map { $0 < gate } ?? false))
let terminateBody = body(of: "func applicationShouldTerminate(", in: delegate)
check("E8 terminate checks the hold before persisting restore state",
      (pos("isHoldingLaunch", in: terminateBody) ?? Int.max) < (pos("persistRestoreState()", in: terminateBody) ?? -1))
check("E9 reopen checks the hold",
      body(of: "func applicationShouldHandleReopen(", in: delegate)
          .contains("MoveToApplicationsWindowController.isHoldingLaunch"))
let argumentsLine = read("Tally/MenuBar/MoveToApplicationsWindowController.swift")
    .components(separatedBy: "\n").first { $0.contains("config.arguments =") } ?? ""
check("E10 the relaunch forwards no preview flag", !argumentsLine.isEmpty && !argumentsLine.contains("MoveToApplications"))

// The disk-image window must fit the smallest supported display, 1024 x 768 points (B-3747).
let windowRectLine = read("scripts/dmg/settings.py").components(separatedBy: "\n")
    .first { $0.hasPrefix("window_rect") } ?? ""
let rect = windowRectLine.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
check("F1 the disk image's window fits a 1024 x 768 display",
      rect.count == 4 && rect[0] + rect[2] <= 1024 && rect[1] + rect[3] <= 768)

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
