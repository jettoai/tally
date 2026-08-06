import Foundation

/// Model choices for the launch-default pickers, from the most authoritative source each
/// provider offers. Neither list is a hard gate - the UI always keeps a Custom escape hatch,
/// because model ids evolve server-side faster than any list.
enum ModelCatalog {
    /// The documented Claude aliases, from the list both targets compile (LaunchAxisNames.swift):
    /// `tally model` offers the same names in its own picker, and two copies would eventually
    /// suggest different models on the same machine.
    static let claudeAliases = claudeModelAliases

    /// Codex maintains its own model list on disk (`models_cache.json`, fetched and refreshed by
    /// the CLI itself with etag semantics) - read the slugs from the first home that has one.
    static let codexModels: [String] = {
        struct Cache: Decodable {
            struct Entry: Decodable { var slug: String? }
            var models: [Entry]?
        }
        for account in CodexAccounts.discover() {
            guard let home = account.launchHome else { continue }
            let url = URL(fileURLWithPath: home).appendingPathComponent("models_cache.json")
            guard let data = try? Data(contentsOf: url),
                  let cache = try? JSONDecoder().decode(Cache.self, from: data) else { continue }
            let slugs = (cache.models ?? []).compactMap(\.slug)
            if !slugs.isEmpty { return slugs }
        }
        return []
    }()
}
