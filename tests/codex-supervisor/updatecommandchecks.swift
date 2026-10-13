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

    // UC4: the 180 s pre-launch update timing out must not hold the 900 s background one off the
    // same version for six hours; every other failure still backs both off.
    let failedAt = start.addingTimeInterval(-60)
    func backedOff(_ attempt: CodexUpdateAttempt?, timeout: TimeInterval) -> Bool {
        codexUpdateBackedOff(attempt: attempt, latest: "0.162.1", timeout: timeout, now: start)
    }
    let shortTimeout = CodexUpdateAttempt(version: "0.162.1", failedAt: failedAt, timedOutAfter: 180)
    check("UC4 a 180 s timeout does not back off a 900 s update", !backedOff(shortTimeout, timeout: 900))
    check("UC4 a 180 s timeout still backs off the next 180 s update", backedOff(shortTimeout, timeout: 180))
    let longTimeout = CodexUpdateAttempt(version: "0.162.1", failedAt: failedAt, timedOutAfter: 900)
    check("UC4 a 900 s timeout backs off a 180 s update", backedOff(longTimeout, timeout: 180))
    let other = CodexUpdateAttempt(version: "0.162.1", failedAt: failedAt, timedOutAfter: nil)
    check("UC4 a failure that is not a timeout backs off both",
          backedOff(other, timeout: 900) && backedOff(other, timeout: 180))
    let legacy = decodeCodexUpdateAttempt(Data(#"{"version":"0.162.1","failedAt":"2027-01-15T07:59:00Z"}"#.utf8))
    check("UC4 an attempt file without the timeout field still reads, and backs off both",
          legacy != nil && legacy?.timedOutAfter == nil
              && backedOff(legacy, timeout: 900) && backedOff(legacy, timeout: 180))
    let roundTrip = encodeCodexUpdateAttempt(shortTimeout).flatMap(decodeCodexUpdateAttempt)
    check("UC4 the timeout limit survives the attempt file", roundTrip?.timedOutAfter == 180)
}
