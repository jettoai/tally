import Foundation

// The arithmetic of seeding one config home's MCP authorizations from its siblings, with no file and
// no Keychain in sight. MCPAuthSync.swift does the reading and the writing; everything that DECIDES
// what a merged document contains is here, because these are the rules a test can state and the I/O
// is the part that cannot be.
//
// Two faces, and they are separate documents with separate rules:
//
//   - The GRANT (`mcpOAuth`, inside the credentials blob): what this machine was given when the user
//     authorized a server. Per server key, newest wins, and nothing is ever removed.
//   - The REGISTRATION (`mcpServers`, inside .claude.json): which servers this home knows about at
//     all. Add only: a key the target already has is left exactly as it is, because a registration
//     is something the user typed and a sibling's copy of it is not more correct.
//
// WHY ADD-ONLY IS THE WHOLE DELETION POLICY: a server missing from a home is indistinguishable from
// a server the user removed there, and the two ask for opposite actions. So a removal never travels
// (design doc, 2026-08-21).
//
// AND THE HONEST READING OF THAT, which the first version of this comment had backwards when it
// claimed a removal at least holds where it was made: it does not. Remove a server in one home and
// the next launch onto THAT home takes it straight back from whichever sibling still has it. Losing
// one for good means removing it in every home with none of them launched in between. A known v1
// edge rather than an oversight - the ways out (a tombstone, or recording which home a grant came
// from) are a design question - and the failure it produces is a registration the user has to remove
// twice, never a grant arriving somewhere it was not granted.

/// The key of the login credential inside the credentials blob. NAMED HERE because the one thing
/// this whole feature must never do is touch it, and a subtree that is only ever spelled at the
/// point of use is a subtree that gets spelled differently once.
let claudeLoginBlobKey = "claudeAiOauth"

/// The key of the MCP grant subtree inside the same blob: the only part of it this feature writes.
let mcpOAuthBlobKey = "mcpOAuth"

/// The registration object inside `.claude.json`, at the TOP level. Not `projects.<dir>.mcpServers`,
/// which is a per-directory list and therefore an answer about one checkout rather than about this
/// machine's account.
let mcpServersStateKey = "mcpServers"

// MARK: - Which documents a home may be addressed by

/// Whether two paths are written as the same place, by text alone.
///
/// No filesystem: this file decides names and nothing else, so two spellings of one directory that
/// only a `stat` could equate read as different here. That costs a seeding which would have been
/// allowed and never allows one that should not be, which is the direction to be wrong in.
private func pathsAreWrittenTheSame(_ one: URL, _ other: URL) -> Bool {
    one.standardizedFileURL.path == other.standardizedFileURL.path
}

/// The Keychain service holding a config home's credentials, or nil when naming it would be a guess.
///
/// `claudeKeychainService` decides "this is the default config home" on the BASENAME: any directory
/// called `.claude` is given the bare, unsuffixed service name. Claude Code gives that name to
/// exactly one directory on a machine, `~/.claude`, so the shortcut is a guess anywhere else - and
/// every caller of that helper until now only ever looked something up, where guessing wrong finds
/// nothing and reads as "not logged in". This feature WRITES. With an exported
/// `CLAUDE_CONFIG_DIR=/somewhere/else/.claude`, the guess would put the siblings' grants into the
/// DEFAULT account's credentials item while the home that was actually named went untouched.
///
/// So the shortcut is allowed only where it is true: a home that resolves to the default account's
/// service without BEING the default home is refused. A refusal is the ordinary fail-open answer -
/// that home is not seeded, and Claude Code asks for the authorization the way it does today.
///
/// The shared helper is deliberately left alone: its lookup-only callers depend on the answer it
/// gives today, and narrowing a name rule underneath them is a larger question than this feature.
func claudeSeedingKeychainService(forConfigDir dir: URL, defaultHome: URL) -> String? {
    let service = claudeKeychainService(forConfigDir: dir)
    guard service != claudeKeychainService(forConfigDir: defaultHome)
            || pathsAreWrittenTheSame(dir, defaultHome) else { return nil }
    return service
}

