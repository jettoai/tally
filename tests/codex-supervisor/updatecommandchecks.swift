import Foundation

// B-1736 round 2: the pure halves of `tally codex-update` (CodexUpdateDecision.swift). `check` and
// `start` come from main.swift.
func runCodexUpdateCommandChecks() {
    func cache(_ latest: String, dismissed: String? = nil) -> Data {
        Data("{\"latest_version\":\"\(latest)\",\"dismissed_version\":\(dismissed.map { "\"\($0)\"" } ?? "null")}".utf8)
    }
    let best = codexBestCandidate([("/a", cache("0.162.0"), false), ("/b", cache("0.163.0"), false),
                                   ("/c", cache("0.164.0", dismissed: "0.164.0"), false), ("/d", cache("0.165.0"), true)])
    check("UC1 the newest offered version wins; dismissed and disabled homes are skipped",
          best?.home == "/b" && best?.version == "0.163.0")
    check("UC1 no home offering anything is no candidate", codexBestCandidate([("/a", nil, false)]) == nil)

    check("UC2 checked 59 minutes ago is not due", !codexUpdateCheckDue(lastCheckedAt: start.addingTimeInterval(-59 * 60), now: start))
    check("UC2 checked 61 minutes ago is due", codexUpdateCheckDue(lastCheckedAt: start.addingTimeInterval(-61 * 60), now: start))
    check("UC2 never checked is due", codexUpdateCheckDue(lastCheckedAt: nil, now: start))

    for trigger in ["schedule", "skip", "manual"] {
        let line = codexUpdateLogLine(at: start, trigger: trigger, codex: "/opt/x/bin/codex", from: "0.161.0",
                                      to: "0.162.1", result: "updated", seconds: 42)
        let fields = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        check("UC3 a \(trigger) log line carries every field, one line, no em dash",
              fields?["trigger"] as? String == trigger && fields?["from"] as? String == "0.161.0"
                  && fields?["to"] as? String == "0.162.1" && fields?["result"] as? String == "updated"
                  && fields?["seconds"] as? Int == 42 && fields?["codex"] as? String == "/opt/x/bin/codex"
                  && fields?["at"] as? String != nil && line.hasSuffix("}\n") && !line.contains("\u{2014}"))
    }
}
