import Foundation

// Assertion harness for the Codex identity reader (Tally/Providers/Codex/CodexIdentity.swift): the
// email a Codex home is signed in as, decoded out of the `id_token` its own `auth.json` holds.
//
// Every token here is built by this file. Nothing reads this machine's real `~/.codex*/auth.json`,
// and no real credential is in the repo: the shapes are what a schema probe of the two live homes
// reported on 2026-08-04 (top level `auth_mode` / `OPENAI_API_KEY` / `tokens` / `last_refresh`,
// `tokens` holding `id_token` / `access_token` / `refresh_token` / `account_id`, and a payload
// carrying `email` among its claims), rebuilt from scratch with a made-up address.

var passed = 0, failed = 0
func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

/// base64url exactly as a JWT writer produces it: standard base64, `+/` swapped for `-_`, padding
/// stripped. The reader has to undo both halves.
func base64URL(_ text: String) -> String {
    Data(text.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func jwt(payload: String) -> String {
    "\(base64URL(#"{"alg":"RS256","typ":"JWT"}"#)).\(base64URL(payload)).c2lnbmF0dXJl"
}

func authJSON(idToken: String?) -> Data {
    // The siblings are here to be ignored: a reader that reached for the wrong key would find a
    // token-shaped string in every one of them.
    var tokens: [String: Any] = ["access_token": "not-read", "refresh_token": "not-read",
                                 "account_id": "acct_123"]
    if let idToken { tokens["id_token"] = idToken }
    let root: [String: Any] = ["auth_mode": "chatgpt", "last_refresh": "2026-08-04T00:00:00Z",
                               "tokens": tokens]
    return try! JSONSerialization.data(withJSONObject: root)
}

// MARK: - The whole chain, on the shape the live homes actually carry

let liveShape = authJSON(idToken: jwt(payload:
    #"{"email":"alex@example.com","email_verified":true,"name":"Alex","sub":"user_1","#
        + #""https://api.openai.com/auth":{"chatgpt_plan_type":"pro"}}"#))
check("the email claim comes out of a live-shaped auth.json",
      CodexIdentity.email(inAuthJSON: liveShape) == "alex@example.com")

// MARK: - base64url is not base64

// The alphabet swap: this payload's standard base64 contains BOTH `+` and `/`, so a reader that
// skipped the swap would decode nothing at all. Asserted on the fixture first, because a fixture
// that happened not to contain them would let the check pass while testing nothing.
let alphabetPayload = #"{"email":"alex@example.com","name":"~~~ÿÿ"}"#
let alphabetSegment = base64URL(alphabetPayload)
check("the alphabet fixture really exercises both swapped characters",
      alphabetSegment.contains("-") && alphabetSegment.contains("_"))
check("a token using the url alphabet still decodes",
      CodexIdentity.emailClaim(inIDToken: jwt(payload: alphabetPayload)) == "alex@example.com")

// The stripped padding: both real tokens on this machine needed a pad character, so an
// implementation that did not put it back would never find an address at all.
for (name, filler) in [("one pad character", "abc"), ("two pad characters", "ab")] {
    let payload = #"{"email":"alex@example.com","name":"\#(filler)"}"#
    let segment = base64URL(payload)
    check("the \(name) fixture is really unpadded", segment.count % 4 != 0)
    check("a token missing \(name) still decodes",
          CodexIdentity.emailClaim(inIDToken: jwt(payload: payload)) == "alex@example.com")
}

// MARK: - Everything unreadable is nil, and nothing here is an error the user sees

// An API-key login: `auth.json` exists (so the account is discovered) and carries no tokens at all.
let apiKeyMode = try! JSONSerialization.data(withJSONObject: [
    "auth_mode": "apikey", "OPENAI_API_KEY": "not-read", "last_refresh": "2026-08-04T00:00:00Z",
] as [String: Any])
check("an API-key login has no email to show",
      CodexIdentity.email(inAuthJSON: apiKeyMode) == nil)
check("tokens without an id_token read as no email",
      CodexIdentity.email(inAuthJSON: authJSON(idToken: nil)) == nil)
check("a file that is not JSON reads as no email",
      CodexIdentity.email(inAuthJSON: Data("not json at all".utf8)) == nil)
check("an empty file reads as no email", CodexIdentity.email(inAuthJSON: Data()) == nil)
check("a two-segment token is not a JWT",
      CodexIdentity.emailClaim(inIDToken: "\(base64URL("{}")).\(base64URL(#"{"email":"a@b.c"}"#))")
          == nil)
check("a payload that is not JSON reads as no email",
      CodexIdentity.emailClaim(inIDToken: "aGVhZGVy.bm90LWpzb24.c2ln") == nil)
check("a payload that is not even base64 reads as no email",
      CodexIdentity.emailClaim(inIDToken: "aGVhZGVy.!!!not-base64!!!.c2ln") == nil)
check("a JWT with no email claim reads as no email",
      CodexIdentity.emailClaim(inIDToken: jwt(payload: #"{"sub":"user_1","name":"Alex"}"#)) == nil)
// An empty address is not an identity: rendering it would put a blank line where a name should be.
check("an empty email claim reads as no email",
      CodexIdentity.emailClaim(inIDToken: jwt(payload: #"{"email":""}"#)) == nil)
check("a non-string email claim reads as no email",
      CodexIdentity.emailClaim(inIDToken: jwt(payload: #"{"email":42}"#)) == nil)
check("an empty token reads as no email", CodexIdentity.emailClaim(inIDToken: "") == nil)

// MARK: - Reading it off a home on disk

let home = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("tally-codex-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
check("a home with no auth.json has no email", CodexIdentity.email(codexHome: home.path) == nil)
try! liveShape.write(to: home.appendingPathComponent("auth.json"))
check("a home with a login names its account",
      CodexIdentity.email(codexHome: home.path) == "alex@example.com")
check("a home that does not exist has no email",
      CodexIdentity.email(codexHome: home.path + "-missing") == nil)
try? FileManager.default.removeItem(at: home)

print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
