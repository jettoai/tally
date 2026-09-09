import Foundation

enum CodexHarnessTrust {
    /// Read native trust without starting a model thread or changing a trust decision.
    static func read(home: String, cwd: String, manifest: HarnessManifest) -> [String: Any] {
        read(home: home, cwd: cwd, registrations: manifest.registrations)
    }

    static func read(home: String, cwd: String, registrations: [HarnessRegistration]) -> [String: Any] {
        guard let binary = CLIRunner.resolve("codex"), let session = RPCSession(binary: binary, codexHome: home) else {
            return ["home": home, "state": "unavailable"]
        }
        defer { session.close() }
        let deadline = Date().addingTimeInterval(5)
        session.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"tally_harness","version":"1"},"capabilities":{"experimentalApi":true}}}"#)
        guard session.awaitLine(id: 1, until: deadline) != nil else { return ["home": home, "state": "unavailable"] }
        session.send(#"{"jsonrpc":"2.0","method":"initialized","params":{}}"#)
        do {
            let request: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "hooks/list", "params": ["cwds": [cwd]]]
            session.send(String(decoding: try HarnessIO.json(request), as: UTF8.self))
            guard let data = session.awaitLine(id: 2, until: deadline) else { return ["home": home, "state": "unavailable"] }
            return try HarnessNativeTrust.summarize(data, home: home, cwd: cwd, registrations: registrations)
        } catch { return ["home": home, "state": "unavailable"] }
    }
}
