import Foundation

/// Who a Codex home is signed in as, taken from the official CLI's own answer.
///
/// The Codex CLI's status subcommand names no account (unlike `claude auth status`, it prints no
/// address and offers no JSON), so for a while the only answer looked like the login record the CLI
/// writes. It is not: the app-server Tally already polls for usage answers `account/read` with
/// `result.account.email`, from the same session, over the same pipe. Verified live against
/// codex-cli 0.146.0 on 2026-08-04: `{"result":{"account":{"email":…,"planType":…,"type":"chatgpt"},
/// "requiresOpenaiAuth":true}}`.
///
/// CREDENTIALS: nothing here opens `auth.json`. That is the promise the README and
/// `CodexAccounts` make - discovery checks only that the file EXISTS - and asking the CLI keeps it,
/// because the CLI is the one process that is supposed to hold those tokens. This parser sees an
/// address and three harmless strings, and never a token, so no failure path here could quote one:
/// every failure is a plain nil.
enum CodexIdentity {
    /// The email in an `account/read` response line, or nil for anything else: an error answer, a
    /// version of the CLI that does not know the method, a login with no address on it. Every one
    /// of those means the card shows no address, exactly as it did before this existed.
    ///
    /// An empty address is nil too: an address nobody can read is not an identity, and showing a
    /// blank line beside a name reads as a rendering bug.
    static func email(inAccountRead data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let account = result["account"] as? [String: Any],
              let email = account["email"] as? String, !email.isEmpty else { return nil }
        return email
    }
}
