import Foundation

// The Artifact publishing guard, RETIRED (Tally/Stores/IntegrationsArtifactHook.swift): what is left
// is taking the `PreToolUse` registration older versions wrote back out of every settings.json.
//
// Everything asserted here is about the SURGERY: settings.json is the user's own file, holding their
// whole harness, so only our own line may go, a file without it is never written, and a file nobody
// can parse is left alone and remembered for the next launch.
@MainActor
func runArtifactHookRetirementChecks(tmp: URL) throws {
    let dir = tmp.appendingPathComponent("artifact-retirement")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let event = "PreToolUse"
    let ours: [String: Any] = ["type": "command", "command": "/usr/local/bin/tally hook-artifact"]
    let ourEntry: [String: Any] = ["matcher": "Artifact", "hooks": [ours]]
    let theirs: [String: Any] = ["type": "command", "command": "/opt/bin/watch-artifacts"]
    let lookalike: [String: Any] = ["type": "command", "command": "/opt/bin/my-hook-artifact"]
    let knockEntry: [String: Any] = ["hooks": [["type": "command",
                                                "command": "/usr/local/bin/tally hook-knock PreToolUse"]]]

    func document(_ file: URL) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]
    }
    func entries(_ file: URL, _ name: String = event) -> [[String: Any]] {
        ((document(file)["hooks"] as? [String: Any])?[name] as? [[String: Any]]) ?? []
    }
    func commands(_ file: URL, _ name: String = event) -> [String] {
        entries(file, name).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
    }
    func write(_ object: [String: Any], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: file)
    }
    func mtime(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    // MARK: T1 - only our line goes

    let alone = dir.appendingPathComponent("alone.json")
    let shared = dir.appendingPathComponent("shared.json")
    let knockOnly = dir.appendingPathComponent("knock-only.json")
    try write(["hooks": [event: [ourEntry],
                         "PostToolUse": [["hooks": [["type": "command", "command": "/opt/bin/x"]]]]],
               "statusLine": ["type": "command", "command": "/opt/bin/my-status-line"]], to: alone)
    try write(["hooks": [event: [["matcher": "Artifact", "hooks": [theirs, ours, lookalike]],
                                 knockEntry]]], to: shared)
    try write(["hooks": [event: [knockEntry]]], to: knockOnly)
    let knockBytes = try Data(contentsOf: knockOnly)
    var pass = IntegrationsStore.removeArtifactHook(from: [alone, shared, knockOnly])
    check("retirement: a pass over readable files finishes", pass.remembered == nil && pass.failure == nil)
    check("retirement: an entry that was ours alone goes, with its emptied event",
          entries(alone).isEmpty && commands(alone, "PostToolUse") == ["/opt/bin/x"])
    check("…and nothing else in the document moves",
          (document(alone)["statusLine"] as? [String: Any])?["command"] as? String
              == "/opt/bin/my-status-line")
    check("retirement: a shared entry loses only our line and keeps its matcher",
          entries(shared).contains { $0["matcher"] as? String == "Artifact" }
              && commands(shared) == ["/opt/bin/watch-artifacts", "/opt/bin/my-hook-artifact",
                                      "/usr/local/bin/tally hook-knock PreToolUse"])
    check("retirement: a knock PreToolUse entry beside it is untouched",
          entries(shared).contains { NSDictionary(dictionary: $0).isEqual(to: knockEntry) })

    // MARK: T2 - a file with nothing of ours is not written

    check("retirement: a file with nothing of ours keeps its bytes",
          (try? Data(contentsOf: knockOnly)) == knockBytes)
    let before = mtime(knockOnly)
    check("…and is not written at all",
          try IntegrationsStore.editSettings(knockOnly) {
              IntegrationsStore.settingsWithoutArtifactHook($0)
          } == false && mtime(knockOnly) == before)

    // MARK: T3 - one physical file behind two homes

    let real = dir.appendingPathComponent("real.json")
    let link = dir.appendingPathComponent("link.json")
    try write(["hooks": [event: [ourEntry]]], to: real)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let population = IntegrationsStore.notificationHookSettingsFiles(discovered: [link],
                                                                    remembered: [real.path])
    check("retirement: a symlinked home and its target are one file to the pass", population.count == 1)
    pass = IntegrationsStore.removeArtifactHook(from: population)
    check("…the target loses our entry", pass.remembered == nil && commands(real).isEmpty)
    check("…and the link is still a link",
          (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)

    // MARK: T4 - unreadable is left alone and remembered, without stopping the pass

    let broken = dir.appendingPathComponent("broken.json")
    let healthy = dir.appendingPathComponent("healthy.json")
    let brokenBytes = Data("{ not json".utf8)
    try brokenBytes.write(to: broken)
    try write(["hooks": [event: [ourEntry]]], to: healthy)
    pass = IntegrationsStore.removeArtifactHook(from: [broken, healthy])
    check("retirement: a file nobody can parse is left exactly as it was",
          (try? Data(contentsOf: broken)) == brokenBytes)
    check("…and stays on the retry list", pass.remembered == [broken.path] && pass.failure != nil)
    check("…while the file after it is still cleared", commands(healthy).isEmpty)

    // MARK: T5 - a second pass is a no-op

    let files = [alone, shared, knockOnly]
    let stamps = files.map(mtime)
    pass = IntegrationsStore.removeArtifactHook(from: files)
    check("retirement: a second pass finishes with nothing to remember", pass.remembered == nil)
    check("…and writes none of the files", files.map(mtime) == stamps)

    // MARK: T6, T7, T12 - the wiring, read rather than run

    let sourceRoot = URL(fileURLWithPath: #filePath)   // tests/integrations/artifacthookchecks.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func source(_ name: String) -> String {
        (try? String(contentsOf: sourceRoot.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }
    func body(_ text: String, from marker: String) -> String {
        guard let start = text.range(of: marker) else { return "" }
        let rest = text[start.lowerBound...]
        let end = rest.range(of: "\n    }\n")?.upperBound ?? rest.endIndex
        return String(rest[..<end])
    }
    let retire = body(source("Tally/Stores/IntegrationsArtifactHook.swift"),
                      from: "func retireArtifactHook()")
    check("retirement: the pass never runs on a build nobody installed, nor on fixtures",
          retire.contains("BuildVariant.isUnshipped") && retire.contains("DemoUsage.isActive"))
    let delegate = source("Tally/App/AppDelegate.swift")
    if let follow = delegate.range(of: "IntegrationsStore.shared.followNewIntegrations()"),
       let retireCall = delegate.range(of: "IntegrationsStore.shared.retireArtifactHook()") {
        check("retirement: launch runs it after the follow pass",
              follow.upperBound <= retireCall.lowerBound)
    } else {
        check("retirement: launch runs it after the follow pass", false)
    }
    let dispatch = source("TallyCLI/HookDispatch.swift")
    check("retirement: the CLI still answers the old subcommand, silently and successfully",
          dispatch.contains("""
            case "hook-artifact":
                    _ = FileHandle.standardInput.readDataToEndOfFile()
                    return 0
            """) && !dispatch.contains("runHookArtifact"))
    let policy = source("Tally/Stores/LaunchPolicyStore.swift")
    check("retirement: state.json keeps the old key and writes it back untouched",
          policy.contains("var artifactAccount: String?")
              && policy.contains("artifactAccount: retiredArtifactAccount")
              && !policy.contains("func setArtifactAccount"))
}