/// A config home's `.claude.json`, or nil when the path would be a guess, for the same reason.
///
/// `claudeStateFile` reads the same basename shortcut the other way round: the default home's state
/// file sits one level UP from it and everybody else's sits inside. So a custom `/x/.claude` resolves
/// to `/x/.claude.json` - a path that belongs to no config home at all and may well be somebody
/// else's file, which this feature would back up and rewrite.
func claudeSeedingStateFile(forConfigDir dir: URL, defaultHome: URL) -> URL? {
    let file = claudeStateFile(forConfigDir: dir)
    // Inside the directory is the ordinary spelling and always safe. One level up is the default
    // home's spelling, and only the default home may be given it.
    guard pathsAreWrittenTheSame(file.deletingLastPathComponent(), dir)
            || pathsAreWrittenTheSame(dir, defaultHome) else { return nil }
    return file
}

// MARK: - Entry portability

/// What an entry must carry for a sibling home to be able to use it.
///
/// `accessToken` is the grant. `clientId` is the IDENTITY the grant was issued to: every config home
/// performs its own dynamic client registration against an MCP server, so an entry copied without the
/// client it belongs to is a token no refresh can ever renew.
///
/// NOT `refreshToken`, though the design asked for it, and the reason is a reading of what Claude
/// Code actually writes: no `mcpOAuth` entry on this machine has one (observed 2026-08-21 across two
/// config homes, six entries, field names only). Requiring a field that is never present would make
/// this feature a no-op that looks implemented, which is the worse of the two failures. Entries are
/// copied WHOLE, so a `refreshToken` written by a future Claude Code travels with the rest.
let mcpAuthRequiredFields = ["accessToken", "clientId"]

/// Whether an entry is a copyable grant: an object carrying every required field as a non-empty
/// string. Anything else (a null left by a half-written document, a string where an object belongs,
/// a blank token) is skipped rather than copied, because the target's own state is at least honest.
func mcpEntryIsPortable(_ value: Any) -> Bool {
    guard let entry = value as? [String: Any] else { return false }
    return mcpAuthRequiredFields.allSatisfy { field in
        guard let text = entry[field] as? String else { return false }
        return !text.isEmpty
    }
}

// MARK: - Age

/// Timestamps an entry may carry, best first. All of them order the same way for one server: a grant
/// issued later expires later, so an expiry is a usable stamp for "which of these two is the newer
/// authorization" even though it is not the moment of issue.
private let mcpEntryTimeFields = ["expiresAt", "updatedAt", "issuedAt", "obtainedAt"]

/// The moment an entry claims for itself, or nil when it claims none.
///
/// Claude Code's current entries claim none (the observation above), so nil is the ordinary answer
/// and the caller falls back to the age of the document the entry came out of. Numbers only, read as
/// epoch milliseconds above the year 2001 in seconds and as epoch seconds below it: the one stamp
/// this repo has seen from Claude Code (`claudeAiOauth.expiresAt`) is milliseconds, and a bare
/// seconds value that large would be a date in the year 33000.
func mcpEntryIssuedAt(_ value: Any) -> Date? {
    guard let entry = value as? [String: Any] else { return nil }
    for field in mcpEntryTimeFields {
        guard let number = entry[field] as? Double, number > 0 else { continue }
        return Date(timeIntervalSince1970: number > 1_000_000_000_000 ? number / 1000 : number)
    }
    return nil
}

/// One config home's contribution: its grant subtree and the age of the document it was read from.
struct MCPAuthSource {
    /// The `mcpOAuth` object as stored, server key to entry.
    var entries: [String: Any]
    /// When the Keychain item holding it was last written, which is the fallback age for every entry
    /// in it. Nil when macOS would not say, which reads as "cannot tell" and never as "old".
    var writtenAt: Date?
}

