import Foundation

// Account discovery reads the home directory by NAME only and asks about an entry only after its
// name matched (jettoai/tally#1: a first launch asked for Downloads access). The listing is wrapped
// in a recorder so every path handed to the filesystem is known.

var passed = 0, failed = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

let fm = FileManager.default
let home = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("tally-homelisting-\(UUID().uuidString)", isDirectory: true)
let protected = ["Downloads", "Desktop", "Documents"]
for name in protected + [".claude", ".claude-work", ".codex2", "Projects"] {
    try! fm.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
}
// Not config dirs: a file with a matching name, and a symlink (the replaced `.isDirectoryKey`
// check did not follow links either).
fm.createFile(atPath: home.appendingPathComponent(".claude2").path, contents: Data())
try! fm.createSymbolicLink(at: home.appendingPathComponent(".codex-link"),
                           withDestinationURL: home.appendingPathComponent("Projects"))
for name in protected { chmod(home.appendingPathComponent(name).path, 0o000) }

var touched: [String] = []
let recording = AccountHomeListing(
    names: { touched.append($0); return AccountHomeListing.live.names($0) },
    isDirectory: { touched.append($0); return AccountHomeListing.live.isDirectory($0) })

func touchedProtected() -> [String] {
    touched.filter { path in
        protected.contains { path == home.appendingPathComponent($0).path
            || path.hasPrefix(home.appendingPathComponent($0).path + "/") }
    }
}

let claude = accountConfigDirs(base: ".claude", home: home, listing: recording)
check("finds the custom claude account", claude.map(\.lastPathComponent) == [".claude-work"])
let codex = accountConfigDirs(base: ".codex", home: home, listing: recording)
check("finds the numbered codex account", codex.map(\.lastPathComponent) == [".codex2"])
check("discovery never touches Downloads, Desktop or Documents", touchedProtected().isEmpty)
check("the home is only listed; only matching names are asked about",
      Set(touched) == Set([home.path] + [".claude-work", ".claude2", ".codex2", ".codex-link"]
          .map { home.appendingPathComponent($0).path }))

touched = []
let roots = accountWatchRoots(home: home, listing: recording)
check("watch roots are the config dirs themselves",
      roots.map(\.lastPathComponent) == [".claude", ".claude-work", ".codex2"])
check("the home root is never an FSEvents root", !roots.contains { $0.path == home.path })
check("watch roots never touch the protected folders", touchedProtected().isEmpty)

// The live listing on the real fake home: unreadable siblings do not stop discovery.
check("live listing still finds both accounts beside mode-000 folders",
      accountConfigDirs(base: ".claude", home: home).count == 1
          && accountConfigDirs(base: ".codex", home: home).count == 1)
check("a missing home lists nothing rather than failing",
      accountConfigDirs(base: ".claude", home: home.appendingPathComponent("absent")).isEmpty)

// The providers must go through the name-only listing, not a keyed listing of the home.
for file in ["Tally/Providers/Claude/ClaudeAccounts.swift", "Tally/Providers/Codex/CodexAccounts.swift"] {
    let source = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
    check("\(file) lists the home by name only",
          !source.isEmpty && !source.contains("includingPropertiesForKeys")
              && source.contains("accountConfigDirs("))
}
let watcherUse = (try? String(contentsOfFile: "Tally/Stores/UsageStore.swift", encoding: .utf8)) ?? ""
check("the account watcher streams over accountWatchRoots, the home only as a shallow root",
      watcherUse.contains("roots: accountWatchRoots()")
          && watcherUse.contains("shallowRoots: [FileManager.default.homeDirectoryForCurrentUser]"))

for name in protected { chmod(home.appendingPathComponent(name).path, 0o755) }
try? fm.removeItem(at: home)
print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
