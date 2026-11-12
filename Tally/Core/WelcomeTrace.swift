import Foundation

/// `-TallyWelcomeTrace <file>` (Dev builds only): one line per state change of the welcome flow, so
/// a run on a Mac nobody can click (a clean virtual machine reached over ssh) can be read back.
/// Stage names only: no failure sentences, folder names or script output, and nothing that is, or
/// could carry, a credential.
enum WelcomeTrace {
    static let key = "TallyWelcomeTrace"
    private static let queue = DispatchQueue(label: "tally.welcome-trace")
    private static let path: String? = {
        guard BuildVariant.isDev, let path = UserDefaults.standard.string(forKey: key), !path.isEmpty else { return nil }
        return path
    }()

    static func note(_ line: String) {
        guard let path else { return }
        let text = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        queue.async {
            if !FileManager.default.fileExists(atPath: path) { _ = FileManager.default.createFile(atPath: path, contents: nil) }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        }
    }
}
