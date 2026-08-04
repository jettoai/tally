import Foundation

// Assertion harness for the Codex identity reader (Tally/Providers/Codex/CodexIdentity.swift): the
// email an `account/read` answer names, taken from the official CLI's app-server.
//
// No credential is involved on either side. The reader never opens `auth.json` (that is the whole
// point of asking the CLI), and every fixture here is written by this file: the shape is what a
// live app-server on codex-cli 0.146.0 answered on 2026-08-04 - `result.account` carrying `email`,
// `planType` and `type`, beside a top-level `requiresOpenaiAuth` - rebuilt with a made-up address.

var passed = 0, failed = 0
func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

func line(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

func accountRead(_ account: Any?) -> Data {
    var result: [String: Any] = ["requiresOpenaiAuth": true]
    if let account { result["account"] = account }
    return line(["jsonrpc": "2.0", "id": 3, "result": result])
}

// MARK: - The whole chain, on the shape a live app-server actually answers with

let liveShape = accountRead(["email": "alex@example.com", "planType": "pro", "type": "chatgpt"])
check("the address comes out of a live-shaped account/read answer",
      CodexIdentity.email(inAccountRead: liveShape) == "alex@example.com")

// The answer is an ordinary JSON-RPC line, so it arrives with the envelope around it. Asserted on
// the fixture itself first: one that had been stripped down to the account object would let the
// check pass while testing nothing.
check("the fixture really is a whole response line, envelope and all",
      String(data: liveShape, encoding: .utf8)!.contains("\"result\"")
          && String(data: liveShape, encoding: .utf8)!.contains("\"jsonrpc\""))

// Fields nobody here knows about are not a reason to answer nothing: the vendor adds them.
check("an answer carrying unknown fields still names the account",
      CodexIdentity.email(inAccountRead: accountRead([
          "email": "alex@example.com", "planType": "pro", "type": "chatgpt",
          "somethingNew": ["nested": true], "workspaceId": "ws_1"])) == "alex@example.com")

// MARK: - Everything unreadable is nil, and nothing here is an error the user sees

// A codex that does not know the method answers with an error rather than a result.
check("an error answer names no account",
      CodexIdentity.email(inAccountRead: line([
          "jsonrpc": "2.0", "id": 3,
          "error": ["code": -32601, "message": "method not found"]])) == nil)
check("a result with no account object names no account",
      CodexIdentity.email(inAccountRead: accountRead(nil)) == nil)
check("an account with no email names no account",
      CodexIdentity.email(inAccountRead: accountRead(["planType": "pro", "type": "chatgpt"])) == nil)
// An empty address is not an identity: rendering it would put a blank line where a name should be.
check("an empty address names no account",
      CodexIdentity.email(inAccountRead: accountRead(["email": ""])) == nil)
check("a non-string address names no account",
      CodexIdentity.email(inAccountRead: accountRead(["email": 42])) == nil)
check("a null address names no account",
      CodexIdentity.email(inAccountRead: accountRead(["email": NSNull()])) == nil)
check("an account that is not an object names no account",
      CodexIdentity.email(inAccountRead: accountRead("alex@example.com")) == nil)
check("a line that is not JSON names no account",
      CodexIdentity.email(inAccountRead: Data("not json at all".utf8)) == nil)
check("an empty line names no account", CodexIdentity.email(inAccountRead: Data()) == nil)
check("a JSON array names no account",
      CodexIdentity.email(inAccountRead: try! JSONSerialization.data(withJSONObject: [1, 2, 3]))
          == nil)

// MARK: - The credential file is not in this picture at all

// The reader is asked with the shape of the OTHER file - the login record it used to open. Nothing
// in here is where it looks now, so the address inside it stays unread. This is the promise
// `CodexAccounts` and the README make, asserted rather than described.
let credentialShape = line([
    "auth_mode": "chatgpt",
    "tokens": ["id_token": "header.payload.signature", "access_token": "not-read",
               "refresh_token": "not-read", "account_id": "acct_123"],
])
check("the login record is not a place this reader looks",
      CodexIdentity.email(inAccountRead: credentialShape) == nil)

// …and the same promise one level up, where a fixture cannot reach: no file in the Codex provider
// OPENS that record. The app said in three places that it never does while one of them read the
// whole thing (codex review, 2026-08-04), so the claim is a check now rather than a comment. Every
// way Foundation has of reading a file's bytes needs one of these spellings.
func source(_ name: String) -> String {
    (try? String(contentsOfFile: "Tally/Providers/Codex/\(name)", encoding: .utf8)) ?? ""
}
let codexFiles = ["CodexIdentity.swift", "CodexProvider.swift", "CodexAppServerClient.swift",
                  "CodexAccounts.swift"]
let codexSources = codexFiles.map(source)
check("every file in the Codex provider was found to read",
      codexSources.allSatisfy { !$0.isEmpty })
for (name, text) in zip(codexFiles, codexSources) {
    for spelling in ["contentsOf:", "contentsOfFile:", "FileHandle", "contents(atPath"] {
        check("\(name) does not open a file with \(spelling)", !text.contains(spelling))
    }
}
// The only mention of the record left is the existence check that makes a home an account, and the
// promises around it. Nothing decodes a token: `id_token` appears nowhere in the provider at all.
check("the provider names no token field anywhere",
      codexSources.allSatisfy { !$0.contains("id_token") && !$0.contains("access_token") })
check("discovery still checks that the record EXISTS, which is what makes a home an account",
      source("CodexAccounts.swift").contains("fileExists(atPath: authPath)"))
// Which leaves exactly one place identity can come from: the CLI's own app-server.
check("identity is asked of the app-server instead",
      source("CodexAppServerClient.swift").contains(#""method":"account/read""#)
          && source("CodexAppServerClient.swift").contains("CodexIdentity.email(inAccountRead:)"))

print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