/// Whether a source entry supersedes the one already in hand.
///
/// The two candidates are compared on the SAME kind of evidence or not at all: entry stamps against
/// entry stamps, document ages against document ages. A stamped entry against an unstamped one is
/// two different measurements of two different things, and ordering them would decide by which
/// Claude Code version wrote each side rather than by which grant is newer.
///
/// No comparable evidence means false, which keeps what is already there. That is the safe half of
/// this feature: adding a grant a home lacks can only save an authorization round, while replacing
/// one it has can spend one.
func mcpEntrySupersedes(source: Any, sourceWrittenAt: Date?,
                        target: Any, targetWrittenAt: Date?) -> Bool {
    if let sourceStamp = mcpEntryIssuedAt(source), let targetStamp = mcpEntryIssuedAt(target) {
        return sourceStamp > targetStamp
    }
    if let sourceStamp = sourceWrittenAt, let targetStamp = targetWrittenAt {
        return sourceStamp > targetStamp
    }
    return false
}

// MARK: - The grant merge

/// What a merge produced, and what it decided along the way.
///
/// `adopted` is SERVER KEYS and nothing else. Nothing in this file ever returns a token, an entry or
/// a fragment of one, because a caller is free to log what it gets.
struct MCPOAuthMerge {
    var entries: [String: Any]
    var adopted: [String]
    var changed: Bool { !adopted.isEmpty }
}

/// An entry as one comparable string, or nil when it will not encode.
///
/// Sorted keys for the reason `credentialBlobIsIntactApartFromGrants` gives: a dictionary's order
/// is not part of its value, so two encodings of one entry have to be made to agree before they can
/// be compared. Two entries this cannot encode compare EQUAL (both nil), which reads as "no
/// adoption" and is the safe direction: an entry that will not encode cannot be written into the
/// blob either, since the whole document is encoded as one.
func mcpEntryCanonical(_ entry: Any) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: ["v": entry],
                                                 options: [.sortedKeys]) else { return nil }
    return String(data: data, encoding: .utf8)
}

/// Fold every source's grant subtree into the target's.
///
/// Sources are taken in the order given and the caller passes them newest document first, so that an
/// entry with no age evidence on either side stays with the fresher home rather than with whichever
/// one the filesystem happened to list first.
func mergedMCPOAuth(target: MCPAuthSource, sources: [MCPAuthSource]) -> MCPOAuthMerge {
    var entries = target.entries
    // Whose document each entry currently comes from, so the second source is compared against the
    // first source's entry rather than against the target's age. Seeded with the target's own.
    var writtenAt = [String: Date?](uniqueKeysWithValues: entries.keys.map { ($0, target.writtenAt) })
    var adopted = Set<String>()

    for source in sources {
        for key in source.entries.keys.sorted() {
            let candidate = source.entries[key]!
            guard mcpEntryIsPortable(candidate) else { continue }
            if let existing = entries[key] {
                // A grant the target ALREADY HOLDS, value for value, is not an adoption however new
                // the document carrying it is. Without this the ages decide on their own, and the
                // ages move for reasons that have nothing to do with these entries: Claude Code
                // rewrites the whole item every time it refreshes the LOGIN token beside them. Every
                // launch would then rewrite a sibling's identical copy over the target's, which is
                // a Keychain write nothing asked for, at every launch, for ever.
                guard mcpEntryCanonical(candidate) != mcpEntryCanonical(existing) else { continue }
                guard mcpEntrySupersedes(source: candidate, sourceWrittenAt: source.writtenAt,
                                         target: existing,
                                         targetWrittenAt: writtenAt[key] ?? nil) else { continue }
            }
            entries[key] = candidate
            writtenAt[key] = source.writtenAt
            adopted.insert(key)
        }
    }
    return MCPOAuthMerge(entries: entries, adopted: adopted.sorted())
}

