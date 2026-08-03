import Foundation

/// Who a Codex home is signed in as, read from that home's own `auth.json`.
///
/// The Codex CLI's status subcommand names no account (unlike `claude auth status`, it prints no
/// address and offers no JSON), so the only local answer to "which ChatGPT account is this?" is the
/// login record the CLI already wrote: `tokens.id_token` is a standard OIDC JWT whose payload
/// carries an `email` claim. Verified on this machine's two homes, 2026-08-04: three segments, an
/// `email` claim in the payload, and base64url padding genuinely needed to decode it.
///
/// SECRETS: the file holds live credentials, so this reads the ONE claim it is here for and returns
/// it. Nothing here logs, prints, writes, or carries a token, not even in an error path: every
/// failure is a plain nil, so no message can ever quote a fragment of one. The signature is not
/// verified, deliberately - the answer is used to LABEL a card, the file is this user's own, and
/// verifying would mean fetching and trusting a signing key for a decision that changes nothing
/// (a tampered file could only put a wrong address on the user's own screen).
enum CodexIdentity {
    /// The email of the account signed into `codexHome`, or nil when there is nothing to read: no
    /// `auth.json`, an API-key login (`auth_mode` with no `tokens`), or a token this cannot parse.
    /// Every one of those means the card shows no address, exactly as it did before this existed.
    static func email(codexHome: String) -> String? {
        let file = URL(fileURLWithPath: codexHome, isDirectory: true)
            .appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return email(inAuthJSON: data)
    }

    /// The same answer from the file's bytes, so the whole rule is testable against a fixture and
    /// no test needs a real credential on disk.
    static func email(inAuthJSON data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String else { return nil }
        return emailClaim(inIDToken: idToken)
    }

    /// The `email` claim of a JWT's payload, or nil for anything that is not one. An empty claim is
    /// nil too: an address nobody can read is not an identity, and showing an empty line beside a
    /// name reads as a rendering bug.
    static func emailClaim(inIDToken token: String) -> String? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, let payload = base64URLDecoded(segments[1]),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let email = claims["email"] as? String, !email.isEmpty else { return nil }
        return email
    }

    /// base64url (RFC 7515) to bytes. Two differences from plain base64, and both are load-bearing
    /// here: the alphabet swaps `-_` for `+/`, and the padding is stripped, so it has to be put
    /// back or the decoder rejects the string outright. Both of this machine's real tokens needed
    /// a pad character, so an unpadded implementation would simply never find an address.
    private static func base64URLDecoded(_ segment: Substring) -> Data? {
        var text = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)
    }
}
