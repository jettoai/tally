import Foundation

enum HarnessNativeTrust {
    static func summarize(_ data: Data, home: String, cwd: String, manifest: HarnessManifest) throws -> [String: Any] {
        try summarize(data, home: home, cwd: cwd, registrations: manifest.registrations)
    }

    static func summarize(_ data: Data, home: String, cwd: String,
                          registrations supplied: [HarnessRegistration]) throws -> [String: Any] {
        let response = try HarnessIO.object(data)
        guard response["error"] == nil, let result = response["result"] as? [String: Any],
              let rows = result["data"] as? [[String: Any]],
              let row = rows.first(where: { ($0["cwd"] as? String).map(HarnessIO.canonical) == HarnessIO.canonical(cwd) }),
              let hooks = row["hooks"] as? [[String: Any]] else { throw HarnessError("Native hook inspection is unavailable.") }
        let registrations = supplied.filter { $0.provider == "codex" }
        guard !registrations.isEmpty else { throw HarnessError("No native Codex registrations were recorded.") }
        var trusted = 0, enabled = 0, found = 0
        for registration in registrations {
            let matches = hooks.filter {
                $0["command"] as? String == registration.command
                    && ($0["sourcePath"] as? String).map(HarnessIO.canonical) == registration.path
                    && ($0["eventName"] as? String)?.lowercased() == registration.event.lowercased()
            }
            guard matches.count == 1 else { continue }
            found += 1
            if matches[0]["trustStatus"] as? String == "trusted" { trusted += 1 }
            if matches[0]["enabled"] as? Bool == true { enabled += 1 }
        }
        return ["home": home, "state": found == registrations.count && trusted == found && enabled == found
                    ? "trusted-enabled" : "needs-review",
                "expected": registrations.count, "found": found, "trusted": trusted, "enabled": enabled,
                "meaning": "Native configuration observation; not a behavioral test."]
    }
}
