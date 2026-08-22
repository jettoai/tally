import Foundation

// The MCP authorization seeding's whole decision (TallyCLI/MCPAuthMerge.swift): what a config home
// about to run a session takes from its siblings, and - far more of these - what it refuses to take.
//
// THE REFUSALS ARE THE SUBJECT. Adopting a grant a home lacks saves one authorization round; getting
// any of the refusals wrong costs a login, a 200 KB state file, or a token in a place it was never
// granted to. So the login credential riding in the same blob has assertions of its own, checked
// with an encoder this file spells out rather than with the product's own predicate, and every
// fail-open path (unreadable bytes, a missing subtree, an entry that is not an object, an entry
// missing the client it was issued to) is a row here.
//
// The age rules are asserted on BOTH kinds of evidence and on the seam between them: an entry stamp
// where both sides carry one, the document's own age where neither does, and nothing at all where
// the two sides carry different kinds. That last one is the case a sampled set of fixtures misses,
// and it is the one where comparing anyway would decide by Claude Code version rather than by age.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

/// Canonical JSON for a value, spelled here rather than borrowed from the product: these assertions
/// are about whether the product preserved something, and asking the product's own comparison would
/// only ever say that it agrees with itself.
func canonical(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: ["v": value],
                                                 options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return "<unencodable>" }
    return text
}