/// Whether everything except the MCP grants survived a rewrite unchanged.
///
/// The grant subtree is the one key this feature may change, so the whole of the rest of the blob is
/// what is compared - the login credential above all, which is an account's identity and the most
/// expensive thing on this machine to overwrite, but also whatever else a Claude Code puts beside it
/// now or later. Checking only the login would leave those keys riding through an unverified round
/// trip, which is exactly what the state-file face of this same feature refuses to do with the keys
/// beside ITS one key (`stateDocumentIsIntactApartFromServers`, and the two are meant to read alike).
///
/// Both sides are re-encoded with sorted keys first, because the comparison has to be about the
/// VALUE and not about the order a dictionary happened to enumerate in: Foundation's dictionaries
/// are unordered, so the same subtree encodes to different bytes on two runs and a raw byte
/// comparison would fail every time while nothing was wrong.
///
/// WHAT EQUAL HERE DOES AND DOES NOT PROVE, because it is weaker than "the bytes are identical" and
/// was once written down as if it were not: both sides are values that have already been PARSED, so
/// anything the parser normalises is gone from both of them equally and cannot be seen here - a
/// number in another spelling, one of two duplicate keys, an escape sequence re-spelled. What it does
/// prove is the load-bearing half: the value about to be written back is, field for field and inside
/// every string character for character, the value that was read.
///
/// A blob with no login in it is a shape Claude Code does not write, and one this feature must not
/// start writing either, so it is refused rather than compared. Anything that will not encode is
/// refused too: this check exists to refuse a write.
func credentialBlobIsIntactApartFromGrants(before: [String: Any], after: [String: Any]) -> Bool {
    func canonical(_ blob: [String: Any]) -> Data? {
        guard blob[claudeLoginBlobKey] != nil else { return nil }
        var rest = blob
        rest.removeValue(forKey: mcpOAuthBlobKey)
        return try? JSONSerialization.data(withJSONObject: rest, options: [.sortedKeys])
    }
    guard let one = canonical(before), let other = canonical(after) else { return false }
    return one == other
}

