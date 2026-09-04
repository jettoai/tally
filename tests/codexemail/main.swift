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

// MARK: - Why a read came home without numbers (CodexReadFailure)

// THREE FAILURES USED TO WEAR ONE COAT. "Codex CLI read failed" was the whole of what a card said
// whether the vendor had answered with an error of its own (OpenAI's endpoint answered 404 through
// the app-server on 2026-09-03), an answer had arrived in a shape nobody could read, or nothing had
// arrived at all - three different things to go and check, under one sentence that named none of
// them. The classification is asked of the line that came back, so it can be stated here.

func rpcError(_ error: Any) -> Data {
    line(["jsonrpc": "2.0", "id": 2, "error": error])
}
func resultLine(_ result: Any) -> Data {
    line(["jsonrpc": "2.0", "id": 2, "result": result])
}

check("an error answer is the server's own words",
      CodexReadFailure.of(limitsLine: rpcError(["code": -32000, "message": "404 Not Found"]),
                          processDied: false, timeout: 20) == .serverSaid("404 Not Found"))
// The fixture is a whole response line rather than the error object alone: one stripped down to
// the payload would let the check pass while testing nothing (the same guard the identity fixtures
// above carry).
check("…out of a whole response line, envelope and all",
      String(data: rpcError(["message": "404 Not Found"]), encoding: .utf8)!.contains("\"jsonrpc\""))
// A message written for a log arrives with a newline on it as often as not, and the callout puts
// it beside a sentence.
check("…trimmed of the whitespace a logged message arrives with",
      CodexReadFailure.of(limitsLine: rpcError(["message": "  upstream 404\n"]),
                          processDied: false, timeout: 20) == .serverSaid("upstream 404"))
// A logged message breaks its own lines, and the callout spends a row on every one of them: a
// stack trace under the cap would still be forty rows tall on a panel with no ceiling. So the
// breaks come home as spaces, and a run of them as one.
let brokenMessage = "upstream 404\nGET /usage\r\n\tretry: 3   soon"
check("…and folded onto one line, however the log broke it",
      CodexReadFailure.of(limitsLine: rpcError(["message": brokenMessage]),
                          processDied: false, timeout: 20)
          == .serverSaid("upstream 404 GET /usage retry: 3 soon"))
// One that runs on is cut, because the callout is anchored to a panel and a stack trace would push
// it off the screen. What a reader needs is at the front: which system is complaining.
let longMessage = String(repeating: "x", count: CodexReadFailure.messageLimit + 40)
check("…and capped where the server wrote a paragraph",
      CodexReadFailure.of(limitsLine: rpcError(["message": longMessage]),
                          processDied: false, timeout: 20)
          == .serverSaid(String(repeating: "x", count: CodexReadFailure.messageLimit) + "\u{2026}"))

// ANYTHING ELSE THAT CAME BACK is a shape nobody could read. This is only ever asked once the
// decode the reader needs has already failed, so a result here is by construction one this app
// could not use.
check("an answer this app cannot read is a shape rather than a quotation",
      CodexReadFailure.of(limitsLine: resultLine(["somethingElse": true]),
                          processDied: false, timeout: 20) == .unreadableAnswer)
check("…as is an error object with nothing to say, which is not the server's words",
      CodexReadFailure.of(limitsLine: rpcError(["code": -32000]),
                          processDied: false, timeout: 20) == .unreadableAnswer
          && CodexReadFailure.of(limitsLine: rpcError(["message": "   "]),
                                 processDied: false, timeout: 20) == .unreadableAnswer)
// Whitespace is nothing to say whichever keys wrote it: a message of blank lines and tabs folds
// down to an empty quotation, which is not the server's words either.
check("…including one written entirely in line breaks and tabs",
      CodexReadFailure.of(limitsLine: rpcError(["message": "\n\r\n \t\n  "]),
                          processDied: false, timeout: 20) == .unreadableAnswer)
check("…and a line that is not JSON at all",
      CodexReadFailure.of(limitsLine: Data("not json at all".utf8),
                          processDied: false, timeout: 20) == .unreadableAnswer)
// A codex that answers "404" and then quits has still told the reader more than its exit did, so
// the words survive the process.
check("…while a line that came back is read even if the process then exited",
      CodexReadFailure.of(limitsLine: rpcError(["message": "404 Not Found"]),
                          processDied: true, timeout: 20) == .serverSaid("404 Not Found"))

// NOTHING CAME BACK, and the two reasons for that are not one: an app-server still running has
// gone quiet, and one that died is a broken CLI the caller already has its own word for.
check("no answer from a running app-server is a silence, and it says how long",
      CodexReadFailure.of(limitsLine: nil, processDied: false, timeout: 20) == .silent(seconds: 20)
          && CodexReadFailure.of(limitsLine: nil, processDied: false, timeout: 7.6)
              == .silent(seconds: 8))
check("…and a process that died is not this question at all",
      CodexReadFailure.of(limitsLine: nil, processDied: true, timeout: 20) == nil)

// …and the same promise one level up, where a fixture cannot reach: no file in the Codex provider
// OPENS that record. The app said in three places that it never does while one of them read the
// whole thing (codex review, 2026-08-04), so the claim is a check now rather than a comment. Every
// way Foundation has of reading a file's bytes needs one of these spellings.
func source(_ name: String) -> String {
    (try? String(contentsOfFile: "Tally/Providers/Codex/\(name)", encoding: .utf8)) ?? ""
}
let codexFiles = ["CodexIdentity.swift", "CodexProvider.swift", "CodexAppServerClient.swift",
                  "CodexAccounts.swift", "CodexReadFailure.swift"]
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

// AND THE ROW'S OWN SENTENCE IS THE ONE THE APP WROTE, whatever the vendor said: the reason rides
// in the hover callout, so no message this app did not write can set a card's width. Only readable
// as source, the two being a view and a provider away from any harness.
let cardSource = (try? String(contentsOfFile: "Tally/Views/AccountCardView.swift",
                              encoding: .utf8)) ?? ""
check("the card was found to read", !cardSource.isEmpty)
check("the card keeps its own short line and hovers the reason",
      source("CodexProvider.swift").contains(#"failed(L("Codex CLI read failed"), detail:"#)
          && cardSource.contains(#".tallyTooltip(usage.errorDetail == nil ? "" : (usage.error ?? ""),"#))
// …and hovers it ONLY THEN: with no reason to add, the callout would repeat the card's own line,
// middle-truncated to one. The header's "Outdated" mark is the opposite case, a glyph plus one
// word with no room to say anything itself, so it is asserted apart and read as the slice AFTER
// its label - one spelling used to stand for both, and either could go missing with it matching.
check("the header's Outdated mark still hands the reason to its own callout",
      cardSource.range(of: #"Label(L("Outdated")"#).map {
          String(cardSource[$0.upperBound...].prefix(300))
              .contains(#".tallyTooltip(usage.error ?? "", detail: usage.errorDetail)"#)
      } == true)

print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
