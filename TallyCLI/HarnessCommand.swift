import Foundation

struct HarnessArguments {
    let verb: String
    private(set) var values: [String: String] = [:]
    private(set) var flags: Set<String> = []

    init(_ args: [String], options: Set<String>, switches: Set<String> = []) throws {
        guard let verb = args.first, !verb.hasPrefix("-") else { throw HarnessError("Specify a subcommand. See tally help.") }
        self.verb = verb
        var index = 1
        while index < args.count {
            let name = args[index]
            guard values[name] == nil, !flags.contains(name) else { throw HarnessError("Duplicate option: \(name)") }
            if switches.contains(name) { flags.insert(name); index += 1; continue }
            guard options.contains(name), index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                throw HarnessError("Unknown option or missing value: \(name)")
            }
            values[name] = args[index + 1]; index += 2
        }
    }

    func required(_ name: String) throws -> String {
        guard let value = values[name], !value.isEmpty else { throw HarnessError("Required option: \(name)") }
        return value
    }

    func path(_ name: String, fallback: String) throws -> String {
        let value = values[name] ?? fallback
        guard value.hasPrefix("/"), !value.contains("\0"), !value.contains("\n") else {
            throw HarnessError("Use an absolute path for \(name).")
        }
        return HarnessIO.canonical(value)
    }

    func only(_ options: Set<String>, switches: Set<String> = []) throws {
        guard Set(values.keys).isSubset(of: options), flags.isSubset(of: switches) else {
            throw HarnessError("An option does not apply to \(verb).")
        }
    }

    static func home(_ provider: String) -> String {
        let env = ProcessInfo.processInfo.environment
        return env[provider == "codex" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path + "/." + provider
    }

    static var stateRoot: String { FileManager.default.homeDirectoryForCurrentUser.path + "/.tally/harness" }

    func location() throws -> HarnessLocation {
        let scope = values["--scope"] ?? "user"
        if scope == "project" && values["--project"] == nil { throw HarnessError("Project scope requires an explicit --project path.") }
        if scope != "project" && values["--project"] != nil { throw HarnessError("Use --scope project with --project.") }
        return try HarnessLocation(scope: scope,
            sourceHome: path("--source-home", fallback: Self.home("claude")),
            targetHome: path("--target-home", fallback: Self.home("codex")),
            project: values["--project"].map { _ in try path("--project", fallback: "") },
            sharedSkills: path("--skills-root", fallback: FileManager.default.homeDirectoryForCurrentUser.path + "/.agents/skills"),
            stateRoot: path("--state-root", fallback: Self.stateRoot))
    }
}

func harnessPrint(_ value: Any) throws {
    var data = try HarnessIO.json(value); data.append(10)
    FileHandle.standardOutput.write(data)
}

func harnessError(_ error: Error) -> Int32 {
    FileHandle.standardError.write(Data(("tally: " + error.localizedDescription + "\n").utf8))
    return 2
}

func runHarness(args: [String]) -> Int32 {
    if args.first == "tools" { return runHarnessTools(args: Array(args.dropFirst())) }
    do {
        let locationOptions: Set<String> = ["--scope", "--source-home", "--target-home", "--project", "--skills-root", "--state-root"]
        let parsed = try HarnessArguments(args, options: locationOptions.union(["--file", "--request", "--authorization", "--manifest"]),
                                          switches: ["--confirm-git-visible"])
        switch parsed.verb {
        case "record":
            try parsed.only(["--file", "--state-root"])
            let path = try parsed.path("--file", fallback: "")
            guard let data = try HarnessIO.data(path, limit: 65_536) else { throw HarnessError("Evaluation file not found.") }
            let result = try HarnessEvaluation.record(data, root: parsed.path("--state-root", fallback: HarnessArguments.stateRoot))
            try harnessPrint(result)
        case "grant":
            try parsed.only(["--request", "--authorization", "--manifest"])
            try harnessPrint(HarnessApproval.grant(parsed.required("--request"),
                authorization: parsed.required("--authorization"), manifestPath: parsed.path("--manifest", fallback: "")))
        case "plan", "status", "install", "remove":
            try parsed.only(locationOptions, switches: parsed.verb == "install" ? ["--confirm-git-visible"] : [])
            let location = try parsed.location()
            switch parsed.verb {
            case "plan": try harnessPrint(HarnessIO.object(HarnessIO.encode(HarnessInventory.plan(location))))
            case "status": try harnessPrint(HarnessInstallation.status(location))
            case "remove": try harnessPrint(HarnessInstallation.remove(location))
            default:
                let executable = HarnessIO.canonical(CommandLine.arguments[0])
                let manifest = try HarnessInstallation.install(HarnessInventory.plan(location), executable: executable,
                    confirmGitVisible: parsed.flags.contains("--confirm-git-visible"))
                try harnessPrint(["state": manifest.phase, "manifest": manifest.location.manifestPath,
                                  "nativeTrust": "verify-in-codex-hooks"])
            }
        default: throw HarnessError("Unknown harness subcommand. Use plan, status, install, remove, grant, or record.")
        }
        return 0
    } catch { return harnessError(error) }
}
