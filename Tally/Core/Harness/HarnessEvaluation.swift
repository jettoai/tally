import CoreFoundation
import Foundation

enum HarnessEvaluation {
    static func record(_ data: Data, root: String) throws -> [String: Any] {
        let value = try HarnessIO.object(data)
        let required: Set<String> = ["scope", "provider", "modelRequested", "modelActual", "effort", "caseHash",
            "oracleHash", "sourceHash", "variant", "quality", "durationMs", "costUSD"]
        guard required.isSubset(of: Set(value.keys)), ["user", "project"].contains(value["scope"] as? String ?? ""),
              ["claude", "codex"].contains(value["provider"] as? String ?? "") else {
            throw HarnessError("Evaluation needs its scope, provider, models, effort, case/oracle/source hashes, variant, quality, durationMs, and costUSD.")
        }
        for key in ["modelRequested", "variant"] {
            guard let text = value[key] as? String, !text.isEmpty, text.count <= 200 else { throw HarnessError("Invalid evaluation field: \(key)") }
        }
        for key in ["modelActual", "effort"] {
            guard value[key] is NSNull || (value[key] as? String).map({ !$0.isEmpty && $0.count <= 200 }) == true else {
                throw HarnessError("Use a string or null for \(key).")
            }
        }
        for key in ["caseHash", "oracleHash", "sourceHash"] {
            guard let hash = value[key] as? String, hash.count == 64,
                  hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw HarnessError("Use a SHA-256 fingerprint for \(key).") }
        }
        for key in ["durationMs", "costUSD"] {
            if key == "costUSD" && value[key] is NSNull { continue }
            guard let number = value[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0 else { throw HarnessError("Use a nonnegative number for \(key).") }
        }
        guard let quality = value["quality"] as? [String: Any], !quality.isEmpty else {
            throw HarnessError("Quality must describe the oracle's measured results as a nonempty object.")
        }
        let id = UUID().uuidString.lowercased(), directory = root + "/evaluations"
        return try HarnessIO.locked(directory) {
            var record = value
            record["schema"] = 1; record["recordedAt"] = Date().timeIntervalSince1970
            record["evidence"] = "caller-reported"
            let path = directory + "/" + id + ".json"
            try HarnessIO.replace(path, expected: nil, with: HarnessIO.json(record))
            return ["id": id, "path": path, "evidence": "caller-reported"]
        }
    }
}
