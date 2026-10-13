import Foundation

// B-1736: whether a launch would meet codex's own startup update menu (CodexUpdateDecision.swift),
// decided field by field the way codex-rs decides it. `check` and `start` come from main.swift.
func runCodexUpdateChecks() {
    func cache(_ latest: String, dismissed: String? = nil) -> Data {
        let dismissedField = dismissed.map { "\"\($0)\"" } ?? "null"
        return Data("{\"latest_version\":\"\(latest)\",\"last_checked_at\":\"2026-10-13T15:07:45.678992Z\",\"dismissed_version\":\(dismissedField)}".utf8)
    }
    func need(_ cache: Data?, installed: String?, disabled: Bool = false) -> CodexUpdateNeed {
        codexUpdateNeed(candidate: codexCachedUpdateCandidate(cache: cache, checkDisabled: disabled), installed: installed)
    }

    check("U1 the failure sample's cache and binary want the update",
          need(cache("0.162.1"), installed: "0.159.2") == .available(latest: "0.162.1"))
    check("U2 a dismissed latest version is not offered", need(cache("0.162.1", dismissed: "0.162.1"), installed: "0.159.2") == .none)
    check("U2 a different dismissed version does not hide the latest",
          need(cache("0.162.1", dismissed: "0.155.1"), installed: "0.159.2") == .available(latest: "0.162.1"))
    check("U3 latest equal to installed is not offered", need(cache("0.162.1"), installed: "0.162.1") == .none)
    check("U3 latest older than installed is not offered", need(cache("0.160.0"), installed: "0.162.1") == .none)
    check("U4 a missing cache offers nothing", need(nil, installed: "0.159.2") == .none)
    check("U4 a malformed cache offers nothing", need(Data("{not json".utf8), installed: "0.159.2") == .none)
    check("U4 a prerelease latest is not comparable, as in codex", need(cache("0.163.0-alpha.1"), installed: "0.159.2") == .none)
    check("U5 a 0.0.0 source build never gets the menu", need(cache("0.162.1"), installed: "0.0.0") == .none)
    check("U5 an unreadable installed version is reported, not guessed",
          need(cache("0.162.1"), installed: nil) == .installedUnknown(latest: "0.162.1"))
    check("U6 a disabled check offers nothing", need(cache("0.162.1"), installed: "0.159.2", disabled: true) == .none)
    check("U6 no candidate means the installed version is never needed",
          codexCachedUpdateCandidate(cache: cache("0.162.1"), checkDisabled: true) == nil
              && codexCachedUpdateCandidate(cache: nil, checkDisabled: false) == nil)
    check("U7 codex --version output parses", codexVersionFromOutput("codex-cli 0.162.1\n") == "0.162.1")
    check("U7 garbage output does not parse", codexVersionFromOutput("garbage") == nil)
    check("U8 a top-level false disables the check", codexConfigDisablesUpdateCheck("model = \"x\"\ncheck_for_update_on_startup = false\n"))
    check("U8 the same key inside a table does not", !codexConfigDisablesUpdateCheck("[profiles.x]\ncheck_for_update_on_startup = false\n"))
    check("U8 true does not disable", !codexConfigDisablesUpdateCheck("check_for_update_on_startup = true\n"))
    check("U8 a commented line does not disable", !codexConfigDisablesUpdateCheck("# check_for_update_on_startup = false\n"))
    check("U8 a trailing comment still disables", codexConfigDisablesUpdateCheck("check_for_update_on_startup = false # x\n"))
    check("U9 fields compare as integers", codexIsNewer("0.162.10", than: "0.162.9") && !codexIsNewer("0.162.9", than: "0.162.10"))
    check("U10 the same version failed 5h ago backs off",
          codexUpdateBackedOff(attempt: ("0.162.1", start.addingTimeInterval(-5 * 3600)), latest: "0.162.1", now: start))
    check("U10 the same version failed 7h ago is tried again",
          !codexUpdateBackedOff(attempt: ("0.162.1", start.addingTimeInterval(-7 * 3600)), latest: "0.162.1", now: start))
    check("U10 a different version is tried at once",
          !codexUpdateBackedOff(attempt: ("0.162.0", start.addingTimeInterval(-60)), latest: "0.162.1", now: start))
}