/// A stored document, decoded, or nil when the bytes are not a JSON object.
///
/// Nil is the fail-open answer for a truncated write, a document from a Claude Code that changed the
/// shape, and an item holding something else entirely. The caller writes nothing when it gets one.
func mcpJSONDocument(from data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// The bytes to store into the target home's credentials item, or nil when nothing should be written.
///
/// EVERY fail-open case of the grant face is decided here, which is why this is the function the
/// tests exercise: bytes that are not a document, a document with no login in it, sources that are
/// not documents or hold no grants, a merge that adopted nothing, an encode that will not decode
/// again, and an encode whose login came back different. The I/O around it (MCPAuthSync.swift) only
/// moves bytes.
///
/// Sources arrive in any order and are put in the order the merge wants (newest document first).
func seededCredentialData(target: Data, targetWrittenAt: Date?,
                          sources: [(data: Data, writtenAt: Date?)])
    -> (data: Data, adopted: [String])? {
    guard let targetBlob = mcpJSONDocument(from: target) else { return nil }
    let targetSource = MCPAuthSource(entries: targetBlob[mcpOAuthBlobKey] as? [String: Any] ?? [:],
                                     writtenAt: targetWrittenAt)
    let decoded = sources.compactMap { source -> MCPAuthSource? in
        guard let blob = mcpJSONDocument(from: source.data),
              let entries = blob[mcpOAuthBlobKey] as? [String: Any], !entries.isEmpty
        else { return nil }
        return MCPAuthSource(entries: entries, writtenAt: source.writtenAt)
    }.sorted { ($0.writtenAt ?? .distantPast) > ($1.writtenAt ?? .distantPast) }

    let merge = mergedMCPOAuth(target: targetSource, sources: decoded)
    guard merge.changed else { return nil }
    // The whole of what is written: the target's own document with one key replaced. What happens to
    // the login credential beside it is NOTHING - it is not read, not re-encoded field by field, not
    // touched, it rides along as a value copied out of the document it was decoded from.
    var next = targetBlob
    next[mcpOAuthBlobKey] = merge.entries
    // Everything but the grants is checked twice on purpose, and the second one is the load-bearing
    // one: it asks the question of the ENCODED bytes, decoded again, which is what will actually be
    // stored. An encoder that dropped part of the login, or re-typed a number inside it, is caught
    // here rather than in somebody's next login.
    guard credentialBlobIsIntactApartFromGrants(before: targetBlob, after: next),
          let data = try? JSONSerialization.data(withJSONObject: next),
          let stored = mcpJSONDocument(from: data),
          credentialBlobIsIntactApartFromGrants(before: targetBlob, after: stored)
    else { return nil }
    return (data, merge.adopted)
}

// MARK: - The registration merge

/// What a registration merge produced. `added` is server names, which are not secrets: they are the
/// words the user typed into `claude mcp add`.
struct MCPServersMerge {
    var servers: [String: Any]
    var added: [String]
    var changed: Bool { !added.isEmpty }
}

/// Fold every source's `mcpServers` into the target's, adding only what the target lacks.
///
/// Sources newest document first, same as the grant merge: with two siblings offering the same
/// missing name, the one whose state file was written last is the one whose definition of it lands.
func mergedMCPServers(target: [String: Any], sources: [[String: Any]]) -> MCPServersMerge {
    var servers = target
    var added: [String] = []
    for source in sources {
        for name in source.keys.sorted() {
            guard servers[name] == nil, source[name] is [String: Any] else { continue }
            servers[name] = source[name]
            added.append(name)
        }
    }
    return MCPServersMerge(servers: servers, added: added.sorted())
}

/// Whether a state document came through a rewrite with everything but the registration untouched.
///
/// The registration is the one key this feature may change, and the file around it is the user's
/// whole Claude Code state: the trusted folders, the tips history, the per-project settings, six
/// figures of bytes of it. So the rest is compared the way the credentials blob's rest is compared,
/// with the same reach and the same limits (`credentialBlobIsIntactApartFromGrants` states both),
/// rather than trusted to a round trip nobody looked at.
func stateDocumentIsIntactApartFromServers(before: [String: Any], after: [String: Any]) -> Bool {
    func canonical(_ document: [String: Any]) -> Data? {
        var rest = document
        rest.removeValue(forKey: mcpServersStateKey)
        return try? JSONSerialization.data(withJSONObject: rest, options: [.sortedKeys])
    }
    guard let one = canonical(before), let other = canonical(after) else { return false }
    return one == other
}

/// The bytes to store into the target home's state file, or nil when nothing should be written.
///
/// The registration face's whole decision, for the reason `seededCredentialData` gives about the
/// grant face. Written pretty printed because that is how Claude Code keeps this file, and a
/// launcher that silently reflowed a 200 KB document into one line would make every later reading of
/// it unusable.
func seededStateData(target: Data, sources: [(data: Data, writtenAt: Date)])
    -> (data: Data, added: [String])? {
    guard let state = mcpJSONDocument(from: target) else { return nil }
    let decoded = sources.compactMap { source -> (servers: [String: Any], writtenAt: Date)? in
        guard let document = mcpJSONDocument(from: source.data),
              let servers = document[mcpServersStateKey] as? [String: Any], !servers.isEmpty
        else { return nil }
        return (servers, source.writtenAt)
    }.sorted { $0.writtenAt > $1.writtenAt }

    let merge = mergedMCPServers(target: state[mcpServersStateKey] as? [String: Any] ?? [:],
                                 sources: decoded.map(\.servers))
    guard merge.changed else { return nil }
    var next = state
    next[mcpServersStateKey] = merge.servers
    guard let data = try? JSONSerialization.data(withJSONObject: next,
                                                 options: [.prettyPrinted, .withoutEscapingSlashes]),
          let stored = mcpJSONDocument(from: data),
          stateDocumentIsIntactApartFromServers(before: state, after: stored)
    else { return nil }
    return (data, merge.added)
}
