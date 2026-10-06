import Foundation

// Assertion harness for the `tally redeem` request channel (TallyCLI/RedeemRequest.swift, which is
// Foundation-only on purpose). Nothing here spends a credit: it exercises the file format, the
// claim/withdraw race and the exit-code table against a temporary directory.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let now = Date(timeIntervalSince1970: 1_800_000_000)
let request = RedeemRequest(id: "abc", accountID: "codex:1", label: "Codex 2", createdAt: now)

// T1/T2: round trip, and a truncated body is never acted on
let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: dir) }
try! writeRedeemRequest(request, dir: dir)
let written = try! Data(contentsOf: redeemRequestURL("abc", dir: dir))
expect(parseRedeemRequest(written) == request, "request round-trips through the file")
expect(parseRedeemRequest(written.prefix(written.count / 2)) == nil, "truncated body is nil")

// T3: pickup window, both clock directions
expect(!redeemRequestExpired(request, now: now.addingTimeInterval(5)), "5s old is fresh")
expect(redeemRequestExpired(request, now: now.addingTimeInterval(11)), "11s old is expired")
expect(redeemRequestExpired(request, now: now.addingTimeInterval(-11)), "clock jumped back 11s is expired")

// T4: the app's claim wins once, and the CLI cannot withdraw after it
expect(claimRedeemRequest("abc", dir: dir), "first claim succeeds")
expect(!claimRedeemRequest("abc", dir: dir), "second claim fails")
expect(!withdrawRedeemRequest("abc", dir: dir), "withdraw after claim fails")
expect(FileManager.default.fileExists(atPath: redeemClaimedURL("abc", dir: dir).path),
       "claim leaves the .claimed file")

// T5: the reverse order: once the CLI said "not picked up", the app can never claim it
try! writeRedeemRequest(RedeemRequest(id: "def", accountID: "x", label: "y", createdAt: now), dir: dir)
expect(withdrawRedeemRequest("def", dir: dir), "withdraw before claim succeeds")
expect(!claimRedeemRequest("def", dir: dir), "claim after withdraw fails")

// Result round trip
let result = RedeemResult(id: "abc", code: "failed", detail: "boom")
try! writeRedeemResult(result, dir: dir)
expect(parseRedeemResult(try! Data(contentsOf: redeemResultURL("abc", dir: dir))) == result,
       "result round-trips through the file")

// The app's directory sweep: garbage and expired requests dropped unclaimed, a fresh one claimed
let sweep = dir.appendingPathComponent("sweep")
try! writeRedeemRequest(RedeemRequest(id: "fresh", accountID: "a", label: "A", createdAt: now), dir: sweep)
try! writeRedeemRequest(RedeemRequest(id: "old", accountID: "a", label: "A",
                                      createdAt: now.addingTimeInterval(-60)), dir: sweep)
try! Data("not json".utf8).write(to: redeemRequestURL("junk", dir: sweep))
let got = claimPendingRedeemRequests(dir: sweep, now: now.addingTimeInterval(1))
expect(got.map(\.id) == ["fresh"], "only the fresh request is claimed")
expect(FileManager.default.fileExists(atPath: redeemClaimedURL("fresh", dir: sweep).path), "fresh is now .claimed")
expect(!FileManager.default.fileExists(atPath: redeemRequestURL("old", dir: sweep).path), "expired request removed")
expect(!FileManager.default.fileExists(atPath: redeemRequestURL("junk", dir: sweep).path), "unreadable request removed")
expect(claimPendingRedeemRequests(dir: sweep, now: now).isEmpty, "a second sweep claims nothing")

answerRedeemRequest(RedeemResult(id: "fresh", code: "busy", detail: nil), dir: sweep)
expect(FileManager.default.fileExists(atPath: redeemResultURL("fresh", dir: sweep).path), "answer writes the result")
expect(!FileManager.default.fileExists(atPath: redeemClaimedURL("fresh", dir: sweep).path), "answer releases the claim")
try! Data().write(to: redeemClaimedURL("crashed", dir: sweep))
sweepRedeemLeftovers(dir: sweep)
expect((try! FileManager.default.contentsOfDirectory(atPath: sweep.path)).isEmpty,
       "launch sweep clears leftover claims and results")

// T6: every code; only redeemed exits 0
for code in RedeemResultCode.allCases {
    let answer = redeemAnswer(RedeemResult(id: "i", code: code.rawValue, detail: nil), label: "Codex 2")
    expect(answer.code == (code == .redeemed ? 0 : 1), "\(code.rawValue) exits \(answer.code)")
    expect(!answer.message.isEmpty, "\(code.rawValue) has a sentence")
    // T8: the repo's em dash rule
    expect(!answer.message.contains("\u{2014}"), "\(code.rawValue) sentence has no em dash")
}
expect(redeemAnswer(RedeemResult(id: "i", code: "failed", detail: "server said no"), label: "L")
        .message.contains("server said no"), "failed carries the server's detail")
expect(redeemAnswer(RedeemResult(id: "i", code: "failed", detail: nil), label: "L")
        .message.contains("no answer"), "failed without detail says no answer")

// T7: an unknown code from a newer app is a failure, never a success
let unknown = redeemAnswer(RedeemResult(id: "i", code: "weird", detail: nil), label: "L")
expect(unknown.code == 1 && unknown.message.hasPrefix("Redeem failed"), "unknown code reads as failed")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
