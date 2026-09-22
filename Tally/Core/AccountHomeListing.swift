import Foundation

/// The only two filesystem questions account discovery asks about the user's home directory.
///
/// The home also holds `~/Downloads`, `~/Desktop` and `~/Documents`, which macOS puts behind a
/// privacy prompt, so discovery reads NAMES only (`readdir`, no resource keys, nothing prefetched
/// per entry) and asks about a single entry only after its name has matched (jettoai/tally#1).
/// Injected so a test can record every path that is touched.
struct AccountHomeListing {
    var names: (String) -> [String]
    /// lstat semantics, matching the `.isDirectoryKey` check this replaced: a symlink is not a
    /// config dir here.
    var isDirectory: (String) -> Bool

    static var live: AccountHomeListing { AccountHomeListing(
        names: { path in
            guard let dir = opendir(path) else { return [] }
            defer { closedir(dir) }
            var out: [String] = []
            while let entry = readdir(dir) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                }
                if name != ".", name != ".." { out.append(name) }
            }
            return out
        },
        isDirectory: { path in
            var info = stat()
            return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
        }) }
}

/// Every `<home>/<base>*` directory other than `<home>/<base>` itself, sorted by name.
func accountConfigDirs(base: String, home: URL,
                       listing: AccountHomeListing = .live) -> [URL] {
    listing.names(home.path)
        .filter { $0.hasPrefix(base) && $0 != base }
        .sorted()
        .map { home.appendingPathComponent($0, isDirectory: true) }
        .filter { listing.isDirectory($0.path) }
}

/// The directories the account watcher hands to FSEvents: the provider config dirs themselves,
/// never the home root. FSEvents watches a whole subtree, and the home's subtree includes the
/// protected folders; a new account dir appearing in the home is noticed by a separate
/// non-recursive watch on the home directory itself (`AccountDirWatcher.shallowRoots`).
func accountWatchRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       listing: AccountHomeListing = .live) -> [URL] {
    [".claude", ".codex"].flatMap { base -> [URL] in
        let main = home.appendingPathComponent(base, isDirectory: true)
        return (listing.isDirectory(main.path) ? [main] : [])
            + accountConfigDirs(base: base, home: home, listing: listing)
    }
}
