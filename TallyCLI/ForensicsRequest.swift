import Foundation

// The `tally forensics setup|remove` request channel, shared by BOTH targets: the CLI posts a
// notification and waits; the installed app shows the system's password window and writes the
// answer to one small file, ~/.tally/forensics/<id>.result. Compiled into Tally.app as well as the
// tally tool (project.yml, beside RedeemRequest.swift), so it must stay dependency-free.
//
// A distributed notification cannot say who sent it, so any program of this account can ask for the
// window. It can only ask: what the window installs is fixed text (ProcessForensicsPrivilege.swift),
// the request carries no path and no text, and the app opens the window at most once in ten minutes.

/// Posted by the CLI; userInfo carries `action` and `id`.
let forensicsRequestedNotification = "ai.jetto.tally.forensicsRequested"

let forensicsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tally/forensics")

/// How long the CLI waits for the app to acknowledge before it says nobody picked the request up.
let forensicsPickupWindow: TimeInterval = 10

/// The password window opens at most once in this long for a request that came by notification.
let forensicsPromptSpacing: TimeInterval = 600

enum ForensicsAction: String { case setup, status, remove }

struct ForensicsArgs: Equatable { var action: ForensicsAction; var timeout: TimeInterval }

/// The app's answer. `pending` is the acknowledgement (the window is up), the rest end the wait.
enum ForensicsResultCode: String { case pending, done, cancelled, failed, throttled }

/// Nil = usage error (the caller prints the usage line, exit 2). A password may take a while to type:
/// the default wait is three minutes.
func parseForensicsArgs(_ args: [String]) -> ForensicsArgs? {
    guard let first = args.first, let action = ForensicsAction(rawValue: first) else { return nil }
    var timeout: TimeInterval = 180
    var i = 1
    while i < args.count {
        guard args[i] == "--timeout", i + 1 < args.count, let t = TimeInterval(args[i + 1]), t > 0 else { return nil }
        timeout = t; i += 2
    }
    return ForensicsArgs(action: action, timeout: timeout)
}

/// The id becomes a file name, so it is held to the characters a UUID has.
func isValidForensicsRequestID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count <= 64 && id.unicodeScalars.allSatisfy {
        ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A)
            || ($0.value >= 0x61 && $0.value <= 0x7A) || $0 == "-"
    }
}

func forensicsResultURL(_ id: String, dir: URL = forensicsDir) -> URL {
    dir.appendingPathComponent("\(id).result")
}

/// Whether a request that came by notification may open the password window now.
func forensicsPromptAllowed(lastShownAt: Date?, now: Date) -> Bool {
    guard let last = lastShownAt else { return true }
    let elapsed = now.timeIntervalSince(last)
    return elapsed < 0 || elapsed >= forensicsPromptSpacing   // a clock set back is not a reason to refuse for hours
}

func writeForensicsResult(_ id: String, _ code: ForensicsResultCode, dir: URL = forensicsDir) {
    guard isValidForensicsRequestID(id) else { return }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: forensicsResultURL(id, dir: dir).path,
                                   contents: Data(code.rawValue.utf8), attributes: [.posixPermissions: 0o600])
}

func readForensicsResult(_ id: String, dir: URL = forensicsDir) -> ForensicsResultCode? {
    guard isValidForensicsRequestID(id),
          let data = try? Data(contentsOf: forensicsResultURL(id, dir: dir)) else { return nil }
    return ForensicsResultCode(rawValue: String(decoding: data, as: UTF8.self))
}

/// Answers nobody read (a CLI killed while waiting) are dropped after a day.
func sweepForensicsResults(dir: URL = forensicsDir, now: Date = Date()) {
    let urls = (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    for url in urls where url.pathExtension == "result" {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, now.timeIntervalSince(modified) > 86_400 { try? FileManager.default.removeItem(at: url) }
    }
}
