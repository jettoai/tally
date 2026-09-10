import Foundation

/// Explicit installer, with injectable paths for isolated native-hook verification.
func runCodexSessionInstall(_ args: [String]) {
    var homes: [String] = []
    var root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tally")
    var executable = "/usr/local/bin/tally"
    guard let action = args.first, ["install", "remove", "status"].contains(action) else {
        warn("usage: tally codex-session-status <install|remove|status> [--home PATH] [--root PATH] [--executable PATH]")
        exit(2)
    }
    var index = 1
    while index < args.count {
        guard index + 1 < args.count else { warn("missing option value"); exit(2) }
        let value = args[index + 1]
        switch args[index] {
        case "--home": homes.append(value)
        case "--root": root = URL(fileURLWithPath: value)
        case "--executable": executable = value
        default: warn("unknown option: \(args[index])"); exit(2)
        }
        index += 2
    }
    if homes.isEmpty {
        homes = loadSnapshot().0?.accounts.filter { $0.provider == "codex" }.compactMap(\.launchHome) ?? []
    }
    do {
        switch action {
        case "install":
            guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
                warn("the Tally executable must be an absolute, executable path"); exit(2)
            }
            let command = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "' codex-session-hook"
            try CodexSessionHooks.install(homes: homes, root: root, command: command)
            print("Installed. Review Codex /hooks before expecting session status. Installation does not grant native trust.")
        case "remove":
            try CodexSessionHooks.remove(root: root)
            print("Removed Tally's Codex session status registrations.")
        default:
            print(try CodexSessionHooks.installed(homes: homes, root: root) ? "installed; native trust is verified in Codex /hooks" : "not installed or incomplete")
        }
    } catch { warn(error.localizedDescription); exit(1) }
}
