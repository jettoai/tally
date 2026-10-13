import Foundation

// The declared default provider (B-1706): what `tally project set --default` writes, what
// `tally start` and a `tally session clear` read back, and what `tally project clear` drops.
// Lives outside main.swift to keep that file under the line cap.

func runDefaultProviderChecks(repoKey: String) {
    let legacy = try? JSONDecoder().decode(ProjectPolicyFile.self,
                                           from: Data(#"{"version":1,"projects":{}}"#.utf8))
    check("a file written before `defaults` existed decodes with none", legacy?.defaults == [:])
    let withDefault = ProjectPolicyFile(projects: [:], defaults: [repoKey: "codex"])
    let roundTripped = try? JSONDecoder().decode(ProjectPolicyFile.self,
                                                 from: JSONEncoder().encode(withDefault))
    check("a declared default survives a round trip", roundTripped?.defaults == [repoKey: "codex"])
    check("the default is read back for its project",
          projectDefaultProvider(withDefault, key: repoKey) == "codex"
              && projectDefaultProvider(withDefault, key: "/nowhere") == nil)
    check("a provider this build does not know is no default",
          projectDefaultProvider(ProjectPolicyFile(defaults: [repoKey: "gemini"]), key: repoKey) == nil)
    var clearing = withDefault
    check("`clear --provider claude` leaves a codex default alone",
          !clearProjectDefault(&clearing, key: repoKey, provider: "claude") && clearing.defaults[repoKey] == "codex")
    check("`clear --provider codex` drops a codex default",
          clearProjectDefault(&clearing, key: repoKey, provider: "codex") && clearing.defaults[repoKey] == nil)
    clearing = withDefault
    check("a bare `clear` drops the default whatever it is",
          clearProjectDefault(&clearing, key: repoKey, provider: nil) && clearing.defaults.isEmpty)
}