func bytes(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

func document(_ data: Data) -> [String: Any] {
    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
}

let hour: TimeInterval = 3600
let old = Date(timeIntervalSince1970: 1_800_000_000)
let recent = old.addingTimeInterval(hour)

/// A login credential with something awkward in every corner: a number that must not become a
/// string, a string that must not lose its escapes, a nested array, an empty string, and a
/// non-ASCII scalar. This value is what "the login is untouched" is asserted against.
let login: [String: Any] = [
    "accessToken": "sk-ant-oat01-\u{4e2d}\u{6587}/slash\\backslash\"quote",
    "expiresAt": 1_800_000_123_456,
    "refreshToken": "",
    "scopes": ["user:inference", "user:profile"],
    "subscriptionType": "max",
]

/// A grant entry as Claude Code writes them (field names observed 2026-08-21; the values here are
/// obviously fake).
func grant(_ server: String, token: String = "mcp-token", client: String? = "client-abc",
           expiresAt: Double? = nil) -> [String: Any] {
    var entry: [String: Any] = [
        "accessToken": token,
        "serverName": server,
        "serverUrl": "https://\(server).example/mcp",
        "discoveryState": ["oauthMetadataFound": true],
        "redirectUri": "http://localhost:1455/callback",
    ]
    if let client { entry["clientId"] = client }
    if let expiresAt { entry["expiresAt"] = expiresAt }
    return entry
}

func blob(_ grants: [String: Any], login loginValue: Any? = login) -> Data {
    var object: [String: Any] = ["mcpOAuth": grants]
    if let loginValue { object["claudeAiOauth"] = loginValue }
    return bytes(object)
}

// MARK: - Adoption

do {
    let target = blob(["sentry|a": grant("sentry")])
    let source = blob(["sentry|a": grant("sentry"), "notion|b": grant("notion")])
    // The target's document is the NEWER one here, so the shared key stays with the target and the
    // only thing that can move is the key it does not have: a missing grant is adopted on the
    // strength of being missing, not on the strength of being fresh.
    let seeded = seededCredentialData(target: target, targetWrittenAt: recent,
                                      sources: [(source, old)])
    expect(seeded?.adopted == ["notion|b"], "a grant the target lacks is adopted whatever its age")
    let entries = document(seeded?.data ?? Data())["mcpOAuth"] as? [String: Any] ?? [:]
    expect(entries.keys.sorted() == ["notion|b", "sentry|a"],
           "…and the target keeps everything it already had")
}

do {
    let target = blob(["notion|b": grant("notion", token: "target-token")])
    let source = blob(["notion|b": grant("notion", token: "source-token")])
    expect(seededCredentialData(target: target, targetWrittenAt: recent,
                                sources: [(source, old)]) == nil,
           "a target whose document is newer keeps its own grant, and nothing is written")
}

do {
    let target = blob(["notion|b": grant("notion", token: "target-token")])
    let source = blob(["notion|b": grant("notion", token: "source-token")])
    let seeded = seededCredentialData(target: target, targetWrittenAt: old,
                                      sources: [(source, recent)])
    let entries = document(seeded?.data ?? Data())["mcpOAuth"] as? [String: Any] ?? [:]
    let entry = entries["notion|b"] as? [String: Any] ?? [:]
    expect(seeded?.adopted == ["notion|b"] && entry["accessToken"] as? String == "source-token",
           "a newer sibling document supersedes the grant that is there")
}

do {
    // Sources arrive in whatever order the fleet listed them; the merge puts them in age order
    // itself, so an older sibling later in the list cannot undo a newer one.
    let target = blob([:])
    let newer = blob(["notion|b": grant("notion", token: "newer")])
    let older = blob(["notion|b": grant("notion", token: "older")])
    let seeded = seededCredentialData(target: target, targetWrittenAt: old,
                                      sources: [(newer, recent), (older, old)])
    let entries = document(seeded?.data ?? Data())["mcpOAuth"] as? [String: Any] ?? [:]
    expect((entries["notion|b"] as? [String: Any])?["accessToken"] as? String == "newer",
           "the newest sibling wins however the sources were ordered")
    let reversed = seededCredentialData(target: target, targetWrittenAt: old,
                                        sources: [(older, old), (newer, recent)])
    let reversedEntries = document(reversed?.data ?? Data())["mcpOAuth"] as? [String: Any] ?? [:]
    expect((reversedEntries["notion|b"] as? [String: Any])?["accessToken"] as? String == "newer",
           "…and the same holds with the list the other way round")
}

do {
    // The churn case, and the reason it matters: Claude Code rewrites the whole credentials item
    // every time it refreshes the LOGIN token, so a sibling's document is newer than the target's
    // most of the time while holding the very same grants. Deciding on age alone would rewrite the
    // target's Keychain item on every launch, for nothing.
    let entry = grant("notion")
    let target = blob(["notion|b": entry])
    let source = blob(["notion|b": entry])
    expect(seededCredentialData(target: target, targetWrittenAt: old,
                                sources: [(source, recent)]) == nil,
           "a grant the target already holds, value for value, is not adopted however new its "
               + "document is")
    let differing = blob(["notion|b": grant("notion", token: "rotated")])
    expect(seededCredentialData(target: target, targetWrittenAt: old,
                                sources: [(differing, recent)])?.adopted == ["notion|b"],
           "…while one that really differs still is")
}

// MARK: - Age evidence

do {
    let target = blob(["notion|b": grant("notion", token: "target", expiresAt: 1_900_000_000_000)])
    let source = blob(["notion|b": grant("notion", token: "source", expiresAt: 1_800_000_000_000)])
    expect(seededCredentialData(target: target, targetWrittenAt: old,
                                sources: [(source, recent)]) == nil,
           "an entry stamp outranks the document's age: an older grant in a newer document loses")
}

do {
    let target = blob(["notion|b": grant("notion", token: "target", expiresAt: 1_800_000_000_000)])
    let source = blob(["notion|b": grant("notion", token: "source", expiresAt: 1_900_000_000_000)])
    let seeded = seededCredentialData(target: target, targetWrittenAt: recent,
                                      sources: [(source, old)])
    expect(seeded?.adopted == ["notion|b"],
           "…and the same rule the other way: a newer stamp wins from an older document")
}

do {
    // One side stamped and the other not is two different measurements, so neither is preferred and
    // what is already there stays.
    let target = blob(["notion|b": grant("notion", token: "target")])
    let source = blob(["notion|b": grant("notion", token: "source", expiresAt: 1_900_000_000_000)])
    expect(seededCredentialData(target: target, targetWrittenAt: old,
                                sources: [(source, old)]) == nil,
           "mixed evidence with equal document ages decides nothing and keeps the target's grant")
}

do {
    let target = blob(["notion|b": grant("notion", token: "target")])
    let source = blob(["notion|b": grant("notion", token: "source")])
    expect(seededCredentialData(target: target, targetWrittenAt: nil, sources: [(source, nil)]) == nil,
           "no age evidence at all keeps the target's grant")
}

expect(mcpEntryIssuedAt(["expiresAt": 1_800_000_000_000.0])
        == Date(timeIntervalSince1970: 1_800_000_000),
       "a stamp in milliseconds is read as milliseconds")
expect(mcpEntryIssuedAt(["expiresAt": 1_800_000_000.0])
        == Date(timeIntervalSince1970: 1_800_000_000),
       "…and one in seconds as seconds")
expect(mcpEntryIssuedAt(["serverName": "notion"]) == nil, "an entry with no stamp claims none")
expect(mcpEntryIssuedAt("not an entry") == nil, "and neither does something that is not an entry")

// MARK: - Portability

do {
    let target = blob([:])
    let source = blob([
        "clientless|a": grant("clientless", client: nil),
        "blank|b": grant("blank", client: ""),
        "tokenless|c": ["clientId": "abc", "serverName": "tokenless"],
        "good|d": grant("good"),
    ])
    let seeded = seededCredentialData(target: target, targetWrittenAt: old,
                                      sources: [(source, recent)])
    expect(seeded?.adopted == ["good|d"],
           "an entry with no client, a blank one, or no token at all is not copied")
    let entries = document(seeded?.data ?? Data())["mcpOAuth"] as? [String: Any] ?? [:]
    expect(entries.keys.sorted() == ["good|d"], "…and none of them reaches the written document")
}

do {
    let target = blob([:])
    let source = blob(["string|a": "not an entry", "null|b": NSNull(), "good|c": grant("good")])
    let seeded = seededCredentialData(target: target, targetWrittenAt: old,
                                      sources: [(source, recent)])
    expect(seeded?.adopted == ["good|c"],
           "a subtree holding values that are not entries yields the entries and skips the rest")
}

expect(mcpEntryIsPortable(grant("notion")), "the shape Claude Code writes is portable")
expect(!mcpEntryIsPortable(grant("notion", token: "")), "an empty token is not")

// MARK: - The login credential

do {
    let target = blob(["sentry|a": grant("sentry")])
    let source = blob(["notion|b": grant("notion")])
    let seeded = seededCredentialData(target: target, targetWrittenAt: old,
                                      sources: [(source, recent)])
    let before = document(target)["claudeAiOauth"]!
    let after = document(seeded?.data ?? Data())["claudeAiOauth"] ?? "<missing>"
    expect(canonical(before) == canonical(after),
           "the login credential is byte for byte what it was, every field and every escape")
    expect(canonical(after).contains("1800000123456"),
           "…including a number that must not have become a string")
}

do {
    // A blob with no login in it is not a document Claude Code writes, so it is not one this feature
    // may write either: it refuses rather than inventing the shape.
    let target = blob(["sentry|a": grant("sentry")], login: nil)
    let source = blob(["notion|b": grant("notion")])
    expect(seededCredentialData(target: target, targetWrittenAt: old,
                                sources: [(source, recent)]) == nil,
           "a target blob with no login is refused rather than seeded")
}

expect(!credentialBlobIsIntactApartFromGrants(
        before: document(blob([:])),
        after: document(blob([:], login: ["accessToken": "other"]))),
       "a changed login is caught")
expect(credentialBlobIsIntactApartFromGrants(before: document(blob([:])), after: document(blob([:]))),
       "…and an unchanged one is not a false alarm")

do {
    // The login is not the only thing riding in that blob, and the state-file face of this feature
    // checks EVERYTHING but its own key. So does this one: a key beside the login is the shape a
    // later Claude Code arrives in, and an unverified round trip is where such a key goes missing.
    let plain = document(blob(["sentry|a": grant("sentry")]))
    let extra = document(bytes(["claudeAiOauth": login,
                                "mcpOAuth": ["sentry|a": grant("sentry")],
                                "organizationUuid": "0f9b"]))
    expect(!credentialBlobIsIntactApartFromGrants(before: extra, after: plain),
           "a top-level key that went missing beside the login is caught, not only the login")
    expect(!credentialBlobIsIntactApartFromGrants(before: plain, after: extra),
           "…and so is one that appeared")
    expect(credentialBlobIsIntactApartFromGrants(before: document(blob(["sentry|a": grant("sentry")])),
                                                 after: document(blob(["notion|b": grant("notion")]))),
           "…while the grants themselves are the one key it is allowed to differ in")
    expect(!credentialBlobIsIntactApartFromGrants(before: plain, after: document(blob([:], login: nil))),
           "a blob that lost its login altogether is refused rather than called equal")
}

do {
    // …and the same, through the function that actually writes: a key this repo has never seen must
    // come out of the rewrite as it went in.
    let target = bytes(["claudeAiOauth": login,
                        "mcpOAuth": ["sentry|a": grant("sentry")],
                        "somethingAddedLater": ["nested": [1, 2, 3], "flag": true]])
    let seeded = seededCredentialData(target: target, targetWrittenAt: old,
                                      sources: [(blob(["notion|b": grant("notion")]), recent)])
    let after = document(seeded?.data ?? Data())["somethingAddedLater"] ?? "<missing>"
    expect(canonical(after) == canonical(document(target)["somethingAddedLater"]!),
           "a key beside the login that a later Claude Code added survives the rewrite too")
}

// MARK: - Fail-open

do {
    let source = blob(["notion|b": grant("notion")])
    expect(seededCredentialData(target: Data("{not json".utf8), targetWrittenAt: old,
                                sources: [(source, recent)]) == nil,
           "a target whose bytes are not a document is left alone")
    expect(seededCredentialData(target: Data(), targetWrittenAt: old,
                                sources: [(source, recent)]) == nil,
           "…and so is one whose item held nothing at all")
}

do {
    let target = blob([:])
    let good = blob(["notion|b": grant("notion")])
    let seeded = seededCredentialData(target: target, targetWrittenAt: old,
                                      sources: [(Data("{broken".utf8), recent),
                                                (bytes(["claudeAiOauth": login]), recent),
                                                (good, old)])
    expect(seeded?.adopted == ["notion|b"],
           "a sibling with unreadable bytes, and one with no grants, do not stop the others")
}

do {
    let target = blob(["notion|b": grant("notion")])
    expect(seededCredentialData(target: target, targetWrittenAt: old,
                                sources: [(blob(["notion|b": grant("notion")]), old)]) == nil,
           "a merge that adopted nothing writes nothing")
    expect(seededCredentialData(target: target, targetWrittenAt: old, sources: []) == nil,
           "and so does a machine with no siblings")
}

// MARK: - The registration face

/// A state file with a user's own things in it, so "everything else survived" is a claim about more
/// than the key under test.
func state(_ servers: [String: Any]?, extras: [String: Any] = [:]) -> Data {
    var object: [String: Any] = [
        "numStartups": 217,
        "installMethod": "native",
        "tipsHistory": ["agent-flag": 203, "artifact-du": 1],
        "projects": ["/Users/someone/repo": ["allowedTools": [], "hasTrustDialogAccepted": true]],
        "oauthAccount": ["emailAddress": "someone@example.com"],
    ]
    object.merge(extras) { _, new in new }
    if let servers { object["mcpServers"] = servers }
    return bytes(object)
}

let sentryServer: [String: Any] = ["type": "http", "url": "https://mcp.sentry.dev/mcp"]
let tallyServer: [String: Any] = ["type": "stdio", "command": "tally", "args": ["mcp-serve"]]

do {
    let target = state(["tally": tallyServer])
    let source = state(["tally": ["type": "stdio", "command": "SOMETHING ELSE"],
                        "sentry": sentryServer])
    let seeded = seededStateData(target: target, sources: [(source, recent)])
    expect(seeded?.added == ["sentry"], "a registration the target lacks is added")
    let servers = document(seeded?.data ?? Data())["mcpServers"] as? [String: Any] ?? [:]
    expect(canonical(servers["tally"]!) == canonical(tallyServer),
           "…and one the target already has is left exactly as the target had it")
    expect(servers.keys.sorted() == ["sentry", "tally"], "nothing else appears or disappears")
}

do {
    let target = state(["tally": tallyServer, "vercel": ["type": "http", "url": "https://v"]])
    let source = state(["tally": tallyServer])
    expect(seededStateData(target: target, sources: [(source, recent)]) == nil,
           "a server missing from every sibling is never removed, and nothing is written")
}

do {
    let target = state(nil)
    let source = state(["sentry": sentryServer])
    let seeded = seededStateData(target: target, sources: [(source, recent)])
    let servers = document(seeded?.data ?? Data())["mcpServers"] as? [String: Any] ?? [:]
    expect(seeded?.added == ["sentry"] && servers.keys.sorted() == ["sentry"],
           "a home that has never registered anything gets the key created")
}

do {
    let newer = state(["sentry": sentryServer])
    let older = state(["sentry": ["type": "http", "url": "https://old.example"]])
    let seeded = seededStateData(target: state(nil), sources: [(older, old), (newer, recent)])
    let servers = document(seeded?.data ?? Data())["mcpServers"] as? [String: Any] ?? [:]
    expect(canonical(servers["sentry"]!) == canonical(sentryServer),
           "with two siblings offering one name, the newer state file's definition lands")
}

do {
    let source = state(["broken": "not an object", "sentry": sentryServer])
    let seeded = seededStateData(target: state(nil), sources: [(source, recent)])
    expect(seeded?.added == ["sentry"], "a registration that is not an object is skipped")
}

do {
    let target = state(["tally": tallyServer])
    let seeded = seededStateData(target: target, sources: [(state(["sentry": sentryServer]), recent)])
    let before = document(target)
    let after = document(seeded?.data ?? Data())
    var beforeRest = before, afterRest = after
    beforeRest.removeValue(forKey: "mcpServers")
    afterRest.removeValue(forKey: "mcpServers")
    expect(canonical(beforeRest) == canonical(afterRest),
           "every other key of the state file survives the rewrite byte for byte")
    expect(canonical(before["projects"]!) == canonical(after["projects"]!),
           "…the trusted-folder record included, which is the expensive one to lose")
}

do {
    expect(seededStateData(target: Data("{broken".utf8), sources: [(state(["s": sentryServer]),
                                                                   recent)]) == nil,
           "a state file that will not parse is left alone")
    expect(seededStateData(target: state(nil), sources: [(Data("nope".utf8), recent)]) == nil,
           "and a sibling's unreadable state file contributes nothing")
    expect(seededStateData(target: state(nil), sources: []) == nil, "no siblings, no write")
}

expect(!stateDocumentIsIntactApartFromServers(before: document(state(nil)),
                                              after: document(state(nil, extras: ["numStartups": 218]))),
       "a state document that lost or changed anything else is caught")

// MARK: - Which item a home may be addressed by

// The name rules Claude Code uses take a shortcut on the BASENAME: a directory called `.claude` gets
// the default account's bare Keychain service and keeps its state file one level up. That is true of
// exactly one directory on a machine, and it was a harmless guess while nothing wrote through it.
// `export CLAUDE_CONFIG_DIR=/somewhere/else/.claude` is the case: an unguarded seeding aims at the
// DEFAULT account's credentials item and leaves the home it was told about untouched.

do {
    let home = URL(fileURLWithPath: "/Users/someone")
    let byDefault = home.appendingPathComponent(".claude")
    let numbered = home.appendingPathComponent(".claude3")
    let impostor = URL(fileURLWithPath: "/somewhere/else/.claude")

    expect(claudeSeedingKeychainService(forConfigDir: byDefault, defaultHome: byDefault)
            == claudeKeychainService(forConfigDir: byDefault),
           "the real default home is addressed by the bare service, the way Claude Code names it")
    expect(claudeSeedingKeychainService(forConfigDir: impostor, defaultHome: byDefault) == nil,
           "another directory that merely happens to be CALLED .claude is refused, rather than "
               + "aimed at the default account's item")
    expect(claudeSeedingKeychainService(forConfigDir: numbered, defaultHome: byDefault)
            == claudeKeychainService(forConfigDir: numbered),
           "a numbered home keeps the hashed service it has always had")

    expect(claudeSeedingStateFile(forConfigDir: byDefault, defaultHome: byDefault)?.path
            == "/Users/someone/.claude.json",
           "the default home's state file is the one a level up, which is where Claude Code keeps it")
    expect(claudeSeedingStateFile(forConfigDir: impostor, defaultHome: byDefault) == nil,
           "…and no other .claude directory is given that spelling of it to back up and rewrite")
    expect(claudeSeedingStateFile(forConfigDir: numbered, defaultHome: byDefault)?.path
            == "/Users/someone/.claude3/.claude.json",
           "a numbered home's state file is the one inside it")
}

// The gate that decides whether any of the above is reached at all (gate.swift), which is a second
// subject rather than a second kind of assertion.
checkTheFreshnessGate()

// And the parts of it that are an ORDER rather than a value, which are asserted off the source
// because neither entrance can be called from here (wiring.swift says what and why).
checkTheWiring()

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("all mcp-auth-sync tests passed")
